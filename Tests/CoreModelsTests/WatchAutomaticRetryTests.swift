import XCTest
@testable import CoreModels

private final class RetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 10_000)
    private var allowed = true
    private var checks = 0
    var now: Date { lock.withLock { date } }
    var isAllowed: Bool { lock.withLock { allowed } }
    var admissionChecks: Int { lock.withLock { checks } }
    func checkAdmission() -> Bool { lock.withLock { checks += 1; return allowed } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    func setAllowed(_ value: Bool) { lock.withLock { allowed = value } }
}

private actor RetrySleeper {
    private var waits: [(UUID, TimeInterval, CheckedContinuation<Void, Error>)] = []
    private var cancelled: Set<UUID> = []
    var delays: [TimeInterval] { waits.map { $0.1 } }

    func sleep(_ delay: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waits.append((id, delay, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        if let index = waits.firstIndex(where: { $0.0 == id }) {
            waits.remove(at: index).2.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
        }
    }

    func wake() {
        guard !waits.isEmpty else { return }
        waits.removeFirst().2.resume()
    }

    func cancelAll() {
        let pending = waits
        waits.removeAll()
        for wait in pending { wait.2.resume(throwing: CancellationError()) }
    }
}

private actor RetryApplier: WatchMutationApplying {
    var failure: AppError? = .serverUnreachable
    var attempts = 0
    var played: [Bool] = []
    var resumes: [TimeInterval] = []
    func setFailure(_ value: AppError?) { failure = value }

    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        attempts += 1
        if let failure { throw failure }
        self.played.append(played)
    }

    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        attempts += 1
        if let failure { throw failure }
        resumes.append(seconds)
    }

    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws {
        if let failure { throw failure }
    }
}

final class WatchAutomaticRetryTests: XCTestCase {
    private func mutation(_ date: Date, played: Bool? = true, resume: Double? = nil) -> WatchMutation {
        WatchMutation(
            capturedAt: date, canonicalMediaID: "movie", resumePosition: resume,
            played: played, targets: [WatchMutationTarget(accountID: "server", itemID: "item")]
        )
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for retry state", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func testFailedWatchRetriesWithoutAnotherAppEventAndStopsWhenSuccessful() async throws {
        let clock = RetryClock()
        let sleeper = RetrySleeper()
        let applier = RetryApplier()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier, now: { clock.now },
            automaticRetryAllowed: { clock.isAllowed }, retrySleeper: { try await sleeper.sleep($0) }
        )
        await reconciler.enqueue(mutation(clock.now))
        await reconciler.drain()
        try await waitUntil { await sleeper.delays == [30] }
        clock.advance(30)
        await sleeper.wake()
        try await waitUntil { await applier.attempts == 2 }
        try await waitUntil { await sleeper.delays == [60] }
        await applier.setFailure(nil)
        clock.advance(60)
        await sleeper.wake()
        try await waitUntil { await reconciler.pendingCount == 0 }
        let played = await applier.played
        XCTAssertEqual(played, [true])
        let delays = await sleeper.delays
        XCTAssertTrue(delays.isEmpty, "A successful empty queue must not poll.")
    }

    func testSavedResumeRestoresItsDeadlineAndRetriesAfterRelaunch() async throws {
        let clock = RetryClock()
        let applier = RetryApplier()
        let store = InMemoryWatchMutationStore()
        let original = WatchStateReconciler(store: store, applier: applier, now: { clock.now })
        await original.enqueue(mutation(clock.now, played: nil, resume: 1234))
        await original.drain()
        let restoredState = try JSONDecoder().decode(
            WatchOutboxState.self, from: JSONEncoder().encode(store.load())
        )
        let sleeper = RetrySleeper()
        let restored = WatchStateReconciler(
            store: InMemoryWatchMutationStore(restoredState), applier: applier, now: { clock.now },
            automaticRetryAllowed: { true }, retrySleeper: { try await sleeper.sleep($0) }
        )
        await restored.drain()
        let attempts = await applier.attempts
        XCTAssertEqual(attempts, 1, "Relaunch must not bypass persisted cooldown.")
        try await waitUntil { await sleeper.delays == [30] }
        await applier.setFailure(nil)
        clock.advance(30)
        await sleeper.wake()
        try await waitUntil { await restored.pendingCount == 0 }
        let resumes = await applier.resumes
        XCTAssertEqual(resumes, [1234])
    }

    func testInactiveOrDifferentProfileDoesNotWriteAndForegroundRestartsRetries() async throws {
        let clock = RetryClock()
        let sleeper = RetrySleeper()
        let applier = RetryApplier()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier, now: { clock.now },
            automaticRetryAllowed: { clock.checkAdmission() }, retrySleeper: { try await sleeper.sleep($0) }
        )
        await reconciler.enqueue(mutation(clock.now))
        await reconciler.drain()
        try await waitUntil { await sleeper.delays == [30] }
        clock.setAllowed(false)
        clock.advance(30)
        await sleeper.wake()
        try await waitUntil { clock.admissionChecks == 1 }
        let attempts = await applier.attempts
        XCTAssertEqual(attempts, 1)
        let pending = await reconciler.pendingCount
        XCTAssertEqual(pending, 1, "Losing admission must preserve the watch.")
        let delays = await sleeper.delays
        XCTAssertTrue(delays.isEmpty, "Inactive profiles must not keep polling.")
        clock.setAllowed(true)
        await reconciler.drain()
        try await waitUntil { await sleeper.delays == [60] }
        await applier.setFailure(nil)
        clock.advance(60)
        await sleeper.wake()
        try await waitUntil { await reconciler.pendingCount == 0 }
    }

    func testFrequentCheckpointsDoNotPostponeRetryAndNewestIntentWins() async throws {
        let clock = RetryClock()
        let sleeper = RetrySleeper()
        let applier = RetryApplier()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier, now: { clock.now },
            automaticRetryAllowed: { true }, retrySleeper: { try await sleeper.sleep($0) }
        )
        await reconciler.enqueue(mutation(clock.now, played: nil, resume: 10))
        await reconciler.drain()
        try await waitUntil { await sleeper.delays == [30] }
        for _ in 0..<4 {
            clock.advance(5)
            await reconciler.enqueue(mutation(clock.now, played: nil, resume: 120))
        }
        await reconciler.enqueue(mutation(clock.now, played: false))
        let delays = await sleeper.delays
        XCTAssertEqual(delays, [30], "New writes must not reset an existing wake.")
        await applier.setFailure(nil)
        clock.advance(10)
        await sleeper.wake()
        try await waitUntil { await reconciler.pendingCount == 0 }
        let played = await applier.played
        XCTAssertEqual(played, [false], "Automatic delivery must not restore an older watched action.")
    }

    func testLiveSessionDoesNotPollOrOverwritePlaybackAndStopArmsRetry() async throws {
        let clock = RetryClock()
        let sleeper = RetrySleeper()
        let applier = RetryApplier()
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier, now: { clock.now },
            automaticRetryAllowed: { true }, retrySleeper: { try await sleeper.sleep($0) }
        )
        await reconciler.beginLiveSession(accountID: "server", itemID: "item")
        await reconciler.enqueue(mutation(clock.now, played: nil, resume: 200))
        await reconciler.drain()
        let attempts = await applier.attempts
        let delays = await sleeper.delays
        XCTAssertEqual(attempts, 0)
        XCTAssertTrue(delays.isEmpty)
        await reconciler.finishLiveSession(
            accountID: "server", itemID: "item", mutation: mutation(clock.now)
        )
        try await waitUntil { await sleeper.delays == [30] }
        await applier.setFailure(nil)
        clock.advance(30)
        await sleeper.wake()
        try await waitUntil { await reconciler.pendingCount == 0 }
        let resumes = await applier.resumes
        XCTAssertTrue(resumes.isEmpty)
    }

    func testServerRetryAfterIsHonoredEvenWhenAnEarlierWakeWasAlreadyArmed() async throws {
        let clock = RetryClock()
        let sleeper = RetrySleeper()
        let applier = RetryApplier()
        await applier.setFailure(.rateLimited(retryAfter: 3600))
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: applier, now: { clock.now },
            automaticRetryAllowed: { true }, retrySleeper: { try await sleeper.sleep($0) }
        )
        await reconciler.enqueue(mutation(clock.now))
        await reconciler.drain()
        try await waitUntil { await sleeper.delays == [30] }
        clock.advance(30)
        await sleeper.wake()
        try await waitUntil { await sleeper.delays == [3570] }
        let attempts = await applier.attempts
        XCTAssertEqual(attempts, 1)
        await applier.setFailure(nil)
        clock.advance(3570)
        await sleeper.wake()
        try await waitUntil { await reconciler.pendingCount == 0 }
    }
}
