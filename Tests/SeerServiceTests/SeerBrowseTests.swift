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
            let page = try await service.discover(feed, page: 2, language: "fr_CA")
            XCTAssertEqual(page.nextPage, 3)
            XCTAssertEqual(page.items.count, 1)
            XCTAssertEqual(page.items.first?.kind, tv ? .series : .movie)
            XCTAssertEqual(page.items.first?.availability?.rawValue, 2)
            XCTAssertEqual(page.items.first?.locallyValidatedPlayableSource, false)
        }
        XCTAssertEqual(http.sent.map(\.path), paths.map { "/api/v1/discover/\($0)" })
        for request in http.sent {
            let language = request.queryItems.first { $0.name == "language" }?.value
            if request.path == "/api/v1/discover/movies" || request.path == "/api/v1/discover/tv" {
                XCTAssertNil(language, "A display locale must not become an original-language filter")
            } else {
                XCTAssertEqual(language, "fr-CA")
            }
            XCTAssertEqual(request.queryItems.first { $0.name == "page" }?.value, "2")
        }
    }

    func testPopularRoutesDoNotFilterByRegionalOrBareDisplayLanguage() async throws {
        let http = SeerRecordingHTTPClient()
        let client = SeerClient(config: SeerConfig(
            baseURL: URL(string: "https://requests.example")!, apiKey: "fixture"
        ), http: http)
        http.stub(pathSuffix: "/discover/movies", json: """
        {"page":1,"totalPages":0,"totalResults":0,"results":[]}
        """)
        http.stub(pathSuffix: "/discover/tv", json: """
        {"page":1,"totalPages":0,"totalResults":0,"results":[]}
        """)
        for language in ["en_US", "en-US", "en", "ja", "pt_BR", "zh_Hant"] {
            _ = try await client.discoverMovies(language: language)
            _ = try await client.discoverTv(language: language)
        }
        XCTAssertEqual(http.sent.count, 12)
        XCTAssertTrue(http.sent.allSatisfy { $0.queryItems == [URLQueryItem(name: "page", value: "1")] })
    }
}
