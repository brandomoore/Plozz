import XCTest
import CoreModels
@testable import ProviderPlex

final class PlexMusicFeedbackTests: XCTestCase {
    private func provider(_ http: StubHTTPClient) -> PlexProvider {
        PlexProvider(session: UserSession(
            server: MediaServer(id: "server", name: "Music", baseURL: URL(string: "https://music.invalid")!, provider: .plex),
            userID: "user", userName: "Listener", deviceID: "device", accessToken: "fixture-token"
        ), http: http)
    }

    func testRatingUsesPlexScaleAndRemovalSentinel() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/metadata/track", json: #"{"MediaContainer":{"Metadata":[{"ratingKey":"track","type":"track","userRating":9}]}}"#)
        http.stub(pathSuffix: "/:/rate", json: "")
        let provider = provider(http)
        let rating = try await provider.musicFeedback(for: "track")
        XCTAssertEqual(rating, .rating(4.5))
        try await provider.setMusicFeedback(.rating(3.5), for: "track")
        XCTAssertEqual(http.queryItems(forPathSuffix: "/:/rate")?.first { $0.name == "rating" }?.value, "7.0")
        XCTAssertEqual(http.queryItems(forPathSuffix: "/:/rate")?.first { $0.name == "key" }?.value, "track")
        try await provider.setMusicFeedback(.rating(nil), for: "track")
        XCTAssertEqual(http.queryItems(forPathSuffix: "/:/rate")?.first { $0.name == "rating" }?.value, "-1")
    }

    func testInvalidRatingsAndWrongCapabilityNeverSend() async {
        let http = StubHTTPClient()
        let provider = provider(http)
        for value in [MusicFeedback.rating(.nan), .rating(.infinity), .rating(-1), .rating(6), .favorite(true)] {
            do {
                try await provider.setMusicFeedback(value, for: "track")
                XCTFail("Invalid music feedback was accepted")
            } catch {}
        }
        XCTAssertTrue(http.sentPaths.isEmpty)
    }
}
