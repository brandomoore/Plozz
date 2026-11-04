import CoreModels
import MediaTransportCore
import XCTest
@testable import MediaDownloads

private actor CancellationInsensitiveReadGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private struct CancellationInsensitiveByteReader: DownloadByteReader {
    let byteSize: Int64
    let payload: Data
    let gate: CancellationInsensitiveReadGate

    func read(at offset: Int64, length: Int) async throws -> Data {
        await gate.wait()
        return Data(payload.prefix(length))
    }

    func close() async {}
}

private struct CancellationInsensitiveOpener: DownloadByteSourceOpening {
    let reader: CancellationInsensitiveByteReader

    func open(
        _ source: DirectShareDownloadSource
    ) async throws -> any DownloadByteReader {
        reader
    }
}

final class TransportCursorDownloadEngineTests: XCTestCase {
    private struct WholeReader: WholeFileDownloadByteReader {
        let byteSize: Int64 = 100
        let requiresWholeFileTransfer = true
        var count = 100
        var cancellation = false
        func read(at offset: Int64, length: Int) async throws -> Data {
            XCTFail("Unvalidated download must not use range reads")
            throw MediaDownloadError.unsupportedSource
        }
        func readWholeFile(consume: @escaping @Sendable (Data) async throws -> Void) async throws {
            try await consume(Data(repeating: 7, count: count))
            if cancellation { throw CancellationError() }
        }
        func close() async {}
    }

    private struct WholeOpener: DownloadByteSourceOpening {
        let reader: WholeReader
        func open(_ source: DirectShareDownloadSource) async throws -> any DownloadByteReader { reader }
    }

    func testWholeResponseRestartsInsteadOfCombiningPersistedBytes() async throws {
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("media.mkv")
        try Data(repeating: 9, count: 50).write(to: destination)
        let engine = TransportCursorDownloadEngine(opener: WholeOpener(reader: WholeReader()))
        let count = try await engine.download(record: DownloadTestFactory.record(), to: destination) { _, _ in }
        XCTAssertEqual(count, 100)
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 7, count: 100))
    }

    func testIncompleteCancelledAndOversizedWholeResponsesDiscardPartialBytes() async throws {
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("media.mkv")
        for reader in [WholeReader(count: 50), WholeReader(count: 101), WholeReader(count: 50, cancellation: true)] {
            try Data(repeating: 9, count: 50).write(to: destination)
            let engine = TransportCursorDownloadEngine(opener: WholeOpener(reader: reader))
            do {
                _ = try await engine.download(record: DownloadTestFactory.record(), to: destination) { _, _ in }
                XCTFail("Partial response cannot complete a download")
            } catch is MediaDownloadError {
            } catch is CancellationError {
            }
            XCTAssertEqual(try Data(contentsOf: destination).count, 0)
        }
    }

    func testProductionOpenerRejectsStreamingOnlyBytesBeforeWritingOrResuming() async throws {
        for persistentReuse in [false, true] {
            let record = try DownloadTestFactory.record()
            let source = try XCTUnwrap(record.directShareSource)
            let key = MediaTransportSessionKey(
                accountID: source.accountID, credentialRevision: source.credentialRevision,
                endpoint: try MediaTransportEndpointIdentity(transportIdentifier: "https", host: "dav.example.com"),
                trustRevision: UUID(), role: .playback
            )
            let session = PersistenceTestSession(key: key, supportsPersistentByteReuse: persistentReuse)
            let registry = MediaTransportResolverRegistry()
            try await registry.register(session: session)
            let resolver = MediaTransportNetworkFileResolver(registry: registry) { _ in key }
            let engine = TransportCursorDownloadEngine(resolver: resolver, chunkSize: 64)
            let dir = DownloadTestFactory.tempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let destination = dir.appendingPathComponent("media.mkv")
            let existing = Data(repeating: 9, count: 10)
            try existing.write(to: destination)
            do {
                let count = try await engine.download(record: record, to: destination) { _, _ in }
                XCTAssertTrue(persistentReuse)
                XCTAssertEqual(count, 100)
                XCTAssertEqual(try Data(contentsOf: destination).count, 100)
                XCTAssertGreaterThan(session.readCount, 0)
            } catch let error as MediaDownloadError {
                XCTAssertFalse(persistentReuse)
                XCTAssertEqual(error, .unsupportedSource)
                XCTAssertEqual(try Data(contentsOf: destination), existing)
                XCTAssertEqual(session.readCount, 0)
            }
            XCTAssertTrue(session.didShutdown)
        }
    }

    private func makeData(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    private class PersistenceTestSession:
        MediaTransportSession, MediaTransportFileSystem, MediaTransportByteSource, @unchecked Sendable
    {
        let key: MediaTransportSessionKey
        let supportsPersistentByteReuse: Bool
        let byteSize: Int64 = 100
        var fileSystem: any MediaTransportFileSystem { self }
        private let lock = NSLock()
        private var reads = 0
        private var closed = false
        var readCount: Int { lock.withLock { reads } }
        var didShutdown: Bool { lock.withLock { closed } }

        init(key: MediaTransportSessionKey, supportsPersistentByteReuse: Bool) {
            self.key = key
            self.supportsPersistentByteReuse = supportsPersistentByteReuse
        }

        func validate() async throws {}
        func isHealthy() async -> Bool { true }
        func shutdown() async { lock.withLock { closed = true } }
        func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
            MediaTransportSourceLease(source: self)
        }
        func read(at offset: Int64, length: Int) async throws -> Data {
            lock.withLock { reads += 1 }
            return Data(repeating: 0, count: min(length, Int(byteSize - offset)))
        }
        func probe() async throws -> MediaTransportProbe {
            throw MediaTransportError.unsupportedCapability("unused fixture operation")
        }
        func list(relativePath: String) async throws -> [RemoteFileEntry] {
            throw MediaTransportError.unsupportedCapability("unused fixture operation")
        }
        func stat(relativePath: String) async throws -> RemoteFileEntry {
            throw MediaTransportError.unsupportedCapability("unused fixture operation")
        }
        func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data {
            throw MediaTransportError.unsupportedCapability("unused fixture operation")
        }
    }

    private final class WholeResponseSession: PersistenceTestSession, MediaTransportWholeFileByteSource, @unchecked Sendable {
        func readWholeFile(consume: @escaping @Sendable (Data) async throws -> Void) async throws {
            try await consume(Data(repeating: 7, count: 40))
            try await consume(Data(repeating: 8, count: 60))
        }
    }

    func testProductionOpenerUsesWholeResponseCapabilityWithoutEnablingRangeReuse() async throws {
        let record = try DownloadTestFactory.record()
        let source = try XCTUnwrap(record.directShareSource)
        let key = MediaTransportSessionKey(
            accountID: source.accountID, credentialRevision: source.credentialRevision,
            endpoint: try MediaTransportEndpointIdentity(transportIdentifier: "https", host: "dav.example.com"),
            trustRevision: UUID(), role: .playback
        )
        let session = WholeResponseSession(key: key, supportsPersistentByteReuse: false)
        let registry = MediaTransportResolverRegistry()
        try await registry.register(session: session)
        let resolver = MediaTransportNetworkFileResolver(registry: registry) { _ in key }
        let engine = TransportCursorDownloadEngine(resolver: resolver)
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("media.mkv")
        try Data(repeating: 1, count: 80).write(to: destination)
        let bytes = try await engine.download(record: record, to: destination) { _, _ in }
        XCTAssertEqual(bytes, 100)
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 7, count: 40) + Data(repeating: 8, count: 60))
        XCTAssertEqual(session.readCount, 0)
        XCTAssertTrue(session.didShutdown)
    }

    func testDownloadsWholeFile() async throws {
        let payload = makeData(300)
        let opener = FakeOpener([FakeByteReader(bytes: payload, maxChunk: 64)])
        let engine = TransportCursorDownloadEngine(opener: opener, chunkSize: 128)
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("media.mkv")
        let record = try DownloadTestFactory.record()

        let total = try await engine.download(record: record, to: dest) { _, _ in }

        XCTAssertEqual(total, 300)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testInterruptionLeavesResumablePartialThenResumesToCompletion() async throws {
        let payload = makeData(300)
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("media.mkv")
        let record = try DownloadTestFactory.record()

        // First attempt: short reads that fail once offset reaches 150 -> a 150-byte
        // partial file is left on disk.
        let interrupting = FakeByteReader(bytes: payload, maxChunk: 50, failAtOffset: 150)
        let engine1 = TransportCursorDownloadEngine(
            opener: FakeOpener([interrupting]), chunkSize: 50
        )
        do {
            _ = try await engine1.download(record: record, to: dest) { _, _ in }
            XCTFail("expected the interrupted download to throw")
        } catch is CancellationError {
            // expected
        }
        let partialSize = try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int
        XCTAssertEqual(partialSize, 150)

        // Second attempt resumes from the 150 bytes already on disk.
        let completing = FakeByteReader(bytes: payload, maxChunk: 50)
        let engine2 = TransportCursorDownloadEngine(
            opener: FakeOpener([completing]), chunkSize: 50
        )
        let total = try await engine2.download(record: record, to: dest) { _, _ in }

        XCTAssertEqual(total, 300)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testResumeOffsetPastEOFRestartsCleanly() async throws {
        // Pre-seed a stale, oversized partial (server file shrank/changed).
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("media.mkv")
        try makeData(500).write(to: dest)

        let payload = makeData(120)
        let engine = TransportCursorDownloadEngine(
            opener: FakeOpener([FakeByteReader(bytes: payload, maxChunk: 40)]),
            chunkSize: 40
        )
        let record = try DownloadTestFactory.record()

        let total = try await engine.download(record: record, to: dest) { _, _ in }
        XCTAssertEqual(total, 120)
        XCTAssertEqual(try Data(contentsOf: dest), payload)
    }

    func testMissingSourceThrowsUnsupported() async throws {
        let engine = TransportCursorDownloadEngine(opener: FakeOpener([]))
        var record = try DownloadTestFactory.record()
        record.directShareSource = nil
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await engine.download(
                record: record, to: dir.appendingPathComponent("m.mkv")
            ) { _, _ in }
            XCTFail("expected unsupportedSource")
        } catch let error as MediaDownloadError {
            XCTAssertEqual(error, .unsupportedSource)
        }
    }

    func testCancellationDuringUncooperativeReadDoesNotWriteReturnedBytes() async throws {
        let payload = makeData(100)
        let gate = CancellationInsensitiveReadGate()
        let reader = CancellationInsensitiveByteReader(
            byteSize: Int64(payload.count),
            payload: payload,
            gate: gate
        )
        let engine = TransportCursorDownloadEngine(
            opener: CancellationInsensitiveOpener(reader: reader),
            chunkSize: payload.count
        )
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("media.mkv")
        let record = try DownloadTestFactory.record()

        let download = Task {
            try await engine.download(
                record: record,
                to: destination
            ) { _, _ in }
        }
        await gate.waitUntilStarted()
        download.cancel()
        await gate.open()

        do {
            _ = try await download.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            let size = try FileManager.default.attributesOfItem(
                atPath: destination.path
            )[.size] as? Int
            XCTAssertEqual(size, 0)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPrematureEOFDoesNotReportCompletion() async throws {
        let payload = makeData(100)
        let reader = FakeByteReader(
            bytes: payload,
            maxChunk: 40,
            reportedByteSize: 150
        )
        let engine = TransportCursorDownloadEngine(
            opener: FakeOpener([reader]),
            chunkSize: 40
        )
        let dir = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("media.mkv")
        let record = try DownloadTestFactory.record()

        do {
            _ = try await engine.download(
                record: record,
                to: destination
            ) { _, _ in }
            XCTFail("expected premature EOF")
        } catch let error as MediaDownloadError {
            XCTAssertEqual(
                error,
                .unexpectedEndOfFile(expected: 150, actual: 100)
            )
        }
    }
}
