import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderSilo
@testable import TestSupportPerformance

extension SiloProviderTests {
    func testFreshCatalogAndSearchUseExplicitKnownIDsWithoutHydratingCompleteCards() async throws {
        let fields: [(json: String, complete: Bool)] = [
            (#","imdb_id":"tt123","tmdb_id":"9000","tvdb_id":"456""#, true),
            (#","tmdb_id":"9000""#, true),
            (#","imdb_id":"tt123""#, true),
            (#","tvdb_id":"456""#, true),
            (#","imdb_id":"tt123","tmdb_id":"9000","tvdb_id":null"#, true),
            ("", false),
            (#","imdb_id":"","tmdb_id":"","tvdb_id":"""#, false),
            (#","imdb_id":null,"tmdb_id":null,"tvdb_id":null"#, false),
            (#","imdb_id":" ","tmdb_id":"\t","tvdb_id":"\n""#, false),
        ]
        for kind in [MediaItemKind.movie, .series] {
            let raw = try credential().encoded()
            let ids = fields.indices.map { "\(kind.rawValue)-tmdb-\(1_000 + $0)" }
            let cards = fields.enumerated().map { index, fields in
                """
                {"content_id":"\(ids[index])","type":"\(kind.rawValue)",
                 "title":"Title \(index)"\(fields.json)}
                """
            }.joined(separator: ",")
            var responses = [
                "/api/v2/user/libraries":
                    #"{"items":[{"id":"library","name":"Library","type":"\#(kind.rawValue)"}]}"#,
                "/api/v2/catalog":
                    #"{"items":[\#(cards)],"total":\#(fields.count),"total_exact":true,"window_cursor":"fixture"}"#
            ]
            for index in fields.indices where !fields[index].complete {
                responses["/api/v2/catalog/items/\(ids[index])"] = """
                {"content_id":"\(ids[index])","type":"\(kind.rawValue)",
                 "title":"Title \(index)","imdb_id":"tt\(index)","tmdb_id":"\(1_000 + index)"}
                """
            }
            let http = SiloHTTPStub(responses)
            let provider = try SiloProvider(
                context: context(raw), credentials: SiloCredentialStub(raw), http: http
            )
            let page = try await provider.items(in: "library", kind: kind, page: .init(limit: 200))
            let search = try await provider.search(query: "Title", limit: 200)
            for items in [page.items, search] {
                XCTAssertEqual(items.map(\.catalogIdentityIsComplete), fields.map(\.complete))
                XCTAssertEqual(items.first?.providerID(.tmdb), "9000", "Explicit IDs win over anchors")
                XCTAssertTrue(items.allSatisfy { $0.sourceAccountID == provider.accountID })
                let prepared = await IdentityEnrichment.prepare(
                    items, enrichIdentifiedItems: provider.catalogIdentityRequiresEnrichment
                ) { try await provider.item(id: $0.id) }
                XCTAssertFalse(prepared.inconclusive)
                XCTAssertEqual(Set(prepared.indexable.map(\.id)), Set(ids))
            }
            XCTAssertTrue(page.items.allSatisfy { $0.libraryID == "library" })
            let requests = await http.requests
            let details = requests.filter { $0.path.hasPrefix("/api/v2/catalog/items/") }
            let expected = fields.indices.filter { !fields[$0].complete }
                .map { "/api/v2/catalog/items/\(ids[$0])" }
            XCTAssertEqual(details.count, expected.count * 2)
            XCTAssertEqual(Set(details.map(\.path)), Set(expected))
        }
    }

    func testModernIdentityIndexingLeavesHomeQuotaWhileLegacyRefusalStillStops() async throws {
        for modern in [true, false] {
            let raw = try credential().encoded()
            let http = SiloIdentityHTTP(
                cards: modern ? .modern : .legacy, latency: .zero, refuseDetails: true
            )
            let provider = try SiloProvider(
                context: context(raw), credentials: SiloCredentialStub(raw), http: http
            )
            let page = try await provider.items(in: "library", kind: .series, page: .init(limit: 200))
            let prepared = await IdentityEnrichment.prepare(
                page.items, concurrency: 1,
                enrichIdentifiedItems: provider.catalogIdentityRequiresEnrichment
            ) { try await provider.item(id: $0.id) }
            XCTAssertEqual(prepared.inconclusive, !modern)
            XCTAssertEqual(prepared.indexable.count, modern ? 200 : 0)
            XCTAssertEqual(prepared.interruption, modern ? nil : .rateLimited(retryAfter: 60))
            let rows = await provider.serverHomeItems(
                sections: [.init(id: "picks", kind: .recommendations)],
                limit: 20, excludingLibraryIDs: []
            )
            let result = try XCTUnwrap(rows["picks"])
            if modern {
                let items = try result.get()
                XCTAssertEqual(items.map(\.id), (0..<20).map(SiloIdentityHTTP.itemID))
                XCTAssertTrue(items.allSatisfy { !$0.catalogIdentityIsComplete },
                              "Home cards must not inherit catalog completeness")
            } else {
                guard case .failure(.rateLimited) = result else {
                    return XCTFail("Home must retain the legacy detail refusal's cooldown")
                }
            }
            let counts = await http.counts
            XCTAssertEqual(counts.catalog, 1)
            XCTAssertEqual(counts.details, modern ? 0 : 1)
            XCTAssertEqual(counts.home, modern ? 1 : 0)
        }
    }

    @MainActor
    func testPerformanceModernCatalogIdentity() async throws {
        try await measureCatalogIdentity(.modern)
    }

    @MainActor
    func testPerformanceLegacyCatalogIdentity() async throws {
        try await measureCatalogIdentity(.legacy)
    }

    @MainActor
    func testPerformanceMixedCatalogIdentity() async throws {
        try await measureCatalogIdentity(.mixed)
    }

    @MainActor
    private func measureCatalogIdentity(_ cards: SiloIdentityHTTP.Cards) async throws {
        try PerformanceProbe.requireEnabled()
        try await PerformanceProbe.measure(self, scenario: "silo-identity-\(cards.rawValue)") {
            let raw = try self.credential().encoded()
            let http = SiloIdentityHTTP(cards: cards, latency: .milliseconds(75))
            let provider = try SiloProvider(
                context: self.context(raw), credentials: SiloCredentialStub(raw), http: http
            )
            let page = try await provider.items(in: "library", kind: .series, page: .init(limit: 200))
            async let home = provider.serverHomeItems(
                sections: [.init(id: "picks", kind: .recommendations)],
                limit: 20, excludingLibraryIDs: []
            )
            let prepared = await IdentityEnrichment.prepare(
                page.items, enrichIdentifiedItems: provider.catalogIdentityRequiresEnrichment
            ) { try await provider.item(id: $0.id) }
            XCTAssertFalse(prepared.inconclusive)
            XCTAssertNil(prepared.interruption)
            XCTAssertEqual(prepared.indexable.count, 200)
            let index = IdentityIndex()
            await index.ingest(prepared.indexable, accountID: provider.accountID)
            let snapshot = await index.snapshot()
            var matched = 0
            for number in 0..<200 {
                let expected = SiloIdentityHTTP.itemID(number)
                for ids in [
                    ["Imdb": "tt\(10_000 + number)"],
                    ["Tmdb": "\(1_000 + number)"],
                    ["Tvdb": "\(20_000 + number)"],
                ] {
                    let discovery = MediaItem(
                        id: "discovery", title: "Title \(number)",
                        kind: .series, providerIDs: ids
                    )
                    XCTAssertEqual(snapshot.sourceRefs(for: discovery).map(\.itemID), [expected])
                }
                matched += 1
            }
            let rows = await home
            let homeItems = try XCTUnwrap(rows["picks"]).get()
            XCTAssertEqual(homeItems.map(\.id), (0..<20).map(SiloIdentityHTTP.itemID))
            let counts = await http.counts
            XCTAssertEqual(counts.catalog, 1)
            XCTAssertEqual(counts.home, 1)
            XCTAssertLessThanOrEqual(counts.maxInFlight, 6)
            return [
                "items": prepared.indexable.count, "matchedItems": matched, "homeItems": homeItems.count,
                "catalogRequests": counts.catalog, "detailRequests": counts.details,
                "homeRequests": counts.home, "maxInFlight": counts.maxInFlight,
            ]
        }
    }
}

private actor SiloIdentityHTTP: HTTPClient {
    enum Cards: String, Sendable { case modern, legacy, mixed }
    private let cards: Cards
    private let latency: Duration
    private let refuseDetails: Bool
    private var inFlight = 0
    private(set) var counts = (catalog: 0, details: 0, home: 0, maxInFlight: 0)

    init(cards: Cards, latency: Duration, refuseDetails: Bool = false) {
        self.cards = cards
        self.latency = latency
        self.refuseDetails = refuseDetails
    }

    static func itemID(_ number: Int) -> String {
        "series-tmdb-\(1_000 + number)"
    }

    private func card(_ number: Int, identity: Bool) -> String {
        let fields = identity
            ? #","imdb_id":"tt\#(10_000 + number)","tmdb_id":"\#(1_000 + number)","tvdb_id":"\#(20_000 + number)""#
            : ""
        return """
        {"content_id":"\(Self.itemID(number))","type":"series",
         "title":"Title \(number)"\(fields)}
        """
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        inFlight += 1
        counts.maxInFlight = max(counts.maxInFlight, inFlight)
        defer { inFlight -= 1 }
        let body: String
        switch endpoint.path {
        case "/api/v2/catalog":
            counts.catalog += 1
            let items = (0..<200).map {
                card($0, identity: cards == .modern || (cards == .mixed && !$0.isMultiple(of: 5)))
            }.joined(separator: ",")
            body = #"{"items":[\#(items)],"total":200,"total_exact":true,"window_cursor":"fixture"}"#
        case "/api/v2/home/sections":
            counts.home += 1
            let items = (0..<20).map { card($0, identity: false) }.joined(separator: ",")
            body = #"{"sections":[{"id":"picks","section_type":"custom_filter","items":[\#(items)]}]}"#
        default:
            guard let number = (0..<200).first(where: {
                endpoint.path == "/api/v2/catalog/items/\(Self.itemID($0))"
            }) else { throw AppError.notFound }
            counts.details += 1
            if refuseDetails {
                return (
                    Data("{}".utf8),
                    HTTPURLResponse(url: baseURL, statusCode: 429, httpVersion: nil,
                                    headerFields: ["Retry-After": "60"])!
                )
            }
            body = card(number, identity: true)
        }
        try await Task.sleep(for: latency)
        return (
            Data(body.utf8),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
