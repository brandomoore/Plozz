import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderSilo

private actor RestartingSiloHTTP: HTTPClient {
    private var online = false
    private let provenUndelivered: Bool
    private(set) var refreshCount = 0

    init(provenUndelivered: Bool = true) { self.provenUndelivered = provenUndelivered }
    func recover() { online = true }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let json: String
        if endpoint.path == "/api/v2/auth/refresh" {
            refreshCount += 1
            XCTAssertTrue(endpoint.reportsUndeliveredRequests)
            if !online {
                if provenUndelivered { throw HTTPRequestNotSentError(underlying: .serverUnreachable) }
                throw AppError.serverUnreachable
            }
            json = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#
        } else {
            XCTAssertTrue(online)
            json = #"{"items":[{"id":"movies","name":"Movies","type":"movie"}]}"#
        }
        return (Data(json.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private final class SiloCooldownClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private actor RateLimitedSiloHTTP: HTTPClient {
    private(set) var requests: [Endpoint] = []
    let headers: [String: String]

    init(headers: [String: String]) { self.headers = headers }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        return (
            Data(#"{"items":[{"id":"movies","name":"Movies","type":"movie"}]}"#.utf8),
            try XCTUnwrap(HTTPURLResponse(
                url: baseURL, statusCode: requests.count == 1 ? 429 : 200,
                httpVersion: nil, headerFields: headers
            ))
        )
    }
}

private actor PacedSiloHTTP: HTTPClient {
    private(set) var requests: [(path: String, instant: ContinuousClock.Instant, background: Bool)] = []

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append((endpoint.path, .now, IdentityEnrichment.isBackgroundScan))
        return (
            Data(),
            try XCTUnwrap(HTTPURLResponse(
                url: baseURL, statusCode: endpoint.path.hasSuffix("/blocked") ? 429 : 204,
                httpVersion: nil, headerFields: ["Retry-After": "120"]
            ))
        )
    }
}

extension SiloProviderTests {
    func testBackgroundCatalogReadsArePacedAcrossConcurrentEnrichmentTasks() async throws {
        let raw = try credential().encoded()
        let http = PacedSiloHTTP()
        let client = try SiloClient(context: context(raw), store: SiloCredentialStub(raw), http: http)
        try await IdentityEnrichment.$isBackgroundScan.withValue(true) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for id in 0..<6 {
                    group.addTask { _ = try await client.send("/catalog/items/\(id)") }
                }
                try await group.waitForAll()
            }
        }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(Set(requests.map(\.path)).count, 6)
        XCTAssertTrue(requests.allSatisfy(\.background))
        let first = try XCTUnwrap(requests.first?.instant)
        let last = try XCTUnwrap(requests.last?.instant)
        XCTAssertGreaterThanOrEqual(first.duration(to: last), .milliseconds(950))
        for pair in zip(requests, requests.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0.instant.duration(to: pair.1.instant), .milliseconds(180))
        }
        XCTAssertFalse(IdentityEnrichment.isBackgroundScan)
    }

    func testInteractiveReadsAndWritesDoNotQueueBehindBackgroundScan() async throws {
        let raw = try credential().encoded()
        let http = PacedSiloHTTP()
        let client = try SiloClient(
            context: context(raw), store: SiloCredentialStub(raw), http: http,
            backgroundReadInterval: .seconds(30)
        )
        _ = try await IdentityEnrichment.$isBackgroundScan.withValue(true) {
            try await client.send("/catalog/items/first")
        }
        let pending = Task {
            try await IdentityEnrichment.$isBackgroundScan.withValue(true) {
                try await client.send("/catalog/items/pending")
            }
        }
        defer { pending.cancel() }
        let completed = expectation(description: "Interactive work bypasses background pacing")
        let interactive = Task {
            defer { completed.fulfill() }
            _ = try await client.send("/catalog")
            _ = try await client.send("/playback/start", method: .post)
        }
        defer { interactive.cancel() }
        await fulfillment(of: [completed], timeout: 2)
        interactive.cancel()
        try await interactive.value
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled background work must not transmit") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), [
            "/api/v2/catalog/items/first", "/api/v2/catalog", "/api/v2/playback/start"
        ])
        XCTAssertEqual(requests.map(\.background), [true, false, false])
    }

    func testBackgroundReadRechecksAuthorizationAfterPacing() async throws {
        let raw = try credential().encoded()
        let http = PacedSiloHTTP()
        let store = SiloCredentialStub(raw)
        let client = try SiloClient(context: context(raw), store: store, http: http)
        _ = try await IdentityEnrichment.$isBackgroundScan.withValue(true) {
            try await client.send("/catalog/items/first")
        }
        let pending = Task {
            try await IdentityEnrichment.$isBackgroundScan.withValue(true) {
                try await client.send("/catalog/items/pending")
            }
        }
        defer { pending.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        store.remove()
        do { _ = try await pending.value; XCTFail("The login was removed while waiting") }
        catch { XCTAssertEqual(error as? AppError, .unauthorized) }
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v2/catalog/items/first"])
    }

    func testBackgroundReadRechecksServerCooldownAfterPacing() async throws {
        let raw = try credential().encoded()
        let http = PacedSiloHTTP()
        let client = try SiloClient(context: context(raw), store: SiloCredentialStub(raw), http: http)
        _ = try await IdentityEnrichment.$isBackgroundScan.withValue(true) {
            try await client.send("/catalog/items/first")
        }
        let pending = Task {
            try await IdentityEnrichment.$isBackgroundScan.withValue(true) {
                try await client.send("/catalog/items/pending")
            }
        }
        defer { pending.cancel() }
        do { _ = try await client.send("/blocked"); XCTFail("Expected the real server refusal") }
        catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 120)) }
        do { _ = try await pending.value; XCTFail("Queued reads must respect the new cooldown") }
        catch {
            guard case .rateLimited(let remaining) = error as? AppError else {
                return XCTFail("Expected cooldown, got \(error)")
            }
            XCTAssertGreaterThan(try XCTUnwrap(remaining), 110)
        }
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v2/catalog/items/first", "/api/v2/blocked"])
    }

    func testRateLimitStopsPendingReadsAndWritesUntilExplicitRetryAfterCooldown() async throws {
        let clock = SiloCooldownClock()
        let raw = try credential().encoded()
        let http = RateLimitedSiloHTTP(headers: ["Retry-After": "120"])
        let client = try SiloClient(
            context: context(raw), store: SiloCredentialStub(raw), http: http, now: { clock.now() }
        )
        do { _ = try await client.send("/catalog/items/movie1"); XCTFail("Expected rate limiting") }
        catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 120)) }
        clock.advance(30)
        for _ in 0..<50 {
            do { _ = try await client.send("/catalog/items/movie2"); XCTFail("The connection is cooling down") }
            catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 90)) }
        }
        do { _ = try await client.send("/watched/movie1", method: .post); XCTFail("Do not transmit during cooldown") }
        catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 90)) }
        let blockedRequests = await http.requests
        XCTAssertEqual(blockedRequests.count, 1)

        let independent = try SiloProvider(
            context: context(raw), credentials: SiloCredentialStub(raw),
            http: SiloHTTPStub(["/api/v2/user/libraries": #"{"items":[]}"#])
        )
        let independentLibraries = try await independent.libraries()
        XCTAssertTrue(independentLibraries.isEmpty, "A connection's cooldown must not block other connections")

        clock.advance(90)
        let beforeRetry = await http.requests
        XCTAssertEqual(beforeRetry.count, 1, "Expiry must not automatically replay the refused read or write")
        let libraries: SiloCollection<SiloLibrary> = try await client.request("/user/libraries")
        XCTAssertEqual(libraries.items.map(\.id), ["movies"])
        let finishedRequests = await http.requests
        XCTAssertEqual(finishedRequests.map(\.path), ["/api/v2/catalog/items/movie1", "/api/v2/user/libraries"])
        XCTAssertTrue(finishedRequests.allSatisfy { $0.method == .get })
    }

    func testRateLimitCooldownUsesServerDateAndSafeMissingHeaderFallback() async throws {
        let clock = SiloCooldownClock()
        let serverDate = clock.now().addingTimeInterval(-3600)
        for headers in [
            ["Date": HTTPDate.string(from: serverDate),
             "Retry-After": HTTPDate.string(from: serverDate.addingTimeInterval(60))],
            ["Retry-After": "nan"],
            [:]
        ] {
            let raw = try credential().encoded()
            let http = RateLimitedSiloHTTP(headers: headers)
            let client = try SiloClient(
                context: context(raw), store: SiloCredentialStub(raw), http: http, now: { clock.now() }
            )
            do { _ = try await client.send("/user/libraries"); XCTFail("Expected rate limiting") }
            catch {
                XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: headers["Date"] == nil ? nil : 60))
            }
            clock.advance(59)
            do { _ = try await client.send("/user/libraries"); XCTFail("Honor the entire cooldown") }
            catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 1)) }
            clock.advance(1)
            _ = try await client.send("/user/libraries")
            let requests = await http.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testNASOutageBeforeRefreshTransmissionCanRecoverWithoutLosingLogin() async throws {
        var login = try credential()
        login.expiresAt = .distantPast
        let raw = try login.encoded()
        let store = SiloCredentialStub(raw)
        let ctx = context(raw)
        let http = RestartingSiloHTTP()
        let first = try SiloProvider(context: ctx, credentials: store, http: http)
        do {
            _ = try await first.libraries()
            XCTFail("The NAS is offline.")
        } catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        XCTAssertEqual(try store.credential(accountID: ctx.accountID, revision: ctx.credentialRevision), raw)
        await http.recover()
        let reopened = try SiloProvider(context: ctx, credentials: store, http: http)
        let libraries = try await reopened.libraries()
        XCTAssertEqual(libraries.map(\.id), ["movies"])
        let updated = try SiloCredential.decode(store.credential(accountID: ctx.accountID, revision: ctx.credentialRevision))
        XCTAssertEqual(updated.loginID, login.loginID)
        XCTAssertEqual(updated.refreshToken, "new-refresh")
        XCTAssertEqual(updated.refreshPending, false)
        let count = await http.refreshCount
        XCTAssertEqual(count, 2, "Only the proven-undelivered attempt may be retried.")
    }

    func testAmbiguousNetworkFailureStillCannotReplayARotatingRefresh() async throws {
        var login = try credential()
        login.expiresAt = .distantPast
        let raw = try login.encoded()
        let store = SiloCredentialStub(raw)
        let ctx = context(raw)
        let http = RestartingSiloHTTP(provenUndelivered: false)
        let first = try SiloProvider(context: ctx, credentials: store, http: http)
        do { _ = try await first.libraries(); XCTFail("The connection failed.") }
        catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        await http.recover()
        let reopened = try SiloProvider(context: ctx, credentials: store, http: http)
        do { _ = try await reopened.libraries(); XCTFail("The first refresh might have consumed its token.") }
        catch { XCTAssertEqual(error as? AppError, .unauthorized) }
        let count = await http.refreshCount
        XCTAssertEqual(count, 1)
    }
}
