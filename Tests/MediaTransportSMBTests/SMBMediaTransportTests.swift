import CoreModels
import Foundation
import MediaTransportCore
@testable import MediaTransportSMB
import XCTest

final class SMBMediaTransportTests: XCTestCase {
    func testConnectResolvesExactRevisionAndScopesPathsToShareRoot() async throws {
        let revision = CredentialRevision()
        let backend = FakeSMBBackend()
        backend.entries = [
            SMBBackendEntry(
                name: "Movies",
                kind: .directory,
                size: nil,
                modifiedAt: nil,
                createdAt: nil
            ),
            SMBBackendEntry(
                name: "movie.mkv",
                kind: .file,
                size: 42,
                modifiedAt: Date(timeIntervalSince1970: 100),
                createdAt: Date(timeIntervalSince1970: 50)
            ),
            SMBBackendEntry(
                name: ".hidden.mkv",
                kind: .file,
                size: 12,
                modifiedAt: nil,
                createdAt: nil,
                isHidden: true
            ),
            SMBBackendEntry(
                name: "System Volume Information",
                kind: .directory,
                size: nil,
                modifiedAt: nil,
                createdAt: nil,
                isSystem: true
            ),
        ]

        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { accountID, requestedRevision in
                XCTAssertEqual(accountID, "account")
                XCTAssertEqual(requestedRevision, revision)
                return SMBMediaTransportConfiguration(
                    credential: .password(username: "viewer", password: "secret"),
                    options: SMBTransportOptions(requiresSigning: true)
                )
            },
            backendFactory: { backend }
        )

        let session = try await adapter.connect(for: makeKey(revision: revision))
        let entries = try await session.fileSystem.list(relativePath: "Genre")

        XCTAssertEqual(backend.connectedHost, "nas.local")
        XCTAssertEqual(backend.connectedPort, 445)
        XCTAssertEqual(backend.connectedShare, "Media")
        XCTAssertEqual(backend.connectedCredential, .password(username: "viewer", password: "secret"))
        XCTAssertEqual(backend.requiresSigning, true)
        XCTAssertEqual(backend.listedPaths, ["Library/Genre"])
        XCTAssertEqual(entries.map(\.relativePath), ["Genre/Movies", "Genre/movie.mkv"])
        XCTAssertEqual(entries.map(\.kind), [.directory, .file])
        XCTAssertEqual(entries.last?.size, 42)
    }

    func testEachConnectCreatesAnIndependentBackendSession() async throws {
        let factory = FakeSMBBackendFactory()
        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { _, _ in
                SMBMediaTransportConfiguration(credential: .anonymous)
            },
            backendFactory: { factory.make() }
        )
        let key = try makeKey()

        let first = try await adapter.connect(for: key)
        let second = try await adapter.connect(for: key)

        XCTAssertEqual(factory.backends.count, 2)
        XCTAssertFalse(factory.backends[0] === factory.backends[1])

        await first.shutdown()
        XCTAssertEqual(factory.backends[0].shutdownCount, 1)
        XCTAssertEqual(factory.backends[1].shutdownCount, 0)

        await second.shutdown()
        XCTAssertEqual(factory.backends[1].shutdownCount, 1)
    }

    func testPasswordedGuestWithBlankUsernameUsesLiteralGuestAccount() async throws {
        let backend = FakeSMBBackend()
        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { _, _ in
                SMBMediaTransportConfiguration(
                    credential: .password(username: "", password: "guest-secret")
                )
            },
            backendFactory: { backend }
        )

        _ = try await adapter.connect(for: makeKey())

        XCTAssertEqual(
            backend.connectedCredential,
            .password(username: "guest", password: "guest-secret")
        )
    }

    func testProbeReportsChangeDetectingRandomAccess() async throws {
        let backend = FakeSMBBackend()
        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { _, _ in
                SMBMediaTransportConfiguration(credential: .anonymous)
            },
            backendFactory: { backend }
        )
        let session = try await adapter.connect(for: makeKey())

        let probe = try await session.fileSystem.probe()

        XCTAssertEqual(probe.capabilities.byteRangeBehavior, .randomAccess)
        XCTAssertEqual(probe.capabilities.consistency, .changeDetecting)
        XCTAssertEqual(probe.capabilities.maximumBoundedWholeFileReadBytes, 16 * 1_024 * 1_024)
        XCTAssertFalse(probe.capabilities.consistency == .representationBound)
    }

    func testRequiredEncryptionFailsClosedBeforeConnecting() async throws {
        let backend = FakeSMBBackend()
        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { _, _ in
                SMBMediaTransportConfiguration(
                    credential: .anonymous,
                    options: SMBTransportOptions(requiresEncryption: true)
                )
            },
            backendFactory: { backend }
        )

        do {
            _ = try await adapter.connect(for: makeKey())
            XCTFail("Expected unsupported encryption policy")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .unsupportedCapability("SMB encryption policy"))
        }
        XCTAssertNil(backend.connectedHost)
    }

    func testUnenforceableMinimumSMB3FailsClosed() async throws {
        let backend = FakeSMBBackend()
        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { _, _ in
                SMBMediaTransportConfiguration(
                    credential: .anonymous,
                    options: SMBTransportOptions(minimumDialect: .smb3)
                )
            },
            backendFactory: { backend }
        )

        do {
            _ = try await adapter.connect(for: makeKey())
            XCTFail("Expected unsupported dialect policy")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .unsupportedCapability("minimum SMB 3 dialect"))
        }
        XCTAssertNil(backend.connectedHost)
    }

    func testSigningRequirementRejectsAnonymousSession() async throws {
        let backend = FakeSMBBackend()
        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { _, _ in
                SMBMediaTransportConfiguration(
                    credential: .anonymous,
                    options: SMBTransportOptions(requiresSigning: true)
                )
            },
            backendFactory: { backend }
        )

        do {
            _ = try await adapter.connect(for: makeKey())
            XCTFail("Expected unsupported anonymous signing policy")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .unsupportedCapability("signed anonymous SMB"))
        }
        XCTAssertNil(backend.connectedHost)
    }

    func testOpenSourceRejectsLocatorFromAnotherCredentialRevision() async throws {
        let revision = CredentialRevision()
        let backend = FakeSMBBackend()
        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { _, _ in
                SMBMediaTransportConfiguration(credential: .anonymous)
            },
            backendFactory: { backend }
        )
        let session = try await adapter.connect(for: makeKey(revision: revision))
        let modifiedAt = Date(timeIntervalSince1970: 1)
        let representation = try RemoteFileRepresentation(
            size: 0,
            identity: RemoteFileIdentity(
                kind: .modificationTime,
                modifiedAt: modifiedAt
            ),
            consistency: .changeDetecting
        )
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "source",
            credentialRevision: CredentialRevision(),
            relativePath: "movie.mkv",
            representation: representation
        )

        do {
            _ = try await session.fileSystem.openSource(for: locator)
            XCTFail("Expected locator mismatch")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .invalidInput(reason: "locator session mismatch"))
        }
    }

    func testCancellingReadReplacesOnlyThatCursorsSMBChannel() async throws {
        let readStarted = ReadStartedSignal()
        let blockedSource = BlockingCancellableByteSource(readStarted: readStarted)
        let expectedBytes = Data([1, 2, 3, 4])
        let factory = FakeSMBBackendFactory { index -> any MediaTransportByteSource in
            if index == 1 {
                return blockedSource
            }
            return ImmediateByteSource(data: expectedBytes)
        }
        let revision = CredentialRevision()
        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { _, _ in
                SMBMediaTransportConfiguration(credential: .anonymous)
            },
            backendFactory: { factory.make() }
        )
        let session = try await adapter.connect(for: makeKey(revision: revision))
        factory.backends[0].entries = [
            SMBBackendEntry(
                name: "movie.mkv",
                kind: .file,
                size: Int64(expectedBytes.count),
                modifiedAt: Date(timeIntervalSince1970: 1),
                createdAt: nil
            )
        ]
        let representation = try RemoteFileRepresentation(
            size: Int64(expectedBytes.count),
            identity: RemoteFileIdentity(
                kind: .modificationTime,
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
            consistency: .changeDetecting
        )
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "source",
            credentialRevision: revision,
            relativePath: "movie.mkv",
            representation: representation
        )
        let lease = try await session.fileSystem.openSource(for: locator)
        let first = try XCTUnwrap(lease.makeCursor())
        let sibling = try XCTUnwrap(first.clone())
        let cancelledRead = Task {
            try await first.read(at: 0, length: expectedBytes.count)
        }
        await readStarted.wait()

        first.cancel()
        do {
            _ = try await cancelledRead.value
            XCTFail("Expected cancelled SMB read")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .cancelled)
        }

        let siblingBytes = try await sibling.read(
            at: 0,
            length: expectedBytes.count
        )
        XCTAssertEqual(siblingBytes, expectedBytes)
        let retriedBytes = try await first.read(
            at: 0,
            length: expectedBytes.count
        )
        XCTAssertEqual(
            retriedBytes,
            expectedBytes,
            "a cancelled cursor remains reusable with a fresh SMB channel"
        )

        XCTAssertEqual(factory.backends.count, 4)
        XCTAssertEqual(factory.backends[0].shutdownCount, 0)
        XCTAssertEqual(factory.backends[1].shutdownCount, 1)
        XCTAssertEqual(factory.backends[2].shutdownCount, 0)
        XCTAssertEqual(factory.backends[3].shutdownCount, 0)

        first.close()
        sibling.close()
        await lease.waitForFinalShutdown()
        await session.shutdown()
    }

    func testConnectFailureShutsDownBackend() async throws {
        let backend = FakeSMBBackend()
        backend.connectError = MediaTransportError.authentication(reason: "rejected")
        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { _, _ in
                SMBMediaTransportConfiguration(credential: .anonymous)
            },
            backendFactory: { backend }
        )

        do {
            _ = try await adapter.connect(for: makeKey())
            XCTFail("Expected authentication failure")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .authentication(reason: "rejected"))
        }
        XCTAssertEqual(backend.shutdownCount, 1)
    }

    func testTraversalAboveConfiguredRootIsRejectedWithoutNetworkIO() async throws {
        let backend = FakeSMBBackend()
        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { _, _ in
                SMBMediaTransportConfiguration(credential: .anonymous)
            },
            backendFactory: { backend }
        )
        let session = try await adapter.connect(for: makeKey())

        do {
            _ = try await session.fileSystem.list(relativePath: "../outside")
            XCTFail("Expected traversal rejection")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .invalidInput(reason: "SMB path traversal"))
        }
        XCTAssertTrue(backend.listedPaths.isEmpty)
    }

    func testSMBMissingFileAndAuthStatusesDoNotRotateConnection() async throws {
        let factory = FakeSMBBackendFactory()
        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { _, _ in
                SMBMediaTransportConfiguration(credential: .anonymous)
            },
            backendFactory: { factory.make() }
        )
        let key = try makeKey(role: .playback)
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let held = try await registry.lease(for: key)
        let backend = try XCTUnwrap(factory.backends.first)
        let finalized = expectation(description: "Terminal-error session finalized")
        finalized.assertForOverFulfill = true
        backend.onShutdown { finalized.fulfill() }
        let resolver = MediaTransportNetworkFileResolver(registry: registry) { _ in key }
        let locator = try makeLocator(for: key)
        let statuses = [0xC000000F, 0xC0000034, 0xC000003A, 0xC0000022, 0xC000006D, 0xC0000001]
        let errors: [MediaTransportError] = statuses.map { .transport(code: $0) } + [
            .authentication(reason: "credentials rejected"),
            .trust(reason: "trust rejected"),
            .permissionDenied,
            .invalidInput(reason: "resource not found"),
            .sourceChanged(reason: "representation changed"),
            .unsupportedRange(reason: "range"),
            .cancelled,
        ]
        for expected in errors {
            XCTAssertFalse(held.session.shouldRetireAfterOpenFailure(expected))
            backend.statError = expected
            do {
                _ = try await resolver.resolve(locator)
                XCTFail("Expected the original resource/auth error.")
            } catch let error as MediaTransportError {
                XCTAssertEqual(error, expected)
            }
            let next = try await registry.lease(for: key)
            XCTAssertTrue(next.session === held.session)
            next.release()
        }
        XCTAssertEqual(factory.backends.count, 1)
        XCTAssertEqual(backend.shutdownCount, 0)
        await registry.retire(accountID: key.accountID, credentialRevision: key.credentialRevision)
        held.release()
        await fulfillment(of: [finalized], timeout: 2)
        XCTAssertEqual(backend.shutdownCount, 1)
    }

    func testSMBSessionLossStatusRetiresForNewLeases() async throws {
        let factory = FakeSMBBackendFactory()
        let adapter = SMBMediaTransportAdapter(
            configurationProvider: { _, _ in
                SMBMediaTransportConfiguration(credential: .anonymous)
            },
            backendFactory: { factory.make() }
        )
        let key = try makeKey(role: .playback)
        let registry = MediaTransportResolverRegistry(adapter: adapter)
        let held = try await registry.lease(for: key)
        let oldBackend = try XCTUnwrap(factory.backends.first)
        let oldFinalized = expectation(description: "Failed generation finalized")
        oldFinalized.assertForOverFulfill = true
        oldBackend.onShutdown { oldFinalized.fulfill() }
        for code in [0xC00000B5, 0xC00000C9, 0xC0000203, 0xC000020C, 0xC000020D, 0xC0000241, 0xC000035C] {
            XCTAssertTrue(held.session.shouldRetireAfterOpenFailure(.transport(code: code)))
        }
        XCTAssertTrue(held.session.shouldRetireAfterOpenFailure(.timeout))
        XCTAssertTrue(held.session.shouldRetireAfterOpenFailure(.transport(code: -1005)))
        oldBackend.statError = MediaTransportError.transport(code: 0xC0000203)
        let resolver = MediaTransportNetworkFileResolver(registry: registry) { _ in key }
        let locator = try makeLocator(for: key)
        do {
            _ = try await resolver.resolve(locator)
            XCTFail("Session loss must propagate without an immediate retry.")
        } catch let error as MediaTransportError {
            XCTAssertEqual(error, .transport(code: 0xC0000203))
        }
        XCTAssertEqual(factory.backends.count, 1)
        let replacement = try await resolver.resolve(locator)
        let newBackend = try XCTUnwrap(factory.backends.last)
        let newFinalized = expectation(description: "Replacement finalized")
        newFinalized.assertForOverFulfill = true
        newBackend.onShutdown { newFinalized.fulfill() }
        XCTAssertEqual(factory.backends.count, 2)
        XCTAssertEqual(oldBackend.shutdownCount, 0)
        held.release()
        await fulfillment(of: [oldFinalized], timeout: 2)
        XCTAssertEqual(oldBackend.shutdownCount, 1)
        XCTAssertEqual(newBackend.shutdownCount, 0)
        await registry.retire(accountID: key.accountID, credentialRevision: key.credentialRevision)
        await replacement.waitForFinalShutdown()
        await fulfillment(of: [newFinalized], timeout: 2)
        XCTAssertEqual(newBackend.shutdownCount, 1)
    }

    private func makeLocator(for key: MediaTransportSessionKey) throws -> NetworkFileLocator {
        try NetworkFileLocator(
            accountID: key.accountID,
            sourceID: "source",
            credentialRevision: key.credentialRevision,
            relativePath: "artwork.jpg",
            representation: RemoteFileRepresentation(
                size: 0,
                identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: Date(timeIntervalSince1970: 1)),
                consistency: .changeDetecting
            )
        )
    }

    private func makeKey(
        revision: CredentialRevision = CredentialRevision(),
        role: MediaTransportRole = .scanner
    ) throws -> MediaTransportSessionKey {
        MediaTransportSessionKey(
            accountID: "account",
            credentialRevision: revision,
            endpoint: try MediaTransportEndpointIdentity(
                transportIdentifier: "smb",
                host: "nas.local",
                rootPath: "/Media/Library"
            ),
            trustRevision: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            role: role
        )
    }
}

private final class FakeSMBBackendFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FakeSMBBackend] = []
    private let sourceFactory: @Sendable (Int) -> any MediaTransportByteSource

    var backends: [FakeSMBBackend] {
        lock.withLock { storage }
    }

    init(
        sourceFactory: @escaping @Sendable (Int) -> any MediaTransportByteSource = {
            _ in FakeByteSource(byteSize: 0)
        }
    ) {
        self.sourceFactory = sourceFactory
    }

    func make() -> FakeSMBBackend {
        lock.withLock {
            let backend = FakeSMBBackend(source: sourceFactory(storage.count))
            storage.append(backend)
            return backend
        }
    }
}

private final class FakeSMBBackend: SMBTransportBackend, @unchecked Sendable {
    private let lock = NSLock()

    var entries: [SMBBackendEntry] {
        get { lock.withLock { entriesStorage } }
        set { lock.withLock { entriesStorage = newValue } }
    }
    var connectError: (any Error)? {
        get { lock.withLock { connectErrorStorage } }
        set { lock.withLock { connectErrorStorage = newValue } }
    }
    var statError: (any Error)? {
        get { lock.withLock { statErrorStorage } }
        set { lock.withLock { statErrorStorage = newValue } }
    }
    var connectedHost: String? { lock.withLock { connectedHostStorage } }
    var connectedPort: Int? { lock.withLock { connectedPortStorage } }
    var connectedShare: String? { lock.withLock { connectedShareStorage } }
    var connectedCredential: SMBMediaTransportCredential? {
        lock.withLock { connectedCredentialStorage }
    }
    var requiresSigning: Bool? { lock.withLock { requiresSigningStorage } }
    var listedPaths: [String] { lock.withLock { listedPathsStorage } }
    var shutdownCount: Int { lock.withLock { shutdownCountStorage } }

    private var entriesStorage: [SMBBackendEntry] = []
    private var connectErrorStorage: (any Error)?
    private var statErrorStorage: (any Error)?
    private var connectedHostStorage: String?
    private var connectedPortStorage: Int?
    private var connectedShareStorage: String?
    private var connectedCredentialStorage: SMBMediaTransportCredential?
    private var requiresSigningStorage: Bool?
    private var listedPathsStorage: [String] = []
    private var shutdownCountStorage = 0
    private var shutdownObserver: (@Sendable () -> Void)?
    private let source: (any MediaTransportByteSource)?

    init(source: (any MediaTransportByteSource)? = nil) {
        self.source = source
    }

    func connect(
        host: String,
        port: Int,
        share: String,
        credential: SMBMediaTransportCredential,
        requiresSigning: Bool
    ) async throws {
        let error = lock.withLock {
            connectedHostStorage = host
            connectedPortStorage = port
            connectedShareStorage = share
            connectedCredentialStorage = credential
            requiresSigningStorage = requiresSigning
            return connectErrorStorage
        }
        if let error { throw error }
    }

    func list(path: String) async throws -> [SMBBackendEntry] {
        lock.withLock {
            listedPathsStorage.append(path)
            return entriesStorage
        }
    }

    func stat(path: String) async throws -> SMBBackendEntry {
        try lock.withLock {
            if let error = statErrorStorage { throw error }
            return entriesStorage.first(where: { $0.name == URL(fileURLWithPath: path).lastPathComponent })
                ?? SMBBackendEntry(
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    kind: .file,
                    size: 0,
                    modifiedAt: Date(timeIntervalSince1970: 1),
                    createdAt: nil
                )
        }
    }

    func readSmallFile(path: String, maximumBytes: Int) async throws -> Data {
        Data()
    }

    func openSource(
        path: String,
        expectedRepresentation: RemoteFileRepresentation
    ) async throws -> any MediaTransportByteSource {
        source ?? FakeByteSource(byteSize: expectedRepresentation.size)
    }

    func onShutdown(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { shutdownObserver = observer }
    }

    func shutdown() async {
        let observer = lock.withLock {
            shutdownCountStorage += 1
            return shutdownObserver
        }
        observer?()
    }
}

private final class ReadStartedSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isStarted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        let waiters = lock.withLock {
            isStarted = true
            let waiters = self.waiters
            self.waiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let started = lock.withLock {
                guard !isStarted else { return true }
                waiters.append(continuation)
                return false
            }
            if started {
                continuation.resume()
            }
        }
    }
}

private final class BlockingCancellableByteSource: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64 = 4

    private let readStarted: ReadStartedSignal

    init(readStarted: ReadStartedSignal) {
        self.readStarted = readStarted
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        readStarted.markStarted()
        try await Task.sleep(for: .seconds(60))
        return Data()
    }

    func shutdown() async {}
}

private final class ImmediateByteSource: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64

    private let data: Data

    init(data: Data) {
        self.data = data
        byteSize = Int64(data.count)
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        let lowerBound = Int(offset)
        let upperBound = min(lowerBound + length, data.count)
        return data.subdata(in: lowerBound..<upperBound)
    }

    func shutdown() async {}
}

private final class FakeByteSource: MediaTransportByteSource, @unchecked Sendable {
    let byteSize: Int64

    init(byteSize: Int64) {
        self.byteSize = byteSize
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        Data()
    }

    func shutdown() async {}
}
