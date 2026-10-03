import CoreModels
import Foundation
import XCTest
@testable import ProviderPlex

final class PlexContinueWatchingArtworkTests: XCTestCase {
    private var session: UserSession {
        UserSession(
            server: MediaServer(id: "server", name: "Fixture", baseURL: URL(string: "https://plex.example.test")!, provider: .plex),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
    }

    func testExistingParentBatchSuppliesMissingLogoAndShowIDsWithoutChangingEpisodePlayback() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/hubs/continueWatching/items", json: """
        {"MediaContainer":{"size":2,"Metadata":[
          {"ratingKey":"e1","type":"episode","title":"One","grandparentRatingKey":"900",
           "grandparentTitle":"The Series","index":4,"parentIndex":3,
           "duration":1800000,"viewOffset":300000,"viewCount":0,"lastViewedAt":1700000000,
           "Guid":[{"id":"tmdb://episode-1"},{"id":"imdb://ttEpisode"}]},
          {"ratingKey":"e2","type":"episode","title":"Two","grandparentRatingKey":"900",
           "grandparentTitle":"The Series","index":5,"parentIndex":3,
           "Guid":[{"id":"tmdb://episode-2"}]}
        ]}}
        """)
        http.stub(pathSuffix: "/library/metadata/900", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"900","type":"show","title":"The Series","year":2002,
           "Guid":[{"id":"tmdb://show-9"},{"id":"imdb://ttSeries"},{"id":"tvdb://show-tvdb"}],
           "Image":[{"type":"clearLogo","url":"/library/metadata/900/clearLogo/123"}]}
        ]}}
        """)
        let provider = PlexProvider(session: session, http: http)
        let items = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(items.map(\.id), ["e1", "e2"])
        XCTAssertEqual(http.sentPaths.filter { $0.hasPrefix("/library/metadata/") }, ["/library/metadata/900"],
                       "Use the existing parent lookup; no per-card or extra artwork requests.")
        for item in items {
            XCTAssertEqual(item.kind, .episode)
            XCTAssertEqual(item.seriesID, "900")
            XCTAssertEqual(item.providerID(.seriesTmdb), "show-9")
            XCTAssertEqual(item.providerID(.seriesImdb), "ttSeries")
            XCTAssertEqual(item.providerID(.seriesTvdb), "show-tvdb")
            XCTAssertEqual(item.logoURL?.path, "/library/metadata/900/clearLogo/123")
        }
        XCTAssertEqual(items[0].providerID(.tmdb), "episode-1")
        XCTAssertEqual(items[1].providerID(.tmdb), "episode-2")
        XCTAssertEqual(items[0].providerID(.imdb), "ttEpisode")
        XCTAssertEqual(items[0].resumePosition, 300)
        XCTAssertEqual(items[0].runtime, 1800)
        XCTAssertFalse(items[0].isPlayed)
        XCTAssertEqual(items[0].lastPlayedAt, Date(timeIntervalSince1970: 1_700_000_000))
        let detail = try await provider.item(id: "900")
        XCTAssertEqual(items[0].logoURL, detail.logoURL,
                       "Continue Watching and Details must use the same server-provided clearLogo.")
        XCTAssertEqual(items[0].artworkReferences(for: .logo), detail.artworkReferences(for: .logo))
    }

    func testFeedCuratedLogoWinsAndParentArtworkDoesNotDependOnRecency() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/hubs/continueWatching/items", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"e1","type":"episode","title":"One","grandparentRatingKey":"900",
           "Image":[{"type":"clearLogo","url":"/curated/logo.png"}]}
        ]}}
        """)
        http.stub(pathSuffix: "/library/metadata/900", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"900","type":"show","Guid":[{"id":"tmdb://show-9"}],
           "Image":[{"type":"clearLogo","url":"/other/logo.png"}]}
        ]}}
        """)
        let items = try await PlexProvider(session: session, http: http).continueWatching(limit: 10)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.logoURL?.path, "/curated/logo.png")
        XCTAssertEqual(item.providerID(.seriesTmdb), "show-9")
        XCTAssertNil(item.lastPlayedAt)
    }

    func testUnrelatedOrNonSeriesMetadataCannotSupplyAnotherTitlesLogo() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/hubs/continueWatching/items", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"e1","type":"episode","title":"One","grandparentRatingKey":"900",
           "Guid":[{"id":"tmdb://episode-1"}]}
        ]}}
        """)
        http.stub(pathSuffix: "/library/metadata/900", json: """
        {"MediaContainer":{"size":2,"Metadata":[
          {"ratingKey":"900","type":"episode","Guid":[{"id":"tmdb://wrong-child"}],
           "Image":[{"type":"clearLogo","url":"/wrong-child.png"}]},
          {"ratingKey":"901","type":"show","Guid":[{"id":"tmdb://wrong-show"}],
           "Image":[{"type":"clearLogo","url":"/wrong-show.png"}]}
        ]}}
        """)
        let items = try await PlexProvider(session: session, http: http).continueWatching(limit: 10)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.providerID(.tmdb), "episode-1")
        XCTAssertNil(item.providerID(.seriesTmdb))
        XCTAssertNil(item.logoURL)
    }
}
