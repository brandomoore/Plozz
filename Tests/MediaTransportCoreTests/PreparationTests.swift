import CoreModels
import Foundation
import XCTest
@testable import MediaTransportCore

private final class PreparationClock: @unchecked Sendable {
    private struct Sleeper {
        let duration: Duration
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var instant = ContinuousClock().now
    private var sleepers: [UUID: Sleeper] = [:]

    var now: ContinuousClock.Instant { lock.withLock { instant } }

    var timing: MediaTransportPreparationTiming {
        MediaTransportPreparationTiming(now: { self.now }, sleep: { try await self.sleep($0) })
    }

    func waiting(for duration: Duration) -> Bool {
        lock.withLock { sleepers.values.contains { $0.duration == duration } }
    }

    func advance(by duration: Duration) {
        let completed = lock.withLock {
            instant = instant.advanced(by: duration)
            let completed = sleepers.filter { $0.value.deadline <= instant }
            completed.keys.forEach { sleepers.removeValue(forKey: $0) }
            return completed.values.map(\.continuation)
        }
        completed.forEach { $0.resume() }
    }

    private func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock {
                    if Task.isCancelled { return true }
                    sleepers[id] = Sleeper(
                        duration: duration, deadline: instant.advanced(by: duration),
                        continuation: continuation
                    )
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = self.lock.withLock { self.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}

private final class PreparationAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var key: MediaTransportSessionKey
    private var error: MediaTransportError?
    private var callCountStorage = 0
    let gate: AsyncTestGate?

    init(key: MediaTransportSessionKey, gate: AsyncTestGate? = nil) {
        self.key = key
        self.gate = gate
    }

    func provide() async throws -> MediaTransportSessionKey {
        lock.withLock { callCountStorage += 1 }
        await gate?.wait()
        return try lock.withLock {
            if let error { throw error }
            return key
        }
    }

    func change(key: MediaTransportSessionKey) { lock.withLock { self.key = key } }
    func reject(_ error: MediaTransportError) { lock.withLock { self.error = error } }
    var callCount: Int { lock.withLock { callCountStorage } }
}

private final class PreparingFileSystem: MediaTransportPreparationWarmingFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private let base = FakeFileSystem()
    private var prepared: [FakeByteSource] = []
    private var opened: [FakeByteSource] = []
    private var revalidationCountStorage = 0
    private var revalidationError: MediaTransportError?
    private var incrementalOpenCountStorage = 0
    private var warmCountStorage = 0
    let prepareError: MediaTransportError?
    let afterOpenGate: AsyncTestGate?
    let revalidationGate: AsyncTestGate?
    let preparedByteSource: (any MediaTransportByteSource)?
    let warmer: (@Sendable (any MediaTransportByteSource) async throws -> Void)?

    init(
        prepareError: MediaTransportError? = nil,
        afterOpenGate: AsyncTestGate? = nil,
        revalidationGate: AsyncTestGate? = nil,
        preparedByteSource: (any MediaTransportByteSource)? = nil,
        warmer: (@Sendable (any MediaTransportByteSource) async throws -> Void)? = nil
    ) {
        self.prepareError = prepareError
        self.afterOpenGate = afterOpenGate
        self.revalidationGate = revalidationGate
        self.preparedByteSource = preparedByteSource
        self.warmer = warmer
    }

    var preparedSources: [FakeByteSource] { lock.withLock { prepared } }
    var openCount: Int { lock.withLock { opened.count } }
    var revalidationCount: Int { lock.withLock { revalidationCountStorage } }
    var incrementalOpenCount: Int { lock.withLock { incrementalOpenCountStorage } }
    var warmCount: Int { lock.withLock { warmCountStorage } }

    func rejectRevalidation(_ error: MediaTransportError) {
        lock.withLock { revalidationError = error }
    }

    func prepareSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        if let prepareError { throw prepareError }
        let source = FakeByteSource(data: Data([1, 2, 3, 4]))
        let first = lock.withLock {
            prepared.append(source)
            return prepared.count == 1
        }
        // Deliberately cancellation-insensitive to exercise late-open draining.
        if first { await afterOpenGate?.wait() }
        return MediaTransportSourceLease(source: preparedByteSource ?? source)
    }

    func revalidatePreparedSource(for locator: NetworkFileLocator) async throws {
        await revalidationGate?.wait()
        try lock.withLock {
            revalidationCountStorage += 1
            if let revalidationError { throw revalidationError }
        }
    }

    func openPreparationSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        lock.withLock { incrementalOpenCountStorage += 1 }
        return try await prepareSource(for: locator)
    }

    func warmPreparedSource(
        for locator: NetworkFileLocator, source: any MediaTransportByteSource
    ) async throws {
        lock.withLock { warmCountStorage += 1 }
        try await warmer?(source)
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        let source = FakeByteSource(data: Data([1, 2, 3, 4]))
        lock.withLock { opened.append(source) }
        return MediaTransportSourceLease(source: source)
    }

    func validate() async throws {}
    func probe() async throws -> MediaTransportProbe { try await base.probe() }
    func list(relativePath: String) async throws -> [RemoteFileEntry] { [] }
    func stat(relativePath: String) async throws -> RemoteFileEntry {
        try await base.stat(relativePath: relativePath)
    }
    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data { Data() }
}

private final class PreparationProbeSource: MediaTransportPreparationFinalizingByteSource, @unchecked Sendable {
    let underlying = FakeByteSource(data: Data([1, 2, 3, 4]))
    let cancelledRead = XCTestExpectation(description: "borrowed read cancelled")
    let gate: AsyncTestGate?
    let readError: MediaTransportError?
    let shutdownGate: AsyncTestGate?
    private let lock = NSLock()
    private var readCountStorage = 0
    private var finishedReadCountsStorage: [Int] = []

    init(
        gate: AsyncTestGate? = nil, readError: MediaTransportError? = nil,
        shutdownGate: AsyncTestGate? = nil
    ) {
        self.gate = gate
        self.readError = readError
        self.shutdownGate = shutdownGate
    }
    var byteSize: Int64 { underlying.byteSize }
    var readCount: Int { lock.withLock { readCountStorage } }
    var finishedReadCounts: [Int] { lock.withLock { finishedReadCountsStorage } }

    func finishPreparation() {
        lock.withLock { finishedReadCountsStorage.append(readCountStorage) }
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        lock.withLock { readCountStorage += 1 }
        return try await withTaskCancellationHandler {
            await gate?.wait()
            if let readError { throw readError }
            return try await underlying.read(at: offset, length: length)
        } onCancel: {
            self.cancelledRead.fulfill()
        }
    }

    func shutdown() async {
        await shutdownGate?.wait()
        await underlying.shutdown()
    }
}

private final class PreparationSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem
    private let lock = NSLock()
    private var shutdownCountStorage = 0

    init(key: MediaTransportSessionKey, fileSystem: any MediaTransportFileSystem) {
        self.key = key
        self.fileSystem = fileSystem
    }

    var shutdownCount: Int { lock.withLock { shutdownCountStorage } }
    func shutdown() async { lock.withLock { shutdownCountStorage += 1 } }
    func isHealthy() async -> Bool { true }
}

private final class PreparationAdmission: @unchecked Sendable {
    let arbiter = MediaIOArbiter(accountID: "account")
    let didAcquire = XCTestExpectation(description: "playback admission requested")
    private let lock = NSLock()
    private var countStorage = 0
    var count: Int { lock.withLock { countStorage } }

    func acquire() async throws -> MediaIOPlaybackLease {
        lock.withLock { countStorage += 1 }
        didAcquire.fulfill()
        return try await arbiter.acquirePlayback()
    }
}

private struct NonPreparingResolver: MediaTransportNetworkFileResolving {
    func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
        throw MediaTransportError.unsupportedCapability("test resolver")
    }
}

private struct PreparationFixture {
    let registry: MediaTransportResolverRegistry
    let resolver: MediaTransportNetworkFileResolver
    let key: MediaTransportSessionKey
    let locator: NetworkFileLocator
    let authorization: PreparationAuthorization
    let session: PreparationSession
    let admission: PreparationAdmission
    let clock: PreparationClock

    static func make(
        fileSystem: any MediaTransportFileSystem = PreparingFileSystem(),
        transport: String = "https",
        authorizationGate: AsyncTestGate? = nil,
        sourcePreparer: MediaTransportNetworkFileResolver.SourcePreparer? = nil
    ) async throws -> PreparationFixture {
        let key = try makeSessionKey(
            endpoint: MediaTransportEndpointIdentity(
                transportIdentifier: transport, host: "nas.example.com", rootPath: "/media"
            ),
            role: .playback
        )
        let locator = try Self.locator(key: key)
        let registry = MediaTransportResolverRegistry()
        let session = PreparationSession(key: key, fileSystem: fileSystem)
        try await registry.register(session: session)
        let authorization = PreparationAuthorization(key: key, gate: authorizationGate)
        let admission = PreparationAdmission()
        let clock = PreparationClock()
        let resolver = MediaTransportNetworkFileResolver(
            registry: registry,
            playbackLeaseProvider: { _ in try await admission.acquire() },
            sourcePreparer: sourcePreparer,
            sessionKeyProvider: { _ in try await authorization.provide() },
            preparationTiming: clock.timing
        )
        return PreparationFixture(
            registry: registry, resolver: resolver, key: key, locator: locator,
            authorization: authorization, session: session, admission: admission, clock: clock
        )
    }

    static func locator(
        key: MediaTransportSessionKey,
        sourceID: String = "source",
        path: String = "movie.mkv",
        identity: String = "\"one\"",
        size: Int64 = 4,
        format: MediaFormatHint = MediaFormatHint()
    ) throws -> NetworkFileLocator {
        try NetworkFileLocator(
            accountID: key.accountID,
            sourceID: sourceID,
            credentialRevision: key.credentialRevision,
            relativePath: path,
            representation: RemoteFileRepresentation(
                size: size, identity: RemoteFileIdentity(kind: .strongETag, value: identity),
                consistency: .stronglyBound
            ),
            formatHint: format
        )
    }
}

private actor PreparationBorrowRecorder {
    private(set) var source: (any MediaTransportByteSource)?
    func record(_ source: any MediaTransportByteSource) { self.source = source }
}

private actor PreparationPositionRecorder {
    private(set) var positions: [Double] = []
    func record(_ position: Double) { positions.append(position) }
}

final class PreparationTests: XCTestCase {
    func testExpectedIncompleteBeforePlayDiscardsSourceAndAllowsFreshResolution() async throws {
        for reason: MediaTransportPreparationIncomplete in [
            .inputBudget, .packetBudget, .packetSizeBudget, .timeBudget, .endOfSource, .seekUnavailable,
        ] {
            let source = PreparationProbeSource()
            let fileSystem = PreparingFileSystem(preparedByteSource: source)
            let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, borrowed in
                _ = try await borrowed.read(at: 0, length: 1)
                throw reason
            })
            let handle = try f.resolver.beginPreparation(f.locator)
            do { try await handle.waitUntilReady(); XCTFail("Incomplete coverage became ready") }
            catch let error as MediaTransportPreparationIncomplete { XCTAssertEqual(error, reason) }
            XCTAssertEqual(source.underlying.shutdownCount, 1)
            XCTAssertTrue(source.finishedReadCounts.isEmpty)
            XCTAssertNil(handle.warmupOutcome)
            XCTAssertEqual(f.admission.count, 0)
            let checksBeforePlay = f.authorization.callCount
            let played = try await f.resolver.resolve(f.locator)
            XCTAssertFalse(played.wasPrepared)
            XCTAssertFalse(handle.wasConsumed)
            XCTAssertEqual(fileSystem.openCount, 1)
            XCTAssertGreaterThanOrEqual(f.authorization.callCount, checksBeforePlay + 2)
            XCTAssertEqual(f.admission.count, 1)
            await played.waitForFinalShutdown()
            let allowed = await f.admission.arbiter.permitsBackgroundWork()
            XCTAssertTrue(allowed)
            XCTAssertEqual(source.underlying.shutdownCount, 1)
        }
    }

    func testIncompleteRacingHandoffDrainsReadsAndShutdownBeforeColdOpen() async throws {
        let readGate = AsyncTestGate()
        let shutdownGate = AsyncTestGate()
        let source = PreparationProbeSource(gate: readGate, shutdownGate: shutdownGate)
        let fileSystem = PreparingFileSystem(preparedByteSource: source)
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, borrowed in
            _ = try await borrowed.read(at: 0, length: 4)
            throw MediaTransportPreparationIncomplete.timeBudget
        })
        let handle = try f.resolver.beginPreparation(f.locator)
        await readGate.waitUntilEntered()
        let playing = Task { try await f.resolver.resolve(f.locator) }
        await fulfillment(of: [source.cancelledRead], timeout: 2)
        XCTAssertEqual(fileSystem.openCount, 0)
        XCTAssertEqual(source.underlying.shutdownCount, 0)
        readGate.open()
        await shutdownGate.waitUntilEntered()
        XCTAssertEqual(fileSystem.openCount, 0)
        XCTAssertEqual(source.underlying.shutdownCount, 0)
        XCTAssertNil(handle.warmupOutcome)
        shutdownGate.open()
        let played = try await playing.value
        XCTAssertFalse(played.wasPrepared)
        XCTAssertFalse(handle.wasConsumed)
        XCTAssertTrue(source.finishedReadCounts.isEmpty)
        XCTAssertEqual(source.underlying.shutdownCount, 1)
        XCTAssertEqual(fileSystem.openCount, 1)
        do { try await handle.waitUntilReady(); XCTFail("Incomplete handoff became ready") }
        catch let error as MediaTransportPreparationIncomplete { XCTAssertEqual(error, .timeBudget) }
        await played.waitForFinalShutdown()
    }

    func testIncompleteFallbackRechecksAuthorizationAfterSourceDrain() async throws {
        let shutdownGate = AsyncTestGate()
        let source = PreparationProbeSource(shutdownGate: shutdownGate)
        let fileSystem = PreparingFileSystem(preparedByteSource: source)
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, _ in
            throw MediaTransportPreparationIncomplete.endOfSource
        })
        let handle = try f.resolver.beginPreparation(f.locator)
        await shutdownGate.waitUntilEntered()
        let playing = Task { try await f.resolver.resolve(f.locator) }
        await fulfillment(of: [f.admission.didAcquire], timeout: 2)
        let revoked = MediaTransportError.authentication(reason: "revoked during drain")
        f.authorization.reject(revoked)
        shutdownGate.open()
        do { _ = try await playing.value; XCTFail("Cold fallback used stale authorization") }
        catch let error as MediaTransportError { XCTAssertEqual(error, revoked) }
        XCTAssertEqual(fileSystem.openCount, 0)
        XCTAssertFalse(handle.wasConsumed)
        XCTAssertNil(handle.warmupOutcome)
        XCTAssertEqual(source.underlying.shutdownCount, 1)
        let allowed = await f.admission.arbiter.permitsBackgroundWork()
        XCTAssertTrue(allowed)
    }

    func testSupersededIncompleteCannotColdOpenOrDiscardNewGeneration() async throws {
        let gate = AsyncTestGate()
        let handoff = expectation(description: "First Play interrupted its exact warmup")
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, position, _ in
            if position == 600 {
                await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: {
                    handoff.fulfill()
                }
                throw MediaTransportPreparationIncomplete.packetBudget
            }
            XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
        })
        let first = try f.resolver.beginPreparation(f.locator, startPosition: 600)
        await gate.waitUntilEntered()
        let firstPlay = Task { try await f.resolver.resolve(f.locator) }
        await fulfillment(of: [handoff], timeout: 2)
        let second = try f.resolver.beginPreparation(f.locator)
        do { _ = try await firstPlay.value; XCTFail("Superseded Play started a cold open") }
        catch let error as MediaTransportError { XCTAssertEqual(error, .cancelled) }
        do { try await first.waitUntilReady(); XCTFail("Superseded ticket became ready") }
        catch let error as MediaTransportError { XCTAssertEqual(error, .cancelled) }
        XCTAssertEqual(fileSystem.preparedSources.count, 1)
        XCTAssertEqual(fileSystem.openCount, 0)
        gate.open()
        try await second.waitUntilReady()
        first.cancel()
        let played = try await f.resolver.resolve(f.locator)
        XCTAssertTrue(played.wasPrepared)
        XCTAssertTrue(second.wasConsumed)
        XCTAssertFalse(first.wasConsumed)
        XCTAssertEqual(fileSystem.preparedSources.count, 2)
        XCTAssertEqual(fileSystem.openCount, 0)
        await played.waitForFinalShutdown()
    }

    func testRealReadFailuresOverrideIncompleteForPendingAndLegacyPreparation() async throws {
        for failure: MediaTransportError in [
            .authentication(reason: "revoked"), .trust(reason: "changed"), .permissionDenied,
            .sourceChanged(reason: "ETag changed"), .protocolViolation(reason: "invalid range"),
            .transport(code: -1004), .timeout,
        ] {
            for pending in [false, true] {
                let source = PreparationProbeSource(readError: failure)
                let fileSystem = PreparingFileSystem(preparedByteSource: source)
                let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, borrowed in
                    do { _ = try await borrowed.read(at: 0, length: 1) }
                    catch { throw MediaTransportPreparationIncomplete.inputBudget }
                })
                if pending {
                    let handle = try f.resolver.beginPreparation(f.locator)
                    do { try await handle.waitUntilReady(); XCTFail("Real failure became incomplete") }
                    catch let error as MediaTransportError { XCTAssertEqual(error, failure) }
                    do { _ = try await f.resolver.resolve(f.locator); XCTFail("Real failure became a cold miss") }
                    catch let error as MediaTransportError { XCTAssertEqual(error, failure) }
                    XCTAssertFalse(handle.wasConsumed)
                    XCTAssertNil(handle.warmupOutcome)
                } else {
                    do { _ = try await f.resolver.prepare(f.locator); XCTFail("Real failure became incomplete") }
                    catch let error as MediaTransportError { XCTAssertEqual(error, failure) }
                }
                XCTAssertEqual(fileSystem.openCount, 0)
                XCTAssertEqual(source.underlying.shutdownCount, 1)
                XCTAssertTrue(source.finishedReadCounts.isEmpty)
            }
        }
    }

    func testRealReadFailureWinsOverIncompleteRacingHandoff() async throws {
        let gate = AsyncTestGate()
        let failure = MediaTransportError.sourceChanged(reason: "ETag changed")
        let source = PreparationProbeSource(gate: gate, readError: failure)
        let fileSystem = PreparingFileSystem(preparedByteSource: source)
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, borrowed in
            do { _ = try await borrowed.read(at: 0, length: 1) }
            catch { throw MediaTransportPreparationIncomplete.seekUnavailable }
        })
        let handle = try f.resolver.beginPreparation(f.locator)
        await gate.waitUntilEntered()
        let playing = Task { try await f.resolver.resolve(f.locator) }
        await fulfillment(of: [source.cancelledRead], timeout: 2)
        gate.open()
        do { _ = try await playing.value; XCTFail("ETag failure was downgraded during handoff") }
        catch let error as MediaTransportError { XCTAssertEqual(error, failure) }
        XCTAssertEqual(fileSystem.openCount, 0)
        XCTAssertFalse(handle.wasConsumed)
        XCTAssertNil(handle.warmupOutcome)
        XCTAssertTrue(source.finishedReadCounts.isEmpty)
        XCTAssertEqual(source.underlying.shutdownCount, 1)
    }

    func testResolvedTransportIdentifierRemainsPinnedToItsExactSession() async throws {
        for transport in ["http", "https", "smb", "sftp"] {
            let f = try await PreparationFixture.make(transport: transport)
            let resolved = try await f.resolver.resolve(f.locator)
            let authorizationCalls = f.authorization.callCount
            XCTAssertEqual(resolved.transportIdentifier, transport)
            f.authorization.reject(.authentication(reason: "authorization changed"))
            await f.registry.retire(
                accountID: f.key.accountID, credentialRevision: f.key.credentialRevision
            )
            XCTAssertEqual(resolved.transportIdentifier, transport)
            XCTAssertEqual(f.authorization.callCount, authorizationCalls)
            await resolved.waitForFinalShutdown()
        }
    }

    func testPendingHandoffDrainsBorrowBeforeSealingAndTransfersSameSource() async throws {
        let gate = AsyncTestGate()
        let source = PreparationProbeSource(gate: gate)
        let captured = PreparationBorrowRecorder()
        let fileSystem = PreparingFileSystem(preparedByteSource: source)
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, borrowed in
            await captured.record(borrowed)
            _ = try await borrowed.read(at: 0, length: 4)
        })
        let handle = try f.resolver.beginPreparation(f.locator)
        await gate.waitUntilEntered()
        XCTAssertNil(handle.warmupOutcome)
        XCTAssertEqual(f.admission.count, 0)
        handle.requestPlaybackHandoff()
        await fulfillment(of: [source.cancelledRead], timeout: 2)
        let playing = Task { try await f.resolver.resolve(f.locator) }
        await fulfillment(of: [f.admission.didAcquire], timeout: 2)
        XCTAssertEqual(fileSystem.openCount, 0)
        XCTAssertTrue(source.finishedReadCounts.isEmpty)
        XCTAssertEqual(source.underlying.shutdownCount, 0)

        gate.open()
        try await handle.waitUntilReady()
        let played = try await playing.value
        XCTAssertEqual(handle.warmupOutcome, .interruptedForPlayback)
        XCTAssertTrue(handle.wasConsumed)
        XCTAssertTrue(played.wasPrepared)
        XCTAssertEqual(fileSystem.incrementalOpenCount, 1)
        XCTAssertEqual(fileSystem.revalidationCount, 1)
        XCTAssertEqual(source.finishedReadCounts, [1])
        let borrowed = await captured.source
        do {
            _ = try await XCTUnwrap(borrowed).read(at: 0, length: 1)
            XCTFail("sealed borrow admitted a new read")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }
        let cursor = try XCTUnwrap(played.sourceLease.makeCursor())
        let bytes = try await cursor.read(at: 0, length: 4)
        XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
        handle.cancel()
        XCTAssertEqual(source.underlying.shutdownCount, 0)
        cursor.close()
        await played.waitForFinalShutdown()
        await played.waitForFinalShutdown()
        XCTAssertEqual(source.underlying.shutdownCount, 1)
        let allowed = await f.admission.arbiter.permitsBackgroundWork()
        XCTAssertTrue(allowed)
        let next = try await f.resolver.resolve(f.locator)
        XCTAssertFalse(next.wasPrepared)
        await next.waitForFinalShutdown()
    }

    func testPendingHandoffBeforeOpeningFinishesSkipsOptionalWarming() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem(afterOpenGate: gate)
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, _ in
            XCTFail("handoff before warming must skip the callback")
        })
        let resolver: any MediaTransportNetworkFileResolving = f.resolver
        let handle = try resolver.beginPreparation(f.locator)
        await gate.waitUntilEntered()
        handle.requestPlaybackHandoff()
        XCTAssertEqual(f.admission.count, 0)
        XCTAssertNil(handle.warmupOutcome)
        gate.open()
        try await handle.waitUntilReady()
        XCTAssertEqual(handle.warmupOutcome, .interruptedForPlayback)
        XCTAssertEqual(fileSystem.warmCount, 0)
        let played = try await resolver.resolve(f.locator)
        XCTAssertTrue(played.wasPrepared)
        XCTAssertEqual(fileSystem.openCount, 0)
        await played.waitForFinalShutdown()
    }

    func testPendingTicketWithoutHandoffCompletesBothWarmersAndForwardsPosition() async throws {
        for position in [0.0, 600] {
            let source = PreparationProbeSource()
            let fileSystem = PreparingFileSystem(preparedByteSource: source, warmer: { borrowed in
                _ = try await borrowed.read(at: 0, length: 1)
            })
            let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, received, borrowed in
                XCTAssertEqual(received, position)
                XCTAssertEqual(source.readCount, 1)
                _ = try await borrowed.read(at: 1, length: 1)
            })
            let resolver: any MediaTransportNetworkFileResolving = f.resolver
            let handle = try resolver.beginPreparation(f.locator, startPosition: position)
            try await handle.waitUntilReady()
            XCTAssertEqual(handle.warmupOutcome, .completed)
            handle.requestPlaybackHandoff()
            XCTAssertEqual(handle.warmupOutcome, .completed)
            XCTAssertEqual(fileSystem.warmCount, 1)
            XCTAssertEqual(source.finishedReadCounts, [2])
            XCTAssertEqual(f.admission.count, 0)
            let played = try await resolver.resolve(f.locator)
            XCTAssertTrue(played.wasPrepared)
            await played.waitForFinalShutdown()
        }
    }

    func testLegacyPrepareAndPendingPlayStillWaitForCompleteWarmup() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem(warmer: { _ in
            XCTFail("legacy prepare must not use the incremental filesystem lane")
        })
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, _ in
            await gate.wait()
            XCTAssertFalse(Task.isCancelled)
        })
        let preparing = Task { try await f.resolver.prepare(f.locator) }
        await gate.waitUntilEntered()
        let playing = Task { try await f.resolver.resolve(f.locator) }
        await fulfillment(of: [f.admission.didAcquire], timeout: 2)
        XCTAssertEqual(fileSystem.openCount, 0)
        gate.open()
        let handle = try await preparing.value
        let played = try await playing.value
        XCTAssertEqual(handle.warmupOutcome, .completed)
        XCTAssertEqual(fileSystem.incrementalOpenCount, 0)
        XCTAssertEqual(fileSystem.warmCount, 0)
        handle.requestPlaybackHandoff()
        await played.waitForFinalShutdown()
    }

    func testResolveAutomaticallyInterruptsOnlyExactPendingPlaybackTicket() async throws {
        let gate = AsyncTestGate()
        let source = PreparationProbeSource(gate: gate)
        let fileSystem = PreparingFileSystem(preparedByteSource: source)
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, borrowed in
            _ = try await borrowed.read(at: 0, length: 4)
        })
        let handle = try f.resolver.beginPreparation(f.locator)
        await gate.waitUntilEntered()
        let probe = try await f.resolver.withoutPlaybackAdmission().resolve(f.locator)
        XCTAssertFalse(probe.wasPrepared)
        await probe.waitForFinalShutdown()
        let other = try PreparationFixture.locator(key: f.key, path: "other.mkv")
        let different = try await f.resolver.resolve(other)
        XCTAssertFalse(different.wasPrepared)
        await different.waitForFinalShutdown()
        XCTAssertNil(handle.warmupOutcome)
        let playing = Task { try await f.resolver.resolve(f.locator) }
        await fulfillment(of: [source.cancelledRead], timeout: 2)
        gate.open()
        let played = try await playing.value
        XCTAssertTrue(handle.wasConsumed)
        XCTAssertEqual(handle.warmupOutcome, .interruptedForPlayback)
        await played.waitForFinalShutdown()
    }

    func testInterruptedReadFailureSurvivesCallbackCancellationTranslation() async throws {
        for failure in [
            MediaTransportError.authentication(reason: "revoked"),
            .sourceChanged(reason: "changed"), .trust(reason: "changed"), .transport(code: -1004),
        ] {
            let gate = AsyncTestGate()
            let source = PreparationProbeSource(gate: gate, readError: failure)
            let fileSystem = PreparingFileSystem(preparedByteSource: source)
            let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, borrowed in
                do { _ = try await borrowed.read(at: 0, length: 4) }
                catch { throw CancellationError() }
            })
            let handle = try f.resolver.beginPreparation(f.locator)
            await gate.waitUntilEntered()
            let playing = Task { try await f.resolver.resolve(f.locator) }
            await fulfillment(of: [source.cancelledRead], timeout: 2)
            gate.open()
            do {
                _ = try await playing.value
                XCTFail("a real transport failure was masked as partial success")
            } catch let error as MediaTransportError {
                XCTAssertEqual(error, failure)
            }
            do {
                try await handle.waitUntilReady()
                XCTFail("failed preparation became ready")
            } catch let error as MediaTransportError {
                XCTAssertEqual(error, failure)
            }
            XCTAssertNil(handle.warmupOutcome)
            XCTAssertFalse(handle.wasConsumed)
            XCTAssertTrue(source.finishedReadCounts.isEmpty)
            XCTAssertEqual(source.underlying.shutdownCount, 1)
            XCTAssertEqual(fileSystem.openCount, 0)
        }
    }

    func testPendingFailureBeforePlayIsNotSilentlyTurnedIntoColdSuccess() async throws {
        let failure = MediaTransportError.protocolViolation(reason: "probe failed")
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, _ in
            throw failure
        })
        let handle = try f.resolver.beginPreparation(f.locator)
        do { try await handle.waitUntilReady(); XCTFail("failure became ready") }
        catch let error as MediaTransportError { XCTAssertEqual(error, failure) }
        do { _ = try await f.resolver.resolve(f.locator); XCTFail("failure became a cold miss") }
        catch let error as MediaTransportError { XCTAssertEqual(error, failure) }
        XCTAssertEqual(fileSystem.openCount, 0)
        XCTAssertFalse(handle.wasConsumed)
        let retry = try await f.resolver.resolve(f.locator)
        XCTAssertFalse(retry.wasPrepared)
        XCTAssertEqual(fileSystem.openCount, 1)
        await retry.waitForFinalShutdown()
    }

    func testPendingHandoffRetainsFreshAuthorizationIdentityAndRetirementFences() async throws {
        for boundary in 0..<3 {
            let gate = AsyncTestGate()
            let fileSystem = PreparingFileSystem()
            let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, _ in
                await gate.wait()
            })
            let handle = try f.resolver.beginPreparation(f.locator)
            await gate.waitUntilEntered()
            handle.requestPlaybackHandoff()
            gate.open()
            try await handle.waitUntilReady()
            let failure: MediaTransportError
            switch boundary {
            case 0:
                failure = .authentication(reason: "revoked")
                f.authorization.reject(failure)
            case 1:
                failure = .sourceChanged(reason: "DAV identity changed")
                fileSystem.rejectRevalidation(failure)
            default:
                failure = .cancelled
                await f.registry.retire(accountID: f.key.accountID, credentialRevision: f.key.credentialRevision)
            }
            do { _ = try await f.resolver.resolve(f.locator); XCTFail("boundary bypassed") }
            catch let error as MediaTransportError { XCTAssertEqual(error, failure) }
            XCTAssertFalse(handle.wasConsumed)
            XCTAssertEqual(fileSystem.openCount, 0)
            await fulfillment(of: [try XCTUnwrap(fileSystem.preparedSources.first).didShutdown], timeout: 2)
        }
    }

    func testFailedPendingTicketExpiresWithoutKeepingAnOpenSource() async throws {
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, _ in
            throw MediaTransportError.sourceChanged(reason: "changed")
        })
        let handle = try f.resolver.beginPreparation(f.locator)
        do { try await handle.waitUntilReady(); XCTFail("failed source became ready") }
        catch let error as MediaTransportError {
            XCTAssertEqual(error, .sourceChanged(reason: "changed"))
        }
        XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
        f.clock.advance(by: .seconds(30))
        let played = try await f.resolver.resolve(f.locator)
        XCTAssertFalse(played.wasPrepared)
        XCTAssertFalse(handle.wasConsumed)
        XCTAssertEqual(fileSystem.openCount, 1)
        await played.waitForFinalShutdown()
    }

    func testPendingHandleDeinitCancelsAndDrainsOnlyItsBorrower() async throws {
        let gate = AsyncTestGate()
        let source = PreparationProbeSource(gate: gate)
        let f = try await PreparationFixture.make(
            fileSystem: PreparingFileSystem(preparedByteSource: source),
            sourcePreparer: { _, _, borrowed in _ = try await borrowed.read(at: 0, length: 1) }
        )
        var handle: MediaTransportPreparation? = try f.resolver.beginPreparation(f.locator)
        await gate.waitUntilEntered()
        XCTAssertNotNil(handle)
        handle = nil
        await fulfillment(of: [source.cancelledRead], timeout: 2)
        XCTAssertEqual(source.underlying.shutdownCount, 0)
        gate.open()
        await fulfillment(of: [source.underlying.didShutdown], timeout: 2)
        XCTAssertEqual(source.underlying.shutdownCount, 1)
        XCTAssertTrue(source.finishedReadCounts.isEmpty)
    }

    func testPendingReplacementAndOldHandoffCannotAffectNewGeneration() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, position, _ in
            if position == 600 { await gate.wait() }
        })
        let first = try f.resolver.beginPreparation(f.locator, startPosition: 600)
        await gate.waitUntilEntered()
        first.requestPlaybackHandoff()
        let second = try f.resolver.beginPreparation(f.locator)
        do { try await first.waitUntilReady(); XCTFail("superseded ticket became ready") }
        catch let error as MediaTransportError { XCTAssertEqual(error, .cancelled) }
        XCTAssertEqual(fileSystem.preparedSources.count, 1)
        first.requestPlaybackHandoff()
        gate.open()
        try await second.waitUntilReady()
        XCTAssertEqual(second.warmupOutcome, .completed)
        XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
        first.cancel()
        let played = try await f.resolver.resolve(f.locator)
        XCTAssertTrue(second.wasConsumed)
        await played.waitForFinalShutdown()
    }

    func testCancelledOrTimedOutPendingHandoffStillDrainsBeforeColdOpen() async throws {
        for timeout in [false, true] {
            let gate = AsyncTestGate()
            let source = PreparationProbeSource(gate: gate)
            let fileSystem = PreparingFileSystem(preparedByteSource: source)
            let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, borrowed in
                _ = try await borrowed.read(at: 0, length: 4)
            })
            let handle = try f.resolver.beginPreparation(f.locator)
            await gate.waitUntilEntered()
            handle.requestPlaybackHandoff()
            await fulfillment(of: [source.cancelledRead], timeout: 2)
            if timeout {
                let ready = await waitUntil { f.clock.waiting(for: .seconds(30)) }
                XCTAssertTrue(ready)
                f.clock.advance(by: .seconds(30))
            } else {
                handle.cancel()
            }
            do { try await handle.waitUntilReady(); XCTFail("cancelled ticket became ready") }
            catch let error as MediaTransportError { XCTAssertEqual(error, timeout ? .timeout : .cancelled) }
            let playing = Task { try await f.resolver.resolve(f.locator) }
            await fulfillment(of: [f.admission.didAcquire], timeout: 2)
            XCTAssertEqual(fileSystem.openCount, 0)
            XCTAssertEqual(source.underlying.shutdownCount, 0)
            gate.open()
            let played = try await playing.value
            XCTAssertFalse(played.wasPrepared)
            XCTAssertEqual(source.underlying.shutdownCount, 1)
            XCTAssertTrue(source.finishedReadCounts.isEmpty)
            XCTAssertNil(handle.warmupOutcome)
            await played.waitForFinalShutdown()
        }
    }

    func testPendingTicketRejectsUnsupportedAndInvalidRequests() async throws {
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let resolvers: [any MediaTransportNetworkFileResolving] = [
            f.resolver, NonPreparingResolver(), f.resolver.withoutPlaybackAdmission(),
        ]
        for resolver in resolvers {
            for position in [-1, Double.nan, .infinity, -.infinity] {
                XCTAssertThrowsError(try resolver.beginPreparation(f.locator, startPosition: position)) {
                    XCTAssertEqual($0 as? MediaTransportError, .invalidInput(reason: "invalid preparation start position"))
                }
            }
        }
        for resolver in resolvers.dropFirst() {
            XCTAssertThrowsError(try resolver.beginPreparation(f.locator)) {
                guard let error = $0 as? MediaTransportError, case .unsupportedCapability = error else {
                    return XCTFail("expected unsupported capability, got \($0)")
                }
            }
        }
        XCTAssertEqual(f.authorization.callCount, 0)
        XCTAssertEqual(f.admission.count, 0)
        XCTAssertTrue(fileSystem.preparedSources.isEmpty)
    }

    func testPreparationDeadlineAndUnclaimedLifetimeAreThirtySeconds() {
        let timing = MediaTransportPreparationTiming()
        XCTAssertEqual(MediaTransportPreparationTiming.defaultTimeout, .seconds(30))
        XCTAssertEqual(timing.timeout, .seconds(30))
        XCTAssertEqual(timing.lifetime, .seconds(30))
    }

    func testExistentialPreparationForwardsDefaultAndRequestedPosition() async throws {
        let positions = PreparationPositionRecorder()
        let f = try await PreparationFixture.make(sourcePreparer: { _, position, _ in
            await positions.record(position)
        })
        let resolver: any MediaTransportNetworkFileResolving = f.resolver
        let beginning = try await resolver.prepare(f.locator)
        let resumed = try await resolver.prepare(f.locator, startPosition: 600)
        let recorded = await positions.positions
        XCTAssertEqual(recorded, [0, 600])
        XCTAssertFalse(beginning.wasConsumed)
        let played = try await resolver.resolve(f.locator)
        XCTAssertTrue(played.wasPrepared)
        XCTAssertTrue(resumed.wasConsumed)
        beginning.cancel()
        resumed.cancel()
        await played.waitForFinalShutdown()
    }

    func testInvalidPreparationPositionsAreRejectedBeforeIO() async throws {
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, _ in
            XCTFail("invalid position invoked the source preparer")
        })
        let resolver: any MediaTransportNetworkFileResolving = f.resolver
        let candidates: [any MediaTransportNetworkFileResolving] = [resolver, NonPreparingResolver()]
        for position in [Double.nan, .infinity, -.infinity, -1] {
            for candidate in candidates {
                do {
                    _ = try await candidate.prepare(f.locator, startPosition: position)
                    XCTFail("invalid position was accepted")
                } catch let error as MediaTransportError {
                    XCTAssertEqual(error, .invalidInput(reason: "invalid preparation start position"))
                }
            }
        }
        XCTAssertEqual(f.authorization.callCount, 0)
        XCTAssertEqual(f.admission.count, 0)
        XCTAssertTrue(fileSystem.preparedSources.isEmpty)
        XCTAssertEqual(fileSystem.openCount, 0)
    }

    func testSameFilePositionReplacementCannotPublishOldGeneration() async throws {
        let gate = AsyncTestGate()
        let positions = PreparationPositionRecorder()
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, position, _ in
            await positions.record(position)
            if position == 600 { await gate.wait() }
        })
        let resolver: any MediaTransportNetworkFileResolving = f.resolver
        let resumed = Task { try await resolver.prepare(f.locator, startPosition: 600) }
        await gate.waitUntilEntered()
        let beginning = Task { try await resolver.prepare(f.locator, startPosition: 0) }
        do {
            _ = try await resumed.value
            XCTFail("superseded position published a preparation")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }
        let pendingPositions = await positions.positions
        XCTAssertEqual(pendingPositions, [600])
        gate.open()
        let handle = try await beginning.value
        let completedPositions = await positions.positions
        XCTAssertEqual(completedPositions, [600, 0])
        XCTAssertEqual(fileSystem.preparedSources.count, 2)
        XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
        let played = try await resolver.resolve(f.locator)
        XCTAssertTrue(played.wasPrepared)
        XCTAssertTrue(handle.wasConsumed)
        XCTAssertEqual(fileSystem.openCount, 0)
        handle.cancel()
        await played.waitForFinalShutdown()
    }

    func testSourcePreparerCanReadAndCloseWithoutConsumingReservation() async throws {
        let source = PreparationProbeSource()
        let captured = PreparationBorrowRecorder()
        source.underlying.didShutdown.assertForOverFulfill = true
        let fileSystem = PreparingFileSystem(preparedByteSource: source)
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { locator, position, borrowed in
            XCTAssertEqual(locator.relativePath, "movie.mkv")
            XCTAssertEqual(position, 0)
            XCTAssertTrue(source.finishedReadCounts.isEmpty)
            await captured.record(borrowed)
            // Mirrors a transport reader that owns a lease around the borrowed
            // source and closes that reader at the end of its header probe.
            let readerLease = MediaTransportSourceLease(source: borrowed)
            let reader = try XCTUnwrap(readerLease.makeCursor())
            let bytes = try await reader.read(at: 1, length: 2)
            XCTAssertEqual(bytes, Data([2, 3]))
            reader.close()
            await readerLease.waitForFinalShutdown()
            await borrowed.shutdown()
            XCTAssertTrue(source.finishedReadCounts.isEmpty)
        })
        let handle = try await f.resolver.prepare(f.locator)
        XCTAssertFalse(handle.wasConsumed)
        XCTAssertEqual(source.readCount, 1)
        XCTAssertEqual(source.finishedReadCounts, [1])
        XCTAssertEqual(source.underlying.shutdownCount, 0)
        XCTAssertEqual(f.admission.count, 0)
        let capturedSource = await captured.source
        let retainedBorrow = try XCTUnwrap(capturedSource)
        do {
            _ = try await retainedBorrow.read(at: 0, length: 1)
            XCTFail("preparation read was admitted after sealing")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(source.readCount, 1)
        let resolved = try await f.resolver.resolve(f.locator)
        XCTAssertTrue(resolved.wasPrepared)
        let player = try XCTUnwrap(resolved.sourceLease.makeCursor())
        let bytes = try await player.read(at: 0, length: 4)
        XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
        handle.cancel()
        XCTAssertEqual(source.underlying.shutdownCount, 0)
        player.close()
        await resolved.waitForFinalShutdown()
        await resolved.waitForFinalShutdown()
        XCTAssertEqual(source.underlying.shutdownCount, 1)
        XCTAssertEqual(source.finishedReadCounts, [1])
    }

    func testNilAndNoOpSourcePreparersDoNotReadOrClaimSource() async throws {
        let preparers: [MediaTransportNetworkFileResolver.SourcePreparer?] = [nil, { _, _, _ in }]
        for preparer in preparers {
            let source = PreparationProbeSource()
            let f = try await PreparationFixture.make(
                fileSystem: PreparingFileSystem(preparedByteSource: source), sourcePreparer: preparer
            )
            let handle = try await f.resolver.prepare(f.locator)
            XCTAssertEqual(source.readCount, 0)
            XCTAssertEqual(source.finishedReadCounts, [0])
            XCTAssertFalse(handle.wasConsumed)
            let resolved = try await f.resolver.resolve(f.locator)
            XCTAssertTrue(resolved.wasPrepared)
            let cursor = try XCTUnwrap(resolved.sourceLease.makeCursor())
            cursor.close()
            await resolved.waitForFinalShutdown()
            handle.cancel()
            XCTAssertEqual(source.readCount, 0)
            XCTAssertEqual(source.underlying.shutdownCount, 1)
            XCTAssertEqual(source.finishedReadCounts, [0])
        }
    }

    func testSourcePreparerFailureDrainsBaseAndPublishesNoReservation() async throws {
        let source = PreparationProbeSource()
        let fileSystem = PreparingFileSystem(preparedByteSource: source)
        let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, borrowed in
            _ = try await borrowed.read(at: 0, length: 1)
            throw MediaTransportError.sourceChanged(reason: "probe rejected source")
        })
        do {
            _ = try await f.resolver.prepare(f.locator)
            XCTFail("failed source probe published a preparation")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .sourceChanged(reason: "probe rejected source"))
        }
        XCTAssertEqual(source.underlying.shutdownCount, 1)
        XCTAssertTrue(source.finishedReadCounts.isEmpty)
        XCTAssertEqual(f.admission.count, 0)
        let resolved = try await f.resolver.resolve(f.locator)
        XCTAssertFalse(resolved.wasPrepared)
        XCTAssertEqual(fileSystem.openCount, 1)
        await resolved.waitForFinalShutdown()
        XCTAssertEqual(source.underlying.shutdownCount, 1)
    }

    func testCancellationAndTimeoutDuringBorrowDrainBeforeBaseRelease() async throws {
        for timeout in [false, true] {
            let gate = AsyncTestGate()
            let source = PreparationProbeSource(gate: gate)
            source.underlying.didShutdown.assertForOverFulfill = true
            let fileSystem = PreparingFileSystem(preparedByteSource: source)
            let f = try await PreparationFixture.make(fileSystem: fileSystem, sourcePreparer: { _, _, borrowed in
                _ = try await borrowed.read(at: 0, length: 4)
                await borrowed.shutdown()
            })
            let preparing = Task { try await f.resolver.prepare(f.locator) }
            await gate.waitUntilEntered()
            if timeout {
                let ready = await waitUntil { f.clock.waiting(for: MediaTransportPreparationTiming.defaultTimeout) }
                XCTAssertTrue(ready)
                f.clock.advance(by: MediaTransportPreparationTiming.defaultTimeout)
            } else {
                preparing.cancel()
            }
            do {
                _ = try await preparing.value
                XCTFail("cancelled or timed-out probe published a reservation")
            } catch let error as MediaTransportError {
                XCTAssertEqual(error, timeout ? .timeout : .cancelled)
            } catch is CancellationError {
                XCTAssertFalse(timeout)
            }
            await fulfillment(of: [source.cancelledRead], timeout: 2)
            XCTAssertEqual(source.underlying.shutdownCount, 0)
            XCTAssertEqual(fileSystem.openCount, 0)
            gate.open()
            await fulfillment(of: [source.underlying.didShutdown], timeout: 2)
            XCTAssertTrue(source.finishedReadCounts.isEmpty)
            let resolved = try await f.resolver.resolve(f.locator)
            XCTAssertFalse(resolved.wasPrepared)
            XCTAssertEqual(source.underlying.shutdownCount, 1)
            await resolved.waitForFinalShutdown()
        }
    }

    func testDefaultProtocolWitnessExplicitlyRejectsPreparation() async throws {
        let f = try await PreparationFixture.make()
        do {
            _ = try await NonPreparingResolver().prepare(f.locator)
            XCTFail("default protocol witness pretended to prepare")
        } catch let error as MediaTransportError {
            guard case .unsupportedCapability = error else { return XCTFail("\(error)") }
        }
    }

    func testPrepareDoesNotAdmitPlaybackAndClaimTransfersLeaseUntilFinalCursor() async throws {
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let scannerResource = FakeScannerResource()
        let scanner = try await f.admission.arbiter.acquireScanner(resource: scannerResource)
        let handle = try await f.resolver.prepare(f.locator)
        XCTAssertFalse(handle.wasConsumed)
        XCTAssertEqual(f.admission.count, 0)
        XCTAssertEqual(scannerResource.cancelCount, 0)
        XCTAssertEqual(fileSystem.openCount, 0)
        let prepared = try XCTUnwrap(fileSystem.preparedSources.first)

        var resolved: MediaTransportResolvedSource? = try await f.resolver.resolve(f.locator)
        XCTAssertTrue(try XCTUnwrap(resolved).wasPrepared)
        XCTAssertTrue(handle.wasConsumed)
        XCTAssertEqual(f.admission.count, 1)
        XCTAssertEqual(scannerResource.cancelCount, 1)
        XCTAssertEqual(fileSystem.revalidationCount, 1)
        let cursor = try XCTUnwrap(resolved?.sourceLease.makeCursor())
        handle.cancel()
        resolved = nil
        XCTAssertEqual(prepared.shutdownCount, 0)
        let bytes = try await cursor.read(at: 0, length: 4)
        XCTAssertEqual(bytes, Data([1, 2, 3, 4]))
        let blocked = await f.admission.arbiter.permitsBackgroundWork()
        XCTAssertFalse(blocked)
        cursor.close()
        let released = await waitUntilAsync { await f.admission.arbiter.permitsBackgroundWork() }
        XCTAssertTrue(released)
        XCTAssertEqual(prepared.shutdownCount, 1)
        let drained = await waitUntilAsync { await f.registry.activeLeaseCount(for: f.key) == 0 }
        XCTAssertTrue(drained)
        await scanner.finishAndWait()

        let second = try await f.resolver.resolve(f.locator)
        XCTAssertFalse(second.wasPrepared)
        XCTAssertEqual(fileSystem.openCount, 1)
        XCTAssertEqual(f.admission.count, 2)
        await second.waitForFinalShutdown()
        await second.waitForFinalShutdown()
        let finalAllowed = await f.admission.arbiter.permitsBackgroundWork()
        XCTAssertTrue(finalAllowed)
    }

    func testProbeResolverCannotPrepareOrConsumePlaybackReservation() async throws {
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let handle = try await f.resolver.prepare(f.locator)
        let probe = f.resolver.withoutPlaybackAdmission()
        for position in [0.0, 600] {
            do {
                _ = try await probe.prepare(f.locator, startPosition: position)
                XCTFail("probe prepared a playback reservation")
            } catch let error as MediaTransportError {
                guard case .unsupportedCapability = error else { return XCTFail("\(error)") }
            }
        }
        let probed = try await probe.resolve(f.locator)
        XCTAssertFalse(probed.wasPrepared)
        XCTAssertFalse(handle.wasConsumed)
        XCTAssertEqual(f.admission.count, 0)
        await probed.waitForFinalShutdown()
        let played = try await f.resolver.resolve(f.locator)
        XCTAssertTrue(played.wasPrepared)
        XCTAssertTrue(handle.wasConsumed)
        XCTAssertEqual(fileSystem.preparedSources.count, 1)
        XCTAssertEqual(fileSystem.openCount, 1)
        handle.cancel()
        await played.waitForFinalShutdown()
    }

    func testEveryLocatorDimensionMustMatch() async throws {
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let handle = try await f.resolver.prepare(f.locator)
        let alternatives = [
            try PreparationFixture.locator(key: f.key, sourceID: "other"),
            try PreparationFixture.locator(key: f.key, path: "other.mkv"),
            try PreparationFixture.locator(key: f.key, identity: "\"two\""),
            try PreparationFixture.locator(key: f.key, size: 5),
            try PreparationFixture.locator(key: f.key, format: MediaFormatHint(container: "mkv")),
        ]
        for locator in alternatives {
            let opened = try await f.resolver.resolve(locator)
            XCTAssertFalse(opened.wasPrepared)
            await opened.waitForFinalShutdown()
        }
        let played = try await f.resolver.resolve(f.locator)
        XCTAssertTrue(played.wasPrepared)
        XCTAssertEqual(fileSystem.openCount, alternatives.count)
        handle.cancel()
        await played.waitForFinalShutdown()
    }

    func testReplacementAndOldHandleCancellationCannotEvictNewReservation() async throws {
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let first = try await f.resolver.prepare(f.locator)
        let second = try await f.resolver.prepare(f.locator)
        first.cancel()
        let resolved = try await f.resolver.resolve(f.locator)
        XCTAssertTrue(resolved.wasPrepared)
        XCTAssertFalse(first.wasConsumed)
        XCTAssertTrue(second.wasConsumed)
        XCTAssertEqual(fileSystem.preparedSources.count, 2)
        XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
        XCTAssertEqual(fileSystem.preparedSources[1].shutdownCount, 0)
        second.cancel()
        await resolved.waitForFinalShutdown()
        XCTAssertEqual(fileSystem.preparedSources[1].shutdownCount, 1)
    }

    func testSupersededPendingOpenDrainsBeforeReplacementOpens() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem(afterOpenGate: gate)
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let first = Task { try await f.resolver.prepare(f.locator) }
        await gate.waitUntilEntered()
        let second = Task { try await f.resolver.prepare(f.locator) }
        do {
            _ = try await first.value
            XCTFail("superseded preparation succeeded")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(fileSystem.preparedSources.count, 1)
        gate.open()
        let handle = try await second.value
        XCTAssertEqual(fileSystem.preparedSources.count, 2)
        XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
        let played = try await f.resolver.resolve(f.locator)
        XCTAssertTrue(played.wasPrepared)
        handle.cancel()
        await played.waitForFinalShutdown()
    }

    func testPlayDuringPendingPreparationDeduplicatesOpen() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem(afterOpenGate: gate)
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let preparing = Task { try await f.resolver.prepare(f.locator) }
        await gate.waitUntilEntered()
        let playing = Task { try await f.resolver.resolve(f.locator) }
        let admitted = await waitUntil { f.admission.count == 1 }
        XCTAssertTrue(admitted)
        XCTAssertEqual(fileSystem.openCount, 0)
        gate.open()
        let handle = try await preparing.value
        let played = try await playing.value
        XCTAssertTrue(played.wasPrepared)
        XCTAssertEqual(fileSystem.preparedSources.count, 1)
        XCTAssertEqual(fileSystem.openCount, 0)
        handle.cancel()
        await played.waitForFinalShutdown()
    }

    func testCancellationBeforeAuthorizationCompletesNeverOpens() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem, authorizationGate: gate)
        let preparing = Task { try await f.resolver.prepare(f.locator) }
        await gate.waitUntilEntered()
        preparing.cancel()
        do {
            _ = try await preparing.value
            XCTFail("cancelled preparation succeeded")
        } catch {}
        gate.open()
        // Replacement waits for the cancelled worker to finish before proceeding.
        let replacement = try await f.resolver.prepare(f.locator)
        XCTAssertEqual(fileSystem.preparedSources.count, 1)
        XCTAssertEqual(f.admission.count, 0)
        replacement.cancel()
        let drained = await waitUntilAsync { await f.registry.activeLeaseCount(for: f.key) == 0 }
        XCTAssertTrue(drained)
    }

    func testCancellationAfterOpenDrainsLateSourceAndReturnsPromptly() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem(afterOpenGate: gate)
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let preparing = Task { try await f.resolver.prepare(f.locator) }
        await gate.waitUntilEntered()
        let source = try XCTUnwrap(fileSystem.preparedSources.first)
        source.didShutdown.assertForOverFulfill = true
        preparing.cancel()
        do {
            _ = try await preparing.value
            XCTFail("cancelled preparation succeeded")
        } catch {}
        XCTAssertEqual(source.shutdownCount, 0)
        gate.open()
        await fulfillment(of: [source.didShutdown], timeout: 2)
        XCTAssertEqual(source.shutdownCount, 1)
        let drained = await waitUntilAsync { await f.registry.activeLeaseCount(for: f.key) == 0 }
        XCTAssertTrue(drained)
        XCTAssertEqual(f.admission.count, 0)
    }

    func testHandleCancellationAndDeinitDrainUnclaimedSource() async throws {
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        var handle: MediaTransportPreparation? = try await f.resolver.prepare(f.locator)
        XCTAssertNotNil(handle)
        handle = nil
        let firstClosed = await waitUntil { fileSystem.preparedSources[0].shutdownCount == 1 }
        XCTAssertTrue(firstClosed)
        let second = try await f.resolver.prepare(f.locator)
        second.cancel()
        second.cancel()
        let secondClosed = await waitUntil { fileSystem.preparedSources[1].shutdownCount == 1 }
        XCTAssertTrue(secondClosed)
        let drained = await waitUntilAsync { await f.registry.activeLeaseCount(for: f.key) == 0 }
        XCTAssertTrue(drained)
    }

    func testExpiryEvictsWithoutAnotherRequestAndUsesColdOpen() async throws {
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let handle = try await f.resolver.prepare(f.locator)
        let timerReady = await waitUntil { f.clock.waiting(for: .seconds(30)) }
        XCTAssertTrue(timerReady)
        f.clock.advance(by: .seconds(30))
        let source = try XCTUnwrap(fileSystem.preparedSources.first)
        await fulfillment(of: [source.didShutdown], timeout: 2)
        XCTAssertEqual(source.shutdownCount, 1)
        let resolved = try await f.resolver.resolve(f.locator)
        XCTAssertFalse(resolved.wasPrepared)
        XCTAssertFalse(handle.wasConsumed)
        XCTAssertEqual(fileSystem.openCount, 1)
        handle.cancel()
        await resolved.waitForFinalShutdown()
    }

    func testTimeoutBoundsPrepareButDrainsLateOpenBeforeColdResolve() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem(afterOpenGate: gate)
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let preparing = Task { try await f.resolver.prepare(f.locator) }
        await gate.waitUntilEntered()
        let timerReady = await waitUntil { f.clock.waiting(for: MediaTransportPreparationTiming.defaultTimeout) }
        XCTAssertTrue(timerReady)
        f.clock.advance(by: MediaTransportPreparationTiming.defaultTimeout)
        do {
            _ = try await preparing.value
            XCTFail("timed-out preparation succeeded")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .timeout)
        }
        let playing = Task { try await f.resolver.resolve(f.locator) }
        let admitted = await waitUntil { f.admission.count == 1 }
        XCTAssertTrue(admitted)
        XCTAssertEqual(fileSystem.openCount, 0)
        gate.open()
        let resolved = try await playing.value
        XCTAssertFalse(resolved.wasPrepared)
        XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
        XCTAssertEqual(fileSystem.openCount, 1)
        await resolved.waitForFinalShutdown()
    }

    func testLifetimeStartsAfterSuccessfulPreparationNotWhenItBegan() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem(afterOpenGate: gate)
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let preparing = Task { try await f.resolver.prepare(f.locator) }
        await gate.waitUntilEntered()
        let timeoutReady = await waitUntil { f.clock.waiting(for: MediaTransportPreparationTiming.defaultTimeout) }
        XCTAssertTrue(timeoutReady)
        f.clock.advance(by: MediaTransportPreparationTiming.defaultTimeout - .seconds(1))
        gate.open()
        let handle = try await preparing.value
        let expiryReady = await waitUntil { f.clock.waiting(for: .seconds(30)) }
        XCTAssertTrue(expiryReady)
        f.clock.advance(by: .seconds(29))
        let resolved = try await f.resolver.resolve(f.locator)
        XCTAssertTrue(resolved.wasPrepared)
        XCTAssertTrue(handle.wasConsumed)
        handle.cancel()
        await resolved.waitForFinalShutdown()
    }

    func testFailedPreparationDoesNotReturnHandleOrAdmitPlayback() async throws {
        let fileSystem = PreparingFileSystem(prepareError: .authentication(reason: "rejected"))
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        do {
            _ = try await f.resolver.prepare(f.locator)
            XCTFail("failed preparation returned a handle")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .authentication(reason: "rejected"))
        }
        XCTAssertEqual(f.admission.count, 0)
        XCTAssertEqual(fileSystem.openCount, 0)
        let drained = await waitUntilAsync { await f.registry.activeLeaseCount(for: f.key) == 0 }
        XCTAssertTrue(drained)
    }

    func testUnsupportedFilesystemsAndTransportsThrowInsteadOfPretendingPrepared() async throws {
        let cases: [(any MediaTransportFileSystem, String)] = [
            (FakeFileSystem(), "https"), (PreparingFileSystem(), "smb"),
        ]
        for (fileSystem, transport) in cases {
            let f = try await PreparationFixture.make(fileSystem: fileSystem, transport: transport)
            do {
                _ = try await f.resolver.prepare(f.locator)
                XCTFail("unsupported preparation returned a handle")
            } catch let error as MediaTransportError {
                guard case .unsupportedCapability = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(f.admission.count, 0)
        }
    }

    func testFreshAuthorizationFailureEvictsAndDoesNotFallback() async throws {
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let handle = try await f.resolver.prepare(f.locator)
        f.authorization.reject(.authentication(reason: "revoked"))
        do {
            _ = try await f.resolver.resolve(f.locator)
            XCTFail("revoked authorization reused preparation")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .authentication(reason: "revoked"))
        }
        XCTAssertEqual(fileSystem.openCount, 0)
        XCTAssertEqual(f.admission.count, 0)
        XCTAssertFalse(handle.wasConsumed)
        let closed = await waitUntil { fileSystem.preparedSources[0].shutdownCount == 1 }
        XCTAssertTrue(closed)
        handle.cancel()
    }

    func testFullSessionKeyChangeRejectsPreparedSource() async throws {
        for changedEndpoint in [false, true] {
            let fileSystem = PreparingFileSystem()
            let f = try await PreparationFixture.make(fileSystem: fileSystem)
            let handle = try await f.resolver.prepare(f.locator)
            let endpoint: MediaTransportEndpointIdentity
            if changedEndpoint {
                endpoint = try MediaTransportEndpointIdentity(
                    transportIdentifier: "https", host: "other.example.com"
                )
            } else {
                endpoint = f.key.endpoint
            }
            let key = MediaTransportSessionKey(
                accountID: f.key.accountID,
                credentialRevision: f.key.credentialRevision,
                endpoint: endpoint,
                trustRevision: changedEndpoint ? f.key.trustRevision : UUID(),
                role: .playback
            )
            f.authorization.change(key: key)
            do {
                _ = try await f.resolver.resolve(f.locator)
                XCTFail("changed key reused preparation")
            } catch let error as MediaTransportError {
                guard case .sourceChanged = error else { return XCTFail("\(error)") }
            }
            XCTAssertEqual(fileSystem.openCount, 0)
            XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
            let released = await f.admission.arbiter.permitsBackgroundWork()
            XCTAssertTrue(released)
            handle.cancel()
        }
    }

    func testAccountCredentialAndRoleChangesRejectWithoutOpening() async throws {
        for dimension in 0..<3 {
            let fileSystem = PreparingFileSystem()
            let f = try await PreparationFixture.make(fileSystem: fileSystem)
            let handle = try await f.resolver.prepare(f.locator)
            let source = try XCTUnwrap(fileSystem.preparedSources.first)
            source.didShutdown.assertForOverFulfill = true
            f.authorization.change(key: MediaTransportSessionKey(
                accountID: dimension == 0 ? "other-account" : f.key.accountID,
                credentialRevision: dimension == 1 ? CredentialRevision() : f.key.credentialRevision,
                endpoint: f.key.endpoint,
                trustRevision: f.key.trustRevision,
                role: dimension == 2 ? .artwork : .playback
            ))
            do {
                _ = try await f.resolver.resolve(f.locator)
                XCTFail("changed ownership reused preparation")
            } catch let error as MediaTransportError {
                guard case .invalidInput = error else { return XCTFail("\(error)") }
            }
            XCTAssertFalse(handle.wasConsumed)
            XCTAssertEqual(fileSystem.openCount, 0)
            XCTAssertEqual(f.admission.count, 0)
            await fulfillment(of: [source.didShutdown], timeout: 2)
            XCTAssertEqual(source.shutdownCount, 1)
            handle.cancel()
        }
    }

    func testIdentityRevalidationFailurePropagatesWithoutColdFallback() async throws {
        let fileSystem = PreparingFileSystem()
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let handle = try await f.resolver.prepare(f.locator)
        fileSystem.rejectRevalidation(.sourceChanged(reason: "identity changed"))
        do {
            _ = try await f.resolver.resolve(f.locator)
            XCTFail("changed source reused preparation")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .sourceChanged(reason: "identity changed"))
        }
        XCTAssertEqual(fileSystem.openCount, 0)
        XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
        XCTAssertEqual(f.admission.count, 1)
        XCTAssertFalse(handle.wasConsumed)
        let released = await f.admission.arbiter.permitsBackgroundWork()
        XCTAssertTrue(released)
        handle.cancel()
    }

    func testCredentialAndConnectionGenerationRetirementRejectClaim() async throws {
        for retireCredential in [true, false] {
            let fileSystem = PreparingFileSystem()
            let f = try await PreparationFixture.make(fileSystem: fileSystem)
            let handle = try await f.resolver.prepare(f.locator)
            if retireCredential {
                await f.registry.retire(accountID: f.key.accountID, credentialRevision: f.key.credentialRevision)
            } else {
                let lease = try await f.registry.lease(for: f.key)
                await lease.reportConnectionFailure()
                lease.release()
                try await f.registry.register(
                    session: PreparationSession(key: f.key, fileSystem: PreparingFileSystem())
                )
            }
            do {
                _ = try await f.resolver.resolve(f.locator)
                XCTFail("retired generation reused preparation")
            } catch let error as MediaTransportError {
                XCTAssertEqual(error, .cancelled)
            }
            XCTAssertEqual(fileSystem.openCount, 0)
            XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
            let shutdown = await waitUntil { f.session.shutdownCount == 1 }
            XCTAssertTrue(shutdown)
            let released = await f.admission.arbiter.permitsBackgroundWork()
            XCTAssertTrue(released)
            handle.cancel()
        }
    }

    func testAuthorizationIsRecheckedAfterIdentityValidationSuspends() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem(revalidationGate: gate)
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let handle = try await f.resolver.prepare(f.locator)
        let playing = Task { try await f.resolver.resolve(f.locator) }
        await gate.waitUntilEntered()
        f.authorization.reject(.permissionDenied)
        gate.open()
        do {
            _ = try await playing.value
            XCTFail("authorization revoked during revalidation")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .permissionDenied)
        }
        XCTAssertEqual(fileSystem.openCount, 0)
        XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
        let released = await f.admission.arbiter.permitsBackgroundWork()
        XCTAssertTrue(released)
        handle.cancel()
    }

    func testCancellationDuringClaimRevalidationDrainsSourceAndPlaybackLease() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem(revalidationGate: gate)
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let handle = try await f.resolver.prepare(f.locator)
        let playing = Task { try await f.resolver.resolve(f.locator) }
        await gate.waitUntilEntered()
        playing.cancel()
        gate.open()
        do {
            _ = try await playing.value
            XCTFail("cancelled playback claimed preparation")
        } catch is CancellationError {}
        XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
        XCTAssertEqual(fileSystem.openCount, 0)
        let released = await f.admission.arbiter.permitsBackgroundWork()
        XCTAssertTrue(released)
        handle.cancel()
    }

    func testRetirementDuringRevalidationIsCheckedBeforeTransfer() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem(revalidationGate: gate)
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let handle = try await f.resolver.prepare(f.locator)
        let playing = Task { try await f.resolver.resolve(f.locator) }
        await gate.waitUntilEntered()
        await f.registry.retire(accountID: f.key.accountID, credentialRevision: f.key.credentialRevision)
        gate.open()
        do {
            _ = try await playing.value
            XCTFail("retired generation transferred after revalidation")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(handle.wasConsumed)
        XCTAssertEqual(fileSystem.openCount, 0)
        XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
        handle.cancel()
    }

    func testAuthorizationFailureDuringPendingPreparationReachesPlayWithoutFallback() async throws {
        let gate = AsyncTestGate()
        let fileSystem = PreparingFileSystem(afterOpenGate: gate)
        let f = try await PreparationFixture.make(fileSystem: fileSystem)
        let preparing = Task { try await f.resolver.prepare(f.locator) }
        await gate.waitUntilEntered()
        let playing = Task { try await f.resolver.resolve(f.locator) }
        let admitted = await waitUntil { f.admission.count == 1 }
        XCTAssertTrue(admitted)
        f.authorization.reject(.permissionDenied)
        gate.open()
        do {
            _ = try await preparing.value
            XCTFail("revoked preparation succeeded")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .permissionDenied)
        }
        do {
            _ = try await playing.value
            XCTFail("Play hid preparation authorization failure")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .permissionDenied)
        }
        XCTAssertEqual(fileSystem.preparedSources[0].shutdownCount, 1)
        XCTAssertEqual(fileSystem.openCount, 0)
        let released = await f.admission.arbiter.permitsBackgroundWork()
        XCTAssertTrue(released)
    }
}
