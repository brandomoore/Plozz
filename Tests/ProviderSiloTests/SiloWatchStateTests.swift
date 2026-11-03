import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderSilo

private actor SiloWatchedHTTP: HTTPClient {
    private(set) var requests: [Endpoint] = []
    let status: Int
    let retryAfter: String?

    init(status: Int = 204, retryAfter: String? = nil) {
        self.status = status
        self.retryAfter = retryAfter
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        let accepted = endpoint.path.hasPrefix("/api/v2/watched/")
            && (endpoint.method == .post || endpoint.method == .delete)
        return (
            Data(),
            try XCTUnwrap(HTTPURLResponse(
                url: baseURL, statusCode: accepted ? status : 405, httpVersion: nil,
                headerFields: retryAfter.map { ["Retry-After": $0] }
            ))
        )
    }
}

private struct SiloWatchedApplier: WatchMutationApplying {
    let provider: SiloProvider
    func setPlayed(_ played: Bool, on target: WatchMutationTarget) async throws {
        try await provider.setPlayed(played, itemID: target.itemID)
    }
    func setResumePosition(_ seconds: TimeInterval, on target: WatchMutationTarget, capturedAt: Date) async throws {
        try await provider.setResumePosition(seconds, itemID: target.itemID, capturedAt: capturedAt)
    }
    func scrobbleTrakt(_ intent: TraktScrobbleIntent) async throws {}
}

extension SiloProviderTests {
    func testResumeWritePreservesWholeMillisecondsAfterSecondsRoundTrip() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub([
            "/api/v2/sync/progress":
                #"{"items":[{"media_item_id":"movie:1","status":"success","index":0}]}"#
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let positions: [Int64] = [0, 1, 1001, 42125, 1044003, 242374, 337004, 491869]
        for milliseconds in positions {
            try await provider.setResumePosition(
                Double(milliseconds) / 1000, itemID: "movie:1", capturedAt: Date()
            )
        }
        let requests = await http.requests
        XCTAssertEqual(requests.count, positions.count)
        for (request, expected) in zip(requests, positions) {
            let body = try XCTUnwrap(request.body)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let item = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
            XCTAssertEqual(item["position_ms"] as? Int64, expected)
        }
    }

    func testInvalidResumePositionsNeverReachTheServer() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub([:])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        for seconds in [-1, Double.nan, .infinity, -.infinity, Double(Int64.max), Double(Int64.max) / 1000] {
            do {
                try await provider.setResumePosition(seconds, itemID: "movie:1", capturedAt: Date())
                XCTFail("Invalid or unrepresentable milliseconds must not be sent")
            } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
        }
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testWatchedUsesNativePostAndUnwatchedUsesDeleteWithProfileHeaders() async throws {
        let login = try credential(profileToken: "profile-proof")
        let raw = try login.encoded()
        let http = SiloWatchedHTTP()
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        for itemID in ["movie-imdb-tt123", "episode-tvdb-123-1-2", "season-tvdb-123-1", "series-tvdb-123"] {
            try await provider.setPlayed(true, itemID: itemID)
            try await provider.setPlayed(false, itemID: itemID)
        }
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.method), [.post, .delete, .post, .delete, .post, .delete, .post, .delete])
        XCTAssertEqual(requests.first?.path, "/api/v2/watched/movie-imdb-tt123")
        XCTAssertTrue(requests.allSatisfy { $0.headers["X-Profile-Id"] == "profile1" })
        XCTAssertTrue(requests.allSatisfy { $0.headers["X-Profile-Token"] == "profile-proof" })
        XCTAssertTrue(requests.allSatisfy { $0.headers["Authorization"] == "Bearer access-secret" })
        XCTAssertTrue(requests.allSatisfy { $0.body == nil })
    }

    func testQueuedWatchedItemsDrainOnceAgainstNativeMethodContract() async throws {
        let raw = try credential().encoded()
        let http = SiloWatchedHTTP()
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(), applier: SiloWatchedApplier(provider: provider)
        )
        for id in ["movie", "episode1", "episode2"] {
            await reconciler.enqueue(.init(
                capturedAt: Date(), canonicalMediaID: id, played: true,
                targets: [.init(accountID: "account1", itemID: id, providerKind: .silo)]
            ))
        }
        for _ in 0..<100 { await reconciler.drain() }
        let pending = await reconciler.pendingCount
        let requests = await http.requests
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.method == .post })
    }

    func testRejectedWatchedWritesStayQueuedWithoutImmediateNetworkRetries() async throws {
        for status in [401, 405, 429, 503] {
            let raw = try credential().encoded()
            let http = SiloWatchedHTTP(status: status)
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            let now = Date()
            let reconciler = WatchStateReconciler(
                store: InMemoryWatchMutationStore(), applier: SiloWatchedApplier(provider: provider), now: { now }
            )
            await reconciler.enqueue(.init(
                capturedAt: now, canonicalMediaID: "movie", played: true,
                targets: [.init(accountID: "account1", itemID: "movie", providerKind: .silo)]
            ))
            for _ in 0..<100 { await reconciler.drain() }
            let pending = await reconciler.pendingCount
            let requests = await http.requests
            XCTAssertEqual(pending, 1, "HTTP \(status) must not masquerade as an applied watch")
            XCTAssertEqual(requests.count, 1, "HTTP \(status) must not cause a tight write loop")
        }
    }

    func testWatchedRateLimitParsesSecondsAndHTTPDateWithoutReplayingTheRequest() async throws {
        let future = Date().addingTimeInterval(3600)
        for header in ["120", HTTPDate.string(from: future), "nan"] {
            let raw = try credential().encoded()
            let http = SiloWatchedHTTP(status: 429, retryAfter: header)
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            do {
                try await provider.setPlayed(true, itemID: "movie")
                XCTFail("Rate limiting must remain an error")
            } catch {
                guard case .rateLimited(let delay) = error as? AppError else {
                    return XCTFail("Expected rate limit, got \(error)")
                }
                if header == "120" { XCTAssertEqual(delay, 120) }
                else if header == "nan" { XCTAssertNil(delay) }
                else { XCTAssertEqual(try XCTUnwrap(delay), 3600, accuracy: 5) }
            }
            let requests = await http.requests
            XCTAssertEqual(requests.count, 1)
        }
    }
}
