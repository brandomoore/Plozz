import XCTest
@testable import CoreModels

/// Applier double that records server writes and lets a test script the
/// cross-server twin **expansion** the reconciler should perform at drain time.
private final class ExpandingFakeApplier: WatchMutationApplying, @unchecked Sendable {
    struct PlayedWrite: Equatable { let played: Bool; let accountID: String; let itemID: String }

    private let lock = NSLock()
    private(set) var playedWrites: [PlayedWrite] = []
    private(set) var resumeWrites: [(seconds: TimeInterval, accountID: String, itemID: String)] = []
    private(set) var expandCallCount = 0

    /// Accounts whose writes currently fail (an offline/asleep server).
    var failingAccounts: Set<String> = []
    /// What `expandTargets` returns. Default: no expansion owed.
    var expansion: WatchTargetExpansion = .none

    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        if failingAccounts.contains(target.accountID) { throw AppError.serverUnreachable }
        lock.lock(); playedWrites.append(.init(played: played, accountID: target.accountID, itemID: target.itemID)); lock.unlock()
    }

    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        if failingAccounts.contains(target.accountID) { throw AppError.serverUnreachable }
        lock.lock(); resumeWrites.append((seconds, target.accountID, target.itemID)); lock.unlock()
    }

    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws {}

    func expandTargets(for mutation: WatchMutation) async -> WatchTargetExpansion {
        lock.lock(); expandCallCount += 1; lock.unlock()
        return expansion
    }

    var playedAccounts: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(playedWrites.map(\.accountID)) }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private func episodeMutation(
    canonical: String = "tvdb:85552",
    capturedAt: Date,
    originAccount: String = "A",
    originItem: String = "A-ep",
    expansionPending: Bool = true
) -> WatchMutation {
    WatchMutation(
        capturedAt: capturedAt,
        canonicalMediaID: canonical,
        seasonNumber: 1,
        episodeNumber: 2,
        played: true,
        clearResume: true,
        targets: [WatchMutationTarget(accountID: originAccount, itemID: originItem)],
        episodeOrigin: EpisodeOrigin(accountID: originAccount, itemID: originItem),
        expansionPending: expansionPending
    )
}

/// Drain-time integration of episode-twin expansion: the reconciler must fan a
/// played episode out to the resolved twin, keep the origin write sacrosanct, and
/// retry only when expansion was inconclusive.
final class WatchOutboxEpisodeExpansionTests: XCTestCase {
    func testEpisodeExpandsToTwinAndConvergesBothServers() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = WatchTargetExpansion(
            targets: [WatchMutationTarget(accountID: "B", itemID: "B-ep", providerKind: .plex)]
        )
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)

        await reconciler.enqueue(episodeMutation(capturedAt: Date()))
        await reconciler.drain()

        XCTAssertEqual(applier.playedAccounts, ["A", "B"], "Watch must converge origin AND the resolved twin")
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 0, "Fully converged ⇒ pruned")
    }

    func testInconclusiveExpansionKeepsMutationPendingButStillWritesOrigin() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = WatchTargetExpansion(inconclusiveAccountIDs: ["B"]) // couldn't reach twin yet
        let store = InMemoryWatchMutationStore()
        let reconciler = WatchStateReconciler(store: store, applier: applier)

        await reconciler.enqueue(episodeMutation(capturedAt: Date()))
        await reconciler.drain()

        XCTAssertEqual(applier.playedAccounts, ["A"], "Origin is never withheld waiting on a twin")
        let pendingAfterFirst = await reconciler.pendingCount
        XCTAssertEqual(pendingAfterFirst, 1, "Inconclusive expansion keeps the mutation alive to retry")

        // The twin server comes back: now expansion resolves it.
        applier.expansion = WatchTargetExpansion(
            targets: [WatchMutationTarget(accountID: "B", itemID: "B-ep")]
        )
        await reconciler.drain()

        XCTAssertEqual(applier.playedAccounts, ["A", "B"], "Retry converges the twin once reachable")
        let pendingAfterSecond = await reconciler.pendingCount
        XCTAssertEqual(pendingAfterSecond, 0)
    }

    func testConclusiveNoTwinStillWritesOriginAndPrunes() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = .none   // confident: no other server hosts it / ambiguous skip
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)

        await reconciler.enqueue(episodeMutation(capturedAt: Date()))
        await reconciler.drain()

        XCTAssertEqual(applier.playedAccounts, ["A"])
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 0, "A conclusive no-twin result must not strand the mutation")
    }

    func testNonEpisodeMutationIsNeverExpanded() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = WatchTargetExpansion(
            targets: [WatchMutationTarget(accountID: "B", itemID: "B-movie")]
        )
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)

        // A movie mutation: expansionPending defaults false.
        let movie = WatchMutation(
            capturedAt: Date(),
            canonicalMediaID: "imdb:tt1",
            played: true,
            clearResume: true,
            targets: [WatchMutationTarget(accountID: "A", itemID: "A-movie")]
        )
        await reconciler.enqueue(movie)
        await reconciler.drain()

        XCTAssertEqual(applier.expandCallCount, 0, "Movies must never trigger cross-server probing")
        XCTAssertEqual(applier.playedAccounts, ["A"])
    }

    func testExpansionIsIdempotentAcrossDrains() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = WatchTargetExpansion(
            targets: [WatchMutationTarget(accountID: "B", itemID: "B-ep")]
        )
        // Origin write fails the first time so the mutation survives a second drain.
        applier.failingAccounts = ["A"]
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)

        await reconciler.enqueue(episodeMutation(capturedAt: Date()))
        await reconciler.drain()   // B written, A fails → still pending
        applier.failingAccounts = []
        await reconciler.drain()   // A written; B must NOT be written twice

        let bWrites = applier.playedWrites.filter { $0.accountID == "B" }
        XCTAssertEqual(bWrites.count, 1, "A resolved twin target must not be written twice")
        XCTAssertEqual(applier.playedAccounts, ["A", "B"])
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 0)
    }

    /// The reported "Continue Watching is out of order" loop: one household server
    /// kept rejecting sign-in, so every expansion stayed inconclusive and every
    /// drain re-added — and rewrote — twins it had already written. Plex stamps
    /// "last viewed" on each write, so stale titles jumped to the front.
    func testInconclusiveRetriesNeverRewriteATwinAlreadyWritten() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = WatchTargetExpansion(
            targets: [WatchMutationTarget(accountID: "B", itemID: "B-ep", providerKind: .plex)],
            inconclusiveAccountIDs: ["C"]
        )
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)

        await reconciler.enqueue(episodeMutation(capturedAt: Date()))
        await reconciler.drain()
        await reconciler.drain()
        await reconciler.drain()

        XCTAssertEqual(applier.playedWrites.filter { $0.accountID == "A" }.count, 1)
        XCTAssertEqual(applier.playedWrites.filter { $0.accountID == "B" }.count, 1,
                       "A twin already written must not be rewritten while another server stays unresolved")
        XCTAssertEqual(applier.expandCallCount, 3, "The unresolved server is still retried")
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 1)

        // The missing server comes back and resolves: only it is written.
        applier.expansion = WatchTargetExpansion(targets: [
            WatchMutationTarget(accountID: "B", itemID: "B-ep", providerKind: .plex),
            WatchMutationTarget(accountID: "C", itemID: "C-ep"),
        ])
        await reconciler.drain()

        XCTAssertEqual(applier.playedWrites.map(\.accountID), ["A", "B", "C"])
        let drained = await reconciler.pendingCount
        XCTAssertEqual(drained, 0)
    }

    func testNewerStateStillReachesTwinsTheOlderStateWasWrittenTo() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = WatchTargetExpansion(
            targets: [WatchMutationTarget(accountID: "B", itemID: "B-ep")],
            inconclusiveAccountIDs: ["C"]
        )
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier)
        let start = Date()

        await reconciler.enqueue(episodeMutation(capturedAt: start))
        await reconciler.drain()

        var unwatch = episodeMutation(capturedAt: start.addingTimeInterval(60))
        unwatch.played = false
        unwatch.clearResume = false
        await reconciler.enqueue(unwatch)
        await reconciler.drain()

        let bWrites = applier.playedWrites.filter { $0.accountID == "B" }.map(\.played)
        XCTAssertEqual(bWrites, [true, false], "The newer intent must be written to the twin once more")
    }

    func testInconclusiveExpansionRetiresAfterTheRetryWindow() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = WatchTargetExpansion(inconclusiveAccountIDs: ["B"])
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(),
            applier: applier,
            now: { clock.now },
            expansionRetryWindow: 3600
        )

        await reconciler.enqueue(episodeMutation(capturedAt: clock.now))
        await reconciler.drain()
        let pendingInsideWindow = await reconciler.pendingCount
        XCTAssertEqual(pendingInsideWindow, 1)

        clock.now = clock.now.addingTimeInterval(3601)
        await reconciler.drain()

        XCTAssertEqual(applier.expandCallCount, 1, "Past the window the unreachable server is no longer probed")
        XCTAssertEqual(applier.playedAccounts, ["A"])
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 0, "A server that never answers must not keep the watch queued forever")
    }

    /// Queued before the applied-target record existed, a mutation's twins had
    /// been rewritten on every drain; reading it back must not schedule one more.
    func testLegacyQueuedMutationTreatsTwinsItAlreadyReachedAsWritten() throws {
        var queued = episodeMutation(capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        queued.optimisticTargets = [
            WatchMutationTarget(accountID: "A", itemID: "A-ep"),
            WatchMutationTarget(accountID: "B", itemID: "B-ep"),
        ]
        queued.targets = [WatchMutationTarget(accountID: "A", itemID: "A-ep")]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queued)) as! [String: Any]
        json.removeValue(forKey: "appliedTargetIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(WatchMutation.self, from: legacyData)
        XCTAssertEqual(decoded.appliedTargetIDs, ["B:B-ep"], "Only the still-queued origin is unwritten")
    }

    func testRetryWindowStartsAtTheFirstAttemptNotTheWatch() async throws {
        let applier = ExpandingFakeApplier()
        applier.expansion = WatchTargetExpansion(inconclusiveAccountIDs: ["B"])
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(),
            applier: applier,
            now: { clock.now },
            expansionRetryWindow: 3600
        )

        // Watched offline a day before the device reconnected.
        await reconciler.enqueue(episodeMutation(capturedAt: clock.now.addingTimeInterval(-86_400)))
        await reconciler.drain()

        XCTAssertEqual(applier.expandCallCount, 1, "A late first drain still gets to look for twins")
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 1)
    }

    func testLegacyOutboxMutationDecodesWithDefaultedExpansionFields() throws {
        // A pre-feature outbox entry has no `episodeOrigin` / `expansionPending` keys.
        let modern = WatchMutation(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            canonicalMediaID: "imdb:tt1",
            played: true,
            clearResume: true,
            targets: [WatchMutationTarget(accountID: "A", itemID: "A1")]
        )
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(modern)) as! [String: Any]
        json.removeValue(forKey: "episodeOrigin")
        json.removeValue(forKey: "expansionPending")
        json.removeValue(forKey: "appliedTargetIDs")
        json.removeValue(forKey: "expansionStartedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(WatchMutation.self, from: legacyData)
        XCTAssertNil(decoded.episodeOrigin)
        XCTAssertFalse(decoded.expansionPending, "Legacy entries must not suddenly start cross-server probing")
        XCTAssertEqual(decoded.appliedTargetIDs, [])
        XCTAssertNil(decoded.expansionStartedAt)
        XCTAssertEqual(decoded.targets, modern.targets)
    }
}

