import CoreModels
import CoreNetworking
import XCTest
@testable import ProviderJellyfin

/// A dropped show is written to Jellyfin as a dislike on the series. That is the
/// call AIOMetadata reads as a drop and passes on to its trackers.
final class JellyfinShowDropTests: XCTestCase {
    private func provider(_ http: StubHTTPClient, kind: ProviderKind = .jellyfin) -> JellyfinProvider {
        JellyfinProvider(
            session: UserSession(
                server: MediaServer(id: "server", name: "Home", baseURL: URL(string: "https://media.test")!, provider: kind),
                userID: "viewer", userName: "Viewer", deviceID: "test-device", accessToken: "TEST_TOKEN"
            ),
            http: http
        )
    }

    func testDroppingAKnownSeriesDislikesIt() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/viewer/Items/series/Rating", json: "{}")
            try await provider(http, kind: kind).setShowDropped(true, itemID: "episode", seriesID: "series")

            XCTAssertEqual(http.sentPaths, ["/Users/viewer/Items/series/Rating"])
            XCTAssertEqual(http.method(forPathSuffix: "/Rating"), .post)
            XCTAssertEqual(
                http.queryItems(forPathSuffix: "/Rating"), [URLQueryItem(name: "likes", value: "false")]
            )
        }
    }

    /// An episode from another server arrives without its series id: it is
    /// resolved first, because a dislike on the episode would leave the show
    /// itself untouched on a plain server.
    func testAnEpisodeIsResolvedToItsSeriesBeforeTheWrite() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/viewer/Items", json: #"{"Items":[{"Id":"episode","Type":"Episode","SeriesId":"series"}]}"#)
        http.stub(pathSuffix: "/Users/viewer/Items/series/Rating", json: "{}")
        try await provider(http).setShowDropped(true, itemID: "episode", seriesID: nil)
        XCTAssertEqual(http.sentPaths.last, "/Users/viewer/Items/series/Rating")
    }

    func testAnItemWithoutASeriesIsNotDisliked() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/viewer/Items", json: #"{"Items":[{"Id":"movie","Type":"Movie"}]}"#)
        do {
            try await provider(http).setShowDropped(true, itemID: "movie", seriesID: nil)
            XCTFail("A film has no show to drop")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        XCTAssertFalse(http.sentPaths.contains { $0.hasSuffix("/Rating") })
    }

    func testUndroppingClearsTheRating() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/viewer/Items/series/Rating", json: "{}")
        try await provider(http).setShowDropped(false, itemID: "series", seriesID: "series")
        XCTAssertEqual(http.method(forPathSuffix: "/Rating"), .delete)
        XCTAssertEqual(http.queryItems(forPathSuffix: "/Rating"), [])
    }
}
