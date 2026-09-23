import CoreModels
import Foundation
import XCTest
@testable import ProviderSilo

final class SiloCatalogIdentityTests: XCTestCase {
    func testMovieAndSeriesCardsCarryStrongIDsWithoutDetailFetch() {
        XCTAssertEqual(SiloCatalogIdentity.parse("movie-tmdb-9799", kind: .movie)?.providerIDs, ["Tmdb": "9799"])
        XCTAssertEqual(SiloCatalogIdentity.parse("series-tvdb-412429", kind: .series)?.providerIDs, ["Tvdb": "412429"])
        XCTAssertEqual(SiloCatalogIdentity.parse("movie-imdb-tt0112442", kind: .movie)?.providerIDs, ["Imdb": "tt0112442"])
    }

    func testEpisodeAnchorIsTheShowsIDNotTheEpisodesExternalID() {
        let identity = SiloCatalogIdentity.parse("episode-tvdb-412429-1-1", kind: .episode)
        XCTAssertEqual(identity?.providerIDs, ["SeriesTvdb": "412429"])
        XCTAssertEqual(identity?.seriesID, "series-tvdb-412429")
        XCTAssertEqual(identity?.seasonNumber, 1)
        XCTAssertEqual(identity?.episodeNumber, 1)
        XCTAssertNil(identity?.providerIDs["Tvdb"])
    }

    func testMalformedOrCrossKindAnchorsFailClosed() {
        for value in ["local-abcd", "12345", "movie-tmdb-", "movie-bogus-1", "movie-tmdb-12-foo", "series-tvdb-12"] {
            XCTAssertNil(SiloCatalogIdentity.parse(value, kind: .movie))
        }
        for value in ["episode-tvdb-12", "episode-tvdb-12-1", "episode-tvdb-12-x-1", "episode-tvdb-12-1-2-extra"] {
            XCTAssertNil(SiloCatalogIdentity.parse(value, kind: .episode))
        }
    }

    func testOptionalFixedSourceExtensionIsNotRequiredForProtocolThree() throws {
        let body = SiloPlaybackStart(installation_id: "instance", file_id: "42", profile_id: "profile",
                                     capabilities: .default, forceTranscode: false, fixedSourceSupported: false)
        let data = try JSONEncoder().encode(body)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(fields["allow_alternate_versions"])
        let features = try XCTUnwrap(fields["client_features"] as? [String])
        XCTAssertTrue(features.contains("playback_plan_v3"))
        XCTAssertFalse(features.contains("fixed_media_file_v1"))
    }
}
