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
public protocol TrackerHistorySyncReading: TrackerHistoryReading, TrackerActivationControlling {
    /// Changes on resume; work admitted before a pause must not restart.
    var historyActivationID: String? { get }
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
    public enum Purpose: Sendable { case enrollment, transfer }
    public struct Destination: Identifiable, Sendable {
        public let id: String
        public let serverName: String
        public let userName: String
        public let transportKind: MediaShareTransportKind?
        public init(id: String, serverName: String, userName: String, transportKind: MediaShareTransportKind? = nil) {
            self.id = id
            self.serverName = serverName
            self.userName = userName
            self.transportKind = transportKind
        }

        public init(account: Account, userName: String? = nil) {
            self.init(
                id: account.id, serverName: account.server.name, userName: userName ?? account.userName,
                transportKind: account.server.provider == .mediaShare
                    ? MediaShareTransportKind(mediaShareScheme: account.server.baseURL.scheme) : nil
            )
        }
    }
    public enum Outcome: Equatable, Sendable { case queued, confirmed, unconfirmed }
    public private(set) var plan: TrackerHistoryImportPlan?
    public private(set) var isBusy = false
    public private(set) var error: (any Error)?
    public private(set) var outcomes: [UUID: Outcome] = [:]
    private(set) var confirmedBaselines: [UUID: TrackerServerHistoryBaseline] = [:]
    public let destinations: [Destination]
    public let scope: WatchMutationServerScope
    public var ongoingSync: TrackerHistorySyncController?
    private let purpose: Purpose
    private let reconciler: WatchStateReconciler
    private let readSnapshot: @MainActor @Sendable () async throws -> TrackerHistorySnapshot
    private let index: @MainActor @Sendable () -> IdentityIndexSnapshot
    private let resolveProvider: @MainActor @Sendable (String) throws -> any MediaProvider
    private let isAuthorized: @MainActor @Sendable () -> Bool
    private var generation = UUID()
    private var isOpen = true
    private var approvedGeneration: UUID?

    public init(
        purpose: Purpose = .transfer,
        scope: WatchMutationServerScope, destinations: [Destination], reconciler: WatchStateReconciler,
        readSnapshot: @escaping @MainActor @Sendable () async throws -> TrackerHistorySnapshot,
        index: @escaping @MainActor @Sendable () -> IdentityIndexSnapshot,
        resolveProvider: @escaping @MainActor @Sendable (String) throws -> any MediaProvider,
        isAuthorized: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.purpose = purpose
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
        confirmedBaselines = [:]
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
        await compare(snapshot: nil, selectingRecords: selectingRecords)
    }

    func compare(
        snapshot initial: TrackerHistorySnapshot?,
        selectingRecords: (@MainActor (TrackerHistorySnapshot) throws -> Set<String>)?
    ) async {
        guard purpose == .transfer else { error = TrackerHistoryError.invalidSelection; return }
        guard !isBusy else { return }
        generation = UUID()
        let current = generation
        approvedGeneration = nil
        plan = nil
        error = nil
        outcomes = [:]
        confirmedBaselines = [:]
        isBusy = true
        defer { if generation == current { isBusy = false } }
        do {
            try requireCurrent(current)
            let snapshot: TrackerHistorySnapshot
            if let initial { snapshot = initial } else { snapshot = try await readSnapshot() }
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

    func enrollmentSnapshot(validating: @MainActor () throws -> Void = {}) async throws -> TrackerHistorySnapshot {
        let current = generation
        try requireCurrent(current)
        guard !isBusy else { throw TrackerHistoryError.stalePreview }
        try validating()
        let snapshot = try await readSnapshot()
        try requireCurrent(current)
        return snapshot
    }

    func snapshotAfterReview(_ reviewed: TrackerHistorySnapshot) async throws -> TrackerHistorySnapshot {
        let snapshot = try await enrollmentSnapshot()
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
        await apply(rowIDs: rowIDs, overridingConflicts: overridingConflicts,
                    confirmsDestructiveChanges: confirmsDestructiveChanges, continuingCheck: false)
    }

    func apply(
        rowIDs: Set<UUID>, overridingConflicts: Set<UUID>, confirmsDestructiveChanges: Bool, continuingCheck: Bool
    ) async {
        guard purpose == .transfer else { error = TrackerHistoryError.invalidSelection; return }
        guard !isBusy else { return }
        // A queued, unconfirmed mutation from the preceding batch must never
        // become authorized again while delivering a different batch.
        generation = UUID()
        let current = generation
        let sync = ongoingSync
        let syncGrantID = sync?.isEnabled == true ? sync?.grant?.id : nil
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
            guard let plan, outcomes.isEmpty || (continuingCheck && rowIDs.isDisjoint(with: outcomes.keys))
            else { throw TrackerHistoryError.stalePreview }
            let approval = try plan.approve(
                rowIDs: rowIDs, overridingConflicts: overridingConflicts,
                confirmsDestructiveChanges: confirmsDestructiveChanges
            )
            let revisionIsCurrent = continuingCheck ? try await plan.snapshot.isStillCurrent?() : nil
            if revisionIsCurrent != true {
                let latest = try await readSnapshot()
                try requireCurrent(current)
                try Self.validateTrackerEvidence(plan: plan, selected: approval.rows, latest: latest)
            }
            try requireCurrent(current)
            approvedGeneration = current
            let mutations = try approval.mutations(
                currentScope: scope, currentTrackerID: plan.snapshot.trackerID,
                currentConnectionID: plan.snapshot.connectionID, owner: self,
                validate: { owner, scope, _, _, row in
                    await owner.allowsDelivery(scope: scope, generation: current, row: row)
                },
                loadCurrentItem: { owner, provider, row in
                    guard let target = row.target else { throw TrackerHistoryError.invalidSelection }
                    return try await owner.freshItem(provider: provider, target: target, generation: current,
                                                     needsDuration: row.baseline?.runtime != nil)
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
            try sync?.recordReviewedImport(plan, baselines: confirmedBaselines, expectedGrantID: syncGrantID)
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
        var resumed: Set<WatchMutationTarget> = []
        for row in rows where outcomes[row.id] == .queued {
            try requireCurrent(generation)
            guard let target = row.target, let change = row.change else { throw TrackerHistoryError.invalidSelection }
            let provider = try resolveProvider(target.accountID)
            let item = try await freshItem(provider: provider, target: target, generation: generation,
                                           needsDuration: row.baseline?.runtime != nil)
            let confirmed: Bool
            switch change {
            case .watched(let value): confirmed = item.isPlayed == value
            case .resume(let value):
                confirmed = item.resumePosition.map { abs($0 - value) <= 0.5 } ?? (value == 0)
            }
            outcomes[row.id] = row.observation.matches(item) && confirmed ? .confirmed : .unconfirmed
            if outcomes[row.id] == .confirmed {
                confirmedBaselines[row.id] = .init(item: item)
                if case .resume = change { resumed.insert(target) }
            }
        }
        // Home may already be visible when a foreground sync finishes. Reload
        // from the share stores once per batch, not from the tracker response.
        if !resumed.isEmpty {
            try requireCurrent(generation)
            MediaItemMutation(itemIDs: Set(resumed.map(\.itemID)), scopedItemIDs: Set(resumed.map(\.id)),
                              refreshContinueWatching: true).post()
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
        var resumesByIdentity: [MediaIdentity: [TrackerHistoryObservation]] = [:]
        for (offset, observation) in snapshot.observations.enumerated() {
            if offset.isMultiple(of: 128) { await Task.yield(); try requireCurrent(generation) }
            guard recordIDs?.contains(observation.recordID) != false else { continue }
            if observation.fact.needsFileDuration {
                for id in observation.verifiedEpisodeIdentities ?? observation.identities {
                    resumesByIdentity[id, default: []].append(observation)
                }
            }
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
        // Share parent metadata only inside this comparison. Dispatch and
        // readback still load the parent freshly through freshItem.
        var seriesItems: [WatchMutationTarget: MediaItem] = [:]
        for target in targets.sorted(by: { $0.id < $1.id }) {
            try requireCurrent(generation)
            let provider = try resolveProvider(target.accountID)
            var item = try await TrackerServerHistorySource.freshItem(
                provider: provider, accountID: target.accountID, itemID: target.itemID,
                validate: { try self.requireCurrent(generation) },
                loadSeries: { seriesID in
                    let parent = WatchMutationTarget(
                        accountID: target.accountID, itemID: seriesID, providerKind: target.providerKind
                    )
                    if let series = seriesItems[parent] { return series }
                    let series = try await provider.item(id: seriesID)
                    try self.requireCurrent(generation)
                    seriesItems[parent] = series
                    return series
                }
            )
            let isPlaying = await reconciler.isLiveSession(
                accountID: target.accountID, itemID: target.itemID, serverScope: scope
            )
            try requireCurrent(generation)
            if !isPlaying, item.runtime == nil, let timing = provider as? any TrackerResumeDurationProviding,
               (item.resumePosition ?? 0) > 0 || MediaItemIdentity.identities(for: item).contains(where: { id in
                   resumesByIdentity[id]?.contains(where: { $0.matches(item) }) == true
               }) {
                item.runtime = try await timing.trackerResumeDuration(for: item)
                try requireCurrent(generation)
            }
            result.append(.init(
                accountID: target.accountID, item: item,
                canWriteWatched: provider is any WatchStateProviding || provider is any PlayedStateWriting,
                canWriteResume: provider is any ResumeStateWriting, isPlaying: isPlaying
            ))
        }
        return result
    }

    private func freshItem(
        provider: any MediaProvider, target: WatchMutationTarget, generation: UUID, needsDuration: Bool
    ) async throws -> MediaItem {
        var item = try await TrackerServerHistorySource.freshItem(
            provider: provider, accountID: target.accountID, itemID: target.itemID,
            validate: { try self.requireCurrent(generation) }
        )
        if needsDuration, item.runtime == nil, let timing = provider as? any TrackerResumeDurationProviding {
            item.runtime = try await timing.trackerResumeDuration(for: item)
            try requireCurrent(generation)
        }
        return item
    }
}
