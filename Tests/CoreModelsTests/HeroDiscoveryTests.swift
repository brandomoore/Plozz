import Foundation
import XCTest
@testable import CoreModels

final class HeroDiscoveryTests: XCTestCase {
    func testDefaultSourcesExcludeTraktAndKeepAnimeOptIn() {
        XCTAssertEqual(HeroDiscoverySource.defaultSelection, [.tmdb, .simkl, .tvdb, .tvmaze])
        XCTAssertFalse(HeroDiscoverySource.allCases.map(\.rawValue).contains("trakt"))
        XCTAssertFalse(HeroSettings.default.discoverySources.contains(.anilist))
    }

    func testSourceSettingsPreserveExplicitEmptyAndIgnoreUnknownNames() throws {
        for (json, expected) in [
            (#"{"discoverySources":[]}"#, [HeroDiscoverySource]()),
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

    func testAttributionSurvivesCodingAndPresentationMerge() throws {
        var item = MediaItem(
            id: "title", title: "Title", kind: .movie,
            discoverySources: [.tmdb, .simkl, .tmdb],
            discoveryURLs: ["simkl": URL(string: "https://simkl.com/movies/42/title")!]
        )
        item.fillingMissingPresentation(from: MediaItem(
            id: "other", title: "Title", kind: .movie,
            discoverySources: [.simkl, .tvmaze],
            discoveryURLs: ["tvmaze": URL(string: "https://www.tvmaze.com/shows/7/title")!]
        ))
        XCTAssertEqual(item.discoverySources, [.tmdb, .simkl, .tvmaze])
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.discoverySources, item.discoverySources)
        XCTAssertEqual(decoded.discoveryURLs, item.discoveryURLs)
        XCTAssertEqual(Set(decoded.discoveryURLs.keys), ["simkl", "tvmaze"])
        let legacy = try JSONDecoder().decode(
            MediaItem.self, from: Data(#"{"id":"legacy","title":"Legacy","kind":"movie"}"#.utf8)
        )
        XCTAssertTrue(legacy.discoverySources.isEmpty)
        XCTAssertTrue(legacy.discoveryURLs.isEmpty)
    }

    func testAttributionLinksAreBrowseOnlyAndBoundToTheirNamedProvider() {
        let source = HeroDiscoverySource.simkl
        XCTAssertTrue(source.acceptsAttributionURL(URL(string: "https://simkl.com/movies/42/title")!))
        for value in [
            "https://example.com/movies/42",
            "https://simkl.com.evil.test/movies/42",
            "https://www.www.simkl.com/movies/42",
            "http://simkl.com/movies/42",
            "https://user:secret@simkl.com/movies/42",
            "https://simkl.com/movies/42?mark=watched",
            "https://simkl.com/movies/42#action",
        ] {
            XCTAssertFalse(source.acceptsAttributionURL(URL(string: value)!))
        }
        var item = MediaItem(id: "title", title: "Title", kind: .movie)
        item.discoveryURLs = ["simkl": URL(string: "https://private.test/?token=secret")!]
        XCTAssertTrue(item.sanitizingArtworkCredentials().discoveryURLs.isEmpty)
    }
}
