import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderSilo

private final class SiloCooldownClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private actor SiloRateLimitHTTP: HTTPClient {
    private var status = 429
    private let retryAfter: String?
    private let throwsRateLimit: Bool
    private(set) var requests: [Endpoint] = []

    init(retryAfter: String? = "12", throwsRateLimit: Bool = false) {
        self.retryAfter = retryAfter
        self.throwsRateLimit = throwsRateLimit
    }

    func succeed() { status = 200 }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        if status == 429, throwsRateLimit { throw AppError.rateLimited(retryAfter: 12) }
        return (
            Data("{}".utf8),
            HTTPURLResponse(
                url: baseURL, statusCode: status, httpVersion: nil,
                headerFields: retryAfter.map { ["Retry-After": $0] }
            )!
        )
    }
}

extension SiloProviderTests {
    func testBrowseRateLimitRejectsOtherRoutesUntilMonotonicDeadline() async throws {
        let raw = try credential().encoded()
        let clock = SiloCooldownClock()
        let http = SiloRateLimitHTTP()
        let client = try SiloClient(
            context: context(raw), store: SiloCredentialStub(raw), http: http, uptime: { clock.now() }
        )
        do {
            try await client.send("/catalog")
            XCTFail("Expected the server's rate limit")
        } catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 12)) }
        await http.succeed()
        clock.advance(5)
        do {
            try await client.send("/home/sections")
            XCTFail("Home must honor the catalog cooldown")
        } catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 7)) }
        let duringCooldown = await http.requests
        XCTAssertEqual(duringCooldown.count, 1)
        clock.advance(7)
        try await client.send("/home/sections")
        let afterCooldown = await http.requests
        XCTAssertEqual(afterCooldown.count, 2)
    }

    func testUnknownRetryDelayUsesBoundedFallbackWithoutReplayingRequest() async throws {
        for header in [nil, "invalid", "-1"] as [String?] {
            let raw = try credential().encoded()
            let clock = SiloCooldownClock()
            let http = SiloRateLimitHTTP(retryAfter: header)
            let client = try SiloClient(
                context: context(raw), store: SiloCredentialStub(raw), http: http, uptime: { clock.now() }
            )
            do {
                try await client.send("/catalog")
                XCTFail("Expected rate limit")
            } catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: nil)) }
            await http.succeed()
            clock.advance(59)
            do {
                try await client.send("/user/libraries")
                XCTFail("An absent/malformed delay must not cause immediate retries")
            } catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 1)) }
            let requests = await http.requests
            XCTAssertEqual(requests.count, 1)
            clock.advance(1)
            try await client.send("/user/libraries")
        }
    }

    func testBrowseCooldownAcceptsHTTPDateAndTransportRateLimit() async throws {
        for transportFailure in [false, true] {
            let raw = try credential().encoded()
            let clock = SiloCooldownClock()
            let http = SiloRateLimitHTTP(
                retryAfter: HTTPDate.string(from: Date().addingTimeInterval(120)),
                throwsRateLimit: transportFailure
            )
            let client = try SiloClient(
                context: context(raw), store: SiloCredentialStub(raw), http: http, uptime: { clock.now() }
            )
            do {
                try await client.send("/catalog")
                XCTFail("Expected rate limit")
            } catch {
                guard case .rateLimited(let delay) = error as? AppError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertGreaterThan(delay ?? 0, 0)
            }
            await http.succeed()
            do {
                try await client.send("/home/layout")
                XCTFail("Cooldown must apply to all browsing routes")
            } catch {
                guard case .rateLimited = error as? AppError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            let requests = await http.requests
            XCTAssertEqual(requests.count, 1)
            clock.advance(121)
            try await client.send("/home/layout")
        }
    }

    func testBrowseCooldownDoesNotBlockPlaybackCleanupOrAnotherLogin() async throws {
        let raw = try credential().encoded()
        let clock = SiloCooldownClock()
        let http = SiloRateLimitHTTP()
        let store = SiloCredentialStub(raw)
        let client = try SiloClient(context: context(raw), store: store, http: http, uptime: { clock.now() })
        do {
            try await client.send("/catalog")
            XCTFail("Expected rate limit")
        } catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 12)) }
        await http.succeed()
        try await client.send("/playback/session1/progress", method: .post)
        try await client.send("/playback/session1", method: .delete)
        let independent = try SiloClient(
            context: context(raw), store: SiloCredentialStub(raw), http: http, uptime: { clock.now() }
        )
        try await independent.send("/home/sections")
        do {
            try await client.send("/catalog")
            XCTFail("Successful playback/another client must not clear this cooldown")
        } catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 12)) }
        store.remove()
        do {
            try await client.send("/catalog")
            XCTFail("A removed login must remain unauthorized")
        } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 4)
    }
}
