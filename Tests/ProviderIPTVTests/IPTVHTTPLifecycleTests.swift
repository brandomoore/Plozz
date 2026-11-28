import Foundation
import XCTest
@testable import ProviderIPTV

final class IPTVHTTPLifecycleTests: XCTestCase {
    override func tearDown() {
        IPTVFixture.state.reset()
        super.tearDown()
    }

    func testRequestAfterShutdownThrowsCancellationWithoutStartingNetworkWork() async throws {
        let http = IPTVHTTP(configuration: IPTVFixture.configuration())
        http.cancel()
        http.cancel()
        do {
            _ = try await http.bytes(url: XCTUnwrap(URL(string: "https://provider.test/closed")), headers: [:])
            XCTFail("A retired provider cannot start a request.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertTrue(IPTVFixture.state.requests.isEmpty)
    }

    func testShutdownCancelsRequestsStillWaitingForHeaders() async throws {
        let server = try IPTVTestHTTPServer { _ in
            .init(data: Data("body".utf8), headerDelay: .seconds(30))
        }
        let url = try await server.start()
        addTeardownBlock { await server.stop() }
        let http = IPTVHTTP()
        let request = Task { try await http.bytes(url: url, headers: [:]) }
        try await waitForRequest(server)
        let start = ContinuousClock.now
        http.cancel()
        do {
            _ = try await request.value
            XCTFail("Shutdown must cancel pending response headers.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
    }

    func testShutdownCancelsBodyAfterHeadersHaveBeenDelivered() async throws {
        let server = try IPTVTestHTTPServer { _ in
            .init(data: Data(repeating: 1, count: 131_072), delay: .seconds(30))
        }
        let url = try await server.start()
        addTeardownBlock { await server.stop() }
        let http = IPTVHTTP()
        let (bytes, _) = try await http.bytes(url: url, headers: [:])
        http.cancel()
        var iterator = bytes.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Shutdown must cancel a streaming response as well as startup.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    func testConcurrentAdmissionAndShutdownCannotCreateTasksInAnInvalidSession() async throws {
        let server = try IPTVTestHTTPServer { _ in .init(data: Data("body".utf8)) }
        let url = try await server.start()
        addTeardownBlock { await server.stop() }
        for _ in 0..<20 {
            let http = IPTVHTTP()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        do {
                            let (bytes, _) = try await http.bytes(url: url, headers: [:])
                            bytes.task.cancel()
                        } catch {
                            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
                        }
                    }
                }
                group.addTask { http.cancel() }
            }
            http.cancel()
        }
    }

    func testCancellingOneCallerDoesNotCloseTheSessionForAnother() async throws {
        let server = try IPTVTestHTTPServer { request in
            .init(data: Data("body".utf8), headerDelay: request.contains("/slow") ? .seconds(30) : .zero)
        }
        let url = try await server.start()
        addTeardownBlock { await server.stop() }
        let http = IPTVHTTP()
        defer { http.cancel() }
        let first = Task { try await http.bytes(url: url.appendingPathComponent("slow"), headers: [:]) }
        try await waitForRequest(server)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("The caller's cancellation must reach its network task.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        let (bytes, response) = try await http.bytes(url: url, headers: [:])
        defer { bytes.task.cancel() }
        var body = Data()
        for try await byte in bytes { body.append(byte) }
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(body, Data("body".utf8))
    }

    func testChunkStreamAppliesBackpressureDrainsCleanlyAndCancelsOnShutdown() async throws {
        let totalBytes = 6 * 1_024 * 1_024
        let payload = Data((0..<totalBytes).map { UInt8($0 & 0xff) })
        let server = try IPTVTestHTTPServer { _ in
            .init(data: payload, headers: ["Content-Type": "video/mp2t"], chunkSize: 65_536)
        }
        let url = try await server.start().appendingPathComponent("stream.ts")
        addTeardownBlock { await server.stop() }
        let http = IPTVHTTP(redirectScope: .playback)
        defer { http.cancel() }

        let (stream, response) = try await http.chunks(url: url, headers: [:])
        XCTAssertEqual(response.statusCode, 200)
        try await Task.sleep(for: .milliseconds(250))
        let pausedSent = await server.bodyBytesSent
        XCTAssertLessThan(pausedSent, totalBytes, "High-water backpressure must suspend upstream before buffering all 6 MiB.")

        var received = Data()
        received.reserveCapacity(totalBytes)
        while let chunk = try await stream.nextChunk() {
            received.append(chunk)
        }
        XCTAssertEqual(received.count, totalBytes)
        XCTAssertEqual(received, payload)

        let slowServer = try IPTVTestHTTPServer { _ in
            .init(data: Data(repeating: 0x47, count: 131_072), delay: .seconds(30), chunkSize: 1_024)
        }
        let slowURL = try await slowServer.start().appendingPathComponent("slow.ts")
        addTeardownBlock { await slowServer.stop() }
        let cancellableHTTP = IPTVHTTP(redirectScope: .playback)
        let (slowStream, _) = try await cancellableHTTP.chunks(url: slowURL, headers: [:])
        cancellableHTTP.cancel()
        do {
            _ = try await slowStream.nextChunk()
            XCTFail("Session shutdown must cancel an active chunk stream.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    func testWarmOriginStripsPathQueryCredentialsAndRefusesRedirects() async throws {
        let redirectTarget = try IPTVTestHTTPServer { _ in .init(data: Data()) }
        let targetURL = try await redirectTarget.start()
        addTeardownBlock { await redirectTarget.stop() }
        let rawRequests = IPTVRecordedRawRequests()
        let originServer = try IPTVTestHTTPServer { request in
            rawRequests.append(request)
            return .init(status: 302, headers: ["Location": targetURL.absoluteString])
        }
        let originURL = try await originServer.start()
        addTeardownBlock { await originServer.stop() }

        var dirty = try XCTUnwrap(URLComponents(url: originURL, resolvingAgainstBaseURL: false))
        dirty.user = "viewer"
        dirty.password = "secret-pass"
        dirty.path = "/player_api.php"
        dirty.queryItems = [URLQueryItem(name: "password", value: "secret-pass")]
        let http = IPTVHTTP(sensitiveValues: ["secret-pass"], redirectScope: .playback)
        defer { http.cancel() }

        await http.warmOrigin(try XCTUnwrap(dirty.url))
        let count = await originServer.requestCount
        let redirectedCount = await redirectTarget.requestCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(redirectedCount, 0, "Origin warmup must never follow HTTP redirects.")
        let recorded = try XCTUnwrap(rawRequests.values.first)
        XCTAssertTrue(recorded.hasPrefix("HEAD / HTTP/1.1\r\n"))
        XCTAssertFalse(recorded.contains("secret-pass"))
        XCTAssertFalse(recorded.contains("viewer"))
    }

    private func waitForRequest(_ server: IPTVTestHTTPServer) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await server.requestCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let count = await server.requestCount
        XCTAssertGreaterThan(count, 0)
    }
}

private final class IPTVRecordedRawRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}
