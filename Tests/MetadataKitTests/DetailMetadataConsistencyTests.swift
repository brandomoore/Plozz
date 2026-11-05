import CoreModels
import XCTest
@testable import MetadataKit

final class DetailMetadataConsistencyTests: XCTestCase {
    private let titleFactFields: Set<MetadataField> = [
        .originalLanguage, .seriesStatus, .catalogSeasonCount, .catalogEpisodeCount
    ]

    func testTitleFactsUseOneIdentityCheckedDetailRequest() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            XCTAssertEqual(request.url?.path, "/3/tv/1408")
            return .init(json: """
            {"original_language":"en","status":"Ended","number_of_seasons":8,"number_of_episodes":177}
            """)
        }
        let provider = TMDbEnrichmentProvider(provider: TMDbMetadataProvider(
            access: .directToken("test-token"), detailHTTP: fixture.http
        ))
        let cache = ProviderResultCache()
        let pipeline = MetadataEnrichmentPipeline(
            providers: [CachedEnrichmentProvider(base: provider, cache: cache)],
            config: .init(order: [.tmdb])
        )
        let item = MediaItem(id: "show", title: "House", kind: .series, providerIDs: ["Tmdb": "1408"])
        for _ in 0..<2 {
            let result = await pipeline.enrich(
                MetadataQuery(item), requesting: titleFactFields, tier: .foregroundFill
            )
            XCTAssertEqual(result.originalLanguage?.value, "en")
            XCTAssertEqual(result.seriesStatus?.value, .ended)
            XCTAssertEqual(result.catalogSeasonCount?.value, 8)
            XCTAssertEqual(result.catalogEpisodeCount?.value, 177)
            XCTAssertEqual(result.filledFields, titleFactFields)
            let enriched = DetailMetadataResolver.applying(result, to: item)
            XCTAssertEqual(enriched.catalogEpisodeCount, 177)
            XCTAssertEqual(enriched.metadataProvenance[.seriesStatus]?.source, .tmdb)
            XCTAssertEqual(enriched.metadataProvenance[.originalLanguage]?.sourceURL?.path, "/3/tv/1408")
            XCTAssertEqual(enriched.providerIDs, item.providerIDs)
        }
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 1, "The existing facts request and cache must serve all four fields.")
    }

    func testDiscoverRequestsTheSameTitleFactsAndPreservesKnownValues() async {
        let enrichment = MetadataEnrichment(
            originalLanguage: .init(value: "fr", source: .tmdb),
            seriesStatus: .init(value: .returning, source: .tmdb),
            catalogSeasonCount: .init(value: 4, source: .tmdb),
            catalogEpisodeCount: .init(value: 30, source: .tmdb)
        )
        let provider = FakeEnrichmentProvider(id: .tmdb, capabilities: [.canonicalText], output: enrichment)
        let resolver = ExternalTitleMetadataResolver(pipeline: .init(
            providers: [provider], config: .init(order: [.tmdb])
        ))
        let item = MediaItem(
            id: "external", title: "Series", originalLanguage: "en", seriesStatus: .ended,
            kind: .series, providerIDs: ["Tmdb": "123"]
        )
        let result = await resolver.resolve(item: item, regionCode: "US")
        XCTAssertEqual(result.enrichment.catalogSeasonCount?.value, 4)
        XCTAssertEqual(result.enrichment.catalogEpisodeCount?.value, 30)
        XCTAssertNil(result.enrichment.originalLanguage)
        XCTAssertNil(result.enrichment.seriesStatus)
        let applied = DetailMetadataResolver.applying(result.enrichment, to: item)
        XCTAssertEqual(applied.originalLanguage, "en")
        XCTAssertEqual(applied.seriesStatus, .ended)
        XCTAssertEqual(applied.catalogEpisodeCount, 30)
    }

    func testUnknownFactsDoNotInventStatusLanguageOrCatalogSize() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in
            .init(json: #"{"original_language":"xx","status":"In Production","number_of_seasons":0,"number_of_episodes":-1}"#)
        }
        let provider = TMDbMetadataProvider(access: .directToken("test-token"), detailHTTP: fixture.http)
        let item = MediaItem(id: "series", title: "Series", kind: .series, providerIDs: ["Tmdb": "1"])
        let result = try await provider.detailMetadata(for: MetadataQuery(item), missing: titleFactFields)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(MediaSeriesStatus(providerValue: "Returning Series"), .returning)
        XCTAssertEqual(MediaSeriesStatus(providerValue: " Continuing "), .returning)
        XCTAssertEqual(MediaSeriesStatus(providerValue: "Ended"), .ended)
        XCTAssertEqual(MediaSeriesStatus(providerValue: "Cancelled"), .canceled)
        XCTAssertEqual(MediaSeriesStatus(providerValue: "Canceled"), .canceled)
        XCTAssertNil(MediaSeriesStatus(providerValue: "Unknown"))
        XCTAssertNil(MediaSeriesStatus(providerValue: ""))
    }

    func testTitleFactsNeverLeakOntoChildrenOrPersonalVideos() async throws {
        let enrichment = MetadataEnrichment(
            originalLanguage: .init(value: "en", source: .tmdb),
            seriesStatus: .init(value: .ended, source: .tmdb),
            catalogSeasonCount: .init(value: 8, source: .tmdb),
            catalogEpisodeCount: .init(value: 177, source: .tmdb)
        )
        for kind: MediaItemKind in [.movie, .series, .season, .episode, .video] {
            let item = MediaItem(id: "item", title: "Title", kind: kind, unwatchedEpisodeCount: 9)
            let missing = DetailMetadataResolver.missingFields(in: item)
            XCTAssertEqual(missing.contains(.originalLanguage), kind == .movie || kind == .series)
            XCTAssertEqual(missing.contains(.catalogEpisodeCount), kind == .series)
            let applied = DetailMetadataResolver.applying(enrichment, to: item)
            XCTAssertEqual(applied.catalogEpisodeCount, kind == .series ? 177 : nil)
            XCTAssertEqual(applied.unwatchedEpisodeCount, 9)
        }
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in
            .init(json: #"{"original_language":"en","status":"Ended","number_of_seasons":8,"number_of_episodes":177}"#)
        }
        let provider = TMDbMetadataProvider(access: .directToken("test-token"), detailHTTP: fixture.http)
        let movie = MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "1"])
        let result = try await provider.detailMetadata(for: MetadataQuery(movie), missing: titleFactFields)
        XCTAssertEqual(result.originalLanguage?.value, "en")
        XCTAssertNil(result.seriesStatus)
        XCTAssertNil(result.catalogSeasonCount)
        XCTAssertNil(result.catalogEpisodeCount)
    }

    func testTitleMatchingOptOutStillPermitsOnlyExplicitIdentityFacts() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            XCTAssertEqual(request.url?.path, "/3/tv/1408")
            return .init(json: #"{"status":"Ended","original_language":"en"}"#)
        }
        let provider = TMDbMetadataProvider(access: .directToken("test-token"), detailHTTP: fixture.http)
        var item = MediaItem(
            id: "series", title: "Do not search this title", kind: .series,
            allowsTitleBasedMetadataMatching: false
        )
        let noMatch = try await provider.detailMetadata(
            for: DetailMetadataResolver.metadataQuery(for: item), missing: titleFactFields
        )
        XCTAssertTrue(noMatch.isEmpty)
        item.providerIDs = ["Tmdb": "1408"]
        let query = DetailMetadataResolver.metadataQuery(for: item)
        XCTAssertEqual(query.title, "")
        let matched = try await provider.detailMetadata(for: query, missing: titleFactFields)
        XCTAssertEqual(DetailMetadataResolver.applying(matched, to: item).seriesStatus, .ended)
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 1)
    }

    func testTitleFactsRoundTripAndRespectGapOnlyMerging() throws {
        var first = MetadataEnrichment(
            originalLanguage: .init(value: "fr", source: .server),
            seriesStatus: .init(value: .ended, source: .server),
            catalogSeasonCount: .init(value: 3, source: .server)
        )
        let incoming = MetadataEnrichment(
            originalLanguage: .init(value: "en", source: .tmdb),
            seriesStatus: .init(value: .returning, source: .tmdb),
            catalogSeasonCount: .init(value: 4, source: .tmdb),
            catalogEpisodeCount: .init(value: 20, source: .tmdb)
        )
        first.fillMissing(from: incoming, skipping: [.catalogEpisodeCount])
        XCTAssertNil(first.catalogEpisodeCount)
        first.fillMissing(from: incoming)
        let restored = try JSONDecoder().decode(MetadataEnrichment.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(restored, first)
        XCTAssertEqual(restored.originalLanguage?.value, "fr")
        XCTAssertEqual(restored.seriesStatus?.value, .ended)
        XCTAssertEqual(restored.catalogSeasonCount?.value, 3)
        XCTAssertEqual(restored.catalogEpisodeCount?.value, 20)
        let item = DetailMetadataResolver.applying(restored, to: .init(id: "series", title: "Series", kind: .series))
        XCTAssertEqual(DetailMetadataResolver.applying(incoming, to: item), item)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item)), item)
        let oldItem = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"id":"old","title":"Old","kind":"series"}"#.utf8))
        XCTAssertNil(oldItem.originalLanguage)
        XCTAssertNil(oldItem.seriesStatus)
        XCTAssertNil(oldItem.catalogSeasonCount)
        XCTAssertNil(oldItem.catalogEpisodeCount)
    }

    func testConflictingCachedTitleMatchCannotRedirectAuthoritativeIMDbCredits() async throws {
        try await verifyConflictingCachedTitleMatch(seedDownstreamCache: false)
    }

    func testAddedAuthoritativeIdentityCannotReuseEarlierWrongTMDbCredits() async throws {
        try await verifyConflictingCachedTitleMatch(seedDownstreamCache: true)
    }

    private func verifyConflictingCachedTitleMatch(seedDownstreamCache: Bool) async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            switch request.url!.path {
            case "/3/find/tt0111161":
                return .init(json: #"{"movie_results":[{"id":278}],"tv_results":[]}"#)
            case "/3/movie/278/credits":
                return .init(json: #"{"cast":[],"crew":[{"id":1,"name":"Correct director","job":"Director"}]}"#)
            case "/3/movie/278":
                return .init(json: #"{"genres":[{"name":"Drama"}]}"#)
            case "/3/movie/13/credits":
                return .init(json: #"{"cast":[],"crew":[{"id":2,"name":"Wrong director","job":"Director"}]}"#)
            case "/3/movie/13":
                return .init(json: #"{"genres":[{"name":"Wrong genre"}]}"#)
            default:
                XCTFail("Unexpected request: \(request.url!.path)")
                return .init(json: "{}", status: 404)
            }
        }
        let wrongMatch = FakeEnrichmentProvider(
            id: .tvdb, capabilities: [.canonicalText, .externalIDs],
            output: MetadataEnrichment(
                externalIDs: [
                    "Imdb": .init(value: "tt0109830", source: .tvdb),
                    "Tmdb": .init(value: "13", source: .tvdb)
                ],
                genres: seedDownstreamCache ? nil : .init(value: ["Wrong genre"], source: .tvdb)
            )
        )
        let cache = ProviderResultCache()
        let pipeline = MetadataEnrichmentPipeline(
            providers: [
                CachedEnrichmentProvider(base: wrongMatch, cache: cache),
                CachedEnrichmentProvider(
                    base: TMDbEnrichmentProvider(provider: TMDbMetadataProvider(
                        access: .directToken("test-token"), detailHTTP: fixture.http
                    )),
                    cache: cache
                )
            ],
            config: MetadataEnrichmentConfig(order: [.tvdb, .tmdb], priority: MetadataPriorityPolicy(rules: []))
        )
        var ids = seedDownstreamCache ? ["AniList": "1"] : [:]
        if seedDownstreamCache {
            let earlierQuery = MetadataQuery(MediaItem(
                id: "movie", title: "A curated title", kind: .movie, providerIDs: ids
            ))
            let earlier = await pipeline.enrich(
                earlierQuery, requesting: [.genres, .directors], tier: .foregroundFill
            )
            XCTAssertEqual(earlier.directors?.value.first?.name, "Wrong director")
        }
        ids["IMDb ID"] = "tt0111161"
        let query = DetailMetadataResolver.metadataQuery(for: MediaItem(
            id: "movie", title: "A curated title", kind: .movie,
            providerIDs: ids
        ))
        for _ in 0..<2 {
            let result = await pipeline.enrich(query, requesting: [.genres, .directors], tier: .foregroundFill)
            XCTAssertEqual(result.directors?.value.first?.name, "Correct director")
            XCTAssertEqual(result.genres?.value, ["Drama"])
            XCTAssertNotEqual(result.externalIDs["Tmdb"]?.value, "13")
        }
        XCTAssertEqual(wrongMatch.callCount, seedDownstreamCache ? 2 : 1,
                       "Each distinct identity context must be fetched once, then exercise its cached response.")
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.filter { $0.url?.path == "/3/movie/13/credits" }.count, seedDownstreamCache ? 1 : 0)
    }

    func testChildMetadataUsesOnlyShowIDsWithoutLosingCreditScope() {
        let item = MediaItem(
            id: "episode", title: "Episode title", kind: .episode, parentTitle: "Show",
            seasonNumber: 2, episodeNumber: 3,
            providerIDs: ["Tmdb": "11", "Tvdb": "22", "SeriesTmdb": "111", "SeriesTvdb": "222"]
        )
        let query = DetailMetadataResolver.metadataQuery(for: item)
        XCTAssertEqual(query.providerIDs.providerID(.tmdb), "111")
        XCTAssertEqual(query.providerIDs.providerID(.tvdb), "222")
        XCTAssertEqual(query.kind, .episode)
        XCTAssertEqual(query.seasonNumber, 2)
        XCTAssertEqual(query.episodeNumber, 3)
        XCTAssertEqual(query.title, "Show")
    }

    func testUnidentifiedChildDoesNotSearchItsEpisodeTitleAsAShow() async throws {
        let item = MediaItem(
            id: "episode", title: "Pilot", kind: .episode,
            seasonNumber: 1, episodeNumber: 1, providerIDs: ["Tmdb": "123"]
        )
        let query = DetailMetadataResolver.metadataQuery(for: item)
        XCTAssertNil(query.providerIDs.providerID(.tmdb))
        XCTAssertEqual(query.title, "")
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in
            XCTFail("An episode title and episode ID cannot identify its series")
            return .init(json: "{}")
        }
        let provider = TMDbMetadataProvider(access: .directToken("test-token"), detailHTTP: fixture.http)
        let result = try await provider.detailMetadata(for: query, missing: [.cast, .genres])
        XCTAssertTrue(result.isEmpty)
    }

    func testCastAPIHonorsCallerLimitAboveDefault() async {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in
            let cast = (1...50).map { #"{"id":\#($0),"name":"Actor \#($0)"}"# }.joined(separator: ",")
            return .init(json: #"{"cast":[\#(cast)]}"#)
        }
        let provider = TMDbMetadataProvider(access: .directToken("test-token"), detailHTTP: fixture.http)
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "123"])
        let cast = await provider.cast(for: MetadataQuery(item), limit: 45)
        XCTAssertEqual(cast.count, 45)
    }

    func testFullEpisodeRequestUsesSeriesIdentityAndOnlyItsOwnCredits() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            switch request.url!.path {
            case "/3/tv/1399/season/2/episode/3/credits":
                return .init(json: #"{"cast":[{"id":1,"name":"Actor"}],"crew":[{"id":2,"name":"Episode director","job":"Director"}]}"#)
            case "/3/tv/1399":
                return .init(json: #"{"genres":[{"name":"Drama"}],"production_companies":[{"name":"Studio"}],"overview":"Show plot"}"#)
            case "/3/tv/1399/season/2/episode/3":
                return .init(json: #"{"overview":"Episode plot"}"#)
            default:
                XCTFail("Unexpected request: \(request.url!.path)")
                return .init(json: "{}", status: 404)
            }
        }
        let provider = TMDbMetadataProvider(access: .directToken("test-token"), detailHTTP: fixture.http)
        let item = MediaItem(
            id: "episode", title: "Episode", kind: .episode, parentTitle: "Curated show",
            seasonNumber: 2, episodeNumber: 3,
            providerIDs: ["Tmdb": "999", "SeriesTmdb": "1399"]
        )
        let result = try await provider.detailMetadata(
            for: MetadataQuery(item), missing: [.cast, .directors, .writers, .genres, .studios, .overview]
        )
        XCTAssertEqual(result.directors?.value.first?.name, "Episode director")
        XCTAssertEqual(result.overview?.value, "Episode plot")
        XCTAssertEqual(result.genres?.value, ["Drama"])
        XCTAssertEqual(result.studios?.value, ["Studio"])
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
    }

    func testKnownIMDbMissNeverSearchesForAnotherTitle() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            XCTAssertEqual(request.url!.path, "/3/find/tt1234567")
            XCTAssertEqual(TMDbTVDBDiscoveryFixture.query(request)["external_source"], "imdb_id")
            return .init(json: #"{"movie_results":[],"tv_results":[]}"#)
        }
        let provider = TMDbMetadataProvider(access: .directToken("test-token"), detailHTTP: fixture.http)
        let item = MediaItem(id: "movie", title: "The Circle", kind: .movie, providerIDs: ["Imdb": "tt1234567"])
        let result = try await provider.detailMetadata(for: MetadataQuery(item), missing: [.directors])
        XCTAssertTrue(result.isEmpty)
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 1)
    }

    func testTitleOnlyCreditsRejectPopularNearMatch() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            XCTAssertEqual(request.url!.path, "/3/search/movie")
            return .init(json: #"{"results":[{"id":1,"title":"Kingsman: The Golden Circle","release_date":"2017-01-01"}]}"#)
        }
        let provider = TMDbMetadataProvider(access: .directToken("test-token"), detailHTTP: fixture.http)
        let item = MediaItem(id: "movie", title: "The Circle", kind: .movie, productionYear: 2017)
        let result = try await provider.detailMetadata(for: MetadataQuery(item), missing: [.directors])
        XCTAssertTrue(result.isEmpty)
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 1)
    }

    func testDisabledProviderDoesNotMakeRequests() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in
            XCTFail("Missing credentials must not send a request")
            return .init(json: "{}")
        }
        let provider = TMDbMetadataProvider(access: .disabled, detailHTTP: fixture.http)
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "123"])
        let result = try await provider.detailMetadata(for: MetadataQuery(item), missing: [.directors])
        XCTAssertTrue(result.isEmpty)
    }

    func testTransportFailuresAreNotCachedAsMissingCredits() async {
        for (status, expected): (Int, ProviderHealth) in [
            (401, .failure(.unauthorized)), (403, .failure(.unauthorized)),
            (429, .failure(.rateLimited(retryAfter: 30))), (503, .failure(.transient))
        ] {
            let fixture = TMDbTVDBDiscoveryFixture { _, _ in
                .init(json: "{}", status: status, headers: ["Retry-After": "30"])
            }
            let provider = TMDbEnrichmentProvider(provider: TMDbMetadataProvider(
                access: .directToken("test-token"), detailHTTP: fixture.http
            ))
            let item = MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "123"])
            let result = await provider.enrichReporting(MetadataQuery(item), missing: [.directors])
            XCTAssertEqual(result.health, expected)
            XCTAssertTrue(result.enrichment.isEmpty)
        }
    }

    func testExistingCastDoesNotHideCrewAndStudioGaps() {
        let item = MediaItem(
            id: "item", title: "Title", kind: .movie,
            people: [.init(id: "actor", name: "Server actor", kind: "Actor")]
        )
        let missing = DetailMetadataResolver.missingFields(in: item)
        XCTAssertFalse(missing.contains(.cast))
        XCTAssertTrue(missing.isSuperset(of: [.directors, .writers, .studios, .genres]))
    }

    func testFillsEachMissingGroupWithoutReplacingServerDataOrIdentity() {
        let director = MediaPerson(id: "director", name: "Server director", kind: "Director")
        let item = MediaItem(
            id: "server-item", title: "Curated title", kind: .movie, overview: "Curated plot",
            genres: ["Custom genre"], people: [director], studios: ["Custom studio"],
            providerIDs: ["Tmdb": "123"], sourceAccountID: "account"
        )
        let actor = MediaPerson(id: "actor", name: "External actor", kind: "Actor")
        let writer = MediaPerson(id: "writer", name: "External writer", kind: "Writer")
        let enrichment = MetadataEnrichment(
            externalIDs: ["Tmdb": .init(value: "wrong", source: .tmdb)],
            overview: .init(value: "External plot", source: .tmdb),
            genres: .init(value: ["External genre"], source: .tmdb),
            cast: .init(value: [actor], source: .tmdb),
            directors: .init(value: [.init(id: "other", name: "Other director", kind: "Director")], source: .tmdb),
            writers: .init(value: [writer], source: .tmdb),
            studios: .init(value: ["Other studio"], source: .tmdb)
        )
        let resolved = DetailMetadataResolver.applying(enrichment, to: item)
        XCTAssertEqual(resolved.people, [director, actor, writer])
        XCTAssertEqual(resolved.title, item.title)
        XCTAssertEqual(resolved.overview, item.overview)
        XCTAssertEqual(resolved.providerIDs, item.providerIDs)
        XCTAssertEqual(resolved.sourceAccountID, item.sourceAccountID)
        XCTAssertEqual(resolved.genres, item.genres)
        XCTAssertEqual(resolved.studios, item.studios)
        XCTAssertNil(resolved.familyGuidance)
        XCTAssertNil(resolved.mediaInfo)
        XCTAssertEqual(resolved.metadataProvenance[.writers]?.source, .tmdb)
        XCTAssertEqual(DetailMetadataResolver.applying(enrichment, to: resolved), resolved)
    }

    func testNoEnrichmentForPersonalVideosOrContainers() {
        for kind: MediaItemKind in [.video, .folder, .collection, .playlist, .unknown] {
            XCTAssertTrue(DetailMetadataResolver.missingFields(
                in: MediaItem(id: "item", title: "Title", kind: kind)
            ).isEmpty)
        }
    }

    func testAbsentProviderDataNeverErasesExistingValues() {
        let item = MediaItem(id: "item", title: "Title", kind: .episode, overview: "Episode plot")
        XCTAssertEqual(DetailMetadataResolver.applying(MetadataEnrichment(), to: item), item)
    }

    func testCrewSurvivesCodingAndPipelinePriorityMerges() throws {
        let director = MediaPerson(id: "one", name: "First director", kind: "Director")
        let first = MetadataEnrichment(directors: .init(value: [director], source: .server))
        var merged = try JSONDecoder().decode(MetadataEnrichment.self, from: JSONEncoder().encode(first))
        merged.fillMissing(from: MetadataEnrichment(
            directors: .init(value: [.init(id: "two", name: "Second", kind: "Director")], source: .tmdb),
            writers: .init(value: [.init(id: "three", name: "Writer", kind: "Writer")], source: .tmdb),
            studios: .init(value: ["Studio"], source: .tmdb)
        ))
        XCTAssertEqual(merged.directors, first.directors)
        XCTAssertTrue(merged.filledFields.isSuperset(of: [.directors, .writers, .studios]))
        XCTAssertFalse(merged.isEmpty)
    }

    func testMovieAndAggregateTVJobsMapOnlyDirectorsAndWriters() throws {
        let json = """
        {"cast":[{"id":1,"name":"Actor","character":"Role"}],
         "guest_stars":[{"id":1,"name":"Actor","character":"Role"},{"id":5,"name":"Guest"}],
         "crew":[
           {"id":2,"name":"Director","job":"Director"},
           {"id":3,"name":"Writer","jobs":[{"job":"Screenplay"},{"job":"Story"}]},
           {"id":3,"name":"Writer","job":"Teleplay"},
           {"id":4,"name":"Producer","job":"Producer"},
           {"id":6,"name":"Art director","job":"Art Direction"}]}
        """
        let credits = try JSONDecoder().decode(TMDbMetadataProvider.CreditsResponse.self, from: Data(json.utf8))
        let result = TMDbMetadataProvider.creditMetadata(credits, missing: [.cast, .directors, .writers])
        XCTAssertEqual(result.cast?.value.map(\.name), ["Actor", "Guest"])
        XCTAssertEqual(result.directors?.value.map(\.name), ["Director"])
        XCTAssertEqual(result.writers?.value.map(\.name), ["Writer"])
        XCTAssertEqual(result.directors?.value.first?.kind, "Director")
        XCTAssertEqual(result.writers?.value.first?.kind, "Writer")
        let castOnly = TMDbMetadataProvider.creditMetadata(credits, missing: [.cast])
        XCTAssertNil(castOnly.directors)
        XCTAssertNil(castOnly.writers)
    }

    func testEpisodeAndSeasonCreditsNeverUseWholeShowAggregate() {
        let episode = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            parentTitle: "Show", seasonNumber: 0, episodeNumber: 2,
            providerIDs: ["Tmdb": "episode-id", "SeriesTmdb": "1399"]
        )
        XCTAssertEqual(
            TMDbMetadataProvider.creditsPath(id: "1399", query: MetadataQuery(episode)),
            "/3/tv/1399/season/0/episode/2/credits"
        )
        var season = episode
        season.kind = .season
        XCTAssertEqual(
            TMDbMetadataProvider.creditsPath(id: "1399", query: MetadataQuery(season)),
            "/3/tv/1399/season/0/credits"
        )
        var unnumbered = episode
        unnumbered.episodeNumber = nil
        XCTAssertNil(TMDbMetadataProvider.creditsPath(id: "1399", query: MetadataQuery(unnumbered)))
        XCTAssertEqual(MetadataQuery(episode).seriesScoped.providerIDs.providerID(.tmdb), "1399")
    }

    func testCacheSeparatesSeriesSeasonsAndUnnumberedEpisodes() {
        var item = MediaItem(id: "show", title: "Show", kind: .series, providerIDs: ["SeriesTmdb": "1399"])
        var keys = [MetadataQuery(item).enrichmentCacheKey]
        item.kind = .season
        keys.append(MetadataQuery(item).enrichmentCacheKey)
        item.seasonNumber = 1
        keys.append(MetadataQuery(item).enrichmentCacheKey)
        item.seasonNumber = 2
        keys.append(MetadataQuery(item).enrichmentCacheKey)
        item.kind = .episode
        keys.append(MetadataQuery(item).enrichmentCacheKey)
        item.episodeNumber = 1
        keys.append(MetadataQuery(item).enrichmentCacheKey)
        item.episodeNumber = 2
        keys.append(MetadataQuery(item).enrichmentCacheKey)
        XCTAssertEqual(Set(keys).count, keys.count)
    }
}
