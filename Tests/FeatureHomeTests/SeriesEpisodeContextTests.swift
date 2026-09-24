import XCTest
import CoreModels
@testable import FeatureHome

final class SeriesEpisodeContextTests: XCTestCase {
    func testStampingAddsSeriesContextWhenEpisodeIsMissingIt() {
        let series = MediaItem(
            id: "show-1",
            title: "Show",
            kind: .series,
            genres: ["Action", "Anime"],
            providerIDs: ["Tmdb": "1234", "AniList": "777"]
        )
        let episode = MediaItem(id: "ep-1", title: "Episode 1", kind: .episode)

        let stamped = SeriesEpisodeContext(series: series).stamping([episode])

        XCTAssertEqual(stamped.count, 1)
        XCTAssertEqual(stamped[0].providerIDs["SeriesTmdb"], "1234")
        XCTAssertEqual(stamped[0].providerIDs["AniList"], "777")
        XCTAssertTrue(stamped[0].genres.isEmpty)
    }

    func testStampingKeepsExistingEpisodeProviderIDs() {
        let context = SeriesEpisodeContext(
            seriesTMDbID: "1234",
            animeIDs: ["AniList": "777"]
        )
        let episode = MediaItem(
            id: "ep-1",
            title: "Episode 1",
            kind: .episode,
            genres: ["Anime"],
            providerIDs: ["SeriesTmdb": "existing", "AniList": "existing"]
        )

        let stamped = context.stamping([episode])

        XCTAssertEqual(stamped[0].providerIDs["SeriesTmdb"], "existing")
        XCTAssertEqual(stamped[0].providerIDs["AniList"], "existing")
        XCTAssertEqual(stamped[0].genres.filter { $0 == "Anime" }.count, 1)
    }

    func testGenreOnlyAnimeClassificationDoesNotPoisonEpisodes() {
        let series = MediaItem(
            id: "show-1",
            title: "Live Action Show",
            kind: .series,
            genres: ["Anime"]
        )
        let episode = MediaItem(id: "ep-1", title: "Episode 1", kind: .episode)

        let stamped = SeriesEpisodeContext(series: series).stamping([episode])

        XCTAssertTrue(stamped[0].genres.isEmpty)
        XCTAssertTrue(stamped[0].providerIDs.isEmpty)
    }

    func testStampingNoOpsWhenContextIsEmpty() {
        let context = SeriesEpisodeContext(seriesTMDbID: nil, animeIDs: [:])
        let episodes = [
            MediaItem(id: "ep-1", title: "Episode 1", kind: .episode),
            MediaItem(id: "ep-2", title: "Episode 2", kind: .episode)
        ]

        XCTAssertEqual(context.stamping(episodes), episodes)
    }
}
