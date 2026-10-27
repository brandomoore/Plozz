import XCTest
import CoreModels
@testable import MetadataKit

final class MetadataKitTests: XCTestCase {
    private func item(
        kind: MediaItemKind = .series,
        title: String = "Show",
        parentTitle: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        year: Int? = nil,
        genres: [String] = [],
        providerIDs: [String: String] = [:],
        allowsTitleBasedMetadataMatching: Bool = true
    ) -> MediaItem {
        MediaItem(
            id: "1",
            title: title,
            kind: kind,
            parentTitle: parentTitle,
            seasonNumber: season,
            episodeNumber: episode,
            productionYear: year,
            genres: genres,
            providerIDs: providerIDs,
            allowsTitleBasedMetadataMatching: allowsTitleBasedMetadataMatching
        )
    }

    // MARK: - Classification

    func testAnimeDetectedByProviderID() {
        XCTAssertEqual(ContentClassifier.classify(item(providerIDs: ["AniList": "21"])), .anime)
        XCTAssertEqual(ContentClassifier.classify(item(providerIDs: ["AniDB": "999"])), .anime)
        XCTAssertEqual(ContentClassifier.classify(item(providerIDs: ["MAL": "1"])), .anime)
    }

    func testAnimeDetectedByGenre() {
        XCTAssertEqual(ContentClassifier.classify(item(genres: ["Anime", "Action"])), .anime)
    }

    func testMovieAndTVClassification() {
        XCTAssertEqual(ContentClassifier.classify(item(kind: .movie, providerIDs: ["Tmdb": "1"])), .movie)
        XCTAssertEqual(ContentClassifier.classify(item(kind: .series, providerIDs: ["Tmdb": "1"])), .tvShow)
        XCTAssertEqual(ContentClassifier.classify(item(kind: .episode)), .tvShow)
    }

    func testOriginalAudioLanguageHeuristic() {
        // Anime → Japanese original; everything else is unknown (nil) so the
        // prefer-original policy defers to the container default.
        XCTAssertEqual(ContentClassifier.originalAudioLanguage(for: item(providerIDs: ["AniList": "21"])), "ja")
        XCTAssertEqual(ContentClassifier.originalAudioLanguage(for: item(genres: ["Anime"])), "ja")
        XCTAssertNil(ContentClassifier.originalAudioLanguage(for: item(kind: .movie, providerIDs: ["Tmdb": "1"])))
        XCTAssertNil(ContentClassifier.originalAudioLanguage(for: item(kind: .episode)))
    }

    func testSeriesScopedLanguageMemoKeyIsSharedAcrossEpisodes() {
        let first = item(
            kind: .episode,
            season: 1,
            episode: 1,
            providerIDs: ["Tmdb": "episode-1", "SeriesTmdb": "show-42"]
        )
        let second = item(
            kind: .episode,
            season: 1,
            episode: 2,
            providerIDs: ["Tmdb": "episode-2", "SeriesTmdb": "show-42"]
        )

        XCTAssertEqual(
            MetadataQuery(first).seriesScoped.cacheKey(for: .poster),
            MetadataQuery(second).seriesScoped.cacheKey(for: .poster)
        )
    }

    func testSeriesScopedLanguageLookupDropsChildIDsWithoutSeriesIDs() {
        let first = MediaItem(
            id: "episode-1",
            title: "Pilot",
            kind: .episode,
            parentTitle: "Futurama",
            seasonNumber: 1,
            episodeNumber: 1,
            seriesID: "show-futurama",
            providerIDs: ["Tmdb": "episode-tmdb-1"]
        )
        let second = MediaItem(
            id: "episode-2",
            title: "The Series Has Landed",
            kind: .episode,
            parentTitle: "Futurama",
            seasonNumber: 1,
            episodeNumber: 2,
            seriesID: "show-futurama",
            providerIDs: ["Tmdb": "episode-tmdb-2"]
        )
        let query = MetadataQuery(first).seriesScoped

        XCTAssertNil(query.providerIDs.providerID(.tmdb))
        XCTAssertEqual(
            ArtworkRouter.originalLanguageCacheKey(for: first),
            ArtworkRouter.originalLanguageCacheKey(for: second)
        )
    }

    func testContentTypeMapsToSubtitleCategory() {
        XCTAssertEqual(ContentType.anime.subtitleCategory, .anime)
        XCTAssertEqual(ContentType.movie.subtitleCategory, .movie)
        XCTAssertEqual(ContentType.tvShow.subtitleCategory, .tvShow)
        XCTAssertEqual(ContentType.music.subtitleCategory, .other)
        XCTAssertEqual(ContentType.unknown.subtitleCategory, .other)
    }

    func testClassifiedItemResolvesSubtitleCategory() {
        XCTAssertEqual(ContentClassifier.classify(item(providerIDs: ["AniList": "21"])).subtitleCategory, .anime)
        XCTAssertEqual(ContentClassifier.classify(item(kind: .movie)).subtitleCategory, .movie)
        XCTAssertEqual(ContentClassifier.classify(item(kind: .episode)).subtitleCategory, .tvShow)
    }

    func testAnimeIDsExtraction() {
        let ids = AnimeIDs(from: item(providerIDs: ["AniList": "21", "MyAnimeList": "20", "AniDB": "5"]))
        XCTAssertEqual(ids.anilist, 21)
        XCTAssertEqual(ids.mal, 20)
        XCTAssertEqual(ids.anidb, 5)
    }

    func testCurrentArtworkPriorityPreservesEveryExistingChain() {
        let expected: [ContentType: [ArtworkKind: [MetadataSource]]] = [
            .anime: [
                .hero: [.tmdb, .anilist, .kitsu],
                .poster: [.anilist, .kitsu, .tmdb],
                .thumbnail: [.tmdb],
                .logo: [.tmdb, .wikidata, .wikipedia]
            ],
            .tvShow: [
                .hero: [.tmdb, .tvdb, .wikidata, .wikipedia],
                .poster: [.tmdb, .tvmaze, .tvdb, .wikidata, .wikipedia],
                .thumbnail: [.tmdb, .tvmaze],
                .logo: [.tmdb, .wikidata, .wikipedia]
            ],
            .movie: [
                .hero: [.tmdb, .tvdb, .wikidata, .wikipedia],
                .poster: [.tmdb, .tvdb, .wikidata, .wikipedia],
                .thumbnail: [.tmdb],
                .logo: [.tmdb, .wikidata, .wikipedia]
            ],
            .unknown: [
                .hero: [.tmdb, .tvdb, .wikidata, .wikipedia],
                .poster: [.tmdb, .tvdb, .wikidata, .wikipedia],
                .thumbnail: [.tmdb],
                .logo: [.tmdb, .wikidata, .wikipedia]
            ],
            .music: [:]
        ]

        for (type, chains) in expected {
            for kind in [ArtworkKind.hero, .poster, .thumbnail, .logo] {
                XCTAssertEqual(
                    CurrentMetadataPriority.artworkSources(for: type, kind: kind),
                    chains[kind] ?? [],
                    "\(type.rawValue) \(kind.rawValue)"
                )
            }
        }
    }

    func testCurrentOverviewPriorityPreservesExistingRouting() {
        XCTAssertEqual(CurrentMetadataPriority.overviewSources(for: .anime), [.wikipedia])
        XCTAssertEqual(CurrentMetadataPriority.overviewSources(for: .movie), [.wikipedia])
        XCTAssertEqual(CurrentMetadataPriority.overviewSources(for: .tvShow), [.tvmaze])
        XCTAssertEqual(CurrentMetadataPriority.overviewSources(for: .unknown), [.wikipedia])
        XCTAssertEqual(CurrentMetadataPriority.overviewSources(for: .music), [])
    }

    // MARK: - Query normalization

    func testEpisodeQueryUsesSeriesTitleAndNoYear() {
        let q = MetadataQuery(item(kind: .episode, title: "Ep 1", parentTitle: "My Show", season: 1, episode: 1, year: 2020))
        XCTAssertEqual(q.title, "My Show")
        XCTAssertTrue(q.isTV)
        XCTAssertNil(q.year) // TV must not pass an episode air-year into title search
    }

    func testMovieQueryKeepsYear() {
        let q = MetadataQuery(item(kind: .movie, title: "Film", year: 1999, providerIDs: ["Tmdb": "603"]))
        XCTAssertFalse(q.isTV)
        XCTAssertEqual(q.year, 1999)
    }

    func testQuerySuppressesFuzzyTitleButPreservesExactIDs() {
        let query = MetadataQuery(
            item(
                kind: .video,
                title: "Birthday",
                providerIDs: ["Tmdb": "603"],
                allowsTitleBasedMetadataMatching: false
            )
        )

        XCTAssertEqual(query.title, "")
        XCTAssertEqual(query.providerIDs.providerID(.tmdb), "603")
    }

    func testFolderQueryNeverUsesItsTitleAsMetadataIdentity() {
        XCTAssertEqual(
            MetadataQuery(item(kind: .folder, title: "Avatar")).title,
            ""
        )
    }

    // MARK: - Cache keys

    func testCacheKeyPrefersStableID() {
        let anilist = MetadataQuery(item(genres: ["Anime"], providerIDs: ["AniList": "21"]))
        XCTAssertTrue(anilist.cacheKey(for: .hero).contains("anilist:21"))

        let tmdb = MetadataQuery(item(kind: .series, providerIDs: ["Tmdb": "1399"]))
        XCTAssertTrue(tmdb.cacheKey(for: .poster).contains("tmdb:1399"))
    }

    func testThumbnailCacheKeyIncludesEpisode() {
        let q = MetadataQuery(item(kind: .episode, parentTitle: "Show", season: 2, episode: 5, providerIDs: ["SeriesTmdb": "1"]))
        XCTAssertTrue(q.cacheKey(for: .thumbnail).contains("s2e5"))
    }

    func testProviderArtworkCacheKeysPreserveSourceIdentity() {
        let query = MetadataQuery(item(kind: .movie, providerIDs: ["Tmdb": "603"]))
        let tmdb = ArtworkRouter.providerCacheKey(query: query, kind: .hero, source: .tmdb)
        let tvdb = ArtworkRouter.providerCacheKey(query: query, kind: .hero, source: .tvdb)

        XCTAssertNotEqual(tmdb, tvdb)
        XCTAssertTrue(tmdb.hasSuffix("provider:tmdb"))
        XCTAssertTrue(tvdb.hasSuffix("provider:tvdb"))
    }

    func testDetailHeroUsesDistinctCandidateWhenAvailable() {
        let home = URL(string: "https://example.com/home.jpg")!
        let detail = URL(string: "https://example.com/detail.jpg")!
        let candidates = [
            SourcedValue(value: home, source: .tmdb),
            SourcedValue(value: detail, source: .tmdb),
        ]

        XCTAssertEqual(
            ArtworkRouter.heroCandidate(from: candidates, placement: .homeHero),
            home
        )
        XCTAssertEqual(
            ArtworkRouter.heroCandidate(from: candidates, placement: .detailBackdrop),
            detail
        )
    }

    func testDetailHeroUsesOnlyCandidateRatherThanDiscardingOnlineFallback() {
        let only = URL(string: "https://example.com/only.jpg")!
        let candidates = [SourcedValue(value: only, source: .tmdb)]

        XCTAssertEqual(
            ArtworkRouter.heroCandidate(from: candidates, placement: .detailBackdrop),
            only
        )
    }

    // MARK: - TMDb selection

    func testBestImagePrefersNeutralLanguageForHero() {
        let images = [
            TMDbMetadataProvider.Image(file_path: "/en.jpg", iso_639_1: "en", vote_average: 9),
            TMDbMetadataProvider.Image(file_path: "/neutral.jpg", iso_639_1: nil, vote_average: 1)
        ]
        XCTAssertEqual(TMDbMetadataProvider.bestImagePath(images, preferNeutral: true), "/neutral.jpg")
    }

    func testBestLogoIncludesSVGAsPNGAndPrefersEnglish() {
        let logos = [
            TMDbMetadataProvider.Image(file_path: "/foreign.png", iso_639_1: "fr", vote_average: 20),
            TMDbMetadataProvider.Image(file_path: "/neutral.png", iso_639_1: nil, vote_average: 15),
            TMDbMetadataProvider.Image(file_path: "/vector.svg", iso_639_1: "en", vote_average: 10),
            TMDbMetadataProvider.Image(file_path: "/logo.png", iso_639_1: "en", vote_average: 5)
        ]
        XCTAssertEqual(TMDbMetadataProvider.bestLogoPath(logos, preferredLanguage: "en"), "/vector.png")
    }

    func testLogoPrefersAppLanguageThenNeutralThenEnglish() {
        let french = TMDbMetadataProvider.Image(file_path: "/fr.svg", iso_639_1: "fr", vote_average: 1)
        let english = TMDbMetadataProvider.Image(file_path: "/en.png", iso_639_1: "en", vote_average: 10)
        let neutral = TMDbMetadataProvider.Image(file_path: "/neutral.png", iso_639_1: nil, vote_average: 5)
        let german = TMDbMetadataProvider.Image(file_path: "/de.png", iso_639_1: "de", vote_average: 20)
        XCTAssertEqual(TMDbMetadataProvider.bestLogoPath(
            [english, neutral, french, german], preferredLanguage: "fr-CA"
        ), "/fr.png")
        XCTAssertEqual(TMDbMetadataProvider.bestLogoPath(
            [english, neutral, german], preferredLanguage: "fr"
        ), "/neutral.png")
        XCTAssertEqual(TMDbMetadataProvider.bestLogoPath(
            [english, german], preferredLanguage: "fr"
        ), "/en.png")
        XCTAssertEqual(TMDbMetadataProvider.bestLogoPath([german], preferredLanguage: "fr"), "/de.png")
    }

    func testLogoCacheSeparatesLanguagesButKeepsOtherArtworkShared() {
        let query = MetadataQuery(item(kind: .episode, providerIDs: ["SeriesTmdb": "42"]))
        let french = query.forArtworkLanguage("fr-CA")
        let english = query.forArtworkLanguage("en-US")
        XCTAssertNotEqual(french, english)
        XCTAssertEqual(french, query.forArtworkLanguage("fr-FR"))
        XCTAssertEqual(french.seriesScoped.artworkLanguage, "fr")
        XCTAssertEqual(french.offering(episodeHints: [], titleAlternates: []).artworkLanguage, "fr")
        XCTAssertNotEqual(french.cacheKey(for: .logo), english.cacheKey(for: .logo))
        XCTAssertNotEqual(
            ArtworkRouter.providerCacheKey(query: french, kind: .logo, source: .tmdb),
            ArtworkRouter.providerCacheKey(query: english, kind: .logo, source: .tmdb)
        )
        for kind in [ArtworkKind.poster, .hero, .thumbnail] {
            XCTAssertEqual(french.cacheKey(for: kind), english.cacheKey(for: kind))
        }
    }

    func testLogoLookupUsesRequestedLanguage() async {
        let provider = TMDbMetadataProvider(
            access: .proxy(baseURL: URL(string: "https://metadata.example")!),
            imagesRequest: { _, _ in
                .init(backdrops: nil, logos: [
                    .init(file_path: "/fr.svg", iso_639_1: "fr", vote_average: 1),
                    .init(file_path: "/en.png", iso_639_1: "en", vote_average: 10)
                ], posters: nil)
            }
        )
        let query = MetadataQuery(item(kind: .episode, providerIDs: ["SeriesTmdb": "42"]))
        let french = await provider.artworkURL(.logo, for: query.forArtworkLanguage("fr"))
        let english = await provider.artworkURL(.logo, for: query.forArtworkLanguage("en"))
        XCTAssertEqual(french?.lastPathComponent, "fr.png")
        XCTAssertEqual(english?.lastPathComponent, "en.png")
    }

    func testBestLogoKeepsHigherRatedRasterAndStableTies() {
        let logos = [
            TMDbMetadataProvider.Image(file_path: "/first.png", iso_639_1: "en", vote_average: 5),
            TMDbMetadataProvider.Image(file_path: "/second.svg", iso_639_1: "en", vote_average: 5),
            TMDbMetadataProvider.Image(file_path: "/third.svg", iso_639_1: "en", vote_average: 4)
        ]
        XCTAssertEqual(TMDbMetadataProvider.bestLogoPath(logos), "/first.png")
    }

    func testBestLogoHandlesMissingImagesAndUppercaseSVGExtension() {
        XCTAssertNil(TMDbMetadataProvider.bestLogoPath(nil))
        XCTAssertNil(TMDbMetadataProvider.bestLogoPath([]))
        let logos = [
            TMDbMetadataProvider.Image(file_path: nil, iso_639_1: "en", vote_average: 10),
            TMDbMetadataProvider.Image(file_path: "", iso_639_1: "en", vote_average: 10),
            TMDbMetadataProvider.Image(file_path: "/CaseSensitive.SVG", iso_639_1: nil, vote_average: nil)
        ]
        XCTAssertEqual(TMDbMetadataProvider.bestLogoPath(logos), "/CaseSensitive.png")
    }

    func testSavingPrivateRyanRankingCanSelectOriginalWhiteArtwork() {
        // Representative TMDb metadata: the white SVG outranks the dark flag PNG.
        let logos = [
            TMDbMetadataProvider.Image(
                file_path: "/vLkIhkELQkSEzprWGLss5egANUq.svg", iso_639_1: "en", vote_average: 3.334
            ),
            TMDbMetadataProvider.Image(
                file_path: "/emQLFPKLJJZn7cJZveKcV0jPGaB.png", iso_639_1: "en", vote_average: 0.5
            )
        ]
        XCTAssertEqual(
            TMDbMetadataProvider.bestLogoPath(logos),
            "/vLkIhkELQkSEzprWGLss5egANUq.png"
        )
    }

    func testSVGLogoResolutionUsesOneImagesRequestAndOneNormalSizedPNG() async {
        for kind in [MediaItemKind.movie, .series] {
            let requests = LogoImagesRequests()
            let provider = TMDbMetadataProvider(
                access: .proxy(baseURL: URL(string: "https://metadata.example")!),
                imagesRequest: { url, _ in
                    await requests.record(url)
                    return .init(backdrops: nil, logos: [
                        .init(file_path: "/white.svg", iso_639_1: "en", vote_average: 10),
                        .init(file_path: "/dark.png", iso_639_1: "en", vote_average: 5)
                    ], posters: nil)
                }
            )
            let query = MetadataQuery(item(kind: kind, providerIDs: ["Tmdb": "857"]))
            let urls = await provider.artworkURLs(.logo, for: query, limit: 5)
            XCTAssertEqual(urls.map(\.absoluteString), ["https://image.tmdb.org/t/p/w500/white.png"])
            let recorded = await requests.urls
            XCTAssertEqual(recorded.map(\.absoluteString), [
                "https://metadata.example/3/\(kind == .movie ? "movie" : "tv")/857/images"
            ])
        }
    }

    func testMissingLogoDoesNotRequestAlternateImages() async {
        let requests = LogoImagesRequests()
        let provider = TMDbMetadataProvider(
            access: .proxy(baseURL: URL(string: "https://metadata.example")!),
            imagesRequest: { url, _ in
                await requests.record(url)
                return nil
            }
        )
        let urls = await provider.artworkURLs(
            .logo, for: MetadataQuery(item(providerIDs: ["Tmdb": "857"])), limit: 5
        )
        XCTAssertTrue(urls.isEmpty)
        let count = await requests.urls.count
        XCTAssertEqual(count, 1)
    }

    func testDisabledOrZeroLimitLogoLookupDoesNotRequestImages() async {
        let requests = LogoImagesRequests()
        let query = MetadataQuery(item(providerIDs: ["Tmdb": "857"]))
        for access in [TMDbAccess.disabled, .proxy(baseURL: URL(string: "https://metadata.example")!)] {
            let provider = TMDbMetadataProvider(access: access, imagesRequest: { url, _ in
                await requests.record(url)
                return nil
            })
            let urls = await provider.artworkURLs(.logo, for: query, limit: access.isEnabled ? 0 : 5)
            XCTAssertTrue(urls.isEmpty)
        }
        let count = await requests.urls.count
        XCTAssertEqual(count, 0)
    }

    private actor LogoImagesRequests {
        private(set) var urls: [URL] = []

        func record(_ url: URL) {
            urls.append(url)
        }
    }

    // MARK: - Config

    func testAccessEnablement() {
        let proxy = TMDbAccess.proxy(baseURL: URL(string: "https://proxy.example")!)
        XCTAssertTrue(proxy.isEnabled)
        XCTAssertTrue(TMDbAccess.directToken("abc").isEnabled)
        XCTAssertFalse(TMDbAccess.disabled.isEnabled)
    }
}
