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
    public let supportedCategories: Set<TrackerHistorySyncCategory>
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
        var confirmedTargets: [String: String]?
    }

    public init(
        identity: TrackerHistorySyncIdentity, scope: WatchMutationServerScope, store: DurableLocalStateStore,
        supportedCategories: Set<TrackerHistorySyncCategory> = [.watched, .resume],
        isAuthorized: @escaping @MainActor @Sendable () -> Bool,
        makeSession: @escaping @MainActor (
            WatchMutationServerScope, @escaping @MainActor @Sendable () -> Bool
        ) throws -> TrackerHistoryImportSession
    ) {
        self.identity = identity
        contextScope = scope
        self.supportedCategories = supportedCategories
        self.store = store
        self.isAuthorized = isAuthorized
        self.makeSession = makeSession
        reload()
    }

    public var isEnabled: Bool {
        guard let grant, !revocationPending else { return false }
        return grant.enabled && grant.identity == identity && grant.scope.profileID == contextScope.profileID
            && grant.categories.isSubset(of: supportedCategories)
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
            grant = try Self.revokePermission(
                store: store, profileID: contextScope.profileID, trackerID: identity.trackerID
            )
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
            guard isAuthorized(), plan.serverScope == contextScope, !categories.isEmpty,
                  categories.isSubset(of: supportedCategories) else {
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
        #if canImport(OSLog)
        Logger(subsystem: "com.plozz.app", category: "tracker-history")
            .debug("Tracker history synchronization started")
        #endif
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
            var buckets = try loadBuckets(initial)
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
                var continuations: Set<UUID> = []
                for row in rows {
                    if row.comparison == .playing {
                        #if canImport(OSLog)
                        Logger(subsystem: "com.plozz.app", category: "tracker-history")
                            .debug("Tracker history synchronization skipped active playback")
                        #endif
                        continue
                    }
                    let receipt: Receipt
                    let targetKey = row.target.map { Self.digest(Data($0.id.utf8)) }
                    let blocked = targetKey.map { buckets[Self.bucket($0)].blockedTargets.contains($0) } ?? false
                    let continues = try canContinue(row, plan: plan, hashes: hashes, buckets: buckets)
                    if (row.comparison == .ready || continues), let change = row.change,
                       !change.isDestructive, !blocked {
                        receipt = .pending
                        selected.insert(row.id)
                        if continues { continuations.insert(row.id) }
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
                    await session.apply(
                        rowIDs: selected, overridingConflicts: continuations, confirmsDestructiveChanges: false
                    )
                    try requireGrant(initial, current)
                    for row in rows where session.outcomes[row.id] == .confirmed {
                        try record(
                            .confirmed, row: row, hashes: hashes, accountID: account.accountID,
                            grant: initial, buckets: &buckets, confirmedBaseline: session.confirmedBaselines[row.id]
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
            #if canImport(OSLog)
            Logger(subsystem: "com.plozz.app", category: "tracker-history")
                .debug("Tracker history synchronization completed")
            #endif
        } catch {
            if generation == current { report(error) }
        }
    }

    private func record(
        _ value: Receipt, row: TrackerHistoryImportPlan.Row, hashes: [String: String],
        accountID: String, grant: TrackerHistorySyncGrant, buckets: inout [Bucket],
        confirmedBaseline: TrackerServerHistoryBaseline? = nil
    ) throws {
        if let target = row.target {
            let key = Self.digest(Data(target.id.utf8))
            let index = Self.bucket(key)
            if value == .pending || value == .confirmed { buckets[index].blockedTargets.insert(key) }
            var confirmed = buckets[index].confirmedTargets ?? [:]
            if value == .confirmed || value == .matched {
                guard let baseline = value == .confirmed ? confirmedBaseline : row.baseline else {
                    throw TrackerHistoryError.incompleteSnapshot
                }
                if case .resume(let seconds) = row.change, seconds > 0, !baseline.played,
                   value == .confirmed || !buckets[index].blockedTargets.contains(key) {
                    confirmed[key] = try Self.baselineFingerprint(baseline)
                } else { confirmed[key] = nil }
            } else if value == .review {
                confirmed[key] = nil
            }
            buckets[index].confirmedTargets = confirmed
            try store.save(buckets[index], for: bucketKey(grant, index))
        }
        for recordID in row.recordIDs {
            guard let hash = hashes[recordID] else { throw TrackerHistoryError.incompleteSnapshot }
            let key = Self.receiptKey(accountID, hash)
            let index = Self.bucket(key)
            buckets[index].receipts[key] = value
            try store.save(buckets[index], for: bucketKey(grant, index))
        }
        if value == .confirmed, let target = row.target {
            let key = Self.digest(Data(target.id.utf8))
            let index = Self.bucket(key)
            // Release the hold only after both the readback proof and receipts are durable.
            buckets[index].blockedTargets.remove(key)
            try store.save(buckets[index], for: bucketKey(grant, index))
        }
    }

    private func canContinue(
        _ row: TrackerHistoryImportPlan.Row, plan: TrackerHistoryImportPlan,
        hashes: [String: String], buckets: [Bucket]
    ) throws -> Bool {
        guard row.comparison == .serverConflict || row.comparison == .trackerConflict, let target = row.target,
              let baseline = row.baseline, !baseline.played,
              let position = baseline.resumePosition, position > 0 else { return false }
        let key = Self.digest(Data(target.id.utf8))
        guard buckets[Self.bucket(key)].confirmedTargets?[key] == (try Self.baselineFingerprint(baseline)) else {
            return false
        }
        if row.comparison == .trackerConflict {
            // Only proven continuation may disregard settled history. Keep new
            // and unresolved conflicts, even outside the current write batch.
            let competing = plan.rows.filter {
                $0.target == target && $0.change != nil && $0.change != row.change
            }
            guard competing.allSatisfy({ other in
                other.recordIDs.allSatisfy { recordID in
                    guard let hash = hashes[recordID] else { return false }
                    let receiptKey = Self.receiptKey(target.accountID, hash)
                    let receipt = buckets[Self.bucket(receiptKey)].receipts[receiptKey]
                    return buckets[Self.bucket(hash)].baseline.contains(hash)
                        || receipt == .confirmed || receipt == .matched
                }
            }) else { return false }
        }
        switch row.change {
        case .resume(let next): return next > position
        case .watched(true): return true
        default: return false
        }
    }

    func recordReviewedImport(
        _ plan: TrackerHistoryImportPlan, baselines: [UUID: TrackerServerHistoryBaseline], expectedGrantID: UUID?
    ) throws {
        guard let expectedGrantID, !baselines.isEmpty else { return }
        reload()
        if let error { throw error }
        guard isEnabled, let grant, grant.id == expectedGrantID else { return }
        guard plan.serverScope == contextScope, plan.snapshot.trackerID == identity.trackerID,
              plan.snapshot.observations.count <= Self.maximumObservations else {
            throw TrackerHistoryError.scopeChanged
        }
        let accounts = Set(grant.scope.accounts.map(\.accountID))
        let rows = plan.rows.filter { row in
            baselines[row.id] != nil && row.target.map { accounts.contains($0.accountID) } == true
                && grant.categories.contains { $0.includes(row.observation.fact) }
        }
        guard !rows.isEmpty else { return }
        if isBusy { stop() }
        try requireGrant(grant, generation)
        var buckets = try loadBuckets(grant)
        let hashes = try Dictionary(uniqueKeysWithValues: plan.snapshot.observations.map {
            ($0.recordID, try Self.fingerprint($0))
        })
        for row in rows {
            guard let target = row.target else { throw TrackerHistoryError.invalidSelection }
            try record(
                .confirmed, row: row, hashes: hashes, accountID: target.accountID,
                grant: grant, buckets: &buckets, confirmedBaseline: baselines[row.id]
            )
        }
        var updated = grant
        updated.reviewCount = Self.reviewCount(buckets)
        try store.save(updated, for: grantKey())
        self.grant = updated
    }

    private func loadBuckets(_ grant: TrackerHistorySyncGrant) throws -> [Bucket] {
        try (0..<Self.bucketCount).map { index in
            guard let bucket: Bucket = try store.load(for: bucketKey(grant, index)) else {
                throw DurableLocalStateError.malformedPayload
            }
            return bucket
        }
    }

    private static func baselineFingerprint(_ baseline: TrackerServerHistoryBaseline) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(baseline))
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
        try Self.grantKey(profileID: contextScope.profileID, trackerID: identity.trackerID)
    }

    @discardableResult
    public static func revokePermission(
        store: DurableLocalStateStore, profileID: String, trackerID: String
    ) throws -> TrackerHistorySyncGrant? {
        let key = try grantKey(profileID: profileID, trackerID: trackerID)
        guard var grant: TrackerHistorySyncGrant = try store.load(for: key) else { return nil }
        guard grant.scope.profileID == profileID, grant.identity.trackerID == trackerID else {
            throw DurableLocalStateError.addressMismatch
        }
        grant.enabled = false
        try store.save(grant, for: key)
        return grant
    }

    private static func grantKey(profileID: String, trackerID: String) throws -> DurableLocalStateKey {
        try .init(
            collection: .trackerDeliveryReceipt,
            scope: .source(profileID: profileID, sourceID: trackerID),
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
        let fact: TrackerHistoryObservation.Fact
        if case .animeList(let progress) = observation.fact, observation.kind == .movie {
            // Rating/count edits are not new movie completions.
            fact = .animeList(try .init(
                status: progress.status, episodesWatched: nil, repeats: nil, score: nil, updatedAt: nil
            ))
        } else {
            fact = observation.fact
        }
        return digest(try encoder.encode(Evidence(
            recordID: observation.recordID, kind: observation.kind, identities: identities,
            season: observation.season, episode: observation.episode, ordering: observation.episodeOrdering,
            requiresExactEpisodeIdentity: observation.requiresExactEpisodeIdentity, fact: fact
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
