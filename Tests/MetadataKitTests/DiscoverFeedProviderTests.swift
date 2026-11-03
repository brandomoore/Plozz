import CoreModels
import Foundation
import XCTest
@testable import MetadataKit

final class DiscoverFeedProviderTests: XCTestCase {
    func testUnavailablePublicMetadataDoesNotAskForMediaServerSignIn() async {
        do {
            _ = try await TMDbDiscoveryProvider(access: .disabled).browse(.trending)
            XCTFail("Disabled metadata must report an explicit unavailable state")
        } catch {
            XCTAssertEqual(error as? DiscoverFeedError, .metadataUnavailable)
        }
    }

    func testBrowseUsesSeparateUpcomingPremiereFeedsAndPreservesFutureTitles() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            let tv = request.url!.path.hasSuffix("/tv")
            return .init(json: """
            {"page":1,"total_pages":3,"results":[
              {"id":7,"\(tv ? "name" : "title")":"Future","\(tv ? "first_air_date" : "release_date")":"2099-01-01"}
            ]}
            """)
        }
        let provider = TMDbDiscoveryProvider(access: .directToken("fixture"), http: fixture.http)
        let now = Date(timeIntervalSince1970: 1_779_494_400)
        let movies = try await provider.browse(.upcomingMovies, language: "fr_CA", now: now)
        let series = try await provider.browse(.upcomingSeries, language: "fr_CA", now: now)
        XCTAssertEqual(movies.items.count, 1)
        XCTAssertEqual(series.items.count, 1)
        XCTAssertEqual(movies.nextPage, 2)
        XCTAssertNotEqual(movies.items.first?.id, series.items.first?.id)
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.map { $0.url!.path }, ["/3/discover/movie", "/3/discover/tv"])
        XCTAssertEqual(TMDbTVDBDiscoveryFixture.query(requests[0])["primary_release_date.gte"], "2026-05-23")
        XCTAssertEqual(TMDbTVDBDiscoveryFixture.query(requests[1])["first_air_date.gte"], "2026-05-23")
        XCTAssertEqual(TMDbTVDBDiscoveryFixture.query(requests[0])["language"], "fr-CA")
        XCTAssertNil(TMDbTVDBDiscoveryFixture.query(requests[0])["primary_release_date.lte"])
    }

    func testTrendingRejectsPeopleAdultTitlesAndDuplicateIdentities() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: """
        {"page":1,"total_pages":1,"results":[
          {"id":1,"media_type":"movie","title":"Movie"},
          {"id":1,"media_type":"movie","title":"Duplicate"},
          {"id":1,"media_type":"tv","name":"Series"},
          {"id":2,"media_type":"person","name":"Person"},
          {"id":3,"media_type":"movie","title":"Adult","adult":true}
        ]}
        """) }
        let page = try await TMDbDiscoveryProvider(
            access: .directToken("fixture"), http: fixture.http
        ).browse(.trending)
        XCTAssertEqual(page.items.map(\.kind), [.movie, .series])
        XCTAssertNil(page.nextPage)
        XCTAssertTrue(page.items.allSatisfy { !$0.locallyValidatedPlayableSource })
    }
}
