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

    private func waitForRequest(_ server: IPTVTestHTTPServer) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await server.requestCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let count = await server.requestCount
        XCTAssertGreaterThan(count, 0)
    }
}
