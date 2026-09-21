import Foundation
import XCTest
@testable import CoreModels

final class HeroDiscoveryTests: XCTestCase {
    func testDiscoverySourcesExcludeTraktAndSimklAndKeepAnimeOptIn() {
        XCTAssertEqual(HeroDiscoverySource.defaultSelection, [.tmdb, .tvdb, .tvmaze])
        XCTAssertEqual(HeroDiscoverySource.allCases, [.tmdb, .anilist, .tvdb, .tvmaze])
        XCTAssertNil(HeroDiscoverySource(rawValue: "simkl"))
        XCTAssertNil(HeroDiscoverySource(rawValue: "trakt"))
        XCTAssertFalse(HeroSettings.default.discoverySources.contains(.anilist))
    }

    func testSourceSettingsPreserveExplicitEmptyAndIgnoreUnknownNames() throws {
        for (json, expected) in [
            (#"{"discoverySources":[]}"#, [HeroDiscoverySource]()),
            (#"{"discoverySources":["simkl"]}"#, []),
            (#"{"discoverySources":["simkl","tvdb","tmdb","simkl"]}"#, [.tvdb, .tmdb]),
            (#"{"discoverySources":["tmdb","future","tmdb","anilist"]}"#, [.tmdb, .anilist])
        ] {
            let settings = try JSONDecoder().decode(HeroSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.discoverySources, expected)
            XCTAssertEqual(
                try JSONDecoder().decode(HeroSettings.self, from: JSONEncoder().encode(settings)),
                settings
            )
        }
        let legacy = try JSONDecoder().decode(HeroSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.discoverySources, HeroDiscoverySource.defaultSelection)
    }

    func testRequestBoundsAndRedactsSeedsToPublicTitleMetadata() {
        var privateSeed = MediaItem(
            id: "/private/library/movie", title: "A Film", kind: .movie,
            productionYear: 2024, resumePosition: 50,
            posterURL: URL(string: "https://server.test/image?token=private"),
            providerIDs: ["tmdb": "42", "PrivateToken": "secret"],
            sourceAccountID: "private-account"
        )
        privateSeed.isFavorite = true
        let request = HeroDiscoveryRequest(limit: 1_000, seeds: Array(repeating: privateSeed, count: 10))
        XCTAssertEqual(request.limit, 48)
        XCTAssertEqual(request.seeds.count, 3)
        XCTAssertEqual(request.seeds.first?.providerIDs, ["Tmdb": "42"])
        XCTAssertEqual(request.seeds.first?.title, "A Film")
        XCTAssertNil(request.seeds.first?.sourceAccountID)
        XCTAssertNil(request.seeds.first?.posterURL)
        XCTAssertNil(request.seeds.first?.resumePosition)
        XCTAssertFalse(request.seeds.first?.locallyValidatedPlayableSource ?? true)
        XCTAssertFalse(request.seeds.first?.isFavorite ?? true)
        XCTAssertNotEqual(request.seeds.first?.id, privateSeed.id)
        XCTAssertEqual(HeroDiscoveryRequest(limit: -1).limit, 0)
    }

    func testPersonalMediaNeverBecomesRecommendationSeed() {
        var personal = MediaItem(id: "personal", title: "Family", kind: .movie)
        personal.allowsTitleBasedMetadataMatching = false
        let folder = MediaItem(id: "folder", title: "Files", kind: .folder)
        XCTAssertTrue(HeroDiscoveryRequest(seeds: [personal, folder]).seeds.isEmpty)
    }

    func testFeaturedReleaseWindowUsesTwoCalendarYearsAndPreservesBoundaryDates() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-09-20T12:00:00Z"))
        let recency = HeroDiscoveryRecency.default
        XCTAssertEqual(recency.years, 2)
        XCTAssertEqual(recency.cutoff(at: now), formatter.date(from: "2024-09-20T00:00:00Z"))
        for (date, included) in [
            ("1994-09-23T00:00:00Z", false),
            ("2024-09-19T23:59:59Z", false),
            ("2024-09-20T00:00:00Z", true),
            ("2026-09-20T23:59:59Z", true),
            ("2026-09-21T00:00:00Z", false)
        ] {
            let item = MediaItem(
                id: date, title: "Movie", kind: .movie, productionYear: 2026,
                releaseDate: try XCTUnwrap(formatter.date(from: date))
            )
            XCTAssertEqual(recency.includesRelease(of: item, at: now), included, date)
        }
        for (year, included) in [(1994, false), (2023, false), (2024, true), (2026, true), (2027, false)] {
            let item = MediaItem(id: "year", title: "Movie", kind: .movie, productionYear: year)
            XCTAssertEqual(recency.includesRelease(of: item, at: now), included)
        }
        XCTAssertFalse(recency.includesRelease(of: MediaItem(id: "unknown", title: "Unknown", kind: .movie), at: now))
        XCTAssertEqual(HeroDiscoveryRecency(years: 0).years, 1)
        XCTAssertEqual(HeroDiscoveryRecency(years: 100).years, 10)
    }

    func testUpcomingEpisodeEvidenceMustBeCurrentAndHandlesLeapYears() throws {
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2028-02-29T12:00:00Z"))
        let recency = HeroDiscoveryRecency.default
        XCTAssertEqual(recency.cutoff(at: now), formatter.date(from: "2026-02-28T00:00:00Z"))
        XCTAssertTrue(recency.includesUpcomingEpisode(
            at: try XCTUnwrap(formatter.date(from: "2028-03-01T00:00:00Z")), now: now
        ))
        for date in ["2028-02-28T00:00:00Z", "2028-03-07T00:00:00Z", "2029-01-01T00:00:00Z"] {
            XCTAssertFalse(recency.includesUpcomingEpisode(
                at: try XCTUnwrap(formatter.date(from: date)), now: now
            ), date)
        }
    }

    func testAttributionSurvivesCodingAndPresentationMerge() throws {
        var item = MediaItem(
            id: "title", title: "Title", kind: .movie,
            discoverySources: [.tmdb, .tvdb, .tmdb],
            discoveryURLs: ["tvdb": URL(string: "https://thetvdb.com/movies/title")!]
        )
        item.fillingMissingPresentation(from: MediaItem(
            id: "other", title: "Title", kind: .movie,
            discoverySources: [.tvdb, .tvmaze],
            discoveryURLs: ["tvmaze": URL(string: "https://www.tvmaze.com/shows/7/title")!]
        ))
        XCTAssertEqual(item.discoverySources, [.tmdb, .tvdb, .tvmaze])
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.discoverySources, item.discoverySources)
        XCTAssertEqual(decoded.discoveryURLs, item.discoveryURLs)
        XCTAssertEqual(Set(decoded.discoveryURLs.keys), ["tvdb", "tvmaze"])
        let legacy = try JSONDecoder().decode(
            MediaItem.self, from: Data(#"{"id":"legacy","title":"Legacy","kind":"movie"}"#.utf8)
        )
        XCTAssertTrue(legacy.discoverySources.isEmpty)
        XCTAssertTrue(legacy.discoveryURLs.isEmpty)
    }

    func testAttributionLinksAreBrowseOnlyAndBoundToTheirNamedProvider() {
        let source = HeroDiscoverySource.tvdb
        XCTAssertTrue(source.acceptsAttributionURL(URL(string: "https://thetvdb.com/movies/title")!))
        for value in [
            "https://example.com/movies/42",
            "https://thetvdb.com.evil.test/movies/42",
            "https://www.www.thetvdb.com/movies/42",
            "http://thetvdb.com/movies/42",
            "https://user:secret@thetvdb.com/movies/42",
            "https://thetvdb.com/movies/42?mark=watched",
            "https://thetvdb.com/movies/42#action",
        ] {
            XCTAssertFalse(source.acceptsAttributionURL(URL(string: value)!))
        }
        var item = MediaItem(id: "title", title: "Title", kind: .movie)
        item.discoveryURLs = ["tvdb": URL(string: "https://private.test/?token=secret")!]
        XCTAssertTrue(item.sanitizingArtworkCredentials().discoveryURLs.isEmpty)
    }

    func testLegacyItemDropsRetiredDiscoveryAttributionWithoutLosingOtherMetadata() throws {
        let json = #"""
        {"id":"legacy","title":"A title","kind":"movie","providerIDs":{"Tmdb":"42"},
         "discoverySources":["simkl","tmdb"],
         "discoveryURLs":{"simkl":"https://simkl.com/movies/42/title","tmdb":"https://www.themoviedb.org/movie/42"}}
        """#
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.discoverySources, [.tmdb])
        XCTAssertEqual(Set(item.discoveryURLs.keys), ["tmdb"])
        XCTAssertEqual(item.providerID(.tmdb), "42")
        XCTAssertEqual(item.title, "A title")
    }
}
