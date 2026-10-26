import Foundation
import Observation
#if canImport(OSLog)
import OSLog
#endif

public enum TrackerHistoryExportError: Error, Equatable, Sendable {
    case unsupported, previousAttempt, uncertainWrite
    case notWritten(AppError)
}

public struct TrackerHistoryExportState: Equatable, Sendable {
    public let observations: [TrackerHistoryObservation]
    public let isPlaying: Bool

    public init(observations: [TrackerHistoryObservation], isPlaying: Bool = false) throws {
        guard Set(observations.map(\.recordID)).count == observations.count else {
            throw TrackerHistoryError.incompleteSnapshot
        }
        self.observations = observations.sorted { $0.recordID < $1.recordID }
        self.isPlaying = isPlaying
    }

    public var isWatched: Bool {
        observations.contains {
            switch $0.fact {
            case .watched: true
            case .animeList(let progress): progress.status == .completed
            default: false
            }
        }
    }

    public func containsWatch(at date: Date?) -> Bool {
        observations.contains {
            guard case .watched(let actual) = $0.fact else { return false }
            switch (date, actual) {
            case (nil, nil): return true
            case (.some(let expected), .some(let actual)):
                return abs(expected.timeIntervalSince(actual)) < 0.001
            default: return false
            }
        }
    }
}

/// Explicit watched-history backfill. Provider adapters own identity and wire formats.
@MainActor
@Observable
public final class TrackerHistoryExportSession<Target: Codable & Hashable & Sendable> {
    public enum Status: Sendable {
        case ready, alreadyMatches, conflict, unsupported, ambiguous, playing, previousAttempt
    }

    public enum Outcome: Sendable { case confirmed, alreadyPresent, unconfirmed }

    public struct Row: Identifiable, Sendable {
        public let id = UUID()
        public let title: String
        public let baseline: TrackerServerHistoryBaseline
        public let watchDate: Date?
        public fileprivate(set) var status: Status
        fileprivate let item: MediaItem
        fileprivate let remote: TrackerHistoryExportState
    }

    private struct Receipt: DurableLocalStateValue {
        static var durableLocalStateSchemaID: String { "com.plozz.tracker-history-export.v1" }
        let trackerID: String
        let connectionID: String
        let target: Target
        let scope: WatchMutationServerScope
        let accountID: String
        let baseline: TrackerServerHistoryBaseline
        let watchDate: Date?
        let idempotencyKey: String
        var confirmed = false
    }

    public let trackerName: String
    public let source: TrackerServerHistorySource
    public let preservesWatchDates: Bool
    public private(set) var rows: [Row] = []
    public private(set) var outcomes: [UUID: Outcome] = [:]
    public private(set) var error: (any Error)?
    public private(set) var isBusy = false
    public private(set) var loadedCount = 0
    public private(set) var hasCompared = false

    private let trackerID: String
    private let connectionID: String
    private let snapshotConnectionID: String
    private let store: DurableLocalStateStore
    private let isConnected: @MainActor @Sendable () -> Bool
    private let supports: @MainActor (MediaItem) -> Bool
    private let readAll: @MainActor () async throws -> TrackerHistorySnapshot
    private let resolve: @MainActor (MediaItem) async throws -> Target
    private let readTarget: @MainActor (Target) async throws -> TrackerHistoryExportState
    private let write: @MainActor (
        Target, Date?, String, @escaping @MainActor @Sendable () async throws -> Void
    ) async throws -> Void
    private var accountID: String?
    private var generation = UUID()
    private var isOpen = true

    public init(
        trackerID: String, trackerName: String, connectionID: String, snapshotConnectionID: String,
        source: TrackerServerHistorySource, store: DurableLocalStateStore,
        preservesWatchDates: Bool,
        isConnected: @escaping @MainActor @Sendable () -> Bool,
        supports: @escaping @MainActor (MediaItem) -> Bool,
        readAll: @escaping @MainActor () async throws -> TrackerHistorySnapshot,
        resolve: @escaping @MainActor (MediaItem) async throws -> Target,
        readTarget: @escaping @MainActor (Target) async throws -> TrackerHistoryExportState,
        write: @escaping @MainActor (
            Target, Date?, String, @escaping @MainActor @Sendable () async throws -> Void
        ) async throws -> Void
    ) {
        self.trackerID = trackerID
        self.trackerName = trackerName
        self.connectionID = connectionID
        self.snapshotConnectionID = snapshotConnectionID
        self.source = source
        self.store = store
        self.preservesWatchDates = preservesWatchDates
        self.isConnected = isConnected
        self.supports = supports
        self.readAll = readAll
        self.resolve = resolve
        self.readTarget = readTarget
        self.write = write
    }

    public func cancel() {
        isOpen = false
        generation = UUID()
        rows = []
        hasCompared = false
        isBusy = false
    }

    public func resetPreview() {
        guard !isBusy else { return }
        generation = UUID()
        rows = []
        outcomes = [:]
        error = nil
        loadedCount = 0
        hasCompared = false
    }

    private func requireCurrent(_ expected: UUID) throws {
        try source.requireCurrent()
        guard isOpen, generation == expected, isConnected() else { throw TrackerHistoryError.scopeChanged }
    }

    public func compare(accountID: String, library: MediaLibrary) async {
        guard !isBusy else { return }
        resetPreview()
        let current = generation
        self.accountID = accountID
        isBusy = true
        defer { if generation == current { isBusy = false } }
        do {
            try requireCurrent(current)
            let inventory = try await source.items(accountID: accountID, library: library) { count in
                if self.generation == current { self.loadedCount = count }
            }
            try requireCurrent(current)
            let snapshot = try await readAll()
            try requireCurrent(current)
            guard snapshot.trackerID == trackerID, snapshot.connectionID == snapshotConnectionID else {
                throw TrackerHistoryError.scopeChanged
            }
            guard snapshot.observations.count <= 100_000 else { throw TrackerHistoryError.incompleteSnapshot }
            var observationsByIdentity: [MediaIdentity: Set<Int>] = [:]
            for (index, observation) in snapshot.observations.enumerated() {
                for identity in observation.identities { observationsByIdentity[identity, default: []].insert(index) }
            }
            var compared: [Row] = []
            for entry in inventory where entry.isPlayed {
                let item = try await source.item(accountID: accountID, itemID: entry.id)
                try requireCurrent(current)
                guard item.isPlayed else { throw TrackerHistoryError.stalePreview }
                let baseline = TrackerServerHistoryBaseline(item: item)
                let candidates = baseline.identities.reduce(into: Set<Int>()) {
                    $0.formUnion(observationsByIdentity[$1] ?? [])
                }
                let remote = try TrackerHistoryExportState(
                    observations: candidates.map { snapshot.observations[$0] }.filter { $0.matches(item) }
                )
                let validDate = item.lastPlayedAt.map {
                    $0.timeIntervalSince1970.isFinite && $0 <= Date()
                } ?? true
                let date = preservesWatchDates && (item.resumePosition ?? 0) <= 0 ? item.lastPlayedAt : nil
                var status: Status = supports(item) && validDate ? .ready : .unsupported
                if status == .ready {
                    if remote.isWatched { status = .alreadyMatches }
                    else if !remote.observations.isEmpty { status = .conflict }
                    do { try await source.requireNotPlaying(accountID: accountID, itemID: item.id) }
                    catch AppError.conflict { status = .playing }
                }
                try requireCurrent(current)
                compared.append(.init(
                    title: item.title, baseline: baseline, watchDate: date,
                    status: status, item: item, remote: remote
                ))
            }
            var owners: [MediaIdentity: Set<UUID>] = [:]
            for row in compared {
                for identity in row.baseline.identities {
                    if case .external = identity { owners[identity, default: []].insert(row.id) }
                }
            }
            let ambiguous = Set(owners.values.filter { $0.count > 1 }.flatMap { $0 })
            for index in compared.indices where ambiguous.contains(compared[index].id) {
                compared[index].status = .ambiguous
            }
            try requireCurrent(current)
            rows = compared
            hasCompared = true
        } catch {
            if generation == current { report(error) }
        }
    }

    public func apply(rowIDs: Set<UUID>, confirmed: Bool) async {
        guard !isBusy else { return }
        let current = generation
        error = nil
        isBusy = true
        defer { if generation == current { isBusy = false } }
        do {
            try requireCurrent(current)
            let selected = rows.filter { rowIDs.contains($0.id) }
            guard confirmed, hasCompared, outcomes.isEmpty, let accountID,
                  (1...50).contains(selected.count), selected.count == rowIDs.count,
                  selected.allSatisfy({ $0.status == .ready }) else { throw TrackerHistoryError.invalidSelection }
            var targets: [UUID: Target] = [:]
            var uniqueTargets = Set<Target>()
            for row in selected {
                try await validate(row, accountID: accountID, generation: current)
                let target = try await resolve(row.item)
                try requireCurrent(current)
                guard uniqueTargets.insert(target).inserted else { throw TrackerHistoryError.invalidSelection }
                try await verifyRemote(target, row: row, generation: current)
                try requireUnattempted(target, row: row)
                targets[row.id] = target
            }
            for row in selected {
                guard let target = targets[row.id] else { throw TrackerHistoryError.invalidSelection }
                do {
                    try await validate(row, accountID: accountID, generation: current)
                    try await verifyRemote(target, row: row, generation: current)
                    try await validate(row, accountID: accountID, generation: current)
                    try requireUnattempted(target, row: row)
                    let key = try key(target)
                    let pendingReceipt = Receipt(
                        trackerID: trackerID, connectionID: connectionID, target: target,
                        scope: source.scope, accountID: accountID, baseline: row.baseline,
                        watchDate: row.watchDate, idempotencyKey: "history-export-" + UUID().uuidString
                    )
                    var receiptSaved = false
                    var acknowledged = false
                    do {
                        try await write(target, row.watchDate, pendingReceipt.idempotencyKey) {
                            try await self.validate(row, accountID: accountID, generation: current)
                            try await self.verifyRemote(target, row: row, generation: current)
                            try await self.validate(row, accountID: accountID, generation: current)
                            try self.requireUnattempted(target, row: row)
                            try self.store.save(pendingReceipt, for: key)
                            receiptSaved = true
                        }
                        acknowledged = true
                    } catch TrackerHistoryExportError.uncertainWrite {
                        // Readback establishes state, not which client wrote it.
                    } catch TrackerHistoryExportError.notWritten(let refusal) {
                        if receiptSaved { try store.remove(key) }
                        throw refusal
                    }
                    guard receiptSaved else { throw TrackerHistoryExportError.uncertainWrite }
                    try requireCurrent(current)
                    let after = try await readTarget(target)
                    try requireCurrent(current)
                    guard after.isWatched else { throw TrackerHistoryExportError.uncertainWrite }
                    var receipt = pendingReceipt
                    receipt.confirmed = true
                    try store.save(receipt, for: key)
                    outcomes[row.id] = acknowledged && (!preservesWatchDates || after.containsWatch(at: row.watchDate))
                        ? .confirmed : .alreadyPresent
                } catch {
                    if generation == current { outcomes[row.id] = .unconfirmed }
                    throw error
                }
            }
        } catch {
            if generation == current { report(error) }
        }
    }

    private func report(_ error: any Error) {
        self.error = error
        #if canImport(OSLog)
        Logger(subsystem: "com.plozz.app", category: "tracker-history")
            .error("Tracker history export could not complete")
        #endif
    }

    private func validate(_ row: Row, accountID: String, generation: UUID) async throws {
        try requireCurrent(generation)
        try await source.requireNotPlaying(accountID: accountID, itemID: row.baseline.itemID)
        let item = try await source.item(accountID: accountID, itemID: row.baseline.itemID)
        try requireCurrent(generation)
        guard item.kind == row.item.kind, TrackerServerHistoryBaseline(item: item) == row.baseline else {
            throw TrackerHistoryError.stalePreview
        }
        try await source.requireNotPlaying(accountID: accountID, itemID: row.baseline.itemID)
        try requireCurrent(generation)
    }

    private func verifyRemote(_ target: Target, row: Row, generation: UUID) async throws {
        let remote = try await readTarget(target)
        try requireCurrent(generation)
        guard !remote.isPlaying else { throw AppError.conflict }
        guard remote == row.remote else { throw TrackerHistoryError.stalePreview }
    }

    private func requireUnattempted(_ target: Target, row: Row) throws {
        if let _: Receipt = try store.load(for: key(target)) {
            if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index].status = .previousAttempt }
            throw TrackerHistoryExportError.previousAttempt
        }
    }

    private func key(_ target: Target) throws -> DurableLocalStateKey {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let targetID = WatchlistReconciliationIdentity.credential(try encoder.encode(target).base64EncodedString())
        return try .init(
            collection: .trackerDeliveryReceipt,
            scope: .source(profileID: source.scope.profileID, sourceID: trackerID + ":" + connectionID),
            recordID: "history-export:" + targetID
        )
    }
}
