import CoreModels
import Foundation
@testable import MediaTransportCore
import XCTest
@testable import AppRuntime

@MainActor
final class ExternalPlaybackByteServerTests: XCTestCase {
    func testRangeParsingIncludesSuffixOpenEndedAndClamping() throws {
        XCTAssertEqual(try ExternalPlaybackByteServer.interval(nil, size: 100), 0..<100)
        XCTAssertEqual(try ExternalPlaybackByteServer.interval("bytes=10-20", size: 100), 10..<21)
        XCTAssertEqual(try ExternalPlaybackByteServer.interval("bytes=90-", size: 100), 90..<100)
        XCTAssertEqual(try ExternalPlaybackByteServer.interval("bytes=-12", size: 100), 88..<100)
        XCTAssertEqual(try ExternalPlaybackByteServer.interval("bytes=90-999", size: 100), 90..<100)
        XCTAssertEqual(try ExternalPlaybackByteServer.interval("bytes=-999", size: 100), 0..<100)
        for value in ["bytes=", "bytes=-0", "bytes=-", "bytes=100-", "bytes=20-10", "bytes=1-2,4-5",
                      "bytes=+1-4", "bytes= 1-4", "bytes=1-999999999999999999999999", "items=0-1"] {
            XCTAssertThrowsError(try ExternalPlaybackByteServer.interval(value, size: 100), value)
        }
    }

    func testRequestRejectsDuplicateRangesBrowserOriginsAndUnexpectedHosts() throws {
        let valid = "GET /capability/0.mkv HTTP/1.1\r\nHost: 127.0.0.1:1000\r\nRange: bytes=0-1\r\n\r\n"
        let parsed = try ExternalPlaybackByteServer.Request(valid, authority: "127.0.0.1:1000")
        XCTAssertEqual(parsed.path, "/capability/0.mkv")
        XCTAssertEqual(parsed.range, "bytes=0-1")
        for invalid in [
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nRange: bytes=2-3\r\n\r\n"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nOrigin: https://untrusted.example\r\n\r\n"),
            valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nTransfer-Encoding: chunked\r\n\r\n"),
            valid.replacingOccurrences(of: "127.0.0.1:1000", with: "attacker.example"),
            valid.replacingOccurrences(of: "GET ", with: "POST ")
        ] {
            XCTAssertThrowsError(try ExternalPlaybackByteServer.Request(invalid, authority: "127.0.0.1:1000"))
        }
    }

    func testRealHTTPRangesAndShortReadsPreserveExactBytes() async throws {
        let fixture = try ByteServerFixture(shortReads: true)
        let urls = try await fixture.server.start()
        do {
            for (range, expected) in [(nil, 0..<1000), ("bytes=201-701", 201..<702), ("bytes=-50", 950..<1000)] {
                var request = URLRequest(url: urls[0])
                request.setValue(range, forHTTPHeaderField: "Range")
                let (data, response) = try await fixture.http.data(for: request)
                XCTAssertEqual(data, fixture.bytes.subdata(in: expected))
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, range == nil ? 200 : 206)
                XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            }
            await fixture.stop()
        } catch { await fixture.stop(); throw error }
        let shutdowns = await fixture.source.shutdowns
        XCTAssertEqual(shutdowns, 1)
    }

    func testHEADAndUnsatisfiableRangesNeverReadTheSource() async throws {
        let fixture = try ByteServerFixture()
        let urls = try await fixture.server.start()
        do {
            var head = URLRequest(url: urls[0])
            head.httpMethod = "HEAD"
            let (body, response) = try await fixture.http.data(for: head)
            XCTAssertTrue(body.isEmpty)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "1000")
            var request = URLRequest(url: urls[0])
            request.setValue("bytes=1000-", forHTTPHeaderField: "Range")
            let (_, refused) = try await fixture.http.data(for: request)
            XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 416)
            let reads = await fixture.source.reads
            XCTAssertEqual(reads, 0)
            await fixture.stop()
        } catch { await fixture.stop(); throw error }
    }

    func testWrongCapabilityAndRevokedAuthorizationCannotReadBytes() async throws {
        let fixture = try ByteServerFixture()
        let urls = try await fixture.server.start()
        do {
            let wrong = urls[0].deletingLastPathComponent().appendingPathComponent("wrong.mkv")
            let (_, response) = try await fixture.http.data(from: wrong)
            XCTAssertNotEqual((response as? HTTPURLResponse)?.statusCode, 200)
            fixture.authorized = false
            let (data, denied) = try await fixture.http.data(from: urls[0])
            XCTAssertTrue(data.isEmpty)
            XCTAssertNotEqual((denied as? HTTPURLResponse)?.statusCode, 200)
            let reads = await fixture.source.reads
            XCTAssertEqual(reads, 0)
            await fixture.stop()
        } catch { await fixture.stop(); throw error }
    }

    func testStopIsIdempotentAndRevokesTheListener() async throws {
        let fixture = try ByteServerFixture()
        let urls = try await fixture.server.start()
        await fixture.server.stop()
        await fixture.server.stop()
        do {
            _ = try await fixture.http.data(from: urls[0])
            XCTFail("Stopped capability must not serve")
        } catch {}
        await fixture.stop()
        let shutdowns = await fixture.source.shutdowns
        XCTAssertEqual(shutdowns, 1)
    }

    func testOnlyExplicitlyOwnedLocalURLsCanEnterAPlayerLink() throws {
        let url = URL(string: "http://127.0.0.1:1234/capability/0.mkv")!
        XCTAssertFalse(ExternalPlayerURL.isSupportedMediaURL(url))
        func link(_ player: ExternalPlayer, owned: Set<URL>) throws -> URL {
            try ExternalPlayerURL.make(
                settings: .init(player: player, customURLTemplate: "other://play?url={url}"),
                mediaURL: url, title: "Movie", position: 0, callbackScheme: "test",
                nonce: UUID(), ownedLocalURLs: owned
            )
        }
        XCTAssertNoThrow(try link(.infuse, owned: [url]))
        XCTAssertThrowsError(try link(.infuse, owned: []))
        XCTAssertThrowsError(try link(.infuse, owned: [url.appendingPathComponent("other")]))
        XCTAssertThrowsError(try link(.custom, owned: [url]))
    }

    func testAdmissionCancellationCompletesLateGrantInsteadOfLaunching() async throws {
        let admission = ExternalPlaybackAdmission()
        admission.cancel()
        let grant = TestExternalExecution()
        admission.resolve(.success(grant))
        XCTAssertFalse(grant.isValid)
        do { _ = try await admission.wait(); XCTFail("Cancelled admission") } catch {}
        XCTAssertEqual(grant.completions, [false])
    }

    func testAdmissionWaitsForGrantAndCancellationRevokesAnEarlyGrant() async throws {
        let admission = ExternalPlaybackAdmission()
        let grant = TestExternalExecution()
        admission.resolve(.success(grant))
        let result = try await admission.wait()
        XCTAssertTrue(result.isValid)
        admission.cancel()
        XCTAssertFalse(result.isValid)
    }

    func testRegistrationReceiverDoesNotRetainAdmissionOrCompletedGrant() async throws {
        var admission: ExternalPlaybackAdmission? = ExternalPlaybackAdmission()
        weak var weakAdmission = admission
        let receive = try XCTUnwrap(admission).receiver()
        weak var weakGrant: TestExternalExecution?
        do {
            let grant = TestExternalExecution()
            weakGrant = grant
            receive(.success(grant))
            let admitted = try await XCTUnwrap(admission).wait()
            admitted.finish(success: true)
        }
        admission = nil
        XCTAssertNil(weakAdmission)
        XCTAssertNil(weakGrant)
        let late = TestExternalExecution()
        receive(.success(late))
        XCTAssertEqual(late.completions, [false])
    }

    func testTerminalUpstreamFailureRevokesAllResourcesButTimeoutCanRetry() async throws {
        for terminal in [false, true] {
            let fixture = try ByteServerFixture()
            let urls = try await fixture.server.start()
            await fixture.source.fail(terminal ? .sourceChanged(reason: "test") : .timeout)
            do {
                let (_, response) = try await fixture.http.data(from: urls[0])
                XCTAssertNotEqual((response as? HTTPURLResponse)?.statusCode, 200)
            } catch {}
            if terminal {
                await fixture.source.waitForShutdown()
                XCTAssertEqual(fixture.failures, 1)
            } else {
                XCTAssertEqual(fixture.failures, 0)
                await fixture.source.fail(nil)
                let (data, response) = try await fixture.http.data(from: urls[0])
                XCTAssertEqual(data, fixture.bytes)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            }
            await fixture.stop()
        }
    }

    func testBoundedUpstreamBatchingAvoidsOneRoundTripPerSocketWrite() async throws {
        var timings: [TimeInterval] = []
        var reads: [Int] = []
        for preferred in [262_144, 32 * 1024 * 1024] {
            let fixture = try ByteServerFixture(
                count: 8 * 1024 * 1024 + 17, preferredReadSize: preferred, latency: .milliseconds(100)
            )
            let urls = try await fixture.server.start()
            do {
                let start = ProcessInfo.processInfo.systemUptime
                let (data, _) = try await fixture.http.data(from: urls[0])
                timings.append(ProcessInfo.processInfo.systemUptime - start)
                XCTAssertEqual(data, fixture.bytes, "Both measurements must transfer the complete file")
                let requested = await fixture.source.requestedLengths
                reads.append(requested.count)
                XCTAssertLessThanOrEqual(requested.max() ?? 0, 4 * 1024 * 1024)
                await fixture.stop()
            } catch { await fixture.stop(); throw error }
        }
        XCTAssertEqual(reads, [33, 3])
        XCTAssertLessThan(timings[1], timings[0] / 2)
    }
}

@MainActor
final class TestExternalExecution: ExternalPlaybackExecutionLease {
    var isValid = true
    var completions: [Bool] = []
    var bytes: [Int64] = []
    var expiration: (@MainActor () -> Void)?
    func onExpiration(_ handler: @escaping @MainActor () -> Void) { expiration = handler }
    func update(deliveredBytes: Int64) { bytes.append(deliveredBytes) }
    func finish(success: Bool) {
        guard isValid else { return }
        isValid = false
        completions.append(success)
    }
    func expire() { isValid = false; expiration?() }
}

@MainActor
private final class ByteServerFixture {
    let bytes: Data
    let source: ExternalTestByteSource
    let lease: MediaTransportSourceLease
    let http: URLSession
    var authorized = true
    private(set) var progress: [Int64] = []
    private(set) var failures = 0
    var server: ExternalPlaybackByteServer!

    init(
        shortReads: Bool = false, count: Int = 1000, preferredReadSize: Int = 1_048_576,
        latency: Duration? = nil
    ) throws {
        bytes = Data((0..<count).map { UInt8($0 % 251) })
        source = ExternalTestByteSource(bytes: bytes, shortReads: shortReads, latency: latency)
        lease = MediaTransportSourceLease(source: source)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        http = URLSession(configuration: config)
        server = try ExternalPlaybackByteServer(
            resources: [.init(
                cursor: try XCTUnwrap(lease.makeCursor()), suffix: "mkv", preferredReadSize: preferredReadSize
            )],
            authorized: { [weak self] in self?.authorized == true },
            progress: { [weak self] in self?.progress.append($0) },
            failed: { [weak self] in self?.failures += 1 }
        )
    }

    func stop() async {
        await server.stop()
        await lease.waitForFinalShutdown()
        http.invalidateAndCancel()
    }
}

actor ExternalTestByteSource: MediaTransportByteSource {
    let byteSize: Int64
    let bytes: Data
    let shortReads: Bool
    let latency: Duration?
    private var failure: MediaTransportError?
    var shutdowns = 0
    var reads = 0
    var requestedLengths: [Int] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(bytes: Data, shortReads: Bool = false, latency: Duration? = nil) {
        self.bytes = bytes
        byteSize = Int64(bytes.count)
        self.shortReads = shortReads
        self.latency = latency
    }
    func fail(_ error: MediaTransportError?) { failure = error }
    func read(at offset: Int64, length: Int) async throws -> Data {
        reads += 1
        requestedLengths.append(length)
        if let failure { throw failure }
        if let latency { try await Task.sleep(for: latency) }
        let start = Int(offset)
        return bytes.subdata(in: start..<min(bytes.count, start + min(length, shortReads ? 17 : length)))
    }
    func shutdown() {
        shutdowns += 1
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
    func waitForShutdown() async {
        if shutdowns > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

actor ExternalRelayTestResolver: MediaTransportNetworkFileResolving {
    let source = ExternalTestByteSource(bytes: Data(repeating: 42, count: 1000))
    let registry = MediaTransportResolverRegistry(adapter: RelayTestAdapter())
    private(set) var resolved: [NetworkFileLocator] = []
    func resolve(_ locator: NetworkFileLocator) async throws -> MediaTransportResolvedSource {
        resolved.append(locator)
        let key = MediaTransportSessionKey(
            accountID: locator.accountID, credentialRevision: locator.credentialRevision,
            endpoint: try .init(transportIdentifier: "webdav", host: "fixture.example"),
            trustRevision: UUID(), role: .playback
        )
        let lease = try await registry.lease(for: key)
        return MediaTransportResolvedSource(
            sourceLease: MediaTransportSourceLease(source: source), sessionLease: lease, playbackLease: nil
        )
    }
}

private struct RelayTestAdapter: MediaTransportAdapter {
    let transportIdentifier = "webdav"
    func connect(for key: MediaTransportSessionKey) async throws -> any MediaTransportSession { RelayTestSession(key: key) }
}

private final class RelayTestSession: MediaTransportSession {
    let key: MediaTransportSessionKey
    let fileSystem: any MediaTransportFileSystem = RelayTestFileSystem()
    init(key: MediaTransportSessionKey) { self.key = key }
    func shutdown() async {}
    func isHealthy() async -> Bool { true }
}

private struct RelayTestFileSystem: MediaTransportFileSystem {
    func validate() async throws {}
    func probe() async throws -> MediaTransportProbe { throw ExternalPlayerError.unsupportedSource }
    func list(relativePath: String) async throws -> [RemoteFileEntry] { [] }
    func stat(relativePath: String) async throws -> RemoteFileEntry { throw ExternalPlayerError.unsupportedSource }
    func readSmallFile(relativePath: String, maximumBytes: Int) async throws -> Data { throw ExternalPlayerError.unsupportedSource }
    func openSource(for locator: NetworkFileLocator) async throws -> MediaTransportSourceLease {
        throw ExternalPlayerError.unsupportedSource
    }
}
