import XCTest
@testable import CoreModels
@testable import MetadataKit

/// Coverage for `ArtworkProvider.artworkURLs` — the candidate list that lets the
/// Home hero and the detail page show *different* pictures.
///
/// The bug this closes: both screens resolved the same `.hero` chain and each took
/// the single answer it returned, so they always drew the identical image. TMDb
/// fetches every backdrop a title has in one response, ranks textless ones first,
/// and all but the best were discarded a layer above.
final class ArtworkCandidateTests: XCTestCase {

    func testOrderedPlacementsRecoverPosterOnlyArtUnderLiveProviderPolicy() async {
        let settings = CatalogArtworkSettings(.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]))
        let cache = MetadataDiskCache(directory: nil)
        let router = catalogRouter(settings: settings, cache: cache)
        var item = MediaItem(id: "poster-only", title: "Poster Only", kind: .movie, posterURL: url("saved-tvdb"))
        item.recordArtworkMetadataSource(.tvdb, for: url("saved-tvdb"))
        for source in [MetadataSource.tvdb, .tmdb] {
            for kind in [ArtworkKind.hero, .thumbnail, .poster] {
                await cache.store(
                    kind == .poster && source == .tmdb ? url("cached-tmdb") : nil,
                    for: ArtworkRouter.providerCacheKey(query: MetadataQuery(item), kind: kind, source: source)
                )
            }
        }
        let placements: [ArtworkPlacement] = [.detailBackdrop, .episodeThumbnail, .poster]
        let initial = await router.sourcedArtworkURL(for: item, placements: placements)
        XCTAssertEqual(initial, .init(value: url("saved-tvdb"), source: .tvdb))
        let heroFallback = await router.heroArtworkURL(for: item, placement: .detailBackdrop)
        XCTAssertEqual(heroFallback, url("saved-tvdb"))
        settings.save(.init(orderMode: .custom, enabledOrder: ["tmdb", "tvdb"]))
        let reordered = await router.sourcedArtworkURL(for: item, placements: placements)
        XCTAssertEqual(reordered, .init(value: url("cached-tmdb"), source: .tmdb))
        settings.save(.init(orderMode: .custom, enabledOrder: ["tvdb"], disabledOrder: ["tmdb"]))
        let disabled = await router.artworkURL(for: item, placements: placements)
        XCTAssertEqual(disabled, url("saved-tvdb"))
        settings.save(.init(orderMode: .custom, disabledOrder: ["tmdb", "tvdb"]))
        let none = await router.artworkURL(for: item, placements: placements)
        XCTAssertNil(none)
        XCTAssertTrue(item.artworkReferences(for: .poster).isEmpty)
    }

    func testSeriesOnlyLadderNeverReusesAnEpisodeStillOrChildIdentifier() async {
        let settings = CatalogArtworkSettings(.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]))
        let cache = MetadataDiskCache(directory: nil)
        let router = catalogRouter(settings: settings, cache: cache)
        var episode = MediaItem(
            id: "episode", title: "A Spoiler", kind: .episode, parentTitle: "The Show",
            seasonNumber: 1, episodeNumber: 2, seriesID: "show",
            posterURL: url("episode-still"), seriesPosterURL: url("series-poster"),
            providerIDs: ["Tvdb": "child-id", "SeriesTvdb": "series-id"]
        )
        episode.recordArtworkMetadataSource(.tvdb, for: url("episode-still"))
        episode.recordArtworkMetadataSource(.tvdb, for: url("series-poster"))
        let series = ArtworkRouter.seriesArtworkItem(for: episode)
        XCTAssertEqual(series.providerIDs.providerID(.tvdb), "series-id")
        XCTAssertFalse(series.providerIDs.values.contains("child-id"))
        for source in [MetadataSource.tvdb, .tmdb] {
            for kind in [ArtworkKind.hero, .poster] {
                await cache.store(nil, for: ArtworkRouter.providerCacheKey(
                    query: MetadataQuery(series), kind: kind, source: source
                ))
            }
            await cache.store(url("episode-still"), for: ArtworkRouter.providerCacheKey(
                query: MetadataQuery(episode), kind: .thumbnail, source: source
            ))
        }
        let hidden = await router.artworkURL(for: episode, placements: [.detailBackdrop, .seriesPoster])
        XCTAssertEqual(hidden, url("series-poster"))
        let visible = await router.artworkURL(
            for: episode, placements: [.episodeThumbnail, .detailBackdrop, .seriesPoster]
        )
        XCTAssertEqual(visible, url("episode-still"))
        episode.seriesPosterURL = nil
        let noSeries = await router.artworkURL(for: episode, placements: [.detailBackdrop, .seriesPoster])
        XCTAssertNil(noSeries, "A known episode still is not a series-poster fallback.")
    }

    func testCatalogSubjectResolvesFolderWithoutChangingItsNavigationIdentity() async throws {
        let settings = CatalogArtworkSettings(.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]))
        let cache = MetadataDiskCache(directory: nil)
        let router = catalogRouter(settings: settings, cache: cache)
        let catalog = MediaItem(
            id: "catalog:series:show", title: "Recognized Show", kind: .series, providerIDs: ["Tvdb": "42"]
        )
        var folder = MediaItem(
            id: "d:TV/Show", title: "Raw Folder", kind: .folder,
            posterURL: url("saved-tvdb"), sourceAccountID: "share-account"
        )
        folder.artworkLookupSubject = try XCTUnwrap(ArtworkLookupSubject(catalog: catalog))
        folder.recordArtworkMetadataSource(.tvdb, for: url("saved-tvdb"))
        folder.recordArtworkSource(accountID: "poster-owner", for: [url("saved-tvdb")])
        let original = folder
        for source in [MetadataSource.tvdb, .tmdb] {
            await cache.store(nil, for: ArtworkRouter.providerCacheKey(
                query: MetadataQuery(folder.artworkLookupItem), kind: .poster, source: source
            ))
        }
        let resolved = await router.artworkURL(for: folder, placements: [.poster])
        XCTAssertEqual(resolved, url("saved-tvdb"))
        XCTAssertEqual(folder, original)
        XCTAssertEqual(folder.kind, .folder)
        XCTAssertEqual(folder.providerIDs, [:])
        XCTAssertEqual(folder.artworkLookupItem.providerIDs, catalog.providerIDs)
        XCTAssertEqual(folder.artworkLookupItem.artworkSourceAccountID(for: url("saved-tvdb")), "poster-owner")
        folder.artworkLookupSubject = nil
        let unqualified = await router.artworkURL(for: folder, placements: [.poster])
        XCTAssertNil(unqualified, "Attribution alone does not qualify an arbitrary folder for title lookup.")
    }

    func testExplicitExternalSelectionsRemainSourceQualifiedRouterCandidates() async {
        let settings = CatalogArtworkSettings(.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]))
        let cache = MetadataDiskCache(directory: nil)
        let router = catalogRouter(settings: settings, cache: cache)
        var item = MediaItem(
            id: "selected-only", title: "Selected Only", kind: .movie,
            artworkSelections: [.init(placement: .poster, references: [.remote(url("selected"))])]
        )
        item.recordArtworkMetadataSource(.tvdb, for: url("selected"))
        for source in [MetadataSource.tvdb, .tmdb] {
            await cache.store(nil, for: ArtworkRouter.providerCacheKey(
                query: MetadataQuery(item), kind: .poster, source: source
            ))
        }
        XCTAssertTrue(item.artworkReferences(for: .poster).isEmpty)
        let enabled = await router.artworkURL(for: item, placements: [.poster])
        XCTAssertEqual(enabled, url("selected"))
        item.recordArtworkMetadataSource(.legacyUnknown, for: url("selected"))
        let unknown = await router.artworkURL(for: item, placements: [.poster])
        XCTAssertNil(unknown)
    }

    func testRecognizedSeasonFolderRetainsItsSourcedSeasonPosterSelection() async throws {
        let settings = CatalogArtworkSettings(.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]))
        let cache = MetadataDiskCache(directory: nil)
        let router = catalogRouter(settings: settings, cache: cache)
        let catalog = MediaItem(
            id: "catalog-season-1", title: "Season 1", kind: .season,
            parentTitle: "Recognized Show", seasonNumber: 1
        )
        var folder = MediaItem(
            id: "d:season", title: "Season Folder", kind: .folder,
            artworkSelections: [.init(placement: .seasonPoster, references: [.remote(url("season-poster"))])]
        )
        folder.artworkLookupSubject = try XCTUnwrap(ArtworkLookupSubject(catalog: catalog))
        folder.recordArtworkMetadataSource(.tvdb, for: url("season-poster"))
        for source in [MetadataSource.tvdb, .tmdb] {
            await cache.store(nil, for: ArtworkRouter.providerCacheKey(
                query: MetadataQuery(ArtworkRouter.seriesArtworkItem(for: folder)), kind: .poster, source: source
            ))
        }
        let poster = await router.artworkURL(for: folder, placements: [.poster])
        XCTAssertEqual(poster, url("season-poster"))
        settings.save(.init(orderMode: .custom, enabledOrder: ["tmdb"], disabledOrder: ["tvdb"]))
        let disabled = await router.artworkURL(for: folder, placements: [.poster])
        XCTAssertNil(disabled)
    }

    func testCatalogPosterFollowsLivePriorityAndDisabledSources() async {
        let cache = MetadataDiskCache(directory: nil)
        let settings = CatalogArtworkSettings(.init(orderMode: .custom, enabledOrder: ["tmdb", "tvdb"]))
        let router = catalogRouter(settings: settings, cache: cache)
        var item = MediaItem(
            id: "catalog-item", title: "Catalog Movie", kind: .movie, posterURL: url("saved-tmdb"),
            providerIDs: ["Tmdb": "42"]
        )
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
        for source in [MetadataSource.tvdb, .tmdb] {
            await cache.store(url("cached-\(source.rawValue)"), for: ArtworkRouter.providerCacheKey(
                query: MetadataQuery(item), kind: .poster, source: source
            ))
        }
        let original = await router.sourcedArtworkURL(.poster, for: item)
        XCTAssertEqual(original, .init(value: url("cached-tmdb"), source: .tmdb))
        settings.save(.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]))
        let reordered = await router.sourcedArtworkURL(.poster, for: item)
        XCTAssertEqual(reordered, .init(value: url("cached-tvdb"), source: .tvdb))
        settings.save(.init(orderMode: .custom, enabledOrder: ["tvdb"], disabledOrder: ["tmdb"]))
        let disabled = await router.sourcedArtworkURL(.poster, for: item)
        XCTAssertEqual(disabled, .init(value: url("cached-tvdb"), source: .tvdb))
        settings.save(.init(orderMode: .custom, disabledOrder: ["tmdb", "tvdb"]))
        let allDisabled = await router.artworkURL(.poster, for: item)
        XCTAssertNil(allDisabled)
        XCTAssertEqual(item.posterURL, url("saved-tmdb"), "The stale input stays intact, but must never bypass policy.")
        XCTAssertEqual(item.providerIDs, ["Tmdb": "42"])
    }

    func testCatalogImageRemainsFallbackOnlyWhileItsKnownSourceIsEnabled() async {
        let cache = MetadataDiskCache(directory: nil)
        let settings = CatalogArtworkSettings(.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]))
        let router = catalogRouter(settings: settings, cache: cache)
        var item = MediaItem(id: "fallback", title: "Fallback", kind: .movie, posterURL: url("saved-tmdb"))
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
        for source in [MetadataSource.tvdb, .tmdb] {
            await cache.store(nil, for: ArtworkRouter.providerCacheKey(
                query: MetadataQuery(item), kind: .poster, source: source
            ))
        }
        let fallback = await router.sourcedArtworkURL(.poster, for: item)
        XCTAssertEqual(fallback, .init(value: url("saved-tmdb"), source: .tmdb))
        settings.save(.init(orderMode: .custom, enabledOrder: ["tvdb"], disabledOrder: ["tmdb"]))
        let disabledFallback = await router.sourcedArtworkURL(.poster, for: item)
        XCTAssertNil(disabledFallback)
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .legacyUnknown)
        let unknownFallback = await router.sourcedArtworkURL(.poster, for: item)
        XCTAssertNil(unknownFallback, "An unattributed old image must not silently resurrect a disabled provider.")
    }

    func testCatalogCandidateMemoTracksLiveProviderPolicyAndSnapshotChanges() async {
        let settings = CatalogArtworkSettings(.init(orderMode: .custom, enabledOrder: ["tmdb", "tvdb"]))
        let cache = MetadataDiskCache(directory: nil)
        let router = catalogRouter(settings: settings, cache: cache)
        var item = MediaItem(
            id: "candidates", title: "Candidates", kind: .movie,
            posterURL: url("tmdb"), fallbackArtworkURL: url("tvdb")
        )
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
        item.metadataProvenance[.backdropURL] = MetadataAttribution(source: .tvdb)
        for source in [MetadataSource.tvdb, .tmdb] {
            await cache.store(nil, for: ArtworkRouter.providerCacheKey(
                query: MetadataQuery(item), kind: .poster, source: source
            ))
        }
        let initial = await router.sourcedArtworkURLs(.poster, for: item)
        XCTAssertEqual(initial.first, .init(value: url("tmdb"), source: .tmdb))
        settings.save(.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]))
        let reordered = await router.sourcedArtworkURLs(.poster, for: item)
        XCTAssertEqual(reordered.first, .init(value: url("tvdb"), source: .tvdb))
        item.fallbackArtworkURL = url("updated-tvdb")
        let updated = await router.sourcedArtworkURLs(.poster, for: item)
        XCTAssertEqual(updated.first, .init(value: url("updated-tvdb"), source: .tvdb))
        settings.save(.init(orderMode: .custom, enabledOrder: ["tmdb"], disabledOrder: ["tvdb"]))
        let disabled = await router.sourcedArtworkURLs(.poster, for: item)
        XCTAssertEqual(disabled.first, .init(value: url("tmdb"), source: .tmdb))
        XCTAssertFalse(disabled.contains { $0.source == .tvdb })
        settings.save(.init(orderMode: .custom, disabledOrder: ["tvdb", "tmdb"]))
        let allDisabled = await router.sourcedArtworkURLs(.poster, for: item)
        XCTAssertTrue(allDisabled.isEmpty)
    }

    private func catalogRouter(
        settings: CatalogArtworkSettings, cache: MetadataDiskCache
    ) -> ArtworkRouter {
        ArtworkRouter(
            cache: cache,
            enrichmentBaseline: .init(order: [.tvdb, .tmdb], priority: .init(rules: [])),
            settingsStore: settings
        )
    }

    private func url(_ name: String) -> URL {
        URL(string: "https://art.example/\(name).jpg")!
    }

    private final class CatalogArtworkSettings: MetadataProviderSettingsStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var value: MetadataProviderSettings
        init(_ value: MetadataProviderSettings) { self.value = value }
        func load() -> MetadataProviderSettings { lock.lock(); defer { lock.unlock() }; return value }
        func save(_ value: MetadataProviderSettings) { lock.lock(); self.value = value; lock.unlock() }
    }

    /// A provider holding one picture needs no change and must keep costing one
    /// call — the default implementation is what guarantees that.
    private struct SingleImageProvider: ArtworkProvider {
        let id = "single"
        let image: URL
        /// Counts calls, to prove the default adds no extra work.
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls: Calls

        func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
            calls.count += 1
            return image
        }
    }

    private struct MultiImageProvider: ArtworkProvider {
        let id = "multi"
        let images: [URL]

        func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
            images.first
        }

        func artworkURLs(_ kind: ArtworkKind, for query: MetadataQuery, limit: Int) async -> [URL] {
            Array(images.prefix(limit))
        }
    }

    private var query: MetadataQuery {
        MetadataQuery(MediaItem(id: "i1", title: "Show", kind: .series))
    }

    // MARK: The default

    /// A single-image provider answers with exactly its one picture...
    func testTheDefaultReturnsTheSingleAnswer() async {
        let provider = SingleImageProvider(image: url("only"), calls: .init())
        let urls = await provider.artworkURLs(.hero, for: query, limit: 4)
        XCTAssertEqual(urls, [url("only")])
    }

    /// ...using exactly one underlying call, however many are asked for. A default
    /// that fanned out per requested candidate would turn one request into four on
    /// every provider that never needed changing.
    func testTheDefaultCostsExactlyOneCall() async {
        let calls = SingleImageProvider.Calls()
        let provider = SingleImageProvider(image: url("only"), calls: calls)
        _ = await provider.artworkURLs(.hero, for: query, limit: 4)
        XCTAssertEqual(calls.count, 1)
    }

    /// Asking for nothing must do nothing — the guard that keeps a satisfied
    /// caller from touching the network at all.
    func testAZeroLimitDoesNoWork() async {
        let calls = SingleImageProvider.Calls()
        let provider = SingleImageProvider(image: url("only"), calls: calls)
        let urls = await provider.artworkURLs(.hero, for: query, limit: 0)
        XCTAssertTrue(urls.isEmpty)
        XCTAssertEqual(calls.count, 0, "a zero limit must not reach the provider")
    }

    // MARK: Multi-image providers

    func testAMultiImageProviderOffersItsWholeRankedSet() async {
        let provider = MultiImageProvider(images: [url("a"), url("b"), url("c")])
        let urls = await provider.artworkURLs(.hero, for: query, limit: 2)
        XCTAssertEqual(urls, [url("a"), url("b")])
    }

    /// The first candidate must remain what the single-answer path returns, so the
    /// Home hero is byte-for-byte unaffected by any of this.
    func testTheFirstCandidateMatchesTheSingleAnswer() async {
        let provider = MultiImageProvider(images: [url("a"), url("b")])
        let single = await provider.artworkURL(.hero, for: query)
        let first = await provider.artworkURLs(.hero, for: query, limit: 2).first
        XCTAssertEqual(single, first)
    }

    /// And the detail page's pick is a different picture from Home's.
    func testTheRunnerUpDiffersFromTheFirst() async {
        let provider = MultiImageProvider(images: [url("a"), url("b")])
        let urls = await provider.artworkURLs(.hero, for: query, limit: 2)
        XCTAssertEqual(urls.dropFirst().first, url("b"))
        XCTAssertNotEqual(urls.first, urls.dropFirst().first)
    }
}
