import Foundation
import Observation

@MainActor
public protocol TrackerHistoryReading: AnyObject, Sendable {
    var historyConnectionID: String? { get }
    var historySyncIdentity: TrackerHistorySyncIdentity? { get }
    func historySnapshot(expectedConnectionID: String) async throws -> TrackerHistorySnapshot
}

public extension TrackerHistoryReading {
    var historySyncIdentity: TrackerHistorySyncIdentity? { nil }
}

@MainActor
public protocol TrackerHistorySyncReading: TrackerHistoryReading {
    var historySyncTrackerID: String { get }
    var historySyncNamespace: String? { get }
    var historySyncCategories: Set<TrackerHistorySyncCategory> { get }
    /// Revoke the old connection's permission before removing or replacing its credential.
    var onHistorySyncDisconnect: (@MainActor () throws -> Void)? { get set }
}

public extension TrackerHistorySyncReading {
    var historySyncCategories: Set<TrackerHistorySyncCategory> { [.watched, .resume] }
}

/// One visible comparison/approval session. Closing it revokes undelivered work.
@MainActor
@Observable
public final class TrackerHistoryImportSession {
    public struct Destination: Identifiable, Sendable {
        public let id: String
        public let serverName: String
        public let userName: String
        public init(id: String, serverName: String, userName: String) {
            self.id = id
            self.serverName = serverName
            self.userName = userName
        }
    }
    public enum Outcome: Equatable, Sendable { case queued, confirmed, unconfirmed }
    public private(set) var plan: TrackerHistoryImportPlan?
    public private(set) var isBusy = false
    public private(set) var error: (any Error)?
    public private(set) var outcomes: [UUID: Outcome] = [:]
    public let destinations: [Destination]
    public let scope: WatchMutationServerScope
    public var ongoingSync: TrackerHistorySyncController?
    private let reconciler: WatchStateReconciler
    private let readSnapshot: @MainActor @Sendable () async throws -> TrackerHistorySnapshot
    private let index: @MainActor @Sendable () -> IdentityIndexSnapshot
    private let resolveProvider: @MainActor @Sendable (String) throws -> any MediaProvider
    private let isAuthorized: @MainActor @Sendable () -> Bool
    private var generation = UUID()
    private var isOpen = true
    private var approvedGeneration: UUID?

    public init(
        scope: WatchMutationServerScope, destinations: [Destination], reconciler: WatchStateReconciler,
        readSnapshot: @escaping @MainActor @Sendable () async throws -> TrackerHistorySnapshot,
        index: @escaping @MainActor @Sendable () -> IdentityIndexSnapshot,
        resolveProvider: @escaping @MainActor @Sendable (String) throws -> any MediaProvider,
        isAuthorized: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.scope = scope
        self.destinations = destinations
        self.reconciler = reconciler
        self.readSnapshot = readSnapshot
        self.index = index
        self.resolveProvider = resolveProvider
        self.isAuthorized = isAuthorized
    }

    public func cancel() {
        isOpen = false
        generation = UUID()
        approvedGeneration = nil
        finishUnconfirmedOutcomes()
        plan = nil
        isBusy = false
    }

    private func finishUnconfirmedOutcomes() {
        outcomes = outcomes.mapValues { $0 == .queued ? .unconfirmed : $0 }
    }

    private func requireCurrent(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard isOpen, self.generation == generation, isAuthorized() else { throw TrackerHistoryError.scopeChanged }
    }

    public func compare(
        selectingRecords: (@MainActor (TrackerHistorySnapshot) throws -> Set<String>)? = nil
    ) async {
        guard !isBusy else { return }
        generation = UUID()
        let current = generation
        approvedGeneration = nil
        plan = nil
        error = nil
        outcomes = [:]
        isBusy = true
        defer { if generation == current { isBusy = false } }
        do {
            try requireCurrent(current)
            let snapshot = try await readSnapshot()
            try requireCurrent(current)
            let selectedRecords = try selectingRecords?(snapshot)
            let candidates = try await candidates(for: snapshot, recordIDs: selectedRecords, generation: current)
            try requireCurrent(current)
            plan = TrackerHistoryImportPlan(snapshot: snapshot, serverScope: scope, candidates: candidates)
        } catch {
            if generation == current {
                self.error = error
            }
        }
    }

    public func snapshotAfterReview(_ reviewed: TrackerHistorySnapshot) async throws -> TrackerHistorySnapshot {
        let current = generation
        try requireCurrent(current)
        guard !isBusy else { throw TrackerHistoryError.stalePreview }
        let snapshot = try await readSnapshot()
        try requireCurrent(current)
        guard snapshot.trackerID == reviewed.trackerID,
              snapshot.connectionID == reviewed.connectionID,
              Dictionary(uniqueKeysWithValues: snapshot.observations.map { ($0.recordID, $0) })
                == Dictionary(uniqueKeysWithValues: reviewed.observations.map { ($0.recordID, $0) }) else {
            throw TrackerHistoryError.stalePreview
        }
        return snapshot
    }

    public func apply(
        rowIDs: Set<UUID>, overridingConflicts: Set<UUID>, confirmsDestructiveChanges: Bool
    ) async {
        guard !isBusy else { return }
        let current = generation
        error = nil
        isBusy = true
        defer {
            if generation == current {
                approvedGeneration = nil
                finishUnconfirmedOutcomes()
                isBusy = false
            }
        }
        do {
            try requireCurrent(current)
            guard let plan, outcomes.isEmpty else { throw TrackerHistoryError.stalePreview }
            let approval = try plan.approve(
                rowIDs: rowIDs, overridingConflicts: overridingConflicts,
                confirmsDestructiveChanges: confirmsDestructiveChanges
            )
            let latest = try await readSnapshot()
            try requireCurrent(current)
            try Self.validateTrackerEvidence(plan: plan, selected: approval.rows, latest: latest)
            approvedGeneration = current
            let mutations = try approval.mutations(
                currentScope: scope, currentTrackerID: plan.snapshot.trackerID,
                currentConnectionID: plan.snapshot.connectionID, owner: self,
                validate: { owner, scope, _, _, row in
                    await owner.allowsDelivery(scope: scope, generation: current, row: row)
                },
                loadCurrentItem: { owner, provider, row in
                    guard let target = row.target else { throw TrackerHistoryError.invalidSelection }
                    return try await owner.freshItem(provider: provider, target: target, generation: current)
                }
            )
            for (row, mutation) in zip(approval.rows, mutations) {
                try requireCurrent(current)
                let accepted = await reconciler.enqueue(mutation)
                try requireCurrent(current)
                outcomes[row.id] = accepted ? .queued : .unconfirmed
            }
            await reconciler.drainAndWait()
            try requireCurrent(current)
            try await readBack(rows: approval.rows, generation: current)
            approvedGeneration = nil
        } catch {
            if generation == current {
                approvedGeneration = nil
                self.error = error
            }
        }
    }

    private static func validateTrackerEvidence(
        plan: TrackerHistoryImportPlan, selected: [TrackerHistoryImportPlan.Row], latest: TrackerHistorySnapshot
    ) throws {
        guard latest.trackerID == plan.snapshot.trackerID,
              latest.connectionID == plan.snapshot.connectionID else { throw TrackerHistoryError.scopeChanged }
        let recordIDs = Set(selected.flatMap(\.recordIDs))
        var identities: [MediaItemKind: Set<MediaIdentity>] = [:]
        for observation in plan.snapshot.observations where recordIDs.contains(observation.recordID) {
            identities[observation.kind, default: []].formUnion(observation.identities)
        }
        func relevant(_ snapshot: TrackerHistorySnapshot) -> [String: TrackerHistoryObservation] {
            Dictionary(uniqueKeysWithValues: snapshot.observations.compactMap { observation in
                guard recordIDs.contains(observation.recordID)
                    || identities[observation.kind]?.isDisjoint(with: observation.identities) == false else { return nil }
                return (observation.recordID, observation)
            })
        }
        // Include competing records for selected titles, not just the chosen
        // play ID. A newly added resume can invalidate an older watched preview.
        guard relevant(plan.snapshot) == relevant(latest) else { throw TrackerHistoryError.stalePreview }
    }

    private func allowsDelivery(
        scope: WatchMutationServerScope, generation: UUID, row: TrackerHistoryImportPlan.Row
    ) async -> Bool {
        guard self.scope == scope, approvedGeneration == generation, self.generation == generation,
              isOpen, isAuthorized(), let target = row.target else { return false }
        let playing = await reconciler.isLiveSession(
            accountID: target.accountID, itemID: target.itemID, serverScope: scope
        )
        return !playing && isOpen && self.generation == generation && isAuthorized()
    }

    private func readBack(rows: [TrackerHistoryImportPlan.Row], generation: UUID) async throws {
        for row in rows where outcomes[row.id] == .queued {
            try requireCurrent(generation)
            guard let target = row.target, let change = row.change else { throw TrackerHistoryError.invalidSelection }
            let provider = try resolveProvider(target.accountID)
            let item = try await freshItem(provider: provider, target: target, generation: generation)
            let confirmed: Bool
            switch change {
            case .watched(let value): confirmed = item.isPlayed == value
            case .resume(let value):
                confirmed = item.resumePosition.map { abs($0 - value) <= 0.5 } ?? (value == 0)
            }
            outcomes[row.id] = row.observation.matches(item) && confirmed ? .confirmed : .unconfirmed
        }
    }

    private func candidates(
        for snapshot: TrackerHistorySnapshot, recordIDs: Set<String>?, generation: UUID
    ) async throws -> [TrackerServerHistoryCandidate] {
        let snapshotIndex = index()
        let permitted = Set(scope.accounts.map(\.accountID))
        guard permitted.isSubset(of: snapshotIndex.indexedAccountIDs) else { throw TrackerHistoryError.incompleteSnapshot }
        var targets: Set<WatchMutationTarget> = []
        var walkedSeries: Set<WatchMutationTarget> = []
        for observation in snapshot.observations where recordIDs.map({ $0.contains(observation.recordID) }) ?? true {
            try requireCurrent(generation)
            for source in snapshotIndex.sources(forIdentities: observation.identities, kind: observation.kind)
            where permitted.contains(source.accountID) {
                targets.insert(source.target)
            }
            guard observation.kind == .episode else { continue }
            for source in snapshotIndex.sources(forIdentities: observation.seriesIdentities, kind: .series)
            where permitted.contains(source.accountID) && walkedSeries.insert(source.target).inserted {
                let provider = try resolveProvider(source.accountID)
                let children = try await provider.children(of: source.itemID)
                try requireCurrent(generation)
                for child in children {
                    if child.kind == .episode {
                        targets.insert(.init(accountID: source.accountID, itemID: child.id, providerKind: source.providerKind))
                    } else if child.kind == .season {
                        let episodes = try await provider.children(of: child.id)
                        try requireCurrent(generation)
                        for episode in episodes where episode.kind == .episode {
                            targets.insert(.init(accountID: source.accountID, itemID: episode.id, providerKind: source.providerKind))
                        }
                    }
                }
            }
        }
        var result: [TrackerServerHistoryCandidate] = []
        for target in targets.sorted(by: { $0.id < $1.id }) {
            try requireCurrent(generation)
            let provider = try resolveProvider(target.accountID)
            let item = try await freshItem(provider: provider, target: target, generation: generation)
            let isPlaying = await reconciler.isLiveSession(
                accountID: target.accountID, itemID: target.itemID, serverScope: scope
            )
            try requireCurrent(generation)
            result.append(.init(
                accountID: target.accountID, item: item,
                canWriteWatched: provider is any WatchStateProviding || provider is any PlayedStateWriting,
                canWriteResume: provider is any ResumeStateWriting, isPlaying: isPlaying
            ))
        }
        return result
    }

    private func freshItem(
        provider: any MediaProvider, target: WatchMutationTarget, generation: UUID
    ) async throws -> MediaItem {
        try await TrackerServerHistorySource.freshItem(
            provider: provider, accountID: target.accountID, itemID: target.itemID,
            validate: { try self.requireCurrent(generation) }
        )
    }
}
