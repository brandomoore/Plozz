import CoreModels
import XCTest
@testable import SeerService

@MainActor
final class SeerBrowseTests: XCTestCase {
    func testAllFiveRoutesPreservePaginationLanguageAndRequestStatus() async throws {
        let paths = ["trending", "movies", "movies/upcoming", "tv", "tv/upcoming"]
        let http = SeerRecordingHTTPClient()
        let service = SeerService(connectionStore: InMemorySeerConnectionStore(
            connection: SeerConnection(baseURL: URL(string: "https://requests.example/seerr")!, apiKey: "fixture")
        ), http: http)
        for (feed, path) in zip(DiscoverFeed.allCases, paths) {
            let tv = feed.kind == .series
            http.enqueueStub(pathSuffix: "/discover/\(path)", json: """
            {"page":2,"totalPages":3,"totalResults":60,"results":[
              {"id":42,"mediaType":"\(tv ? "tv" : "movie")","\(tv ? "name" : "title")":"Title",
               "mediaInfo":{"status":2}},
              {"id":43,"mediaType":"movie","title":"Excluded","adult":true}
            ]}
            """)
            let page = try await service.discover(feed, page: 2, language: "fr-CA")
            XCTAssertEqual(page.nextPage, 3)
            XCTAssertEqual(page.items.count, 1)
            XCTAssertEqual(page.items.first?.kind, tv ? .series : .movie)
            XCTAssertEqual(page.items.first?.availability?.rawValue, 2)
            XCTAssertEqual(page.items.first?.locallyValidatedPlayableSource, false)
        }
        XCTAssertEqual(http.sent.map(\.path), paths.map { "/api/v1/discover/\($0)" })
        for request in http.sent {
            XCTAssertEqual(request.queryItems.first { $0.name == "language" }?.value, "fr-CA")
            XCTAssertEqual(request.queryItems.first { $0.name == "page" }?.value, "2")
        }
    }
}
