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
             (.watched, .episodeCount), (.resume, .resume), (.resume, .resumePercentage), (.resume, .pausedPercentage),
             (.resume, .explicitlyClearedResume): true
        default: false
        }
    }
}

public enum TrackerHistorySyncError: Error, Equatable {
    case unavailable, permissionChanged, historyTooLarge, timedOut, revocationFailed
}

public struct TrackerHistorySyncResult: Codable, Equatable, Sendable {
    public enum Outcome: String, CaseIterable, Codable, Sendable {
        case updated, alreadyMatched, noMatch, multipleMatches, libraryConflict, trackerConflict
        case unsupported, incompatibleRuntime, wouldClearHistory, unconfirmed, previousUnconfirmed
        case playing, leftToCheck
    }

    /// Counts belong to this check and library, not the lifetime delivery ledger.
    /// Applied/compared rows can combine repeat watches; deferred counts are source entries.
    public struct Library: Codable, Equatable, Sendable {
        public let accountID: String
        public fileprivate(set) var counts: [Outcome: Int] = [:]
    }

    public let completedAt: Date
    public let confirmedCount: Int
    public let hasMoreChanges: Bool
    public var libraries: [Library]? = nil // Older results did not retain the breakdown.
}

public enum TrackerHistorySyncCheckStatus: String, Codable, Sendable {
    /// Started, but no finish was recorded (including cancellation or process exit).
    case incomplete
    case failed, completed
}

/// Counts describe one provider read, not overall import completion.
public enum TrackerHistoryReadDetail: Equatable, Sendable {
    case watches(page: Int, total: Int), verifyingRange(page: Int, total: Int)
    case waiting(until: Date)
    @TaskLocal public static var report: (@MainActor @Sendable (Self?) -> Void)?
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
    // Applies only to original shares with uninterrupted watched consent.
    var includesExistingWatched: Bool?
    // A historical watched-only confirmation is not permission to backfill progress.
    var includesExistingResumes: Bool?
    var checkID: UUID?
    public internal(set) var lastCheckStatus: TrackerHistorySyncCheckStatus?
    /// The last successful check of this selection, not necessarily the latest attempt.
    public internal(set) var lastCompletedResult: TrackerHistorySyncResult?

    var authorizesSync: Bool { enabled && betaConsentVersion == Self.currentBetaConsentVersion }
}

/// Device-local consent and receipts. No timer polls a tracker, and this never
/// writes server state except through a freshly authorized import session.
@MainActor
@Observable
public final class TrackerHistorySyncController {
    public enum Stage {
        case reading, verifying, saving, selecting
        case comparing(library: Int, total: Int), applying(library: Int, total: Int)
    }
    public private(set) var stage: Stage = .reading
    public private(set) var readDetail: TrackerHistoryReadDetail?
    public private(set) var checkedEntries: Int?
    public private(set) var totalEntries = 0
    public private(set) var retryDate: Date?
    public let identity: TrackerHistorySyncIdentity
    public let contextScope: WatchMutationServerScope
    public let supportedCategories: Set<TrackerHistorySyncCategory>
    public private(set) var grant: TrackerHistorySyncGrant?
    public private(set) var error: (any Error)?
    public var isBusy: Bool { isWorking || isEditing }
    private var isWorking = false
    private var isEditing = false
    public var confirmedCount: Int { grant?.lastCompletedResult?.confirmedCount ?? 0 }
    public var hasMoreChanges: Bool { grant?.lastCompletedResult?.hasMoreChanges ?? false }
    /// Only this controller's fresh enrollment can offer a choice. Never restored from disk.
    public private(set) var pendingHistoryGrantID: UUID?
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
    @ObservationIgnored private var lastProgress = ContinuousClock.now

    private func trackRead<T>(_ current: UUID, _ body: @MainActor () async throws -> T) async rethrows -> T {
        readDetail = nil
        defer { if generation == current { readDetail = nil } }
        return try await TrackerHistoryReadDetail.$report.withValue({ [weak self] detail in
            guard let self, self.generation == current else { return }
            self.readDetail = detail
            self.lastProgress = .now
        }, operation: body)
    }

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
                if let result = stored.lastCompletedResult, result.confirmedCount < 0 {
                    throw DurableLocalStateError.malformedPayload
                }
                if let enrollments = stored.enrollmentIDs,
                   !Set(enrollments.keys).isSubset(of: Set(stored.scope.accounts.map(\.accountID))) {
                    throw DurableLocalStateError.malformedPayload
                }
            }
            grant = stored
            if !isEnabled || pendingHistoryGrantID != stored?.id { pendingHistoryGrantID = nil }
            error = nil
        } catch { report(error) }
    }

    public func stop() {
        pendingHistoryGrantID = nil
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
        pendingHistoryGrantID = nil
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
            let previous: TrackerHistorySyncGrant? = try store.load(for: grantKey())
            stage = .reading
            let reviewed = try await trackRead(current, reviewedSnapshot)
            try requireContext(current)
            let session = try makeSession(contextScope, isAuthorized)
            defer { session.cancel() }
            stage = .verifying
            let snapshot = try await trackRead(current) { try await session.snapshotAfterReview(reviewed) }
            try requireContext(current)
            guard snapshot.trackerID == identity.trackerID else { throw TrackerHistoryError.scopeChanged }
            guard snapshot.observations.count <= Self.maximumObservations else {
                throw TrackerHistorySyncError.historyTooLarge
            }
            guard try store.load(TrackerHistorySyncGrant.self, for: grantKey()) == previous else {
                throw TrackerHistorySyncError.permissionChanged
            }
            stage = .saving
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
            guard try store.load(TrackerHistorySyncGrant.self, for: grantKey()) == next else {
                removeLedger(next)
                throw TrackerHistorySyncError.permissionChanged
            }
            next.enabled = true
            try store.save(next, for: grantKey())
            grant = next
            revocationPending = false
            error = nil
            pendingHistoryGrantID = categories.contains(.watched) ? next.id : nil
            if let previous { removeLedger(previous) }
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
            stage = .selecting
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
                createdAt: latest.createdAt, enabled: true,
                reviewCount: latest.reviewCount, enrollmentIDs: enrollments, betaConsentVersion: latest.betaConsentVersion,
                includesExistingWatched: categories.contains(.watched) ? latest.includesExistingWatched : nil,
                includesExistingResumes: categories.contains(.resume) ? latest.includesExistingResumes : nil
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

    public func skipExistingHistory(for grantID: UUID) {
        if pendingHistoryGrantID == grantID { pendingHistoryGrantID = nil }
    }

    public func syncExistingHistory(for grantID: UUID) async {
        guard pendingHistoryGrantID == grantID else { return }
        let current = generation
        // A foreground check may already be settling receipts. Don't cancel a
        // dispatched write or start a second writer for the same ledger.
        if let operation { await operation.value }
        guard pendingHistoryGrantID == grantID, generation == current, !isBusy,
              isEnabled, let grant, grant.id == grantID, grant.categories.contains(.watched) else { return }
        await runCheck(grant, admittingExistingHistory: true)
    }

    public func synchronize(manual: Bool = true) async {
        guard !isBusy, !revocationPending else { return }
        reload()
        guard error == nil, isEnabled, let grant else { return }
        guard manual || (identity.allowsForegroundChecks
            && Date().timeIntervalSince(grant.lastAttemptAt ?? .distantPast) >= 15 * 60) else { return }
        await runCheck(grant, admittingExistingHistory: false)
    }

    private func runCheck(_ expected: TrackerHistorySyncGrant, admittingExistingHistory: Bool) async {
        guard !isBusy else { return }
        if admittingExistingHistory {
            guard pendingHistoryGrantID == expected.id else { return }
            pendingHistoryGrantID = nil
        }
        let current = UUID()
        var admitted: TrackerHistorySyncGrant
        do {
            admitted = try requireGrant(expected, generation)
            if admittingExistingHistory {
                guard admitted.includesExistingWatched != true else { return }
                admitted.includesExistingWatched = true
                if admitted.categories.contains(.resume) { admitted.includesExistingResumes = true }
            }
            admitted.lastAttemptAt = Date()
            admitted.checkID = current
            admitted.lastCheckStatus = .incomplete
            // Publish consent and the start of its check atomically. A relaunch
            // after this write can never present this attempt as a success.
            try store.save(admitted, for: grantKey())
            grant = admitted
            error = nil
        } catch {
            if error as? TrackerHistorySyncError == .permissionChanged { reload() }
            report(error)
            return
        }
        #if canImport(OSLog)
        Logger(subsystem: "com.plozz.app", category: "tracker-history")
            .debug("Tracker history synchronization started")
        #endif
        isWorking = true
        generation = current
        checkedEntries = nil
        lastProgress = .now
        let work = Task { [admitted] in
            await perform(admitted, generation: current)
            activeSession?.cancel()
            activeSession = nil
            operation = nil
            isWorking = false
            checkedEntries = nil
        }
        operation = work
        let deadline = Task { [admitted] in
            repeat {
                do { try await Task.sleep(until: lastProgress.advanced(by: .seconds(60)), clock: .continuous) }
                catch { return }
            } while lastProgress.duration(to: .now) < .seconds(60)
            guard generation == current, operation != nil else { return }
            markCheckFailed(admitted, current)
            stop()
            report(TrackerHistorySyncError.timedOut)
        }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        deadline.cancel()
    }

    private func markCheckFailed(_ expected: TrackerHistorySyncGrant, _ current: UUID) {
        guard var latest = try? requireCheck(expected, current) else { return }
        latest.lastCheckStatus = .failed
        if let buckets = try? loadBuckets(latest) { latest.reviewCount = Self.reviewCount(buckets) }
        do {
            try store.save(latest, for: grantKey())
            grant = latest
        } catch { report(error) }
    }

    private func perform(_ initial: TrackerHistorySyncGrant, generation current: UUID) async {
        do {
            try requireCheck(initial, current)
            var libraries: [TrackerHistorySyncResult.Library] = []
            var buckets = try loadBuckets(initial)
            var snapshot: TrackerHistorySnapshot?
            var hashes: [String: String] = [:]
            for (offset, account) in initial.scope.accounts.enumerated() {
                let scope = try initial.scope.selectingAccounts([account.accountID])
                let library = try await processLibrary(
                    scope: scope, accountID: account.accountID, grant: initial, generation: current,
                    snapshot: &snapshot, hashes: &hashes, buckets: &buckets, libraryNumber: offset + 1
                )
                libraries.append(library)
            }
            var persisted = try requireCheck(initial, current)
            persisted.reviewCount = Self.reviewCount(buckets)
            persisted.lastCheckStatus = .completed
            persisted.lastCompletedResult = .init(
                completedAt: Date(), confirmedCount: libraries.reduce(0) { $0 + ($1.counts[.updated] ?? 0) },
                hasMoreChanges: libraries.contains { $0.counts[.playing] != nil || $0.counts[.leftToCheck] != nil },
                libraries: libraries
            )
            try store.save(persisted, for: grantKey())
            grant = persisted
            #if canImport(OSLog)
            Logger(subsystem: "com.plozz.app", category: "tracker-history")
                .debug("Tracker history synchronization completed")
            #endif
        } catch {
            if generation == current {
                if !Task.isCancelled { markCheckFailed(initial, current) }
                report(error)
            }
        }
    }

    private func processLibrary(
        scope: WatchMutationServerScope, accountID: String, grant initial: TrackerHistorySyncGrant, generation current: UUID,
        snapshot: inout TrackerHistorySnapshot?, hashes: inout [String: String],
        buckets: inout [Bucket], libraryNumber: Int
    ) async throws -> TrackerHistorySyncResult.Library {
        try requireCheck(initial, current)
        let session = try makeSession(scope) { [weak self] in
            guard let self else { return false }
            do {
                try self.requireCheck(initial, current)
                self.lastProgress = .now
                return true
            } catch {
                if self.generation == current { self.report(error) }
                return false
            }
        }
        activeSession = session
        defer { session.cancel(); activeSession = nil }
        var library = TrackerHistorySyncResult.Library(accountID: accountID)
        stage = .comparing(library: libraryNumber, total: initial.scope.accounts.count)
        checkedEntries = nil
        if snapshot == nil {
            let source = try await trackRead(current) { try await session.enrollmentSnapshot() }
            try requireCheck(initial, current)
            guard source.trackerID == initial.identity.trackerID else { throw TrackerHistoryError.scopeChanged }
            guard source.observations.count <= Self.maximumObservations else { throw TrackerHistorySyncError.historyTooLarge }
            for (index, observation) in source.observations.enumerated() {
                if index.isMultiple(of: 128) { await Task.yield(); try requireCheck(initial, current); lastProgress = .now }
                hashes[observation.recordID] = try Self.fingerprint(observation)
            }
            snapshot = source
        }
        guard let source = snapshot else { throw TrackerHistoryError.incompleteSnapshot }
        var eligible: Set<String> = []
        for (index, observation) in source.observations.enumerated() {
            if index.isMultiple(of: 128) { await Task.yield(); try requireCheck(initial, current); lastProgress = .now }
            guard let hash = hashes[observation.recordID],
                  initial.categories.contains(where: { $0.includes(observation.fact) }),
                  !Self.isEnrolled(hash, accountID, initial, buckets, observation: observation) else { continue }
            let receipt = Self.receiptKey(accountID, hash, initial)
            if buckets[Self.bucket(receipt)].receipts[receipt] == nil { eligible.insert(observation.recordID) }
        }
        guard !eligible.isEmpty else { return library }
        let considered = eligible
        await session.compare(snapshot: source, selectingRecords: { _ in considered })
        try requireCheck(initial, current)
        if let error = session.error { throw error }
        guard let plan = session.plan else { throw TrackerHistoryError.incompleteSnapshot }
        let rows = plan.rows.filter { !considered.isDisjoint(with: $0.recordIDs) }
        totalEntries = rows.count
        checkedEntries = 0
        for offset in stride(from: 0, to: rows.count, by: Self.batchSize) {
            await Task.yield()
            try requireCheck(initial, current)
            let slice = rows[offset..<min(offset + Self.batchSize, rows.count)]
            try await processRows(slice, in: plan, session: session, library: &library, considered: considered,
                                  hashes: hashes, grant: initial, generation: current, buckets: &buckets, libraryNumber: libraryNumber)
            checkedEntries = slice.endIndex
            lastProgress = .now
        }
        return library
    }

    private func processRows(
        _ rows: ArraySlice<TrackerHistoryImportPlan.Row>, in plan: TrackerHistoryImportPlan,
        session: TrackerHistoryImportSession, library: inout TrackerHistorySyncResult.Library, considered: Set<String>,
        hashes: [String: String], grant initial: TrackerHistorySyncGrant, generation current: UUID,
        buckets: inout [Bucket], libraryNumber: Int
    ) async throws {
        let accountID = library.accountID
        var selected: Set<UUID> = []
        var continuations: Set<UUID> = []
        for row in rows {
            if row.comparison == .playing {
                library.counts[.playing, default: 0] += row.recordIDs.filter(considered.contains).count
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
                library.counts[.alreadyMatched, default: 0] += 1
            } else {
                receipt = .review
                let reason: TrackerHistorySyncResult.Outcome
                switch row.comparison {
                case _ where blocked: reason = .previousUnconfirmed
                case _ where row.change?.isDestructive == true: reason = .wouldClearHistory
                case .serverConflict: reason = .libraryConflict
                case .trackerConflict: reason = .trackerConflict
                case .unmatched: reason = .noMatch
                case .ambiguous: reason = .multipleMatches
                case .incompatibleRuntime: reason = .incompatibleRuntime
                default: reason = .unsupported
                }
                library.counts[reason, default: 0] += 1
            }
            try record(receipt, row: row, hashes: hashes, accountID: accountID, grant: initial, buckets: &buckets)
        }
        if !selected.isEmpty {
            var persisted = try requireCheck(initial, current)
            persisted.reviewCount = Self.reviewCount(buckets)
            try store.save(persisted, for: grantKey())
            grant = persisted
            stage = .applying(library: libraryNumber, total: initial.scope.accounts.count)
            await trackRead(current) {
                await session.apply(rowIDs: selected, overridingConflicts: continuations, confirmsDestructiveChanges: false,
                                    continuingCheck: true)
            }
            try requireCheck(initial, current)
            for row in rows where session.outcomes[row.id] == .confirmed {
                try record(
                    .confirmed, row: row, hashes: hashes, accountID: accountID,
                    grant: initial, buckets: &buckets, confirmedBaseline: session.confirmedBaselines[row.id]
                )
                library.counts[.updated, default: 0] += 1
            }
            if let error = session.error { throw error }
            let unconfirmed = selected.filter { session.outcomes[$0] != .confirmed }.count
            if unconfirmed > 0 { library.counts[.unconfirmed, default: 0] += unconfirmed }
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
        var dirtyPages: Set<Int> = []
        for recordID in row.recordIDs {
            guard let hash = hashes[recordID] else { throw TrackerHistoryError.incompleteSnapshot }
            let key = Self.receiptKey(accountID, hash, grant)
            let index = Self.bucket(key)
            buckets[index].receipts[key] = value
            dirtyPages.insert(index)
        }
        for index in dirtyPages { try store.save(buckets[index], for: bucketKey(grant, index)) }
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
                    return Self.isEnrolled(hash, target.accountID, grant, buckets, observation: other.observation)
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
        // Another controller may still be comparing an older copy of these
        // receipts. Fence that check before it can settle over the reviewed import.
        if updated.lastCheckStatus == .incomplete { updated.checkID = nil }
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
              stored.includesExistingWatched == expected.includesExistingWatched,
              stored.includesExistingResumes == expected.includesExistingResumes,
              stored.enrollmentIDs == expected.enrollmentIDs else {
            throw TrackerHistorySyncError.permissionChanged
        }
        return stored
    }

    @discardableResult
    private func requireCheck(_ expected: TrackerHistorySyncGrant, _ current: UUID) throws -> TrackerHistorySyncGrant {
        let stored = try requireGrant(expected, current)
        guard stored.checkID == current else { throw TrackerHistorySyncError.permissionChanged }
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
        // Invalidate a disabled enrollment manifest that's still staging pages.
        grant.checkID = UUID()
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
        if case .rateLimited(let delay) = error as? AppError, let delay, delay.isFinite {
            retryDate = Date().addingTimeInterval(delay)
        } else { retryDate = nil }
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
        } else if case .pausedPercentage(let percent, let date) = observation.fact {
            // The new interpretation must not turn previously baselined pauses into new events.
            fact = .resumePercentage(percent: percent, updatedAt: date)
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

    private static func isWatched(_ observation: TrackerHistoryObservation) -> Bool {
        switch observation.fact {
        case .watched: observation.kind == .movie || observation.kind == .episode
        case .animeList(let progress): observation.kind == .movie && progress.status == .completed
        default: false
        }
    }

    private static func isEnrolled(
        _ hash: String, _ accountID: String, _ grant: TrackerHistorySyncGrant, _ buckets: [Bucket], observation: TrackerHistoryObservation
    ) -> Bool {
        let page = buckets[bucket(hash)]
        let enrollment = grant.enrollmentIDs?[accountID]
        if page.baseline.contains(hash) {
            let backfill = (isWatched(observation) && grant.includesExistingWatched == true)
                || (observation.fact.needsFileDuration && grant.includesExistingResumes == true)
            return !(backfill && enrollment == nil)
        }
        guard let enrollment else { return false }
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
