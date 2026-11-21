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
    static let currentBetaConsentVersion = 1
    public let id: UUID
    public let identity: TrackerHistorySyncIdentity
    public let scope: WatchMutationServerScope
    public let categories: Set<TrackerHistorySyncCategory>
    public let createdAt: Date
    public var enabled: Bool
    public var lastAttemptAt: Date?
    public var reviewCount: Int
    // Shares added together share an observation baseline, not delivery receipts
    // or continuation proof. A re-added account starts a new enrollment.
    var enrollmentIDs: [String: UUID]?
    // An absent version is a pre-beta grant, not consent to this beta.
    var betaConsentVersion: Int?

    var authorizesSync: Bool { enabled && betaConsentVersion == Self.currentBetaConsentVersion }
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
    public var isBusy: Bool { isWorking || isEditing }
    private var isWorking = false
    private var isEditing = false
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
        var shareBaselines: [UUID: Set<String>]?
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

    public var eligibleAccountIDs: Set<String> {
        Set(contextScope.accounts.filter { $0.providerKind == .mediaShare }.map(\.accountID))
    }

    private func permits(_ scope: WatchMutationServerScope) -> Bool {
        let ids = Set(scope.accounts.map(\.accountID))
        return ids.count == scope.accounts.count && scope.accounts.allSatisfy { $0.providerKind == .mediaShare }
            && (try? contextScope.selectingAccounts(ids)) == scope
    }

    public var isEnabled: Bool {
        guard let grant, !revocationPending else { return false }
        return grant.authorizesSync && grant.identity == identity && permits(grant.scope)
            && grant.categories.isSubset(of: supportedCategories)
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
                if let enrollments = stored.enrollmentIDs,
                   !Set(enrollments.keys).isSubset(of: Set(stored.scope.accounts.map(\.accountID))) {
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
        await enable(scope: plan.serverScope, accountIDs: accountIDs, categories: categories) {
            plan.snapshot
        }
    }

    /// Direct Settings enrollment needs tracker evidence, not a comparison of
    /// every managed server. Use the same recheck and grant fences as reviewed enrollment.
    public func enable(
        from session: TrackerHistoryImportSession, accountIDs: Set<String>,
        categories: Set<TrackerHistorySyncCategory>
    ) async {
        await enable(scope: session.scope, accountIDs: accountIDs, categories: categories) {
            try await session.enrollmentSnapshot()
        }
    }

    private func enable(
        scope: WatchMutationServerScope, accountIDs: Set<String>, categories: Set<TrackerHistorySyncCategory>,
        reviewedSnapshot: @MainActor () async throws -> TrackerHistorySnapshot
    ) async {
        guard !isBusy else { return }
        isWorking = true
        generation = UUID()
        let current = generation
        defer { isWorking = false }
        do {
            guard isAuthorized(), scope == contextScope, !categories.isEmpty,
                  categories.isSubset(of: supportedCategories) else {
                throw TrackerHistoryError.scopeChanged
            }
            let selectedScope = try contextScope.selectingAccounts(accountIDs)
            guard permits(selectedScope) else { throw TrackerHistoryError.invalidSelection }
            let reviewed = try await reviewedSnapshot()
            try requireContext(current)
            let session = try makeSession(contextScope, isAuthorized)
            defer { session.cancel() }
            let snapshot = try await session.snapshotAfterReview(reviewed)
            try requireContext(current)
            guard snapshot.trackerID == identity.trackerID else { throw TrackerHistoryError.scopeChanged }
            guard snapshot.observations.count <= Self.maximumObservations else {
                throw TrackerHistorySyncError.historyTooLarge
            }
            let previous: TrackerHistorySyncGrant? = try store.load(for: grantKey())
            var next = TrackerHistorySyncGrant(
                id: UUID(), identity: identity, scope: selectedScope,
                categories: categories, createdAt: Date(), enabled: false, reviewCount: 0,
                betaConsentVersion: TrackerHistorySyncGrant.currentBetaConsentVersion
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

    /// Atomically edits the currently displayed, still-authorized grant. Additions
    /// start at a complete tracker snapshot; unchanged pairs retain unprocessed
    /// history. A failed edit leaves the durable selection unchanged.
    public func updateSelection(accountIDs: Set<String>, categories: Set<TrackerHistorySyncCategory>) async {
        guard !revocationPending else {
            report(TrackerHistorySyncError.revocationFailed)
            return
        }
        guard !isEditing, !isWorking || operation != nil else {
            report(TrackerHistorySyncError.unavailable)
            return
        }
        var current = generation
        do {
            guard isEnabled, let previous = grant else { throw TrackerHistorySyncError.permissionChanged }
            try requireGrant(previous, current)
            let scope = try contextScope.selectingAccounts(accountIDs)
            guard permits(scope), !categories.isEmpty, categories.isSubset(of: supportedCategories) else {
                throw TrackerHistoryError.invalidSelection
            }
            guard scope != previous.scope || categories != previous.categories else {
                error = nil
                return
            }

            stop()
            current = generation
            isEditing = true
            defer { isEditing = false }
            let addedAccounts = accountIDs.subtracting(previous.scope.accounts.map(\.accountID))
            let addedCategories = categories.subtracting(previous.categories)
            let enrollment = UUID()
            var enrollments = (previous.enrollmentIDs ?? [:]).filter { accountIDs.contains($0.key) }
            for account in addedAccounts { enrollments[account] = enrollment }
            let additions = try await selectionBaseline(
                previous: previous, scope: scope, generation: current,
                addsShares: !addedAccounts.isEmpty, addedCategories: addedCategories
            )

            // Read the latest receipts *after* the tracker await. No suspension
            // between copying the ledger and swapping the manifest: another
            // MainActor controller cannot settle work in a page already copied.
            let latest = try requireGrant(previous, current)
            var next = TrackerHistorySyncGrant(
                id: UUID(), identity: identity, scope: scope, categories: categories,
                createdAt: latest.createdAt, enabled: true, lastAttemptAt: latest.lastAttemptAt,
                reviewCount: latest.reviewCount, enrollmentIDs: enrollments, betaConsentVersion: latest.betaConsentVersion
            )
            do {
                var buckets = try loadBuckets(latest)
                let retained = Set(enrollments.values)
                for index in buckets.indices {
                    var shares = buckets[index].shareBaselines?.filter { retained.contains($0.key) } ?? [:]
                    if let additions {
                        buckets[index].baseline.formUnion(additions[index].categories)
                        if !addedAccounts.isEmpty {
                            shares[enrollment] = additions[index].shares.subtracting(buckets[index].baseline)
                        }
                    }
                    buckets[index].shareBaselines = shares
                    try store.save(buckets[index], for: bucketKey(next, index))
                }
                next.reviewCount = Self.reviewCount(buckets)
                try requireGrant(latest, current)
                try store.save(next, for: grantKey())
            } catch {
                removeLedger(next)
                throw error
            }
            grant = next
            error = nil
            removeLedger(previous)
        } catch {
            if generation == current {
                reload()
                report(error)
            }
        }
    }

    private struct BaselineAddition {
        var categories: Set<String> = []
        var shares: Set<String> = []
    }

    private func selectionBaseline(
        previous: TrackerHistorySyncGrant, scope: WatchMutationServerScope, generation: UUID,
        addsShares: Bool, addedCategories: Set<TrackerHistorySyncCategory>
    ) async throws -> [BaselineAddition]? {
        guard addsShares || !addedCategories.isEmpty else { return nil }
        let session = try makeSession(scope, isAuthorized)
        defer { session.cancel() }
        let snapshot = try await session.enrollmentSnapshot { _ = try self.requireGrant(previous, generation) }
        try requireGrant(previous, generation)
        guard snapshot.trackerID == identity.trackerID else { throw TrackerHistoryError.scopeChanged }
        guard snapshot.observations.count <= Self.maximumObservations else { throw TrackerHistorySyncError.historyTooLarge }
        var pages = Array(repeating: BaselineAddition(), count: Self.bucketCount)
        for (offset, observation) in snapshot.observations.enumerated() {
            if offset > 0, offset.isMultiple(of: 512) {
                await Task.yield()
                try requireGrant(previous, generation)
            }
            let newCategory = addedCategories.contains { $0.includes(observation.fact) }
            guard newCategory || addsShares else { continue }
            let hash = try Self.fingerprint(observation)
            if newCategory { pages[Self.bucket(hash)].categories.insert(hash) }
            else { pages[Self.bucket(hash)].shares.insert(hash) }
        }
        return pages
    }

    private func removeLedger(_ obsolete: TrackerHistorySyncGrant) {
        // These pages are unreachable. Cleanup failure must not make a committed
        // edit look like a failed edit or roll it back over a newer permission.
        for index in 0..<Self.bucketCount { try? store.remove(bucketKey(obsolete, index)) }
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
        isWorking = true
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
        isWorking = false
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
                        if self.generation == current { self.report(error) }
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
                              !Self.isEnrolled(hash, account.accountID, initial, buckets) else { continue }
                        let receipt = Self.receiptKey(account.accountID, hash, initial)
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
                    let continues = try canContinue(row, plan: plan, hashes: hashes, grant: initial, buckets: buckets)
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
            let proof = Self.proofKey(target, grant)
            if value == .confirmed || value == .matched {
                guard let baseline = value == .confirmed ? confirmedBaseline : row.baseline else {
                    throw TrackerHistoryError.incompleteSnapshot
                }
                if case .resume(let seconds) = row.change, seconds > 0, !baseline.played,
                   value == .confirmed || !buckets[index].blockedTargets.contains(key) {
                    confirmed[proof] = try Self.baselineFingerprint(baseline)
                } else { confirmed[proof] = nil }
            } else if value == .review {
                confirmed[proof] = nil
            }
            buckets[index].confirmedTargets = confirmed
            try store.save(buckets[index], for: bucketKey(grant, index))
        }
        for recordID in row.recordIDs {
            guard let hash = hashes[recordID] else { throw TrackerHistoryError.incompleteSnapshot }
            let key = Self.receiptKey(accountID, hash, grant)
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
        hashes: [String: String], grant: TrackerHistorySyncGrant, buckets: [Bucket]
    ) throws -> Bool {
        guard row.comparison == .serverConflict || row.comparison == .trackerConflict, let target = row.target,
              let baseline = row.baseline, !baseline.played,
              let position = baseline.resumePosition, position > 0 else { return false }
        let key = Self.digest(Data(target.id.utf8))
        guard buckets[Self.bucket(key)].confirmedTargets?[Self.proofKey(target, grant)]
                == (try Self.baselineFingerprint(baseline)) else {
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
                    let receiptKey = Self.receiptKey(target.accountID, hash, grant)
                    if let receipt = buckets[Self.bucket(receiptKey)].receipts[receiptKey] {
                        return receipt == .confirmed || receipt == .matched
                    }
                    return Self.isEnrolled(hash, target.accountID, grant, buckets)
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
        if isWorking && !isEditing { stop() }
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
        let enrollments = grant.enrollmentIDs.map { Set($0.values) }
        return try (0..<Self.bucketCount).map { index in
            guard let bucket: Bucket = try store.load(for: bucketKey(grant, index)),
                  bucket.shareBaselines.map({ Set($0.keys) }) == enrollments else {
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

    @discardableResult
    private func requireGrant(_ expected: TrackerHistorySyncGrant, _ current: UUID) throws -> TrackerHistorySyncGrant {
        try requireContext(current)
        guard !revocationPending, permits(expected.scope),
              let stored: TrackerHistorySyncGrant = try store.load(for: grantKey()),
              stored.authorizesSync, stored.id == expected.id, stored.identity == identity,
              stored.scope == expected.scope, stored.categories == expected.categories,
              stored.enrollmentIDs == expected.enrollmentIDs else {
            throw TrackerHistorySyncError.permissionChanged
        }
        return stored
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
        // Older readers don't understand per-enrollment baselines. They must
        // see missing pages rather than interpreting an edited ledger as v1.
        let prefix = grant.enrollmentIDs == nil ? "history-sync" : "history-sync/selection"
        return try .init(
            collection: .trackerDeliveryReceipt,
            scope: .source(profileID: contextScope.profileID, sourceID: identity.trackerID),
            recordID: "\(prefix)/\(grant.id.uuidString)/\(index)"
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

    private static func enrollmentKey(_ key: String, _ enrollment: UUID) -> String {
        digest(Data("\(enrollment.uuidString):\(key)".utf8))
    }

    private static func isEnrolled(
        _ hash: String, _ accountID: String, _ grant: TrackerHistorySyncGrant, _ buckets: [Bucket]
    ) -> Bool {
        let page = buckets[bucket(hash)]
        if page.baseline.contains(hash) { return true }
        guard let enrollment = grant.enrollmentIDs?[accountID] else { return false }
        return page.shareBaselines?[enrollment]?.contains(hash) == true
    }

    private static func receiptKey(_ accountID: String, _ hash: String, _ grant: TrackerHistorySyncGrant) -> String {
        let key = digest(Data("\(accountID.utf8.count):\(accountID)\(hash)".utf8))
        guard let enrollment = grant.enrollmentIDs?[accountID] else { return key }
        return enrollmentKey(key, enrollment)
    }

    private static func proofKey(_ target: WatchMutationTarget, _ grant: TrackerHistorySyncGrant) -> String {
        guard let enrollment = grant.enrollmentIDs?[target.accountID] else { return digest(Data(target.id.utf8)) }
        return enrollmentKey("\(target.accountID.utf8.count):\(target.accountID)\(target.itemID)", enrollment)
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
