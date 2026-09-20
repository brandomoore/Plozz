import CoreModels
import Foundation
@testable import MediaTransportCore
import XCTest

private final class OpenFailureBarrier: @unchecked Sendable {
    let arrivals: XCTestExpectation
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        arrivals = XCTestExpectation(description: "Failing opens entered")
        arrivals.expectedFulfillmentCount = count
    }

    func wait() async {
        arrivals.fulfill()
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                guard !released else { return true }
                waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func release() {
        let ready = lock.withLock {
            released = true
            let ready = waiters
            waiters.removeAll()
            return ready
        }
        ready.forEach { $0.resume() }
    }
}

private final class FailureReportingFileSystem: MediaTransportFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: (error: any Error, barrier: OpenFailureBarrier?)?
    private var sourcesStorage: [FakeByteSource] = []
    private var openCountStorage = 0

    var sources: [FakeByteSource] { lock.withLock { sourcesStorage } }
    var openCount: Int { lock.withLock { openCountStorage } }

    func failOpens(with error: any Error, barrier: OpenFailureBarrier? = nil) {
        lock.withLock { failure = (error, barrier) }
    }

    func validate() async throws {}
    func probe() async throws -> MediaTransportProbe { try await FakeFileSystem().probe() }
    func list(relativePath: String) async throws -> [RemoteFileEntry] { [] }
    func stat(relativePath: String) async throws -> RemoteFileEntry {
        try RemoteFileEntry(relativePath: relativePath, kind: .file, size: 3)
    }
    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
        Data([1, 2, 3]).prefix(maximumBytes)
    }

    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        let failure = lock.withLock {
            openCountStorage += 1
            return self.failure
        }
        if let failure {
            await failure.barrier?.wait()
            throw failure.error
        }
        let source = FakeByteSource(data: Data([1, 2, 3]))
        lock.withLock { sourcesStorage.append(source) }
        return MediaTransportSourceLease(source: source)
    }
}

private final class FailureReportingSession: MediaTransportSession, @unchecked Sendable {
    let key: MediaTransportSessionKey
    let controlledFileSystem = FailureReportingFileSystem()
    var fileSystem: any MediaTransportFileSystem { controlledFileSystem }
    let didShutdown = XCTestExpectation(description: "Session finalized")
    private let lock = NSLock()
    private var shutdownCountStorage = 0
    private var healthProbeCountStorage = 0

    init(key: MediaTransportSessionKey) {
        self.key = key
        didShutdown.assertForOverFulfill = true
    }

    var shutdownCount: Int { lock.withLock { shutdownCountStorage } }
    var healthProbeCount: Int { lock.withLock { healthProbeCountStorage } }

    func isHealthy() async -> Bool {
        lock.withLock { healthProbeCountStorage += 1 }
        return true
    }

    func shutdown() async {
        lock.withLock { shutdownCountStorage += 1 }
        didShutdown.fulfill()
    }
}

private final class FailureReportingAdapter: MediaTransportAdapter, @unchecked Sendable {
    let transportIdentifier: String
    private let lock = NSLock()
    private var sessionsStorage: [FailureReportingSession] = []

    init(transportIdentifier: String) {
        self.transportIdentifier = transportIdentifier
    }

    var sessions: [FailureReportingSession] { lock.withLock { sessionsStorage } }
    var connectCount: Int { lock.withLock { sessionsStorage.count } }

    func connect(for key: MediaTransportSessionKey) async throws -> any MediaTransportSession {
        let session = FailureReportingSession(key: key)
        lock.withLock { sessionsStorage.append(session) }
        return session
    }
}

private final class NonRetiringSession: MediaTransportSession, Sendable {
    let base: FailureReportingSession
    var key: MediaTransportSessionKey { base.key }
    var fileSystem: any MediaTransportFileSystem { base.fileSystem }

    init(base: FailureReportingSession) { self.base = base }

    func shouldRetireAfterOpenFailure(_ error: MediaTransportError) -> Bool { false }
    func isHealthy() async -> Bool { await base.isHealthy() }
    func shutdown() async { await base.shutdown() }
}

final class ResolverFailureRetirementTests: XCTestCase {
    private func locator(for key: MediaTransportSessionKey) throws -> NetworkFileLocator {
        try NetworkFileLocator(
            accountID: key.accountID,
            sourceID: key.accountID,
            credentialRevision: key.credentialRevision,
            relativePath: "artwork.jpg",
            representation: RemoteFileRepresentation(
                size: 3,
                identity: RemoteFileIdentity(kind: .snapshot, value: "snapshot"),
                consistency: .stronglyBound
            )
        )
    }

    func testFailedOpenRotatesPinnedSessionWithoutClosingOldReader() async throws {
        let key = try makeSessionKey(role: .playback)
        let adapter = FailureReportingAdapter(transportIdentifier: key.endpoint.transportIdentifier)
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let resolver = MediaTransportNetworkFileResolver(registry: registry) { _ in key }
        let locator = try locator(for: key)
        let oldSource = try await resolver.resolve(locator)
        let cursor = try XCTUnwrap(oldSource.sourceLease.makeCursor())
        let oldSession = try XCTUnwrap(adapter.sessions.first)
        let oldBytes = try XCTUnwrap(oldSession.controlledFileSystem.sources.first)
        oldSession.controlledFileSystem.failOpens(with: MediaTransportError.transport(code: -1005))

        do {
            _ = try await resolver.resolve(locator)
            XCTFail("Failed open must propagate, not retry within resolve.")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .transport(code: -1005))
        }
        XCTAssertEqual(adapter.connectCount, 1)

        let replacementSource = try await resolver.resolve(locator)
        let replacement = try XCTUnwrap(adapter.sessions.last)
        XCTAssertEqual(adapter.connectCount, 2)
        XCTAssertFalse(replacement === oldSession)
        XCTAssertEqual(oldSession.healthProbeCount, 0)
        XCTAssertEqual(oldSession.shutdownCount, 0)
        XCTAssertEqual(oldBytes.shutdownCount, 0)
        let retainedGenerations = await registry.liveSessionCount
        XCTAssertEqual(retainedGenerations, 2)
        let data = try await cursor.read(at: 0, length: 3)
        XCTAssertEqual(data, Data([1, 2, 3]))

        cursor.close()
        await oldSource.waitForFinalShutdown()
        await fulfillment(of: [oldSession.didShutdown], timeout: 2)
        XCTAssertEqual(oldSession.shutdownCount, 1)
        XCTAssertEqual(oldBytes.shutdownCount, 1)
        XCTAssertEqual(replacement.shutdownCount, 0)

        await registry.retire(accountID: key.accountID, credentialRevision: key.credentialRevision)
        await replacementSource.waitForFinalShutdown()
        await fulfillment(of: [replacement.didShutdown], timeout: 2)
        XCTAssertEqual(replacement.shutdownCount, 1)
    }

    func testLateOldReleaseAndFailureCannotAffectReplacementGeneration() async throws {
        let key = try makeSessionKey()
        let adapter = FailureReportingAdapter(transportIdentifier: key.endpoint.transportIdentifier)
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let old = try await registry.lease(for: key)
        let otherOld = try await registry.lease(for: key)
        let oldSession = try XCTUnwrap(adapter.sessions.first)
        await old.reportConnectionFailure()
        let replacement = try await registry.lease(for: key)
        let replacementSession = try XCTUnwrap(adapter.sessions.last)

        old.release()
        await old.reportConnectionFailure()
        otherOld.release()
        await fulfillment(of: [oldSession.didShutdown], timeout: 2)
        old.release()
        otherOld.release()
        await otherOld.reportConnectionFailure()

        let additional = try await registry.lease(for: key)
        XCTAssertTrue(additional.session === replacement.session)
        XCTAssertEqual(adapter.connectCount, 2)
        XCTAssertEqual(oldSession.shutdownCount, 1)
        XCTAssertEqual(replacementSession.shutdownCount, 0)
        let active = await registry.activeLeaseCount(for: key)
        XCTAssertEqual(active, 2)
        let live = await registry.liveSessionCount
        XCTAssertEqual(live, 1)

        await registry.retire(accountID: key.accountID, credentialRevision: key.credentialRevision)
        replacement.release()
        additional.release()
        await fulfillment(of: [replacementSession.didShutdown], timeout: 2)
        XCTAssertEqual(replacementSession.shutdownCount, 1)
    }

    func testConcurrentFailedOpensRetireOnlyTheirPinnedGeneration() async throws {
        let key = try makeSessionKey(role: .playback)
        let adapter = FailureReportingAdapter(transportIdentifier: key.endpoint.transportIdentifier)
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let held = try await registry.lease(for: key)
        let oldSession = try XCTUnwrap(adapter.sessions.first)
        let barrier = OpenFailureBarrier(count: 2)
        defer { barrier.release() }
        oldSession.controlledFileSystem.failOpens(with: MediaTransportError.timeout, barrier: barrier)
        let resolver = MediaTransportNetworkFileResolver(registry: registry) { _ in key }
        let locator = try locator(for: key)
        let attempt: @Sendable () async -> MediaTransportError? = {
            do {
                let unexpected = try await resolver.resolve(locator)
                await unexpected.waitForFinalShutdown()
                return nil
            } catch {
                return error as? MediaTransportError
            }
        }
        let first = Task { await attempt() }
        let second = Task { await attempt() }
        await fulfillment(of: [barrier.arrivals], timeout: 2)
        barrier.release()
        let firstError = await first.value
        let secondError = await second.value
        XCTAssertEqual(firstError, .timeout)
        XCTAssertEqual(secondError, .timeout)
        XCTAssertEqual(adapter.connectCount, 1)
        XCTAssertEqual(oldSession.shutdownCount, 0)

        let replacement = try await resolver.resolve(locator)
        let newSession = try XCTUnwrap(adapter.sessions.last)
        XCTAssertEqual(adapter.connectCount, 2)
        held.release()
        await fulfillment(of: [oldSession.didShutdown], timeout: 2)
        XCTAssertEqual(oldSession.shutdownCount, 1)
        await registry.retire(accountID: key.accountID, credentialRevision: key.credentialRevision)
        await replacement.waitForFinalShutdown()
        await fulfillment(of: [newSession.didShutdown], timeout: 2)
    }

    func testCredentialRetirementDuringFailedOpenStillForbidsReconnect() async throws {
        let key = try makeSessionKey(role: .playback)
        let adapter = FailureReportingAdapter(transportIdentifier: key.endpoint.transportIdentifier)
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let held = try await registry.lease(for: key)
        let session = try XCTUnwrap(adapter.sessions.first)
        let barrier = OpenFailureBarrier(count: 1)
        defer { barrier.release() }
        session.controlledFileSystem.failOpens(with: MediaTransportError.timeout, barrier: barrier)
        let resolver = MediaTransportNetworkFileResolver(registry: registry) { _ in key }
        let locator = try locator(for: key)
        let request = Task { try await resolver.resolve(locator) }
        await fulfillment(of: [barrier.arrivals], timeout: 2)
        await registry.retire(accountID: key.accountID, credentialRevision: key.credentialRevision)
        barrier.release()
        do {
            _ = try await request.value
            XCTFail("Expected original timeout.")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .timeout)
        }
        do {
            _ = try await registry.lease(for: key)
            XCTFail("Failure reporting must not unretire credentials.")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(adapter.connectCount, 1)
        XCTAssertEqual(session.shutdownCount, 0)
        held.release()
        await fulfillment(of: [session.didShutdown], timeout: 2)
        XCTAssertEqual(session.shutdownCount, 1)
    }

    func testNonConnectionOpenErrorsDoNotRotateInUseSession() async throws {
        let key = try makeSessionKey(role: .playback)
        let adapter = FailureReportingAdapter(transportIdentifier: key.endpoint.transportIdentifier)
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let held = try await registry.lease(for: key)
        let session = try XCTUnwrap(adapter.sessions.first)
        let resolver = MediaTransportNetworkFileResolver(registry: registry) { _ in key }
        let locator = try locator(for: key)
        let errors: [MediaTransportError] = [
            .authentication(reason: "credentials rejected"),
            .trust(reason: "trust rejected"),
            .permissionDenied,
            .invalidInput(reason: "resource not found"),
            .protocolViolation(reason: "request rejected"),
            .unsupportedCapability("operation"),
            .unsupportedRange(reason: "range"),
            .resourceBusy,
            .sourceChanged(reason: "representation changed"),
            .cancelled,
        ]
        for expected in errors {
            session.controlledFileSystem.failOpens(with: expected)
            do {
                _ = try await resolver.resolve(locator)
                XCTFail("Expected terminal open error.")
            } catch let error as MediaTransportError {
                XCTAssertEqual(error, expected)
            }
            let next = try await registry.lease(for: key)
            XCTAssertTrue(next.session === held.session)
            next.release()
        }
        XCTAssertEqual(adapter.connectCount, 1)
        XCTAssertEqual(session.controlledFileSystem.openCount, errors.count)
        XCTAssertEqual(session.healthProbeCount, 0)
        XCTAssertEqual(session.shutdownCount, 0)
        await registry.retire(accountID: key.accountID, credentialRevision: key.credentialRevision)
        held.release()
        await fulfillment(of: [session.didShutdown], timeout: 2)
    }

    func testResolverUsesSessionFailurePolicyWithoutChangingThrownError() async throws {
        let key = try makeSessionKey(role: .playback)
        let base = FailureReportingSession(key: key)
        let session = NonRetiringSession(base: base)
        let registry = MediaTransportResolverRegistry()
        try await registry.register(session: session)
        let held = try await registry.lease(for: key)
        let resolver = MediaTransportNetworkFileResolver(registry: registry) { _ in key }
        let locator = try locator(for: key)
        let expected = MediaTransportError.transport(code: -1005)
        base.controlledFileSystem.failOpens(with: expected)
        do {
            _ = try await resolver.resolve(locator)
            XCTFail("Expected original error from the session.")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, expected)
        }
        let next = try await registry.lease(for: key)
        XCTAssertTrue(next.session === held.session)
        XCTAssertEqual(base.controlledFileSystem.openCount, 1)
        XCTAssertEqual(base.shutdownCount, 0)
        await registry.retire(accountID: key.accountID, credentialRevision: key.credentialRevision)
        held.release()
        next.release()
        await fulfillment(of: [base.didShutdown], timeout: 2)
    }

    func testFailureDoesNotRetireAnotherTrustRevision() async throws {
        let key = try makeSessionKey()
        let otherKey = try makeSessionKey(
            accountID: key.accountID, credentialRevision: key.credentialRevision,
            endpoint: key.endpoint, trustRevision: UUID(), role: key.role
        )
        let adapter = FailureReportingAdapter(transportIdentifier: key.endpoint.transportIdentifier)
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let failed = try await registry.lease(for: key)
        let other = try await registry.lease(for: otherKey)
        await failed.reportConnectionFailure()
        let replacement = try await registry.lease(for: key)
        let reusedOther = try await registry.lease(for: otherKey)
        XCTAssertTrue(reusedOther.session === other.session)
        XCTAssertEqual(adapter.connectCount, 3)
        XCTAssertTrue(adapter.sessions.allSatisfy { $0.shutdownCount == 0 })

        await registry.retire(accountID: key.accountID, credentialRevision: key.credentialRevision)
        failed.release()
        replacement.release()
        other.release()
        reusedOther.release()
        await fulfillment(of: adapter.sessions.map(\.didShutdown), timeout: 2)
        XCTAssertTrue(adapter.sessions.allSatisfy { $0.shutdownCount == 1 })
    }

    func testReportedFailurePreservesRegisteredFinalizerUntilFinalRelease() async throws {
        let key = try makeSessionKey()
        let adapter = FailureReportingAdapter(transportIdentifier: key.endpoint.transportIdentifier)
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let registered = FailureReportingSession(key: key)
        let finalized = expectation(description: "Registered finalizer")
        finalized.assertForOverFulfill = true
        try await registry.register(session: registered) { session in
            finalized.fulfill()
            await session.shutdown()
        }
        let first = try await registry.lease(for: key)
        let second = try await registry.lease(for: key)
        await first.reportConnectionFailure()
        let replacement = try await registry.lease(for: key)
        XCTAssertEqual(registered.shutdownCount, 0)
        first.release()
        second.release()
        await fulfillment(of: [finalized, registered.didShutdown], timeout: 2)
        await first.reportConnectionFailure()
        first.release()
        XCTAssertEqual(registered.shutdownCount, 1)
        let replacementSession = try XCTUnwrap(adapter.sessions.first)
        XCTAssertTrue(replacement.session === replacementSession)
        XCTAssertEqual(replacementSession.shutdownCount, 0)

        await registry.retire(accountID: key.accountID, credentialRevision: key.credentialRevision)
        replacement.release()
        await fulfillment(of: [replacementSession.didShutdown], timeout: 2)
    }
}
