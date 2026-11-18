import CoreModels
import Foundation
import XCTest
@testable import ProviderSilo

extension SiloProviderTests {
    private var nativeHome: String {
        """
        {"sections":[
          {"id":"curated-42","section_type":"custom_filter","title":"Our Picks","items":[
            {"content_id":"movie:2","type":"movie","title":"Second"},
            {"content_id":"ebook:1","type":"ebook","title":"Book"},
            {"content_id":"movie:1","type":"movie","title":"First"}]},
          {"id":"resume","section_type":"continue_watching","title":"Keep Going","items":[]},
          {"id":"next","section_type":"next_up","title":"Your Next Episodes","items":[]}]}
        """
    }

    func testNativeHomePreservesRowAndCardOrderTitlesAndProfile() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(["/api/v2/home/layout": nativeHome, "/api/v2/home/sections": nativeHome])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let layout = try await provider.serverHomeLayout()
        let rows = try XCTUnwrap(layout).sections
        XCTAssertEqual(layout?.source, .server)
        XCTAssertEqual(rows.map(\.id), ["curated-42", "resume", "next"])
        XCTAssertEqual(rows.map(\.title), ["Our Picks", "Keep Going", "Your Next Episodes"])
        XCTAssertEqual(rows.map(\.kind), [.recommendations, .continueWatching, .nextUp])
        let values = await provider.serverHomeItems(sections: rows, limit: 20, excludingLibraryIDs: [])
        XCTAssertEqual(try values["curated-42"]?.get().map(\.id), ["movie:2", "movie:1"])
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v2/home/layout", "/api/v2/home/sections"])
        XCTAssertTrue(requests.allSatisfy { $0.headers["X-Profile-Id"] == "profile1" })
        XCTAssertTrue(requests.allSatisfy { $0.headers["Authorization"] == "Bearer access-secret" })
    }

    func testOlderHomeUsesSectionsWithoutInventingRowsAndMissingAPIIsUnsupported() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(["/api/v2/home/sections": nativeHome])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let layout = try await provider.serverHomeLayout()
        XCTAssertEqual(layout?.sections.map(\.id), ["curated-42", "resume", "next"])
        let row = try XCTUnwrap(layout?.sections.first)
        let items = try await provider.serverHomeItems(section: row, limit: 1, excludingLibraryIDs: [])
        XCTAssertEqual(items.map(\.id), ["movie:2"])
        let unsupported = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: SiloHTTPStub([:]))
        let absent = try await unsupported.serverHomeLayout()
        XCTAssertNil(absent)
    }

    func testMalformedOrDuplicateLayoutDoesNotBecomeProviderFallback() async throws {
        for response in ["{}", #"{"sections":[{"id":"same","section_type":"next_up"},{"id":"same","section_type":"next_up"}]}"#] {
            let raw = try credential().encoded()
            let http = SiloHTTPStub(["/api/v2/home/layout": response, "/api/v2/home/sections": nativeHome])
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            do {
                _ = try await provider.serverHomeLayout()
                XCTFail("Invalid layouts must not silently fall back")
            } catch { XCTAssertTrue([AppError.decoding, .invalidResponse].contains(error as? AppError ?? .cancelled)) }
            let requests = await http.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testNativeHomeResolvesPlayableNextUpAndKeepsResumeAndSeriesLogo() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub([
            "/api/v2/home/sections/next/items": """
            {"id":"next","section_type":"next_up","items":[
              {"content_id":"series:1","type":"series","title":"Show","play_content_id":"episode:1",
               "position_seconds":123,"logo_url":"https://silo.test/logo.png"}]}
            """,
            "/api/v2/catalog/items/episode:1": """
            {"content_id":"episode:1","type":"episode","title":"Episode","series_id":"series:1"}
            """
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.serverHomeItems(
            section: .init(id: "next", kind: .nextUp), limit: 20, excludingLibraryIDs: []
        )
        XCTAssertEqual(items.first?.id, "episode:1")
        XCTAssertEqual(items.first?.resumePosition, 123)
        XCTAssertEqual(items.first?.logoURL?.path, "/logo.png")
    }

    func testRestrictedHomeRequiresExactMembershipNotTitleMatch() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub([
            "/api/v2/home/sections": nativeHome,
            "/api/v2/user/libraries": #"{"items":[{"id":"allowed","name":"Movies","type":"movie"},{"id":"hidden","name":"Hidden","type":"movie"}]}"#,
            "/api/v2/catalog": #"{"items":[{"content_id":"movie:1","type":"movie","title":"First"}],"total":1,"total_exact":true,"window_cursor":""}"#
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let values = await provider.serverHomeItems(
            sections: [.init(id: "curated-42", kind: .recommendations)], limit: 10, excludingLibraryIDs: ["hidden"]
        )
        let items = try XCTUnwrap(values["curated-42"]).get()
        XCTAssertEqual(items.map(\.id), ["movie:1"])
        XCTAssertEqual(items.first?.libraryID, "allowed")
        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.queryItems.contains(.init(name: "library_id", value: "hidden")) })
    }

    func testMissingRowIsFailureAndARefreshDoesNotReuseOldContents() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(["/api/v2/home/sections": nativeHome])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let rows = [ServerHomeSection(id: "gone", kind: .recommendations)]
        for _ in 0..<2 {
            let result = await provider.serverHomeItems(sections: rows, limit: 10, excludingLibraryIDs: [])
            guard case .failure(.notFound) = result["gone"] else { return XCTFail("Missing row is not an empty success") }
        }
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), [
            "/api/v2/home/sections", "/api/v2/home/sections/gone/items",
            "/api/v2/home/sections", "/api/v2/home/sections/gone/items"
        ])
    }

    func testSeasonalRowOmittedFromBulkHomeIsConfirmedEmptyByItsOwnEndpoint() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub([
            "/api/v2/home/layout": """
            {"sections":[{"id":"seasonal","section_type":"seasonal","title":"Seasonal picks"}]}
            """,
            "/api/v2/home/sections": #"{"sections":[]}"#,
            "/api/v2/home/sections/seasonal/items": """
            {"id":"seasonal","section_type":"seasonal","title":"Seasonal picks","items":[]}
            """
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let layout = try await provider.serverHomeLayout()
        let row = try XCTUnwrap(layout?.sections.first)
        XCTAssertEqual(row.title, "Seasonal picks")
        let result = await provider.serverHomeItems(sections: [row], limit: 20, excludingLibraryIDs: [])
        XCTAssertEqual(try XCTUnwrap(result[row.id]).get(), [])
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), [
            "/api/v2/home/layout", "/api/v2/home/sections", "/api/v2/home/sections/seasonal/items"
        ])
    }

    func testOmittedHomeRowUsesNormalLimitsAndExactLibraryMembership() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub([
            "/api/v2/home/sections": #"{"sections":[]}"#,
            "/api/v2/home/sections/seasonal/items": """
            {"id":"seasonal","section_type":"seasonal","items":[
              {"content_id":"excluded","type":"movie","title":"Same title"},
              {"content_id":"allowed","type":"movie","title":"Same title"},
              {"content_id":"unused","type":"movie","title":"Other"}]}
            """,
            "/api/v2/user/libraries": #"{"items":[{"id":"visible","name":"Movies","type":"movie"},{"id":"hidden","name":"Hidden","type":"movie"}]}"#,
            "/api/v2/catalog": #"{"items":[{"content_id":"allowed","type":"movie","title":"Same title"}],"total":1,"total_exact":true,"window_cursor":""}"#
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let row = ServerHomeSection(id: "seasonal", kind: .recommendations)
        let result = await provider.serverHomeItems(
            sections: [row, row], limit: 1, excludingLibraryIDs: ["hidden"]
        )
        let items = try XCTUnwrap(result[row.id]).get()
        XCTAssertEqual(items.map(\.id), ["allowed"])
        XCTAssertEqual(items.first?.libraryID, "visible")
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path == "/api/v2/home/sections/seasonal/items" }.count, 1)
        XCTAssertEqual(requests.filter { $0.path == "/api/v2/catalog" }.count, 2)
        XCTAssertFalse(requests.contains { $0.queryItems.contains(.init(name: "library_id", value: "hidden")) })
    }

    func testRestrictedHomeSharesMembershipWithinRefreshButNotAcrossRefreshes() async throws {
        let raw = try credential().encoded()
        let row = """
        {"section_type":"custom_filter","items":[
          {"content_id":"allowed","type":"movie","title":"Same title"},
          {"content_id":"excluded","type":"movie","title":"Same title"}]
        """
        let home = #"{"sections":[{"id":"a",\#(row.dropFirst())},{"id":"b",\#(row.dropFirst())}]}"#
        let http = SiloHTTPStub([
            "/api/v2/home/sections": home,
            "/api/v2/user/libraries": #"{"items":[{"id":"allowed-library","name":"Movies","type":"movie"},{"id":"hidden","name":"Hidden","type":"movie"}]}"#,
            "/api/v2/catalog": #"{"items":[{"content_id":"allowed","type":"movie","title":"Same title"}],"total":1,"total_exact":true,"window_cursor":""}"#
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let rows = ["a", "b"].map { ServerHomeSection(id: $0, kind: .recommendations) }
        for refresh in 1...2 {
            let result = await provider.serverHomeItems(sections: rows, limit: 20, excludingLibraryIDs: ["hidden"])
            for row in rows {
                XCTAssertEqual(try result[row.id]?.get().map(\.id), ["allowed"])
                XCTAssertEqual(try result[row.id]?.get().first?.libraryID, "allowed-library")
            }
            let requests = await http.requests
            XCTAssertEqual(requests.filter { $0.path == "/api/v2/user/libraries" }.count, refresh)
            XCTAssertEqual(requests.filter { $0.path == "/api/v2/catalog" }.count, 2 * refresh)
        }
    }

    func testRestrictedHomeStopsPagingImmediatelyAfterExactMembershipMatch() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub([
            "/api/v2/home/sections": nativeHome,
            "/api/v2/user/libraries": #"{"items":[{"id":"allowed","name":"Movies","type":"movie"}]}"#,
            "/api/v2/catalog": """
            {"items":[{"content_id":"movie:2","type":"movie","title":"Second"}],
             "total":1000,"total_exact":true,"window_cursor":"","page":{"has_more":true,"next_cursor":"unused"}}
            """
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let result = await provider.serverHomeItems(
            sections: [.init(id: "curated-42", kind: .recommendations)],
            limit: 1, excludingLibraryIDs: ["hidden"]
        )
        XCTAssertEqual(try result["curated-42"]?.get().map(\.id), ["movie:2"])
        let requests = await http.requests.filter { $0.path == "/api/v2/catalog" }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.queryItems.first { $0.name == "limit" }?.value, "200")
    }

    func testHomeSharesPlayableDetailsWithoutSharingRowResumeState() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub([
            "/api/v2/home/sections": """
            {"sections":[
              {"id":"a","section_type":"next_up","items":[
                {"content_id":"series:1","type":"series","title":"Show","play_content_id":"episode:1","position_seconds":12}]},
              {"id":"b","section_type":"next_up","items":[
                {"content_id":"series:1","type":"series","title":"Show","play_content_id":"episode:1","position_seconds":34}]}]}
            """,
            "/api/v2/catalog/items/episode:1": #"{"content_id":"episode:1","type":"episode","title":"Episode","series_id":"series:1"}"#
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let result = await provider.serverHomeItems(
            sections: ["a", "b"].map { .init(id: $0, kind: .nextUp) }, limit: 10, excludingLibraryIDs: []
        )
        XCTAssertEqual(try result["a"]?.get().first?.resumePosition, 12)
        XCTAssertEqual(try result["b"]?.get().first?.resumePosition, 34)
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path.hasPrefix("/api/v2/catalog/items/") }.count, 1)
        XCTAssertFalse(requests.contains { $0.path == "/api/v2/user/libraries" })
    }
}
