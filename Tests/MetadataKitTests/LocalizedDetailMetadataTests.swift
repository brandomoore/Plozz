import CoreModels
import XCTest
@testable import MetadataKit

final class LocalizedDetailMetadataTests: XCTestCase {
    func testWikipediaFollowsMatchedArticleLanguageLinkAndScript() async throws {
        for (language, edition, variant) in [
            ("fr-CA", "fr", ""), ("nb-NO", "no", ""),
            ("zh-Hant", "zh", "zh-hant"), ("sr-Latn", "sr", "sr-el")
        ] {
            let fixture = TMDbTVDBDiscoveryFixture { request, _ in
                let query = TMDbTVDBDiscoveryFixture.query(request)
                if request.url?.host == "en.wikipedia.org" {
                    XCTAssertEqual(query["lllang"], edition)
                    return .init(json: """
                    {"query":{"pages":{"1":{"extract":"English","langlinks":[{"lang":"\(edition)","*":"Matched title"}]}}}}
                    """)
                }
                XCTAssertEqual(request.url?.host, "\(edition).wikipedia.org")
                XCTAssertEqual(query["titles"], "Matched title")
                XCTAssertEqual(query["variant"] ?? "", variant)
                return .init(json: #"{"query":{"pages":{"2":{"extract":"Localized synopsis"}}}}"#)
            }
            let result = await WikipediaEnrichmentProvider(http: fixture.http).enrich(
                MetadataQuery(MediaItem(id: "m", title: "Movie", kind: .movie))
                    .forMetadataLanguage(language),
                missing: [.overview]
            )
            XCTAssertEqual(result.overview?.value, "Localized synopsis")
            let requests = await fixture.recorded()
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testTVDBRequestsSelectedLanguage() async {
        let codes = [
            "en": "eng", "ar": "ara", "bg": "bul", "ca": "cat", "cs": "ces", "da": "dan",
            "de": "deu", "el": "ell", "es": "spa", "fa": "fas", "fi": "fin", "fr": "fra",
            "he": "heb", "hi": "hin", "hr": "hrv", "hu": "hun", "id": "ind", "it": "ita",
            "ja": "jpn", "ko": "kor", "ms": "msa", "nb": "nor", "nl": "nld", "pl": "pol",
            "pt-BR": "por", "ro": "ron", "ru": "rus", "sk": "slk", "sl": "slv", "sr-Latn": "srp",
            "sv": "swe", "th": "tha", "tr": "tur", "uk": "ukr", "vi": "vie",
            "zh-Hans": "zho", "zh-Hant": "zho", "fr-CA": "fra"
        ]
        for language in AppLanguage.releaseReady + ["en", "fr-CA"] {
            guard let code = codes[language] else {
                XCTFail("Missing request expectation for supported language \(language)")
                continue
            }
            let fixture = TMDbTVDBDiscoveryFixture { request, _ in
                if request.url?.lastPathComponent == "login" {
                    return TMDbTVDBDiscoveryFixture.tvdbReply(request)
                }
                XCTAssertEqual(request.url?.path, "/v4/series/42/translations/\(code)")
                return .init(json: """
                {"data":{"name":"Localized title","overview":"Localized overview","language":"\(code)"}}
                """)
            }
            let client = TVDBClient(config: .init(apiKey: "fixture", apiBaseURL: URL(string: "https://tvdb.example/v4")!),
                                    http: fixture.http)
            let text = await client.translatedText(id: "42", isMovie: false, language: language)
            XCTAssertEqual(text?.title, "Localized title")
            XCTAssertEqual(text?.overview, "Localized overview")
        }
    }

    func testTVDBRejectsWrongLanguageInsteadOfBeatingLocalizedFallbacks() async {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            if request.url?.lastPathComponent == "login" {
                return TMDbTVDBDiscoveryFixture.tvdbReply(request)
            }
            return .init(json: #"{"data":{"name":"English title","language":"eng"}}"#)
        }
        let client = TVDBClient(
            config: .init(apiKey: "fixture", apiBaseURL: URL(string: "https://tvdb.example/v4")!),
            http: fixture.http
        )
        let text = await client.translatedText(id: "42", isMovie: true, language: "fr")
        XCTAssertNil(text)
    }

    func testBiographyLocalizesOnlyTheValidatedPersonAndFallsBackWhenAbsent() async {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            if request.url?.host == "fr.wikipedia.org" {
                XCTAssertEqual(TMDbTVDBDiscoveryFixture.query(request)["titles"], "Tom Hanks FR")
                return .init(json: #"{"query":{"pages":{"2":{"extract":"Biographie FR"}}}}"#)
            }
            return .init(json: """
            {"query":{"pages":[
                {"title":"Tom Hanks (historian)","description":"Historian","extract":"Wrong person","index":1},
                {"title":"Tom Hanks","description":"American actor","extract":"English biography","index":2,
                 "langlinks":[{"lang":"fr","title":"Tom Hanks FR"}]}
            ]}}
            """)
        }
        let provider = WikipediaPersonBiographyProvider(http: fixture.http)
        let french = await provider.biography(for: "Tom Hanks", role: "Actor", language: "fr")
        let german = await provider.biography(for: "Tom Hanks", role: "Actor", language: "de")
        XCTAssertEqual(french, "Biographie FR")
        XCTAssertEqual(german, "English biography")
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 3)
    }

    func testReleaseAliasLookupKeepsFrenchDetailAndRejectsWrongYear() async throws {
        for year in [2001, 2002] {
            let fixture = TMDbTVDBDiscoveryFixture { request, _ in
                let language = TMDbTVDBDiscoveryFixture.query(request)["language"]
                if request.url?.path == "/3/search/movie" {
                    let title = language == "en" ? "Spirited Away" : "Le voyage de Chihiro"
                    return .init(json: """
                    {"results":[{"id":129,"title":"\(title)","original_title":"Sen to Chihiro no kamikakushi","release_date":"\(year)-07-20"}]}
                    """)
                }
                XCTAssertEqual(language, "fr")
                XCTAssertEqual(request.url?.path, "/3/movie/129")
                return .init(json: #"{"overview":"Description FR"}"#)
            }
            let provider = TMDbMetadataProvider(access: .directToken("fixture"), detailHTTP: fixture.http)
            let item = MediaItem(id: "movie", title: "Spirited Away", kind: .movie, productionYear: 2001)
            let result = try await provider.detailMetadata(
                for: MetadataQuery(item).forMetadataLanguage("fr"), missing: [.overview]
            )
            XCTAssertEqual(result.overview?.value, year == 2001 ? "Description FR" : nil)
            let requests = await fixture.recorded()
            XCTAssertEqual(requests.count, year == 2001 ? 3 : 2)
        }
    }

    func testMissingWikipediaTranslationFallsBackAndArtworkStaysIdle() async {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            XCTAssertEqual(request.url?.host, "en.wikipedia.org")
            return .init(json: #"{"query":{"pages":{"1":{"extract":"English synopsis"}}}}"#)
        }
        let provider = WikipediaEnrichmentProvider(http: fixture.http)
        let wrapped = ResilientEnrichmentProvider(
            base: provider, breaker: ProviderCircuitBreaker(), cache: ProviderResultCache()
        )
        XCTAssertFalse(wrapped.supports(.posterURL, at: .foregroundFill))
        XCTAssertTrue(wrapped.supports(.posterURL, at: .idleBacklog))
        let pipeline = MetadataEnrichmentPipeline(providers: [wrapped], config: .init(order: [.wikipedia]))
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        for language in ["fr", "en"] {
            let result = await pipeline.enrich(
                MetadataQuery(item).forMetadataLanguage(language),
                requesting: [.overview, .posterURL], tier: .foregroundFill
            )
            XCTAssertEqual(result.overview?.value, "English synopsis")
            XCTAssertNil(result.posterURL)
        }
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 2, "The English fallback is shared, not the French lookup.")
    }

    func testLocalizedSearchStillMatchesAnExactOriginalMovieOrSeriesTitle() async throws {
        for kind: MediaItemKind in [.movie, .series] {
            let type = kind == .movie ? "movie" : "tv"
            let titleKey = kind == .movie ? "title" : "name"
            let dateKey = kind == .movie ? "release_date" : "first_air_date"
            let fixture = TMDbTVDBDiscoveryFixture { request, _ in
                XCTAssertEqual(TMDbTVDBDiscoveryFixture.query(request)["language"], "fr")
                if request.url?.path == "/3/search/\(type)" {
                    return .init(json: """
                    {"results":[
                        {"id":1,"\(titleKey)":"Unrelated","original_\(titleKey)":"Unrelated"},
                        {"id":2,"\(titleKey)":"Titre FR","original_\(titleKey)":"Original title","\(dateKey)":"2020-01-01"}
                    ]}
                    """)
                }
                XCTAssertEqual(request.url?.path, "/3/\(type)/2")
                return .init(json: #"{"overview":"Description FR"}"#)
            }
            let provider = TMDbMetadataProvider(access: .directToken("fixture"), detailHTTP: fixture.http)
            let item = MediaItem(id: "item", title: "Original title", kind: kind, productionYear: 2020)
            let result = try await provider.detailMetadata(
                for: MetadataQuery(item).forMetadataLanguage("fr"), missing: [.overview]
            )
            XCTAssertEqual(result.overview?.value, "Description FR")
            let requests = await fixture.recorded()
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testEpisodeRequestsAndCachesKeepLanguagesAndEpisodesSeparate() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            let url = try XCTUnwrap(request.url)
            let language = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "language" })?.value)
            XCTAssertTrue(["fr", "en"].contains(language))
            if url.path == "/3/tv/123" {
                return .init(json: """
                {"genres":[{"name":"Genre \(language)"}],"overview":"Wrong series overview"}
                """)
            }
            XCTAssertTrue(["/3/tv/123/season/1/episode/34", "/3/tv/123/season/1/episode/36"].contains(url.path))
            return .init(json: """
            {"overview":"Episode \(url.lastPathComponent) \(language)"}
            """)
        }
        let provider = TMDbEnrichmentProvider(provider: TMDbMetadataProvider(
            access: .directToken("fixture"), detailHTTP: fixture.http
        ))
        let pipeline = MetadataEnrichmentPipeline(
            providers: [CachedEnrichmentProvider(base: provider, cache: ProviderResultCache())],
            config: .init(order: [.tmdb])
        )
        for (number, language) in [(34, "fr"), (34, "en"), (36, "fr"), (34, "fr")] {
            let item = episode(number)
            let result = await pipeline.enrich(
                DetailMetadataResolver.metadataQuery(for: item).forMetadataLanguage(language),
                requesting: [.overview, .genres], tier: .foregroundFill
            )
            XCTAssertEqual(result.overview?.value, "Episode \(number) \(language)")
            XCTAssertEqual(result.genres?.value, ["Genre \(language)"])
            XCTAssertEqual(result.overview?.source, .tmdb)
        }
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 6, "Only the identical episode/language request may reuse the cache.")
    }

    func testFrenchSkipsEnglishTextWithoutDisablingOtherProviderCapabilities() async {
        let poster = URL(string: "https://example.com/poster.jpg")!
        let english = FakeEnrichmentProvider(
            id: .tvmaze, capabilities: [.canonicalText, .poster],
            output: .init(
                overview: .init(value: "English overview", source: .tvdb),
                genres: .init(value: ["English genre"], source: .tvdb),
                posterURL: .init(value: poster, source: .tvdb)
            )
        )
        let french = FakeEnrichmentProvider(
            id: .tmdb, capabilities: [.canonicalText],
            output: .init(
                overview: .init(value: "Description FR", source: .tmdb),
                genres: .init(value: ["Genre FR"], source: .tmdb)
            )
        )
        let pipeline = MetadataEnrichmentPipeline(
            providers: [english, french],
            config: .init(order: [.tvmaze, .tmdb], priority: .init(rules: []))
        )
        let query = MetadataQuery(MediaItem(id: "movie", title: "Movie", kind: .movie))
        let result = await pipeline.enrich(
            query.forMetadataLanguage("fr_FR"), requesting: [.overview, .genres, .posterURL],
            tier: .foregroundFill
        )
        XCTAssertEqual(result.overview?.value, "Description FR")
        XCTAssertEqual(result.genres?.value, ["Genre FR"])
        XCTAssertEqual(result.posterURL?.value, poster)
        XCTAssertEqual(english.calls.first?.missing, [.posterURL])
        let untranslated = await MetadataEnrichmentPipeline(
            providers: [english], config: .init(order: [.tvmaze])
        ).enrich(query.forMetadataLanguage("fr"), requesting: [.overview, .genres], tier: .foregroundFill)
        XCTAssertEqual(untranslated.overview?.value, "English overview")
        XCTAssertEqual(untranslated.genres?.value, ["English genre"])
        let original = await pipeline.enrich(query, requesting: [.overview], tier: .foregroundFill)
        XCTAssertEqual(original.overview?.value, "English overview", "English keeps its configured fallback.")
    }

    func testNativeFrenchTextAndIdentityRemainAuthoritative() {
        var item = episode(34)
        item.title = "Titre FR"
        item.overview = "Description FR"
        item.genres = ["Genre FR"]
        item.sourceAccountID = "jellyfin"
        let result = DetailMetadataResolver.applying(.init(
            title: .init(value: "English title", source: .tmdb),
            overview: .init(value: "English overview", source: .tmdb),
            genres: .init(value: ["English genre"], source: .tmdb)
        ), to: item)
        XCTAssertEqual(result, item)
        XCTAssertFalse(DetailMetadataResolver.missingFields(in: item).contains(.overview))
        item.overview = " \n "
        let filled = DetailMetadataResolver.applying(
            .init(overview: .init(value: "Description FR", source: .tmdb)), to: item
        )
        XCTAssertEqual(filled.overview, "Description FR")
        XCTAssertEqual(filled.metadataProvenance[.overview]?.source, .tmdb)
        XCTAssertEqual(filled.id, item.id)
        XCTAssertEqual(filled.providerIDs, item.providerIDs)
        XCTAssertEqual(filled.sourceAccountID, item.sourceAccountID)
    }

    func testExternalDetailMissingTextUsesRequestedLanguage() async {
        let provider = FakeEnrichmentProvider(
            id: .tmdb, capabilities: [.canonicalText],
            output: .init(overview: .init(value: "Description FR", source: .tmdb))
        )
        let resolver = ExternalTitleMetadataResolver(pipeline: .init(
            providers: [provider], config: .init(order: [.tmdb])
        ))
        let item = MediaItem(id: "external", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "123"])
        let result = await resolver.resolve(item: item, regionCode: "US", language: "fr")
        XCTAssertEqual(result.enrichment.overview?.value, "Description FR")
        XCTAssertFalse(provider.calls.isEmpty)
        XCTAssertEqual(provider.calls.first?.query.metadataLanguage, "fr")
        XCTAssertTrue(provider.calls.filter { $0.query.metadataLanguage == "en" }
            .allSatisfy { !$0.missing.contains(.overview) })
    }

    func testQueryCopiesPreserveLanguageAndLanguageIsPartOfIdentity() {
        let query = MetadataQuery(episode(34))
            .forArtworkLanguage("fr").forMetadataLanguage("fr-CA")
        for copy in [
            query.seriesScoped, query.mergingProviderIDs(["Imdb": "tt1234567"]),
            query.offering(titleAlternates: ["Alternate"])
        ] {
            XCTAssertEqual(copy.metadataLanguage, "fr-CA")
            XCTAssertEqual(copy.artworkLanguage, "fr")
        }
        let english = query.forMetadataLanguage("en")
        XCTAssertNotEqual(query, english)
        XCTAssertNotEqual(query.enrichmentCacheKey, english.enrichmentCacheKey)
        XCTAssertEqual(Set([query, english]).count, 2)
    }

    func testEpisodeNeverUsesAnUnscopedSeriesOverview() async {
        let series = FakeEnrichmentProvider(
            id: .tvdb, capabilities: [.canonicalText],
            output: .init(overview: .init(value: "Series overview", source: .tvdb))
        )
        let result = await MetadataEnrichmentPipeline(
            providers: [series], config: .init(order: [.tvdb])
        ).enrich(MetadataQuery(episode(34)), requesting: [.overview], tier: .foregroundFill)
        XCTAssertNil(result.overview)
        XCTAssertEqual(series.callCount, 0)
    }

    private func episode(_ number: Int) -> MediaItem {
        MediaItem(
            id: "episode-\(number)", title: "Episode \(number)", kind: .episode,
            parentTitle: "Show", seasonNumber: 1, episodeNumber: number,
            seriesID: "show", providerIDs: ["SeriesTmdb": "123"]
        )
    }
}
