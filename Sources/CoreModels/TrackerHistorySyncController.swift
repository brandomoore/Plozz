import CryptoKit
import Foundation
import Observation
#if canImport(OSLog)
import OSLog
#endif

public struct TrackerHistorySyncIdentity: Codable, Equatable, Sendable {
    public let trackerID: String
    public let connectionID: String
    public let allowsForegroundChecks: Bool

    public init(trackerID: String, connectionID: String, allowsForegroundChecks: Bool = true) {
        self.trackerID = trackerID
        self.connectionID = connectionID
        self.allowsForegroundChecks = allowsForegroundChecks
    }
}

public enum TrackerHistorySyncCategory: String, Codable, CaseIterable, Sendable {
    case watched, resume

    func includes(_ fact: TrackerHistoryObservation.Fact) -> Bool {
        switch (self, fact) {
        case (.watched, .watched), (.watched, .explicitlyUnwatched), (.watched, .animeList),
             (.watched, .episodeCount), (.resume, .resume), (.resume, .resumePercentage),
             (.resume, .explicitlyClearedResume): true
        default: false
        }
    }
}

public enum TrackerHistorySyncError: Error, Equatable {
    case unavailable, permissionChanged, historyTooLarge, timedOut, revocationFailed
}

public struct TrackerHistorySyncGrant: DurableLocalStateValue, Equatable {
    public static let durableLocalStateSchemaID = "tracker-history-sync-grant.v1"
    public let id: UUID
    public let identity: TrackerHistorySyncIdentity
    public let scope: WatchMutationServerScope
    public let categories: Set<TrackerHistorySyncCategory>
    public let createdAt: Date
    public var enabled: Bool
    public var lastAttemptAt: Date?
    public var reviewCount: Int
}

/// Device-local consent and receipts. No timer polls a tracker, and this never
/// writes server state except through a freshly authorized import session.
@MainActor
@Observable
public final class TrackerHistorySyncController {
    public let identity: TrackerHistorySyncIdentity
    public let contextScope: WatchMutationServerScope
    public private(set) var grant: TrackerHistorySyncGrant?
    public private(set) var error: (any Error)?
    public private(set) var isBusy = false
    public private(set) var confirmedCount = 0
    public private(set) var hasMoreChanges = false
    private let store: DurableLocalStateStore
    private let isAuthorized: @MainActor @Sendable () -> Bool
    private let makeSession: @MainActor (
        WatchMutationServerScope, @escaping @MainActor @Sendable () -> Bool
    ) throws -> TrackerHistoryImportSession
    private var operation: Task<Void, Never>?
    private var activeSession: TrackerHistoryImportSession?
    private var generation = UUID()
    private var revocationPending = false
    private static let bucketCount = 64
    private static let maximumObservations = 100_000
    private static let batchSize = 25

    private enum Receipt: String, Codable, Sendable { case pending, confirmed, matched, review }
    private struct Bucket: DurableLocalStateValue {
        static let durableLocalStateSchemaID = "tracker-history-sync-ledger.v1"
        var baseline: Set<String> = []
        var receipts: [String: Receipt] = [:]
        var blockedTargets: Set<String> = []
    }

    public init(
        identity: TrackerHistorySyncIdentity, scope: WatchMutationServerScope, store: DurableLocalStateStore,
        isAuthorized: @escaping @MainActor @Sendable () -> Bool,
        makeSession: @escaping @MainActor (
            WatchMutationServerScope, @escaping @MainActor @Sendable () -> Bool
        ) throws -> TrackerHistoryImportSession
    ) {
        self.identity = identity
        contextScope = scope
        self.store = store
        self.isAuthorized = isAuthorized
        self.makeSession = makeSession
        reload()
    }

    public var isEnabled: Bool {
        guard let grant, !revocationPending else { return false }
        return grant.enabled && grant.identity == identity && grant.scope.profileID == contextScope.profileID
            && !grant.scope.accounts.isEmpty && Set(grant.scope.accounts).isSubset(of: Set(contextScope.accounts))
    }

    public func reload() {
        guard !revocationPending else {
            error = TrackerHistorySyncError.revocationFailed
            return
        }
        do {
            let stored: TrackerHistorySyncGrant? = try store.load(for: grantKey())
            if let stored {
                guard stored.scope.profileID == contextScope.profileID,
                      stored.identity.trackerID == identity.trackerID else {
                    throw DurableLocalStateError.addressMismatch
                }
                guard !stored.scope.accounts.isEmpty, !stored.categories.isEmpty, stored.reviewCount >= 0 else {
                    throw DurableLocalStateError.malformedPayload
                }
            }
            grant = stored
            error = nil
        } catch { report(error) }
    }

    public func stop() {
        generation = UUID()
        operation?.cancel()
        activeSession?.cancel()
        activeSession = nil
    }

    public func disable() {
        stop()
        revocationPending = true
        do {
            if var current: TrackerHistorySyncGrant = try store.load(for: grantKey()) {
                current.enabled = false
                try store.save(current, for: grantKey())
                grant = current
            } else {
                grant = nil
            }
            revocationPending = false
            error = nil
        } catch { report(TrackerHistorySyncError.revocationFailed) }
    }

    public func enable(
        afterReview plan: TrackerHistoryImportPlan, accountIDs: Set<String>,
        categories: Set<TrackerHistorySyncCategory>
    ) async {
        guard !isBusy else { return }
        isBusy = true
        generation = UUID()
        let current = generation
        defer { isBusy = false }
        do {
            guard isAuthorized(), plan.serverScope == contextScope, !categories.isEmpty else {
                throw TrackerHistoryError.scopeChanged
            }
            let session = try makeSession(contextScope, isAuthorized)
            defer { session.cancel() }
            let snapshot = try await session.snapshotAfterReview(plan.snapshot)
            try requireContext(current)
            guard snapshot.trackerID == identity.trackerID else { throw TrackerHistoryError.scopeChanged }
            guard snapshot.observations.count <= Self.maximumObservations else {
                throw TrackerHistorySyncError.historyTooLarge
            }
            let previous: TrackerHistorySyncGrant? = try store.load(for: grantKey())
            var next = TrackerHistorySyncGrant(
                id: UUID(), identity: identity, scope: try contextScope.selectingAccounts(accountIDs),
                categories: categories, createdAt: Date(), enabled: false, reviewCount: 0
            )
            // Publish a disabled manifest first. An interrupted enrollment cannot
            // authorize writes or mistake missing baseline pages for new history.
            try store.save(next, for: grantKey())
            grant = next
            var buckets = Array(repeating: Bucket(), count: Self.bucketCount)
            for observation in snapshot.observations {
                let hash = try Self.fingerprint(observation)
                buckets[Self.bucket(hash)].baseline.insert(hash)
            }
            for index in buckets.indices {
                try requireContext(current)
                try store.save(buckets[index], for: bucketKey(next, index))
                await Task.yield()
            }
            try requireContext(current)
            next.enabled = true
            try store.save(next, for: grantKey())
            grant = next
            revocationPending = false
            error = nil
            if let previous {
                for index in 0..<Self.bucketCount {
                    try store.remove(bucketKey(previous, index))
                }
            }
        } catch {
            if generation == current { report(error) }
        }
    }

    public func synchronize(manual: Bool = true) async {
        guard !isBusy, !revocationPending else { return }
        reload()
        guard error == nil, isEnabled, let grant else { return }
        guard manual || (identity.allowsForegroundChecks
            && Date().timeIntervalSince(grant.lastAttemptAt ?? .distantPast) >= 15 * 60) else { return }
        isBusy = true
        generation = UUID()
        let current = generation
        let work = Task { await perform(grant, generation: current) }
        operation = work
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard generation == current else { return }
            stop()
            report(TrackerHistorySyncError.timedOut)
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        deadline.cancel()
        activeSession?.cancel()
        activeSession = nil
        operation = nil
        isBusy = false
    }

    private func perform(_ initial: TrackerHistorySyncGrant, generation current: UUID) async {
        do {
            try requireGrant(initial, current)
            var persisted = initial
            persisted.lastAttemptAt = Date()
            try store.save(persisted, for: grantKey())
            grant = persisted
            confirmedCount = 0
            hasMoreChanges = false
            var buckets: [Bucket] = []
            for index in 0..<Self.bucketCount {
                guard let bucket: Bucket = try store.load(for: bucketKey(initial, index)) else {
                    throw DurableLocalStateError.malformedPayload
                }
                buckets.append(bucket)
            }
            for account in initial.scope.accounts {
                try requireGrant(initial, current)
                let scope = try initial.scope.selectingAccounts([account.accountID])
                let session = try makeSession(scope) { [weak self] in
                    guard let self else { return false }
                    do {
                        try self.requireGrant(initial, current)
                        return true
                    } catch {
                        self.report(error)
                        return false
                    }
                }
                activeSession = session
                var considered: Set<String> = []
                var hashes: [String: String] = [:]
                await session.compare { snapshot in
                    try self.requireGrant(initial, current)
                    guard snapshot.trackerID == initial.identity.trackerID else {
                        throw TrackerHistoryError.scopeChanged
                    }
                    guard snapshot.observations.count <= Self.maximumObservations else {
                        throw TrackerHistorySyncError.historyTooLarge
                    }
                    var newRecords: [String] = []
                    for observation in snapshot.observations {
                        let hash = try Self.fingerprint(observation)
                        hashes[observation.recordID] = hash
                        guard initial.categories.contains(where: { $0.includes(observation.fact) }),
                              !buckets[Self.bucket(hash)].baseline.contains(hash) else { continue }
                        let receipt = Self.receiptKey(account.accountID, hash)
                        if buckets[Self.bucket(receipt)].receipts[receipt] == nil {
                            newRecords.append(observation.recordID)
                        }
                    }
                    self.hasMoreChanges = self.hasMoreChanges || newRecords.count > Self.batchSize
                    considered = Set(newRecords.sorted().prefix(Self.batchSize))
                    return considered
                }
                try requireGrant(initial, current)
                if let error = session.error { throw error }
                guard let plan = session.plan else { throw TrackerHistoryError.incompleteSnapshot }
                let rows = plan.rows.filter { !considered.isDisjoint(with: $0.recordIDs) }
                var selected: Set<UUID> = []
                for row in rows {
                    if row.comparison == .playing { continue }
                    let receipt: Receipt
                    let targetKey = row.target.map { Self.digest(Data($0.id.utf8)) }
                    let blocked = targetKey.map { buckets[Self.bucket($0)].blockedTargets.contains($0) } ?? false
                    if row.comparison == .ready, let change = row.change, !change.isDestructive, !blocked {
                        receipt = .pending
                        selected.insert(row.id)
                    } else if row.comparison == .alreadyMatches {
                        receipt = .matched
                    } else {
                        receipt = .review
                    }
                    try record(
                        receipt, row: row, hashes: hashes, accountID: account.accountID,
                        grant: initial, buckets: &buckets
                    )
                }
                if !selected.isEmpty {
                    try requireGrant(initial, current)
                    persisted.reviewCount = Self.reviewCount(buckets)
                    try store.save(persisted, for: grantKey())
                    grant = persisted
                    await session.apply(rowIDs: selected, overridingConflicts: [], confirmsDestructiveChanges: false)
                    try requireGrant(initial, current)
                    for row in rows where session.outcomes[row.id] == .confirmed {
                        try record(
                            .confirmed, row: row, hashes: hashes, accountID: account.accountID,
                            grant: initial, buckets: &buckets
                        )
                        confirmedCount += 1
                    }
                    if let error = session.error { throw error }
                }
                session.cancel()
                activeSession = nil
            }
            try requireGrant(initial, current)
            persisted.reviewCount = Self.reviewCount(buckets)
            try store.save(persisted, for: grantKey())
            grant = persisted
        } catch {
            if generation == current { report(error) }
        }
    }

    private func record(
        _ value: Receipt, row: TrackerHistoryImportPlan.Row, hashes: [String: String],
        accountID: String, grant: TrackerHistorySyncGrant, buckets: inout [Bucket]
    ) throws {
        if let target = row.target, value == .pending || value == .confirmed {
            let key = Self.digest(Data(target.id.utf8))
            let index = Self.bucket(key)
            if value == .pending { buckets[index].blockedTargets.insert(key) }
            else { buckets[index].blockedTargets.remove(key) }
            try store.save(buckets[index], for: bucketKey(grant, index))
        }
        for recordID in row.recordIDs {
            guard let hash = hashes[recordID] else { throw TrackerHistoryError.incompleteSnapshot }
            let key = Self.receiptKey(accountID, hash)
            let index = Self.bucket(key)
            buckets[index].receipts[key] = value
            try store.save(buckets[index], for: bucketKey(grant, index))
        }
    }

    private func requireContext(_ current: UUID) throws {
        try Task.checkCancellation()
        guard generation == current, isAuthorized() else { throw TrackerHistoryError.scopeChanged }
    }

    private func requireGrant(_ expected: TrackerHistorySyncGrant, _ current: UUID) throws {
        try requireContext(current)
        guard !revocationPending, let stored: TrackerHistorySyncGrant = try store.load(for: grantKey()),
              stored.enabled, stored.id == expected.id, stored.identity == identity,
              stored.scope == expected.scope, stored.categories == expected.categories else {
            throw TrackerHistorySyncError.permissionChanged
        }
    }

    private func grantKey() throws -> DurableLocalStateKey {
        try .init(
            collection: .trackerDeliveryReceipt,
            scope: .source(profileID: contextScope.profileID, sourceID: identity.trackerID),
            recordID: "history-sync"
        )
    }

    private func bucketKey(_ grant: TrackerHistorySyncGrant, _ index: Int) throws -> DurableLocalStateKey {
        try .init(
            collection: .trackerDeliveryReceipt,
            scope: .source(profileID: contextScope.profileID, sourceID: identity.trackerID),
            recordID: "history-sync/\(grant.id.uuidString)/\(index)"
        )
    }

    private func report(_ error: any Error) {
        self.error = error
        #if canImport(OSLog)
        Logger(subsystem: "com.plozz.app", category: "tracker-history")
            .error("Tracker history synchronization could not complete")
        #endif
    }

    static func fingerprint(_ observation: TrackerHistoryObservation) throws -> String {
        struct Evidence: Encodable {
            let recordID: String
            let kind: MediaItemKind
            let identities: [String]
            let season: Int?
            let episode: Int?
            let ordering: EpisodeOrdering?
            let requiresExactEpisodeIdentity: Bool
            let fact: TrackerHistoryObservation.Fact
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let identities = try observation.identities.map { try encoder.encode($0).base64EncodedString() }.sorted()
        return digest(try encoder.encode(Evidence(
            recordID: observation.recordID, kind: observation.kind, identities: identities,
            season: observation.season, episode: observation.episode, ordering: observation.episodeOrdering,
            requiresExactEpisodeIdentity: observation.requiresExactEpisodeIdentity, fact: observation.fact
        )))
    }

    private static func receiptKey(_ accountID: String, _ hash: String) -> String {
        digest(Data("\(accountID.utf8.count):\(accountID)\(hash)".utf8))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func bucket(_ hash: String) -> Int {
        hash.utf8.reduce(0) { ($0 * 31 + Int($1)) % bucketCount }
    }

    private static func reviewCount(_ buckets: [Bucket]) -> Int {
        let receipts = buckets.reduce(0) {
            $0 + $1.receipts.values.filter { $0 == .pending || $0 == .review }.count
        }
        return max(receipts, buckets.reduce(0) { $0 + $1.blockedTargets.count })
    }
}
