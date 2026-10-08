import CoreModels
import XCTest
@testable import MediaDownloads

private actor FailOnceDownloadEngine: MediaDownloadEngine {
    private var attempt = 0
    private var failedProgress: (@Sendable (Int64, Int64) async -> Void)?

    func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        attempt += 1
        if attempt == 1 {
            failedProgress = onProgress
            throw Failure()
        }
        await onProgress(42, 42)
        return 42
    }

    private struct Failure: Error {}

    func reportFailedAttemptProgress() async {
        await failedProgress?(32, 64)
    }
}

private actor CountingDownloadEngine: MediaDownloadEngine {
    private var count = 0

    func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        count += 1
        await onProgress(16, 16)
        return 16
    }

    func callCount() -> Int { count }
}

private actor BlockingThenCompletingEngine: MediaDownloadEngine {
    private var attempt = 0

    func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        attempt += 1
        if attempt == 1 {
            try await Task.sleep(for: .seconds(30))
        }
        await onProgress(64, 64)
        return 64
    }
}

private actor CancellationInsensitiveThenCompletingEngine: MediaDownloadEngine {
    private var attempt = 0
    private var firstStarted = false
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstProgress: (@Sendable (Int64, Int64) async -> Void)?

    func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 {
        attempt += 1
        if attempt == 1 {
            firstProgress = onProgress
            firstStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { firstContinuation = $0 }
            await onProgress(32, 64)
            return 64
        }
        await onProgress(64, 64)
        return 64
    }

    func waitUntilFirstAttemptStarts() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseFirstAttempt() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    func attemptCount() -> Int { attempt }

    func reportIndependentProgress() async {
        guard let firstProgress else { return }
        await Task { await firstProgress(32, 64) }.value
    }
}

private actor SuspensionTestGate {
    private var entered = false
    private var opened = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor FirstQueryBlockedObserver: DownloadNetworkObserving {
    let gate: SuspensionTestGate
    private var queried = false
    init(gate: SuspensionTestGate) { self.gate = gate }

    func currentConditions() async -> DownloadNetworkConditions {
        if !queried {
            queried = true
            await gate.wait()
        }
        return .unknownSatisfied
    }
}

private final class PolicyRecordingEngine: MediaDownloadEngine, DownloadPolicyApplying, @unchecked Sendable {
    private let lock = NSLock()
    private var policy: DownloadNetworkPolicy?
    var lastPolicy: DownloadNetworkPolicy? { lock.withLock { policy } }

    func applyDownloadPolicy(_ policy: DownloadNetworkPolicy) {
        lock.withLock { self.policy = policy }
    }

    func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 { 64 }
}

private struct BlockedDiscardEngine: MediaDownloadEngine, DownloadPersistentWorkCancelling {
    let gate: SuspensionTestGate

    func discardPersistentWork(identityKey: String) async { await gate.wait() }

    func download(
        record: DownloadedMediaRecord,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> Int64 { 64 }
}

final class DownloadQueueTests: XCTestCase {

    func testCancelledQueuedAttemptCannotRestartBeforePauseCommits() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let engine = CancellationInsensitiveThenCompletingEngine()
        let (queue, directory) = makeQueue(registry: registry, engine: engine)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try await queue.enqueue(DownloadTestFactory.request())
        await engine.waitUntilFirstAttemptStarts()
        await queue.pause(identityKey: record.identityKey)
        await queue.resume(identityKey: record.identityKey)

        let entered = expectation(description: "Registry commit boundary occupied")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let blockedRegistry = Task {
            try await registry.withMutationPermit(DownloadMutationPermit()) { _ in
                entered.fulfill()
                release.wait()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let pause = Task { await queue.pause(identityKey: record.identityKey) }
        var pauseEntered = false
        for _ in 0..<2_000 {
            if await queue.hasPendingPauseForTesting(identityKey: record.identityKey) {
                pauseEntered = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(pauseEntered)
        await engine.releaseFirstAttempt()
        release.signal()
        try await blockedRegistry.value
        await pause.value
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        let attempts = await engine.attemptCount()
        XCTAssertEqual(final?.status, .paused)
        XCTAssertEqual(attempts, 1)
    }

    func testFailedRetryCannotReportProgressAfterItsTransferEnds() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let engine = FailOnceDownloadEngine()
        let directory = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = try DownloadTestFactory.record().identityKey
        let queue = DownloadQueue(
            registry: registry,
            storage: FixedDownloadStorageLocator(root: directory),
            engine: engine,
            maxAttempts: 2,
            backoff: { _ in
                await engine.reportFailedAttemptProgress()
                let record = await registry.record(forKey: key)
                XCTAssertEqual(record?.status, .preparing)
                XCTAssertEqual(record?.bytesDownloaded, 0)
            }
        )
        _ = try await queue.enqueue(DownloadTestFactory.request(quality: .hd720))
        await queue.drainForTesting()
        let completed = await registry.record(forKey: key)
        XCTAssertEqual(completed?.status, .completed)
        XCTAssertEqual(completed?.bytesDownloaded, 42)
    }

    func testIndependentProgressCannotResurrectPausedOrReplacementAttempt() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let engine = CancellationInsensitiveThenCompletingEngine()
        let (queue, dir) = makeQueue(registry: registry, engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = try await queue.enqueue(DownloadTestFactory.request(quality: .hd720))
        await engine.waitUntilFirstAttemptStarts()
        await queue.pause(identityKey: record.identityKey)
        await engine.reportIndependentProgress()
        let paused = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(paused?.status, .paused)
        XCTAssertEqual(paused?.bytesDownloaded, 0)

        await queue.resume(identityKey: record.identityKey)
        await engine.releaseFirstAttempt()
        await queue.drainForTesting()
        await engine.reportIndependentProgress()
        let completed = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(completed?.status, .completed)
        XCTAssertEqual(completed?.bytesDownloaded, 64)
    }

    func testStaleBackgroundPolicyAndPauseCannotOverrideForegroundRevision() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let gate = SuspensionTestGate()
        let engine = PolicyRecordingEngine()
        let capped = DownloadNetworkPolicy(maximumBytesPerSecond: 1_024)
        let (queue, dir) = makeQueue(
            registry: registry, engine: engine,
            observer: FirstQueryBlockedObserver(gate: gate), policy: capped
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = try await queue.enqueue(DownloadTestFactory.request(), startImmediately: false)
        await queue.setApplicationActive(false, revision: 1)
        let background = Task { await queue.updatePolicy(.default, applicationRevision: 1) }
        await gate.waitUntilEntered()
        await queue.setApplicationActive(true, revision: 2)
        await queue.updatePolicy(capped, applicationRevision: 2)
        await gate.open()
        await background.value
        await queue.updatePolicy(.default, applicationRevision: 1)
        await queue.pause(identityKey: record.identityKey, applicationRevision: 1)

        XCTAssertEqual(engine.lastPolicy, capped)
        let current = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(current?.status, .queued)
    }

    func testRetirementFencesSingleAndGroupEnqueueAfterQualityReplacementWait() async throws {
        for isGroup in [false, true] {
            let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
            let gate = SuspensionTestGate()
            let (queue, dir) = makeQueue(registry: registry, engine: BlockedDiscardEngine(gate: gate))
            defer { try? FileManager.default.removeItem(at: dir) }
            let original = try DownloadTestFactory.record(status: .completed)
            _ = try await registry.beginDownload(original)
            try await registry.markCompleted(identityKey: original.identityKey, totalBytes: 100)
            let replacement = try DownloadTestFactory.request(quality: .hd720)
            let enqueue = Task {
                if isGroup {
                    _ = try await queue.enqueueGroup([replacement], startImmediately: false)
                } else {
                    _ = try await queue.enqueue(replacement, startImmediately: false)
                }
            }
            await gate.waitUntilEntered()
            await queue.suspendScheduling()
            await gate.open()
            do {
                try await enqueue.value
                XCTFail("Retired queue persisted a replacement")
            } catch is CancellationError {
                // Retirement must reject the actual persistence, not just scheduling.
            }
            let retained = await registry.record(forKey: original.identityKey)
            XCTAssertEqual(retained?.status, .completed)
            XCTAssertEqual(retained?.quality, original.quality)
        }
    }

    func testRevokedPermitRejectsRegistryMutationAtCommitBoundary() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let permit = DownloadMutationPermit()
        let record = try DownloadTestFactory.record()
        permit.invalidate()
        do {
            _ = try await registry.withMutationPermit(permit) { try $0.beginDownload(record) }
            XCTFail("Revoked mutation permit admitted a registry write")
        } catch is CancellationError {}
        let records = await registry.all()
        XCTAssertTrue(records.isEmpty)
    }

    private func makeQueue(
        registry: DownloadedMediaRegistry,
        engine: any MediaDownloadEngine,
        observer: any DownloadNetworkObserving = StaticDownloadNetworkObserver(),
        policy: DownloadNetworkPolicy = .default
    ) -> (DownloadQueue, URL) {
        let dir = DownloadTestFactory.tempDirectory()
        let queue = DownloadQueue(
            registry: registry,
            storage: FixedDownloadStorageLocator(root: dir),
            engine: engine,
            observer: observer,
            policy: policy,
            maxAttempts: 1,
            backoff: { _ in }
        )
        return (queue, dir)
    }

    func testEnqueueCompletesAndPersists() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(registry: registry, engine: FakeDownloadEngine.completing(at: 100))
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(final?.status, .completed)
        XCTAssertEqual(final?.bytesDownloaded, 100)
        XCTAssertEqual(final?.totalBytes, 100)
    }

    func testEnqueueIsIdempotent() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(registry: registry, engine: FakeDownloadEngine.completing(at: 50))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await queue.enqueue(try DownloadTestFactory.request())
        _ = try await queue.enqueue(try DownloadTestFactory.request())
        await queue.drainForTesting()

        let count = await registry.all().count
        XCTAssertEqual(count, 1)
    }

    func testFailedQualityReplacementKeepsCompletedCopyPlayable() async throws {
        struct ReplacementFailure: Error {}

        let registry = DownloadedMediaRegistry(
            store: InMemoryDownloadedMediaStore()
        )
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: FakeDownloadEngine.failing(with: ReplacementFailure())
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = FixedDownloadStorageLocator(root: dir)
        let completed = try DownloadTestFactory.record(status: .completed)
        _ = try await registry.beginDownload(completed)
        try await registry.markCompleted(
            identityKey: completed.identityKey,
            totalBytes: 100
        )
        let originalURL = try storage.pinnedFileURL(for: completed)
        try FileManager.default.createDirectory(
            at: originalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("offline-copy".utf8).write(to: originalURL)

        _ = try await queue.enqueue(
            try DownloadTestFactory.request(quality: .hd720)
        )
        await queue.drainForTesting()

        let replacement = await registry.record(forKey: completed.identityKey)
        XCTAssertEqual(replacement?.status, .failed)
        let resolver = RegistryOfflinePlaybackResolver(
            registry: registry,
            storage: storage
        )
        let playbackURL = await resolver.localPlaybackURL(
            for: DownloadTestFactory.movie(),
            versionID: nil
        )
        XCTAssertEqual(
            playbackURL,
            try storage.replacementBackupFolderURL(
                forKey: completed.identityKey
            ).appendingPathComponent(completed.localFileName)
        )
    }

    func testNetworkGatePausesWhenPolicyDisallows() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        // Wi‑Fi‑only policy + an expensive (cellular) path -> must not download.
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: FakeDownloadEngine.completing(at: 100),
            observer: StaticDownloadNetworkObserver(
                DownloadNetworkConditions(isSatisfied: true, isExpensive: true, isConstrained: false)
            )
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(final?.status, .paused)
        XCTAssertNotEqual(final?.status, .completed)
    }

    func testCancellationMarksPaused() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(
            registry: registry, engine: FakeDownloadEngine.failing(with: CancellationError())
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(final?.status, .paused)
    }

    func testImmediateResumeWaitsForCancelledAttemptToFinish() async throws {
        let registry = DownloadedMediaRegistry(
            store: InMemoryDownloadedMediaStore()
        )
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: BlockingThenCompletingEngine()
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        try await Task.sleep(for: .milliseconds(50))
        await queue.pause(identityKey: record.identityKey)
        await queue.resume(identityKey: record.identityKey)
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(final?.status, .completed)
        XCTAssertEqual(final?.bytesDownloaded, 64)
    }

    func testDeferredEnqueueDoesNotStartUntilExplicitResume() async throws {
        let registry = DownloadedMediaRegistry(
            store: InMemoryDownloadedMediaStore()
        )
        let engine = CountingDownloadEngine()
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: engine
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(
            try DownloadTestFactory.request(),
            startImmediately: false
        )

        let callsBeforeResume = await engine.callCount()
        let deferred = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(callsBeforeResume, 0)
        XCTAssertEqual(deferred?.status, .queued)

        await queue.resume(identityKey: record.identityKey)
        await queue.drainForTesting()

        let callsAfterResume = await engine.callCount()
        let completed = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(callsAfterResume, 1)
        XCTAssertEqual(completed?.status, .completed)
    }

    func testStaleInactiveRevisionCannotBlockForegroundDownloadResume() async throws {
        let registry = DownloadedMediaRegistry(
            store: InMemoryDownloadedMediaStore()
        )
        let engine = CountingDownloadEngine()
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: engine
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(
            try DownloadTestFactory.request(),
            startImmediately: false
        )
        await queue.setApplicationActive(false, revision: 1)
        await queue.resume(identityKey: record.identityKey)
        let inactive = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(inactive?.status, .paused)
        XCTAssertEqual(inactive?.pauseReason, .directShareBackground)

        await queue.setApplicationActive(true, revision: 2)
        await queue.setApplicationActive(false, revision: 1)
        await queue.resume(identityKey: record.identityKey)
        await queue.drainForTesting()

        let calls = await engine.callCount()
        let completed = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(completed?.status, .completed)
    }

    func testDirectShareBackgroundDownloadRequiresUnrevokedExecutionLease() async throws {
        for grantsLease in [false, true] {
            let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
            let engine = CountingDownloadEngine()
            let (queue, dir) = makeQueue(registry: registry, engine: engine)
            defer { try? FileManager.default.removeItem(at: dir) }
            let record = try await queue.enqueue(DownloadTestFactory.request(), startImmediately: false)
            let lease = DownloadBackgroundExecutionLease()
            await queue.setBackgroundExecutionLease(lease)
            if !grantsLease { lease.invalidate() }
            await queue.setApplicationActive(false, revision: 1)
            await queue.resume(identityKey: record.identityKey)
            await queue.drainForTesting()
            let result = await registry.record(forKey: record.identityKey)
            let calls = await engine.callCount()
            XCTAssertEqual(result?.status, grantsLease ? .completed : .paused)
            XCTAssertEqual(calls, grantsLease ? 1 : 0)
        }
    }

    func testExecutionLeaseDoesNotOverrideSavedCappedPausePolicy() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let engine = CountingDownloadEngine()
        let (queue, dir) = makeQueue(registry: registry, engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }
        var policy = DownloadNetworkPolicy.default
        policy.maximumBytesPerSecond = 100
        policy.cappedBackgroundBehavior = .pause
        await queue.updatePolicy(policy)
        await queue.setBackgroundExecutionLease(DownloadBackgroundExecutionLease())
        let record = try await queue.enqueue(DownloadTestFactory.request(), startImmediately: false)
        await queue.setApplicationActive(false, revision: 1)
        await queue.resume(identityKey: record.identityKey)
        await queue.drainForTesting()
        let calls = await engine.callCount()
        let paused = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(paused?.status, .paused)
        XCTAssertEqual(paused?.pauseReason, .backgroundPolicy)
    }

    func testProfileRetirementRevokesExecutionLease() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(registry: registry, engine: CountingDownloadEngine())
        defer { try? FileManager.default.removeItem(at: dir) }
        let lease = DownloadBackgroundExecutionLease()
        await queue.setBackgroundExecutionLease(lease)
        await queue.suspendScheduling()
        XCTAssertFalse(lease.isValid)
        let lateLease = DownloadBackgroundExecutionLease()
        await queue.setBackgroundExecutionLease(lateLease)
        do {
            _ = try await queue.enqueue(DownloadTestFactory.request())
            XCTFail("A late system grant must not reopen a retired profile")
        } catch is CancellationError {}
    }

    func testResumeInterruptedDoesNotResetAnAlreadyRunningTransfer() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let engine = CancellationInsensitiveThenCompletingEngine()
        let (queue, dir) = makeQueue(registry: registry, engine: engine)
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = try await queue.enqueue(DownloadTestFactory.request())
        await engine.waitUntilFirstAttemptStarts()
        await queue.resumeInterrupted()
        let active = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(active?.status, .downloading)
        await engine.releaseFirstAttempt()
        await queue.drainForTesting()
        let attempts = await engine.attemptCount()
        XCTAssertEqual(attempts, 1)
    }

    func testResumeIsNotBlockedByCancellationInsensitiveAttempt() async throws {
        let registry = DownloadedMediaRegistry(
            store: InMemoryDownloadedMediaStore()
        )
        let engine = CancellationInsensitiveThenCompletingEngine()
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: engine
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        await engine.waitUntilFirstAttemptStarts()

        await queue.pause(
            identityKey: record.identityKey,
            reason: .directShareBackground
        )
        await queue.resume(identityKey: record.identityKey)
        let desired = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(desired?.status, .queued)

        await engine.releaseFirstAttempt()
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        let attempts = await engine.attemptCount()
        XCTAssertEqual(final?.status, .completed)
        XCTAssertEqual(final?.bytesDownloaded, 64)
        XCTAssertEqual(attempts, 2)
    }

    func testRetiredQueueRejectsEnqueueAndDoesNotResumePersistedWork() async throws {
        let registry = DownloadedMediaRegistry(
            store: InMemoryDownloadedMediaStore()
        )
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: FakeDownloadEngine.completing(at: 100)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(
            try DownloadTestFactory.request(),
            startImmediately: false
        )
        await queue.suspendScheduling()
        do {
            _ = try await queue.enqueue(DownloadTestFactory.request())
            XCTFail("A retired queue must reject enqueue admission")
        } catch is CancellationError {}
        await queue.resume(identityKey: record.identityKey)
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(final?.status, .queued)
        XCTAssertEqual(final?.bytesDownloaded, 0)
    }

    func testFatalErrorMarksFailed() async throws {
        struct Boom: LocalizedError {
            var errorDescription: String? {
                "The media server rejected the download."
            }
        }
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(
            registry: registry, engine: FakeDownloadEngine.failing(with: Boom())
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        await queue.drainForTesting()

        let final = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(final?.status, .failed)
        XCTAssertEqual(
            final?.failureReason,
            "The media server rejected the download."
        )
    }

    func testResumeRetriesFailedDownload() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: FailOnceDownloadEngine()
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let record = try await queue.enqueue(try DownloadTestFactory.request())
        await queue.drainForTesting()
        let failed = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(failed?.status, .failed)

        await queue.resume(identityKey: record.identityKey)
        await queue.drainForTesting()

        let completed = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(completed?.status, .completed)
        XCTAssertEqual(completed?.bytesDownloaded, 42)
    }

    func testRestartFailedReplacesStaleFileAndSourceMetadata() async throws {
        struct Failure: Error {}
        let registry = DownloadedMediaRegistry(
            store: InMemoryDownloadedMediaStore()
        )
        let (failingQueue, dir) = makeQueue(
            registry: registry,
            engine: FakeDownloadEngine.failing(with: Failure())
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let failed = try await failingQueue.enqueue(
            try DownloadTestFactory.request(quality: .hd720)
        )
        await failingQueue.drainForTesting()
        let storage = FixedDownloadStorageLocator(root: dir)
        let staleURL = try storage.pinnedFileURL(for: failed)
        try FileManager.default.createDirectory(
            at: staleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: staleURL)

        let replacementQueue = DownloadQueue(
            registry: registry,
            storage: storage,
            engine: FakeDownloadEngine.completing(at: 100),
            maxAttempts: 1,
            backoff: { _ in }
        )
        var request = try DownloadTestFactory.request(quality: .hd720)
        request.fileExtension = "mkv"
        let restarted = try await replacementQueue.restartFailed(request)
        await replacementQueue.drainForTesting()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertEqual(restarted.localFileName, "media.mkv")
        let completed = await registry.record(forKey: restarted.identityKey)
        XCTAssertEqual(completed?.status, .completed)
        XCTAssertEqual(completed?.localFileName, "media.mkv")
    }

    func testManagedRequestPersistsSecretFreeReopenSource() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: FakeDownloadEngine.completing(at: 100)
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ManagedHTTPDownloadSource(
            provider: .jellyfin,
            accountID: "account-1",
            itemID: "movie-1",
            mediaSourceID: "source-1",
            preferredAudioLanguages: ["ja", "en"]
        )
        let request = DownloadRequest.managedHTTP(
            identity: DownloadTestFactory.imdbIdentity(),
            source: source,
            snapshot: PinnedMediaSnapshot(
                title: "Movie",
                kind: .movie
            ),
            fileExtension: "mkv"
        )

        let record = try await queue.enqueue(request)
        await queue.drainForTesting()

        let stored = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(stored?.sourceKind, .managedHTTP)
        XCTAssertEqual(stored?.managedHTTPSource, source)
        XCTAssertNil(stored?.directShareSource)
    }

    func testManagedPreparationReferenceCanBePersistedDuringDownload() async throws {
        let registry = DownloadedMediaRegistry(
            store: InMemoryDownloadedMediaStore()
        )
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: FakeDownloadEngine.completing(at: 100)
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ManagedHTTPDownloadSource(
            provider: .plex,
            accountID: "account-1",
            itemID: "episode-1",
            quality: .constrained(
                .init(
                    maximumHeight: 720,
                    maximumVideoBitrateBps: 4_000_000
                )
            )
        )
        let record = try await queue.enqueue(
            .managedHTTP(
                identity: DownloadTestFactory.imdbIdentity(),
                source: source,
                snapshot: PinnedMediaSnapshot(
                    title: "Episode",
                    kind: .episode
                ),
                fileExtension: "mp4"
            )
        )
        let updated = ManagedHTTPDownloadSource(
            provider: source.provider,
            accountID: source.accountID,
            itemID: source.itemID,
            quality: source.quality,
            preparationReference: .init(
                queueIdentifier: "12",
                itemIdentifier: "34"
            )
        )

        try await registry.setManagedHTTPSource(
            identityKey: record.identityKey,
            source: updated
        )

        let stored = await registry.record(forKey: record.identityKey)
        XCTAssertEqual(stored?.managedHTTPSource, updated)
    }

    func testEnqueueGroupSharesGroupID() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(registry: registry, engine: FakeDownloadEngine.completing(at: 10))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await queue.enqueueGroup([
            try DownloadTestFactory.request(identity: .external(source: "imdb", value: "s1e1"), groupID: "season-1"),
            try DownloadTestFactory.request(identity: .external(source: "imdb", value: "s1e2"), groupID: "season-1"),
        ])
        await queue.drainForTesting()

        let members = await registry.records(inGroup: "season-1")
        XCTAssertEqual(members.count, 2)
        XCTAssertTrue(members.allSatisfy { $0.status == .completed })
    }

    func testResumeInterruptedLeavesManualPauseAlone() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let seeded = try DownloadTestFactory.record(status: .paused)
        _ = try await registry.beginDownload(seeded)
        try await registry.setStatus(
            identityKey: seeded.identityKey,
            .paused,
            failureReason: "Paused",
            pauseReason: .manual
        )
        let (queue, dir) = makeQueue(registry: registry, engine: FakeDownloadEngine.completing(at: 70))
        defer { try? FileManager.default.removeItem(at: dir) }

        await queue.resumeInterrupted()
        await queue.drainForTesting()

        let all = await registry.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.status, .paused)
        XCTAssertEqual(all.first?.pauseReason, .manual)
    }

    func testResumeInterruptedRestartsDownloadingRecords() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(status: .downloading)
        )
        let (queue, dir) = makeQueue(
            registry: registry,
            engine: FakeDownloadEngine.completing(at: 70)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        await queue.resumeInterrupted()
        await queue.drainForTesting()

        let all = await registry.all()
        XCTAssertEqual(all.first?.status, .completed)
    }

    func testStorageBudgetBlocksNewDownloads() async throws {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let (queue, dir) = makeQueue(registry: registry, engine: FakeDownloadEngine.completing(at: 100))
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await queue.enqueue(try DownloadTestFactory.request(identity: .external(source: "imdb", value: "a")))
        await queue.drainForTesting()

        await queue.updatePolicy(DownloadNetworkPolicy(storageBudgetBytes: 50))
        let second = try await queue.enqueue(try DownloadTestFactory.request(identity: .external(source: "imdb", value: "b")))
        await queue.drainForTesting()

        let final = await registry.record(forKey: second.identityKey)
        XCTAssertEqual(final?.status, .failed)
    }
}
