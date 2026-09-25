import CoreModels
import Foundation
import XCTest
@testable import MetadataKit

final class CommunitySkipMarkersTests: XCTestCase {
    private func episode(providerIDs: [String: String], season: Int? = 1, number: Int? = 2) -> MediaItem {
        var item = MediaItem(id: "ep", title: "Episode", kind: .episode)
        item.providerIDs = providerIDs
        item.seasonNumber = season
        item.episodeNumber = number
        item.runtime = 3000
        return item
    }

    // MARK: Query

    func testEpisodeQueryUsesSeriesIDsNotTheEpisodesOwn() throws {
        let item = episode(providerIDs: ["Imdb": "tt999", "SeriesImdb": "tt0903747", "SeriesTmdb": "1396"])
        let query = try XCTUnwrap(CommunitySkipMarkerQuery(item: item))
        XCTAssertEqual(query.imdbID, "tt0903747")
        XCTAssertEqual(query.tmdbID, "1396")
        XCTAssertEqual(query.season, 1)
        XCTAssertEqual(query.episode, 2)
        XCTAssertEqual(query.duration, 3000)
        XCTAssertFalse(query.isMovie)
    }

    func testEpisodeQueryFallsBackToTheSeriesItem() throws {
        let item = episode(providerIDs: ["Imdb": "tt999"])
        XCTAssertTrue(CommunitySkipMarkerQuery.needsSeriesIDs(item))
        XCTAssertNil(CommunitySkipMarkerQuery(item: item))
        var series = MediaItem(id: "s", title: "Show", kind: .series)
        series.providerIDs = ["Imdb": "tt0903747"]
        let query = try XCTUnwrap(CommunitySkipMarkerQuery(item: item, series: series))
        XCTAssertEqual(query.imdbID, "tt0903747")
    }

    func testEpisodeWithoutNumbersHasNoQuery() {
        XCTAssertNil(CommunitySkipMarkerQuery(item: episode(providerIDs: ["SeriesImdb": "tt1"], season: nil)))
    }

    // MARK: IntroDB

    func testIntroDBURL() throws {
        let tv = CommunitySkipMarkerQuery(isMovie: false, imdbID: "tt0903747", tmdbID: nil, season: 1, episode: 2)
        XCTAssertEqual(
            IntroDBClient.url(for: tv)?.absoluteString,
            "https://api.introdb.app/segments?imdb_id=tt0903747&season=1&episode=2"
        )
        let movie = CommunitySkipMarkerQuery(isMovie: true, imdbID: "tt1375666", tmdbID: "27205")
        XCTAssertEqual(
            IntroDBClient.url(for: movie)?.absoluteString,
            "https://api.introdb.app/segments?imdb_id=tt1375666&is_movie=true"
        )
        // IntroDB is IMDb-only.
        XCTAssertNil(IntroDBClient.url(for: CommunitySkipMarkerQuery(isMovie: true, imdbID: nil, tmdbID: "27205")))
    }

    func testIntroDBParsesIntroRecapAndOutro() throws {
        let json = #"""
        {"imdb_id":"tt0903747","intro":{"start_sec":10,"end_sec":40,"start_ms":10000,"end_ms":40000,"confidence":1,"submission_count":2},
         "recap":null,
         "outro":{"start_sec":3431,"end_sec":3500,"start_ms":3431000,"end_ms":3500000,"confidence":1,"submission_count":1},
         "post_credits":null}
        """#
        let response = try JSONDecoder().decode(IntroDBClient.Response.self, from: Data(json.utf8))
        let segments = IntroDBClient.segments(from: response)
        XCTAssertEqual(segments.map(\.kind), [.intro, .credits])
        XCTAssertEqual(segments[0].start, 10)
        XCTAssertEqual(segments[0].end, 40)
        XCTAssertEqual(segments[1].start, 3431)
        XCTAssertEqual(segments[1].end, 3500)
    }

    // MARK: TheIntroDB

    func testTheIntroDBURLPrefersTMDB() {
        let tv = CommunitySkipMarkerQuery(isMovie: false, imdbID: "tt0903747", tmdbID: "1396", season: 1, episode: 2)
        XCTAssertEqual(
            TheIntroDBClient.url(for: tv)?.absoluteString,
            "https://api.theintrodb.org/v3/media?tmdb_id=1396&season=1&episode=2"
        )
        let imdbOnly = CommunitySkipMarkerQuery(isMovie: true, imdbID: "tt1375666", tmdbID: nil)
        XCTAssertEqual(
            TheIntroDBClient.url(for: imdbOnly)?.absoluteString,
            "https://api.theintrodb.org/v3/media?imdb_id=tt1375666"
        )
    }

    func testTheIntroDBResolvesOpenEndedSegments() throws {
        let json = #"""
        {"tmdb_id":1396,"type":"tv","season":1,"episode":1,
         "intro":[{"start_ms":null,"end_ms":38000}],
         "credits":[{"start_ms":3431000,"end_ms":null}],
         "preview":[{"start_ms":3480000,"end_ms":3495000}]}
        """#
        let response = try JSONDecoder().decode(TheIntroDBClient.Response.self, from: Data(json.utf8))

        let withDuration = TheIntroDBClient.segments(from: response, duration: 3500)
        XCTAssertEqual(withDuration.map(\.kind), [.intro, .credits, .preview])
        XCTAssertEqual(withDuration[0].start, 0)
        XCTAssertEqual(withDuration[0].end, 38)
        XCTAssertEqual(withDuration[1].end, 3500)

        // Without a duration an open-ended segment has no skip target, so it's dropped.
        let withoutDuration = TheIntroDBClient.segments(from: response, duration: nil)
        XCTAssertEqual(withoutDuration.map(\.kind), [.intro, .preview])
    }
}
