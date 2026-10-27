import CoreModels
import XCTest
@testable import FeatureHomeCore

final class HeroSeriesSynopsisTests: XCTestCase {
    func testHomeUsesSeriesTextButDetailKeepsEpisodeTextAndSpoilerRules() throws {
        let series = MediaItem(
            id: "series", title: "La serie", kind: .series,
            overview: "Le synopsis choisi sur le serveur.", sourceAccountID: "account"
        )
        for watched in [false, true] {
            for resume in [0.0, 120.0] {
                var episode = MediaItem(
                    id: "episode", title: "Episode title", kind: .episode,
                    overview: "Episode spoiler", taglines: ["Episode tagline"],
                    seriesID: series.id, resumePosition: resume, isPlayed: watched,
                    sourceAccountID: "account"
                )
                episode.seriesSynopsis = try XCTUnwrap(MediaSeriesSynopsis(series: series))
                let home = HeroPresentation(item: episode, artworkStyle: .landscape, surface: .home)
                XCTAssertEqual(HeroContentPolicy.homeDescription(for: home), series.overview)
                let detail = HeroPresentation(item: episode, artworkStyle: .landscape, surface: .detail)
                XCTAssertEqual(detail.overview, episode.overview)
                XCTAssertEqual(detail.tagline, "Episode tagline")
                var spoilers = SpoilerSettings.default
                spoilers.isEnabled = true
                XCTAssertEqual(spoilers.shouldHideText(for: episode), !watched)
                XCTAssertEqual(episode.id, "episode")
                XCTAssertEqual(episode.resumePosition, resume)
            }
        }
    }

    func testMissingEmptyOrWrongSeriesNeverExposesEpisodeDescriptionInHome() throws {
        let series = MediaItem(id: "series", title: "Show", kind: .series, sourceAccountID: "account")
        var episode = MediaItem(
            id: "episode", title: "Spoiler", kind: .episode, overview: "Episode spoiler",
            taglines: ["Episode tagline"], seriesID: series.id, sourceAccountID: "account"
        )
        XCTAssertNil(homeText(episode))
        episode.seriesSynopsis = try XCTUnwrap(MediaSeriesSynopsis(series: series))
        XCTAssertNil(homeText(episode))
        var described = series
        described.overview = "Series synopsis"
        episode.seriesSynopsis = MediaSeriesSynopsis(series: described)
        XCTAssertEqual(homeText(episode), described.overview)
        episode.seriesID = "another-series"
        XCTAssertNil(homeText(episode))
        episode.seriesID = series.id
        episode.sourceAccountID = "another-account"
        XCTAssertNil(homeText(episode))
        XCTAssertNil(MediaSeriesSynopsis(series: episode))
    }

    func testSeriesSynopsisRoundTripAndLegacyItemDecoding() throws {
        var episode = MediaItem(id: "episode", title: "Episode", kind: .episode, seriesID: "series")
        episode.seriesSynopsis = MediaSeriesSynopsis(series: MediaItem(
            id: "series", title: "Show", kind: .series, overview: "Server overview", taglines: ["Server tagline"]
        ))
        let data = try JSONEncoder().encode(episode)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: data), episode)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "seriesSynopsis")
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.seriesSynopsis)
        XCTAssertNil(homeText(decoded))
        XCTAssertEqual(homeText(episode), "Server tagline")
    }

    func testMovieAndSeriesDescriptionsKeepExistingPrecedence() {
        for kind in [MediaItemKind.movie, .series] {
            let item = MediaItem(id: "item", title: "Title", kind: kind, overview: "Overview", taglines: ["Tagline"])
            XCTAssertEqual(homeText(item), "Tagline")
        }
    }

    func testLivePresentationFillKeepsOnlyTheMatchingSeriesSynopsis() {
        var donor = MediaItem(
            id: "episode", title: "Episode", kind: .episode, seriesID: "series", sourceAccountID: "account"
        )
        donor.seriesSynopsis = MediaSeriesSynopsis(series: MediaItem(
            id: "series", title: "Show", kind: .series, overview: "Server synopsis", sourceAccountID: "account"
        ))
        var current = donor
        current.seriesSynopsis = nil
        current.fillingMissingPresentation(from: donor)
        XCTAssertEqual(homeText(current), "Server synopsis")
        current.sourceAccountID = "other"
        current.seriesSynopsis = nil
        current.fillingMissingPresentation(from: donor)
        XCTAssertNil(current.seriesSynopsis)
    }

    private func homeText(_ item: MediaItem) -> String? {
        HeroContentPolicy.homeDescription(
            for: HeroPresentation(item: item, artworkStyle: .landscape, surface: .home)
        )
    }
}
