import CoreModels
import MetadataKit
import XCTest
@testable import CoreUI

@MainActor
final class SeriesArtworkIdentityTests: XCTestCase {
    private func episode(_ id: String = "episode-1", ids: [String: String]) -> MediaItem {
        var item = MediaItem(
            id: id, title: "Episode title", kind: .episode, parentTitle: "The Series",
            seasonNumber: 3, episodeNumber: 4, productionYear: 2004,
            seriesID: "series-1", providerIDs: ids
        )
        item.sourceAccountID = "plex-account"
        return item
    }

    func testSeriesArtworkNeverReinterpretsChildIDsAsShowIDs() {
        let child = episode(ids: [
            "TMDb ID": "episode-tmdb", "IMDb": "ttEpisode", "TVDB ID": "episode-tvdb",
            "TvMaze": "episode-tvmaze", "PlexGuid": "plex://episode/child"
        ])
        let series = PosterCardView.seriesArtworkItem(for: child)
        XCTAssertEqual(series.id, "series-1")
        XCTAssertEqual(series.kind, .series)
        XCTAssertEqual(series.title, "The Series")
        XCTAssertEqual(series.sourceAccountID, child.sourceAccountID)
        XCTAssertNil(series.seasonNumber)
        XCTAssertNil(series.episodeNumber)
        XCTAssertNil(series.productionYear, "An episode's air year is not the show's premiere year.")
        for namespace in [ProviderIDNamespace.tmdb, .imdb, .tvdb, .tvmaze, .plexGuid] {
            XCTAssertNil(series.providerID(namespace), "\(namespace) still identifies the episode.")
        }
        XCTAssertEqual(child.providerID(.tmdb), "episode-tmdb", "The playable episode must remain unchanged.")
    }

    func testExplicitSeriesIDsWinOverEveryChildAlias() {
        let child = episode(ids: [
            "Tmdb": "child", "SeriesTheMovieDb": "series-tmdb",
            "IMDb": "ttChild", "SeriesImdb": "ttSeries",
            "Tvdb": "child-tvdb", "SeriesTheTvdb": "series-tvdb",
            "TvMaze": "child-tvmaze", "SeriesTvMaze": "series-tvmaze"
        ])
        let series = PosterCardView.seriesArtworkItem(for: child)
        XCTAssertEqual(series.providerID(.tmdb), "series-tmdb")
        XCTAssertEqual(series.providerID(.imdb), "ttSeries")
        XCTAssertEqual(series.providerID(.tvdb), "series-tvdb")
        XCTAssertEqual(series.providerID(.tvmaze), "series-tvmaze")
    }

    func testShowScopedAnimeIDsSurviveEpisodeArtworkConversion() {
        let child = episode(ids: ["AniList": "21", "MAL": "20", "AniDB": "5", "Kitsu": "12"])
        let series = PosterCardView.seriesArtworkItem(for: child)
        XCTAssertEqual(MetadataQuery(series).contentType, .anime)
        XCTAssertEqual(MetadataQuery(series).animeIDs, MetadataQuery(child).seriesScoped.animeIDs)
        let explicit = episode(ids: ["AniList": "21", "SeriesAniList": "99"])
        XCTAssertEqual(PosterCardView.seriesArtworkItem(for: explicit).providerID(.aniList), "99")
    }

    func testSiblingEpisodesShareLogoMemoButAccountsStaySeparate() {
        let first = episode(ids: ["Tmdb": "child-1", "PlexGuid": "plex://episode/first"])
        let second = episode("episode-2", ids: ["Tmdb": "child-2", "PlexGuid": "plex://episode/second"])
        func key(_ item: MediaItem) -> HeroLogoMemo.Key {
            HeroLogoMemo.key(for: [], fallback: HeroLogoFallback(
                for: PosterCardView.seriesArtworkItem(for: item), resolve: { nil }
            ))
        }
        XCTAssertEqual(key(first), key(second))
        var anotherAccount = first
        anotherAccount.sourceAccountID = "other-account"
        XCTAssertNotEqual(key(first), key(anotherAccount))
    }

    func testCorrectedLogoLookupBypassesOldChildNegativeAndReusesSeriesAnswer() async throws {
        let child = episode(ids: ["Tmdb": "child-123", "SeriesTmdb": "show-456"])
        let legacy = MediaItem(id: "series-1", title: "The Series", kind: .series, providerIDs: child.providerIDs)
        let corrected = PosterCardView.seriesArtworkItem(for: child)
        let detail = MediaItem(id: "series-1", title: "The Series", kind: .series, providerIDs: ["Tmdb": "show-456"])
        let oldKey = MetadataQuery(legacy).cacheKey(for: .logo)
        let correctKey = MetadataQuery(corrected).cacheKey(for: .logo)
        let detailKey = MetadataQuery(detail).cacheKey(for: .logo)
        XCTAssertNotEqual(oldKey, correctKey)
        XCTAssertEqual(correctKey, detailKey)

        let cache = MetadataDiskCache(directory: nil)
        await cache.store(nil, for: oldKey)
        let cachedMiss = await cache.cached(oldKey)
        XCTAssertTrue(cachedMiss != nil, "The old failed lookup remains cached; no global purge is needed.")
        XCTAssertNil(cachedMiss ?? nil)
        let before = await cache.cached(correctKey)
        XCTAssertNil(before)
        let logo = try XCTUnwrap(URL(string: "https://artwork.example.test/series-logo.png"))
        await cache.store(logo, for: detailKey)
        let actual = await cache.cached(correctKey)
        XCTAssertEqual(actual ?? nil, logo)
    }

    func testConversionKeepsMatchingRestrictionsAndLeavesRealSeriesUntouched() {
        var child = episode(ids: [:])
        child.allowsTitleBasedMetadataMatching = false
        let target = PosterCardView.seriesArtworkItem(for: child)
        XCTAssertFalse(target.allowsTitleBasedMetadataMatching)
        XCTAssertEqual(MetadataQuery(target).title, "")
        let series = MediaItem(id: "show", title: "Real show", kind: .series, productionYear: 2002,
                               providerIDs: ["Tmdb": "show-id"])
        XCTAssertEqual(PosterCardView.seriesArtworkItem(for: series), series)
    }

    func testMissingSeriesTitleCannotSearchForAShowUsingAnEpisodeTitle() {
        let titles: [String?] = [nil, "", " \n "]
        for title in titles {
            var child = episode(ids: ["Tmdb": "episode-id"])
            child.parentTitle = title
            let query = MetadataQuery(PosterCardView.seriesArtworkItem(for: child))
            XCTAssertEqual(query.title, "")
            XCTAssertNil(query.providerIDs.providerID(.tmdb))
            child.providerIDs["SeriesTmdb"] = "show-id"
            let exact = MetadataQuery(PosterCardView.seriesArtworkItem(for: child))
            XCTAssertEqual(exact.providerIDs.providerID(.tmdb), "show-id",
                           "Missing display metadata must not discard an authoritative show ID.")
        }
    }

    func testLegacyBackdropMissCannotKeepSuppressingTheCorrectedLogo() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = TextlessBackdropIndex(directory: directory)
        index.save(.none, for: "series-1")
        let store = TextlessBackdropStore(store: index)
        var item = episode(ids: ["Tmdb": "child-123", "SeriesTmdb": "show-456"])
        item.genres = ["Anime"]
        XCTAssertFalse(store.hasAnswer(for: item), "Legacy ID-only answers do not prove a correctly scoped lookup ran.")
        XCTAssertFalse(store.suppressesLogo(for: item))
        XCTAssertEqual(index.load()["series-1"], TextlessBackdropStore.Outcome.none,
                       "Unrelated cache entries are retained rather than cleared.")
    }

    func testBackdropAnswersAreScopedToTheAccountAndCorrectedSeriesIdentity() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TextlessBackdropStore(store: TextlessBackdropIndex(directory: directory))
        let first = episode(ids: ["Tmdb": "child-123", "SeriesTmdb": "show-456"])
        store.recordForTesting(.none, for: first)
        let sibling = episode("episode-2", ids: ["Tmdb": "child-999", "SeriesTmdb": "show-456"])
        XCTAssertTrue(store.hasAnswer(for: sibling))
        var corrected = first
        corrected.providerIDs["SeriesTmdb"] = "show-789"
        XCTAssertFalse(store.hasAnswer(for: corrected))
        var otherAccount = first
        otherAccount.sourceAccountID = "different-server"
        XCTAssertFalse(store.hasAnswer(for: otherAccount))
    }
}
