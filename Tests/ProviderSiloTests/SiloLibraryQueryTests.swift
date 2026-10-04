import CoreModels
import Foundation
import XCTest
@testable import ProviderSilo

extension SiloProviderTests {
    func testLibraryRottenTomatoesSortRequiresLiveRatingCapability() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub([
            "/api/v2/capabilities/ratings": """
            {"allowed":true,"state":"available","revision":"1",
            "sources":[{"source":"rt_critic","name":"Rotten Tomatoes"}]}
            """,
            "/api/v2/catalog": """
            {"items":[{"content_id":"movie","type":"movie","title":"Movie",
            "release_date":"2024-06-15","rating_rt_critic":94}],"total":1,
            "total_exact":true,"window_cursor":"cursor"}
            """
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        XCTAssertFalse(provider.supportedSortFields(in: "library", kind: .movie).contains(.criticRating))
        try await provider.prepareLibraryQueryCapabilities()
        XCTAssertTrue(provider.supportedSortFields(in: "library", kind: .movie).contains(.criticRating))
        let page = try await provider.items(in: "library", kind: .movie,
                                            page: .init(sort: .init(field: .criticRating, direction: .descending)))
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.librarySortValues?.criticRating, 94)
        XCTAssertNotNil(item.releaseDate)
        let requests = await http.requests
        XCTAssertTrue(requests.last?.queryItems.contains(.init(name: "sort", value: "-rating_rt_critic")) == true)
    }

    func testDisabledSiloRatingsDoNotAdvertiseCriticSort() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(["/api/v2/capabilities/ratings": """
            {"allowed":false,"state":"disabled","revision":"1",
            "sources":[{"source":"rt_critic","name":"Rotten Tomatoes"}]}
            """])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        try await provider.prepareLibraryQueryCapabilities()
        XCTAssertFalse(provider.supportedSortFields(in: "library", kind: .movie).contains(.criticRating))
    }
}
