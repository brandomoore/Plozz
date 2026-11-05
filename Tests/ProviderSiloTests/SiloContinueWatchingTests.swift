import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderSilo

private actor SiloContinueWatchingHTTP: HTTPClient {
    struct Reply: Sendable {
        var status = 200
        var body: String
    }

    let pages: [String: String]
    let replies: [String: Reply]
    let cancelsCatalog: Bool
    let failsTransport: Bool
    private(set) var requests: [Endpoint] = []
    private var activeCatalogRequests = 0
    private(set) var peakCatalogRequests = 0

    init(
        pages: [String: String] = [:], replies: [String: Reply] = [:],
        cancelsCatalog: Bool = false, failsTransport: Bool = false
    ) {
        self.pages = pages
        self.replies = replies
        self.cancelsCatalog = cancelsCatalog
        self.failsTransport = failsTransport
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        let reply: Reply
        if endpoint.path == "/api/v2/progress" {
            let library = endpoint.queryItems.first { $0.name == "library_id" }?.value ?? ""
            let cursor = endpoint.queryItems.first { $0.name == "cursor" }?.value ?? ""
            reply = pages[library + "|" + cursor].map { Reply(body: $0) }
                ?? replies[endpoint.path] ?? Reply(status: 404, body: "{}")
        } else {
            if endpoint.path.hasPrefix("/api/v2/catalog/items/") {
                if cancelsCatalog { throw CancellationError() }
                if failsTransport { throw URLError(.notConnectedToInternet) }
                activeCatalogRequests += 1
                peakCatalogRequests = max(peakCatalogRequests, activeCatalogRequests)
                do {
                    try await Task.sleep(for: .milliseconds(5))
                } catch {
                    activeCatalogRequests -= 1
                    throw error
                }
                activeCatalogRequests -= 1
            }
            reply = replies[endpoint.path] ?? Reply(status: 404, body: "{}")
        }
        return (
            Data(reply.body.utf8),
            HTTPURLResponse(url: baseURL, statusCode: reply.status, httpVersion: nil,
                            headerFields: ["Retry-After": "12"])!
        )
    }
}

extension SiloProviderTests {
    private func progressPage(_ ids: [String], next: String? = nil, date: String = "2026-11-02T12:00:00Z") -> String {
        let entries = ids.map {
            """
            {"media_item_id":"\($0)","position_seconds":120,"duration_seconds":1800,
             "completed":false,"updated_at":"\(date)"}
            """
        }.joined(separator: ",")
        let page = next.map { #","page":{"has_more":true,"next_cursor":"\#($0)"}"# }
            ?? #","page":{"has_more":false}"#
        return #"{"items":[\#(entries)]\#(page)}"#
    }

    private func catalogMovie(_ id: String) -> SiloContinueWatchingHTTP.Reply {
        .init(body: #"{"content_id":"\#(id)","type":"movie","title":"Fixture"}"#)
    }

    private var emptyHome: SiloContinueWatchingHTTP.Reply {
        .init(body: #"{"sections":[]}"#)
    }

    private var staleNextUpRow: String {
        """
        {"id":"next","section_type":"next_up","items":[
          {"content_id":"series:1","type":"series","title":"Removed","play_content_id":"gone"},
          {"content_id":"series:2","type":"series","title":"Available","play_content_id":"live",
           "position_seconds":120,"duration_seconds":1800,"logo_url":"https://silo.test/logo.png"}]}
        """
    }

    private var liveEpisode: SiloContinueWatchingHTTP.Reply {
        .init(body: #"{"content_id":"live","type":"episode","title":"Episode","series_id":"series:2"}"#)
    }

    func testContinueWatchingSkipsMissingProgressAndDoesNotRefetchItFromNextUp() async throws {
        let raw = try credential().encoded()
        let http = SiloContinueWatchingHTTP(
            pages: ["|": progressPage(["gone", "live", "live"])],
            replies: [
                "/api/v2/catalog/items/live": liveEpisode,
                "/api/v2/home/sections": .init(body: #"{"sections":[\#(staleNextUpRow)]}"#)
            ]
        )
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(items.map(\.id), ["live"])
        XCTAssertEqual(items.first?.resumePosition, 120)
        XCTAssertEqual(items.first?.logoURL?.path, "/logo.png")
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path == "/api/v2/catalog/items/gone" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/api/v2/catalog/items/live" }.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.headers["X-Profile-Id"] == "profile1" })
    }

    func testContinueWatchingBackfillsMissingItemsWithStableCursorPageSize() async throws {
        let raw = try credential().encoded()
        let http = SiloContinueWatchingHTTP(
            pages: ["|": progressPage(["gone"], next: "next"), "|next": progressPage(["live"])],
            replies: ["/api/v2/catalog/items/live": catalogMovie("live"), "/api/v2/home/sections": emptyHome]
        )
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 1)
        XCTAssertEqual(items.map(\.id), ["live"])
        let requests = await http.requests.filter { $0.path == "/api/v2/progress" }
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.queryItems.contains(.init(name: "limit", value: "1")) })
    }

    func testContinueWatchingStopsHydratingOnceTheRowIsFull() async throws {
        let raw = try credential().encoded()
        let ids = (0..<200).map { "movie:\($0)" }
        var replies = Dictionary(uniqueKeysWithValues: ids.map { ("/api/v2/catalog/items/" + $0, catalogMovie($0)) })
        replies["/api/v2/home/sections"] = emptyHome
        let http = SiloContinueWatchingHTTP(pages: ["|": progressPage(ids, next: "unused")], replies: replies)
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 2)
        XCTAssertEqual(Set(items.map(\.id)), ["movie:0", "movie:1"])
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path.hasPrefix("/api/v2/catalog/items/") }.count, 2)
        XCTAssertEqual(requests.filter { $0.path == "/api/v2/progress" }.count, 1)
        let peak = await http.peakCatalogRequests
        XCTAssertLessThanOrEqual(peak, 2)
    }

    func testContinueWatchingKeepsFourRequestBoundAndConsidersEveryEnabledLibrary() async throws {
        let raw = try credential().encoded()
        let ids = (0..<12).map { "movie:\($0)" }
        var replies = Dictionary(uniqueKeysWithValues: ids.map { ("/api/v2/catalog/items/" + $0, catalogMovie($0)) })
        replies["/api/v2/catalog/items/newest"] = catalogMovie("newest")
        replies["/api/v2/home/sections"] = emptyHome
        let http = SiloContinueWatchingHTTP(pages: [
            "first|": progressPage(ids),
            "second|": progressPage(["newest"], date: "2026-11-02T13:00:00Z")
        ], replies: replies)
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 10, inLibraries: ["first", "second"])
        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(items.first?.id, "newest")
        XCTAssertEqual(items.first?.libraryID, "second")
        let peak = await http.peakCatalogRequests
        XCTAssertLessThanOrEqual(peak, 4)
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path.hasPrefix("/api/v2/catalog/items/") }.count, 11)
    }

    func testAllMissingProgressIsAnEmptyRowButMissingEndpointsStillFail() async throws {
        let raw = try credential().encoded()
        let http = SiloContinueWatchingHTTP(pages: ["|": progressPage(["gone"])],
                                           replies: ["/api/v2/home/sections": emptyHome])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 10)
        XCTAssertTrue(items.isEmpty)
        for pages in [[String: String](), ["|": progressPage([])]] {
            let missing = SiloContinueWatchingHTTP(pages: pages)
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: missing)
            do {
                _ = try await provider.continueWatching(limit: 10)
                XCTFail("Missing progress/Home endpoints must remain failures.")
            } catch { XCTAssertEqual(error as? AppError, .notFound) }
        }
    }

    func testContinueWatchingSkipsStaleNextUpWhenProgressIsEmpty() async throws {
        let raw = try credential().encoded()
        let http = SiloContinueWatchingHTTP(pages: ["|": progressPage([])], replies: [
            "/api/v2/home/sections": .init(body: #"{"sections":[\#(staleNextUpRow)]}"#),
            "/api/v2/catalog/items/live": liveEpisode
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(items.map(\.id), ["live"])
        XCTAssertEqual(items.first?.resumePosition, 120)
        XCTAssertEqual(items.first?.logoURL?.path, "/logo.png")
    }

    func testContinueWatchingDoesNotReintroduceMissingItemFromHomeSummary() async throws {
        let raw = try credential().encoded()
        let http = SiloContinueWatchingHTTP(pages: ["|": progressPage(["gone"])], replies: [
            "/api/v2/home/sections": .init(body: """
            {"sections":[{"id":"continue","section_type":"continue_watching","items":[
              {"content_id":"gone","type":"movie","title":"Removed"}]}]}
            """)
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 10)
        XCTAssertTrue(items.isEmpty)
    }

    func testContinueWatchingDeduplicatesAcrossLibrariesAndRejectsRepeatingCursors() async throws {
        let raw = try credential().encoded()
        let http = SiloContinueWatchingHTTP(pages: [
            "first|": progressPage(["shared", "shared"]),
            "second|": progressPage(["shared", "gone", "new"])
        ], replies: [
            "/api/v2/catalog/items/shared": catalogMovie("shared"),
            "/api/v2/catalog/items/new": catalogMovie("new"),
            "/api/v2/home/sections": emptyHome
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 2, inLibraries: ["first", "second"])
        XCTAssertEqual(Set(items.map(\.id)), ["shared", "new"])
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path.hasPrefix("/api/v2/catalog/items/") }.count, 3)
        let repeating = SiloContinueWatchingHTTP(pages: [
            "|": progressPage(["gone"], next: "same"), "|same": progressPage(["gone"], next: "same")
        ])
        let invalid = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: repeating)
        do {
            _ = try await invalid.continueWatching(limit: 2)
            XCTFail("Stale items must not cause an endless cursor walk.")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    }

    func testContinueWatchingDoesNotHideRateLimitAuthorizationOrMalformedCatalogFailures() async throws {
        for (status, body, expected) in [
            (403, "{}", AppError.unauthorized), (429, "{}", .rateLimited(retryAfter: 12)),
            (500, "{}", .invalidResponse), (200, "{}", .decoding)
        ] {
            let raw = try credential().encoded()
            let http = SiloContinueWatchingHTTP(pages: ["|": progressPage(["live"])], replies: [
                "/api/v2/catalog/items/live": .init(status: status, body: body),
                "/api/v2/home/sections": emptyHome
            ])
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            do {
                _ = try await provider.continueWatching(limit: 1)
                XCTFail("Only missing catalog entries are skippable.")
            } catch { XCTAssertEqual(error as? AppError, expected) }
            let requests = await http.requests
            XCTAssertEqual(requests.filter { $0.path == "/api/v2/catalog/items/live" }.count, 1)
        }
        let raw = try credential().encoded()
        let http = SiloContinueWatchingHTTP(pages: ["|": progressPage(["live"])], cancelsCatalog: true)
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        do {
            _ = try await provider.continueWatching(limit: 1)
            XCTFail("Cancellation must propagate.")
        } catch { XCTAssertTrue(error is CancellationError) }
        let offline = SiloContinueWatchingHTTP(pages: ["|": progressPage(["live"])], failsTransport: true)
        let disconnected = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: offline)
        do {
            _ = try await disconnected.continueWatching(limit: 1)
            XCTFail("Transport failures must propagate.")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testNativeHomeSkipsMissingPlayableCardsInSingleAndBatchRefreshes() async throws {
        let raw = try credential().encoded()
        let http = SiloContinueWatchingHTTP(replies: [
            "/api/v2/home/sections/next/items": .init(body: staleNextUpRow),
            "/api/v2/home/sections": .init(body: #"{"sections":[\#(staleNextUpRow)]}"#),
            "/api/v2/catalog/items/live": liveEpisode
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let row = ServerHomeSection(id: "next", kind: .nextUp)
        let single = try await provider.serverHomeItems(section: row, limit: 1, excludingLibraryIDs: [])
        let batch = await provider.serverHomeItems(sections: [row], limit: 1, excludingLibraryIDs: [])
        for items in [single, try XCTUnwrap(batch["next"]).get()] {
            XCTAssertEqual(items.map(\.id), ["live"])
            XCTAssertEqual(items.first?.resumePosition, 120)
            XCTAssertEqual(items.first?.logoURL?.path, "/logo.png")
        }
    }

    func testNativeHomeDoesNotTreatRateLimitingAsAnEmptyRow() async throws {
        let raw = try credential().encoded()
        let http = SiloContinueWatchingHTTP(replies: [
            "/api/v2/home/sections/next/items": .init(body: staleNextUpRow),
            "/api/v2/home/sections": .init(body: #"{"sections":[\#(staleNextUpRow)]}"#),
            "/api/v2/catalog/items/gone": .init(status: 429, body: "{}")
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let row = ServerHomeSection(id: "next", kind: .nextUp)
        do {
            _ = try await provider.serverHomeItems(section: row, limit: 1, excludingLibraryIDs: [])
            XCTFail("Rate limits must remain actionable.")
        } catch { XCTAssertEqual(error as? AppError, .rateLimited(retryAfter: 12)) }
        let result = await provider.serverHomeItems(sections: [row], limit: 1, excludingLibraryIDs: [])
        guard case .failure(.rateLimited(let remaining)) = result["next"] else {
            return XCTFail("Batch refresh must retain the rate-limit error.")
        }
        XCTAssertGreaterThan(remaining ?? 0, 0)
        XCTAssertLessThanOrEqual(remaining ?? 0, 12)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2, "The batch must fail promptly without transmitting during cooldown.")
    }

    func testHomeBatchStopsAfterRateLimitAndPreservesEarlierSuccessfulRows() async throws {
        let raw = try credential().encoded()
        let http = SiloContinueWatchingHTTP(replies: [
            "/api/v2/home/sections": .init(body: """
            {"sections":[
              {"id":"ready","section_type":"recently_added","items":[
                {"content_id":"movie:1","type":"movie","title":"Ready"}]},
              \(staleNextUpRow),
              {"id":"later","section_type":"next_up","items":[
                {"content_id":"series:3","type":"series","title":"Later","play_content_id":"unused"}]}]}
            """),
            "/api/v2/catalog/items/gone": .init(status: 429, body: "{}")
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let result = await provider.serverHomeItems(sections: [
            .init(id: "ready", kind: .recentlyAdded), .init(id: "next", kind: .nextUp),
            .init(id: "later", kind: .nextUp)
        ], limit: 20, excludingLibraryIDs: [])
        XCTAssertEqual(try result["ready"]?.get().map(\.id), ["movie:1"])
        for id in ["next", "later"] {
            guard case .failure(.rateLimited(retryAfter: 12)) = result[id] else {
                return XCTFail("Unfinished rows must retain the actual refusal.")
            }
        }
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testOmittedHomeRowPreservesActualEndpointFailures() async throws {
        for (status, body, expected) in [
            (404, "{}", AppError.notFound),
            (403, "{}", .unauthorized),
            (429, "{}", .rateLimited(retryAfter: 12)),
            (500, "{}", .invalidResponse),
            (200, "{}", .decoding),
            (200, #"{"id":"wrong","section_type":"seasonal","items":[]}"#, .invalidResponse),
            (200, #"{"id":"seasonal","section_type":"seasonal"}"#, .invalidResponse)
        ] {
            let raw = try credential().encoded()
            let http = SiloContinueWatchingHTTP(replies: [
                "/api/v2/home/sections": .init(body: """
                {"sections":[{"id":"ready","section_type":"recently_added","items":[
                  {"content_id":"movie:1","type":"movie","title":"Ready"}]}]}
                """),
                "/api/v2/home/sections/seasonal/items": .init(status: status, body: body),
                "/api/v2/home/sections/later/items": .init(body: """
                {"id":"later","section_type":"custom_filter","items":[]}
                """)
            ])
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            let result = await provider.serverHomeItems(
                sections: ["ready", "seasonal", "later"].map { .init(id: $0, kind: .recommendations) },
                limit: 20, excludingLibraryIDs: []
            )
            XCTAssertEqual(try result["ready"]?.get().map(\.id), ["movie:1"])
            guard case .failure(let failure) = result["seasonal"] else {
                return XCTFail("An omitted row must not hide an actual endpoint failure.")
            }
            XCTAssertEqual(failure, expected)
            let requests = await http.requests
            if status == 403 || status == 429 {
                XCTAssertEqual(result["later"], .failure(expected))
                XCTAssertEqual(requests.count, 2, "A provider refusal must stop further row requests.")
            } else {
                XCTAssertEqual(try result["later"]?.get(), [])
                XCTAssertEqual(requests.count, 3)
            }
        }
    }
}
