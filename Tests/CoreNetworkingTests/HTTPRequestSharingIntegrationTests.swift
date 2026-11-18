import CoreModels
import Foundation
import XCTest
@testable import CoreNetworking
@testable import TestSupportNetworking

final class HTTPRequestSharingIntegrationTests: XCTestCase {
    func testRealTransferSurvivesOneReaderCancellationAndLaterReadsAreFresh() async throws {
        let gate = ResponseGate()
        let (server, url) = try await server { _ in
            await gate.wait()
            return .json(#"{"value":"shared"}"#)
        }
        addTeardownBlock { await gate.release() }
        let session = session()
        let endpoint = Endpoint(
            path: "/items", headers: ["Authorization": "fixture-viewer"], allowsRequestCoalescing: true
        )
        let first = Task { try await URLSessionHTTPClient(session: session).send(endpoint, baseURL: url) }
        defer { first.cancel() }
        try await waitUntil { await server.requests.count == 1 }
        let second = Task { try await URLSessionHTTPClient(session: session).send(endpoint, baseURL: url) }
        defer { second.cancel() }
        try await waitUntil { await HTTPRequestCoalescer.shared.waitingReaderCount() == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled reader succeeded") }
        catch { XCTAssertEqual(error as? AppError, .cancelled) }
        await gate.release()
        let result = try await second.value
        XCTAssertEqual(result.0, Data(#"{"value":"shared"}"#.utf8))
        let sharedRequests = await server.requests.count
        XCTAssertEqual(sharedRequests, 1)
        _ = try await URLSessionHTTPClient(session: session).send(endpoint, baseURL: url)
        let freshRequests = await server.requests.count
        XCTAssertEqual(freshRequests, 2)
    }

    func testRealAccountsSessionsAndNonshareableRequestsRemainIndependent() async throws {
        let gate = ResponseGate()
        let (server, url) = try await server { request in
            await gate.wait()
            return .init(body: Data((request.headers["authorization"] ?? "missing").utf8))
        }
        addTeardownBlock { await gate.release() }
        let firstSession = session()
        let secondSession = session()
        var noRetry = Endpoint(path: "/no-retry", allowsRequestCoalescing: true)
        noRetry.allowsAutomaticAddressRetry = false
        var delivery = Endpoint(path: "/delivery", allowsRequestCoalescing: true)
        delivery.reportsUndeliveredRequests = true
        let stateful = Endpoint(path: "/stateful-get", allowsRequestCoalescing: false)
        let unreviewed = Endpoint(path: "/unreviewed-get")
        let requests: [(URLSession, Endpoint, String)] = [
            (firstSession, .init(path: "/accounts", headers: ["Authorization": "first"], allowsRequestCoalescing: true), "first"),
            (firstSession, .init(path: "/accounts", headers: ["Authorization": "second"], allowsRequestCoalescing: true), "second"),
            (firstSession, .init(path: "/lanes", allowsRequestCoalescing: true), "missing"),
            (secondSession, .init(path: "/lanes", allowsRequestCoalescing: true), "missing"),
            (firstSession, .init(method: .post, path: "/mutation", allowsRequestCoalescing: true), "missing"),
            (firstSession, .init(method: .post, path: "/mutation", allowsRequestCoalescing: true), "missing"),
            (firstSession, noRetry, "missing"), (firstSession, noRetry, "missing"),
            (firstSession, delivery, "missing"), (firstSession, delivery, "missing"),
            (firstSession, stateful, "missing"), (firstSession, stateful, "missing"),
            (firstSession, unreviewed, "missing"), (firstSession, unreviewed, "missing")
        ]
        let tasks = requests.map { session, endpoint, _ in
            Task { try await URLSessionHTTPClient(session: session).send(endpoint, baseURL: url) }
        }
        defer { tasks.forEach { $0.cancel() } }
        // The fixture session permits all requests so its connection cap cannot
        // conceal accidental request sharing.
        try await waitUntil { await server.requests.count == requests.count }
        await gate.release()
        for (task, request) in zip(tasks, requests) {
            let result = try await task.value
            XCTAssertEqual(result.0, Data(request.2.utf8))
        }
    }

    func testRealRedirectPolicyCannotJoinAPermissiveTransfer() async throws {
        let (_, destination) = try await server { _ in .json("{}") }
        let gate = ResponseGate()
        let (redirect, origin) = try await server { _ in
            await gate.wait()
            return .init(status: 302, headers: ["Location": destination.absoluteString + "/target"])
        }
        addTeardownBlock { await gate.release() }
        let client = URLSessionHTTPClient(session: session())
        let follow = Task {
            try await client.sendRaw(.init(path: "/redirect", allowsRequestCoalescing: true), baseURL: origin)
        }
        let protected = Task {
            try await client.sendRaw(
                .init(path: "/redirect", redirectPolicy: .sameOrigin, allowsRequestCoalescing: true), baseURL: origin
            )
        }
        defer { follow.cancel(); protected.cancel() }
        try await waitUntil { await redirect.requests.count == 2 }
        await gate.release()
        let followed = try await follow.value
        let blocked = try await protected.value
        XCTAssertEqual(followed.1.statusCode, 200)
        XCTAssertEqual(blocked.1.statusCode, 302)
    }

    func testSharedForegroundPoolsKeepDiscoveryCookieStorageIsolated() throws {
        XCTAssertTrue(URLSession.plozzDefault === URLSession.plozzDefault)
        XCTAssertTrue(URLSession.plozzInteractive === URLSession.plozzInteractive)
        XCTAssertFalse(URLSession.plozzDefault === URLSession.plozzInteractive)
        let first = URLSession.plozzDiscovery
        let second = URLSession.plozzDiscovery
        defer { first.invalidateAndCancel(); second.invalidateAndCancel() }
        XCTAssertFalse(first === second)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "fixture.invalid", .path: "/", .name: "viewer", .value: "first"
        ]))
        first.configuration.httpCookieStorage?.setCookie(cookie)
        XCTAssertFalse(second.configuration.httpCookieStorage?.cookies?.contains(cookie) == true)
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        return session
    }

    private func server(
        _ respond: @escaping @Sendable (LoopbackHTTPServer.Request) async -> LoopbackHTTPServer.Response
    ) async throws -> (LoopbackHTTPServer, URL) {
        let server = try LoopbackHTTPServer(respond: respond)
        addTeardownBlock { await server.stop() }
        return (server, try await server.start())
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("The expected real transfers did not start")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private actor ResponseGate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if !released { await withCheckedContinuation { waiters.append($0) } }
        }
        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
}
