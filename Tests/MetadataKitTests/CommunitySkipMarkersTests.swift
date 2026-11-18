import CoreModels
import Foundation
import XCTest
@testable import MetadataKit
@testable import TestSupportNetworking

final class CommunitySkipMarkersTests: XCTestCase {
    private func episode(providerIDs: [String: String], season: Int? = 1, number: Int? = 2) -> MediaItem {
        var item = MediaItem(id: "ep", title: "Episode", kind: .episode)
        item.providerIDs = providerIDs
        item.seasonNumber = season
        item.episodeNumber = number
        item.seriesID = "s"
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

    func testIntroDBProtectsAnExplicitSceneWithoutExtendingCredits() throws {
        let response = try JSONDecoder().decode(IntroDBClient.Response.self, from: Data(#"""
        {"outro":{"start_ms":100000,"end_ms":300000},
         "post_credits":{"start_ms":200000,"end_ms":250000}}
        """#.utf8))
        let segments = IntroDBClient.segments(from: response)
        XCTAssertEqual(segments.map(\.start), [100, 250])
        XCTAssertEqual(segments.map(\.end), [200, 300])
        XCTAssertNil(segments.activeSkippable(at: 225))
    }

    func testMalformedIntroDBPostCreditsAndPartialIntroPreserveValidOutro() throws {
        for post in [
            #"{"start_ms":0,"end_ms":147000}"#,
            #"{"start_ms":null,"end_ms":147000}"#,
            #"{"start_ms":200000,"end_ms":150000}"#
        ] {
            let json = """
            {"intro":{"start_ms":null,"end_ms":10000},
             "outro":{"start_ms":100000,"end_ms":200000},"post_credits":\(post)}
            """
            let response = try JSONDecoder().decode(IntroDBClient.Response.self, from: Data(json.utf8))
            let segments = IntroDBClient.segments(from: response)
            XCTAssertEqual(segments.map(\.kind), [.credits])
            XCTAssertEqual(segments.first?.end, 200)
        }
    }

    func testTheIntroDBKeepsDistinctCreditsWindowsAroundAScene() throws {
        let response = try JSONDecoder().decode(TheIntroDBClient.Response.self, from: Data(#"""
        {"credits":[{"start_ms":100000,"end_ms":200000},
                    {"start_ms":100000,"end_ms":200000},
                    {"start_ms":250000,"end_ms":null}]}
        """#.utf8))
        let segments = TheIntroDBClient.segments(from: response, duration: 300)
        XCTAssertEqual(segments.map(\.start), [100, 250])
        XCTAssertEqual(segments.map(\.end), [200, 300])
        XCTAssertNil(segments.activeSkippable(at: 225))
    }

    func testTheIntroDBRequestsIdentifyPlozz() async throws {
        let session = URLSession(configuration: StubURLProtocol.makeEphemeralSession())
        defer {
            session.invalidateAndCancel()
            StubURLProtocol.reset()
        }
        let queries = [
            CommunitySkipMarkerQuery(isMovie: true, imdbID: "tt1375666", tmdbID: nil),
            CommunitySkipMarkerQuery(
                isMovie: false, imdbID: nil, tmdbID: nil,
                season: 1, episode: 2, tvdbID: "81189", episodeOrdering: .aired
            )
        ]
        for query in queries {
            let url = try XCTUnwrap(TheIntroDBClient.url(for: query))
            StubURLProtocol.queue(StubResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"tvdb_id":81189,"intro":[{"start_ms":10000,"end_ms":40000}]}"#.utf8)
            ), for: url)

            let segments = await TheIntroDBClient.segments(for: query, session: session)

            let requests = StubURLProtocol.requests(for: url)
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.host, "api.theintrodb.org")
            XCTAssertEqual(request.url?.path, "/v4/media")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let userAgent = try XCTUnwrap(request.value(forHTTPHeaderField: "User-Agent"))
            XCTAssertEqual(userAgent, MetadataHTTP.userAgent)
            XCTAssertNotNil(userAgent.range(of: #"^Plozz/[0-9]+\.[0-9]+"#, options: .regularExpression))
            XCTAssertEqual(segments.map(\.kind), [.intro])
            XCTAssertEqual(segments.first?.start, 10)
            XCTAssertEqual(segments.first?.end, 40)
        }
    }

    func testTheIntroDBURLPrefersTMDB() {
        let tv = CommunitySkipMarkerQuery(isMovie: false, imdbID: "tt0903747", tmdbID: "1396", season: 1, episode: 2)
        XCTAssertEqual(
            TheIntroDBClient.url(for: tv)?.absoluteString,
            "https://api.theintrodb.org/v4/media?tmdb_id=1396&season=1&episode=2"
        )
        let imdbOnly = CommunitySkipMarkerQuery(isMovie: true, imdbID: "tt1375666", tmdbID: nil)
        XCTAssertEqual(
            TheIntroDBClient.url(for: imdbOnly)?.absoluteString,
            "https://api.theintrodb.org/v4/media?imdb_id=tt1375666"
        )
    }

    func testTheIntroDBResolvesOpenEndedSegments() throws {
        let json = #"""
        {"tvdb_id":81189,"type":"tv","season":1,"episode":1,
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

    func testTVDBSeriesAndEpisodeIdentityStaySeparate() throws {
        let item = episode(providerIDs: ["Tvdb": "349232", "SeriesTvdb": "81189"])
        XCTAssertFalse(CommunitySkipMarkerQuery.needsSeriesIDs(item))
        let query = try XCTUnwrap(CommunitySkipMarkerQuery(item: item))
        XCTAssertEqual(query.tvdbID, "81189")
        XCTAssertEqual(query.tvdbEpisodeID, "349232")
        let params = try parameters(query)
        XCTAssertEqual(params["tvdb_id"], "81189")
        XCTAssertEqual(params["tvdb_episode_id"], "349232")
        XCTAssertEqual(params["duration_ms"], "3000000")
        XCTAssertEqual(params["episode_name"], "Episode")
        XCTAssertNil(params["mapping"])
        XCTAssertNil(CommunitySkipMarkerQuery(item: episode(providerIDs: ["Tvdb": "349232"])))
    }

    func testOwningSeriesSuppliesTVDBAndOrderingWithoutOverwritingEpisode() throws {
        var item = episode(providerIDs: ["SeriesTmdb": "1396"])
        let series = MediaItem(id: "s", title: "Show", kind: .series, episodeOrdering: .dvd,
                               providerIDs: ["Tvdb": "81189", "Tmdb": "999"])
        let query = try XCTUnwrap(CommunitySkipMarkerQuery(item: item, series: series))
        XCTAssertEqual(query.tmdbID, "1396")
        XCTAssertEqual(query.tvdbID, "81189")
        XCTAssertEqual(query.episodeOrdering, .dvd)
        XCTAssertEqual(try parameters(query)["mapping"], "dvd")
        XCTAssertNil(IntroDBClient.url(for: query), "An unconverted IntroDB result must not mask the correct v4 result")
        item.providerIDs = [:]
        var unrelated = series
        unrelated.id = "different"
        XCTAssertNil(CommunitySkipMarkerQuery(item: item, series: unrelated))
        unrelated.id = "s"
        unrelated.kind = .season
        XCTAssertNil(CommunitySkipMarkerQuery(item: item, series: unrelated))
    }

    func testKnownTVDBOrdersUseCanonicalMappingAndUnknownDoesNotGuess() throws {
        let cases: [(EpisodeOrdering, String)] = [
            (.tvdbDefault, "default"), (.aired, "official"), (.dvd, "dvd"),
            (.absolute, "absolute"), (.alternate, "alternate"), (.regional, "regional")
        ]
        var query = CommunitySkipMarkerQuery(
            isMovie: false, imdbID: "tt0903747", tmdbID: "1396", season: 0, episode: 0, tvdbID: "81189"
        )
        for (order, mapping) in cases {
            query.episodeOrdering = order
            for episodeID in [nil, "349232"] {
                query.tvdbEpisodeID = episodeID
                let params = try parameters(query)
                XCTAssertEqual(params["mapping"], mapping)
                XCTAssertEqual(params["season"], "0")
                XCTAssertEqual(params["episode"], "0")
                XCTAssertEqual(params["tvdb_id"], "81189")
                XCTAssertEqual(params["tvdb_episode_id"], episodeID)
            }
        }
        query.episodeOrdering = .unknown
        for episodeID in [nil, "349232"] {
            query.tvdbEpisodeID = episodeID
            XCTAssertNil(TheIntroDBClient.url(for: query), "An episode ID cannot make unknown coordinates safe")
        }
    }

    func testTMDBNumberingUsesTMDBResolutionEvenWhenExactEpisodeIsKnown() throws {
        var query = CommunitySkipMarkerQuery(
            isMovie: false, imdbID: "tt0903747", tmdbID: "1396", season: 1, episode: 2,
            tvdbID: "81189", episodeName: "Title", episodeOrdering: .tmdb
        )
        for episodeID in [nil, "349232"] {
            query.tmdbID = "1396"
            query.tvdbEpisodeID = episodeID
            let params = try parameters(query)
            XCTAssertEqual(params["tmdb_id"], "1396")
            XCTAssertNil(params["tvdb_id"])
            XCTAssertNil(params["mapping"])
            XCTAssertNil(params["episode_name"], "The API ignores this hint for TMDB addressing")
            XCTAssertEqual(params["tvdb_episode_id"], episodeID)
            query.tmdbID = nil
            XCTAssertNil(TheIntroDBClient.url(for: query), "Do not send TMDB coordinates as TVDB or IMDb coordinates")
        }
    }

    func testTVDBOrderingFallsBackToIMDbNeverTMDB() throws {
        var query = CommunitySkipMarkerQuery(
            isMovie: false, imdbID: "tt0149460", tmdbID: "615", season: 7, episode: 1,
            duration: 1325.2, episodeName: "Rebirth", episodeOrdering: .alternate
        )
        for order in [EpisodeOrdering.tvdbDefault, .aired, .dvd, .absolute, .alternate, .regional] {
            query.episodeOrdering = order
            for episodeID in [nil, "1051911"] {
                query.tvdbEpisodeID = episodeID
                for invalidTVDB in [nil, "0", "100000001"] {
                    query.tvdbID = invalidTVDB
                    query.imdbID = "tt0149460"
                    let params = try parameters(query)
                    XCTAssertEqual(params["imdb_id"], "tt0149460")
                    XCTAssertEqual(params["mapping"], query.mapping)
                    XCTAssertNil(params["tmdb_id"])
                    XCTAssertNil(params["tvdb_id"])
                    XCTAssertEqual(params["tvdb_episode_id"], episodeID)
                    for invalidIMDb in [nil, "tt1"] {
                        query.imdbID = invalidIMDb
                        XCTAssertNil(TheIntroDBClient.url(for: query), "TMDB cannot convert TVDB-order coordinates")
                    }
                }
            }
        }
    }

    func testAlternateOrderEpisodeIDRetainsRebirthMapping() throws {
        let query = CommunitySkipMarkerQuery(
            isMovie: false, imdbID: "tt0149460", tmdbID: "615", season: 7, episode: 1,
            duration: 1325.2, tvdbID: "73871", tvdbEpisodeID: "1051911",
            episodeName: "Rebirth", episodeOrdering: .alternate
        )
        XCTAssertEqual(try parameters(query), [
            "tvdb_id": "73871", "season": "7", "episode": "1",
            "tvdb_episode_id": "1051911", "mapping": "alternate",
            "episode_name": "Rebirth", "duration_ms": "1325200"
        ])
    }

    func testMoviesOmitAllTVParametersEvenWhenCallerSuppliesThem() throws {
        let query = CommunitySkipMarkerQuery(
            isMovie: true, imdbID: "tt1375666", tmdbID: "27205", season: 1, episode: 2,
            duration: 120.125, tvdbID: "169", tvdbEpisodeID: "123",
            episodeName: "Not an episode", episodeOrdering: .dvd
        )
        XCTAssertEqual(try parameters(query), ["tvdb_id": "169", "duration_ms": "120125"])
        let movie = MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tvdb": "169"])
        XCTAssertNotNil(CommunitySkipMarkerQuery(item: movie))
    }

    func testInvalidIDsFallThroughWithoutSendingMalformedQueries() throws {
        var query = CommunitySkipMarkerQuery(isMovie: true, imdbID: " TT1375666\n", tmdbID: " 0027205 ", tvdbID: "169")
        for invalid in ["0", "-1", "100000001", "١٢", "12abc", "999999999999999999999"] {
            query.tvdbID = invalid
            XCTAssertEqual(try parameters(query)["tmdb_id"], "27205")
        }
        query.tmdbID = "10000001"
        XCTAssertEqual(try parameters(query)["imdb_id"], "tt1375666")
        for invalid in ["tt1", "ttabcdefg", "tt123456789", "tt１２３４５６７"] {
            query.imdbID = invalid
            XCTAssertNil(TheIntroDBClient.url(for: query))
        }
    }

    func testCoordinateBoundsAndUnknownDuration() throws {
        var query = CommunitySkipMarkerQuery(isMovie: false, imdbID: nil, tmdbID: nil, season: 1000, episode: 10000, tvdbID: "100000000")
        XCTAssertNotNil(TheIntroDBClient.url(for: query))
        for (season, episode) in [(nil, 1), (1, nil), (-1, 1), (1, -1), (1001, 1), (1, 10001)] as [(Int?, Int?)] {
            query.season = season
            query.episode = episode
            XCTAssertNil(TheIntroDBClient.url(for: query))
        }
        query.isMovie = true
        for duration in [0, -1, Double.infinity, Double.nan, Double.greatestFiniteMagnitude] {
            query.duration = duration
            XCTAssertNil(try parameters(query)["duration_ms"])
        }
    }

    func testCombinedEpisodeDoesNotReceiveSingleEpisodeMarkers() {
        var item = episode(providerIDs: ["SeriesTvdb": "81189", "Tvdb": "349232"])
        item.episodeNumberEnd = 3
        XCTAssertNil(CommunitySkipMarkerQuery(item: item))
        item.episodeNumberEnd = item.episodeNumber
        XCTAssertNotNil(CommunitySkipMarkerQuery(item: item))
    }

    func testV4EmptyAndAlternateResponsesDoNotBecomeSkipSegments() throws {
        for json in [
            #"{"tvdb_id":81189,"type":"tv","season":1,"episode":1}"#,
            #"{"tvdb_id":81189,"type":"tv","episodes":[{"season":1,"episode":1,"name":"Pilot"}]}"#,
            #"{"tvdb_id":81189,"type":"tv","versions":[{"duration_ms":3000000}]}"#
        ] {
            let response = try JSONDecoder().decode(TheIntroDBClient.Response.self, from: Data(json.utf8))
            XCTAssertTrue(TheIntroDBClient.segments(from: response, duration: 3000).isEmpty)
        }
    }

    func testInvalidOrOutOfRuntimeTimestampsAreNotSkippable() throws {
        let response = try JSONDecoder().decode(TheIntroDBClient.Response.self, from: Data(
            #"{"intro":[{"start_ms":-1,"end_ms":1000},{"start_ms":5000,"end_ms":5000},{"start_ms":5000,"end_ms":1000},{"start_ms":0,"end_ms":999999}],"credits":[{"start_ms":9000,"end_ms":null}]}"#.utf8
        ))
        XCTAssertEqual(TheIntroDBClient.segments(from: response, duration: 10).map(\.kind), [.credits])
        XCTAssertTrue(TheIntroDBClient.segments(from: response, duration: .nan).allSatisfy { $0.end.isFinite })
    }

    func testEpisodeOrderingSurvivesPersistenceAndOldCachesRemainReadable() throws {
        var item = episode(providerIDs: [:])
        item.episodeOrdering = .dvd
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: data).episodeOrdering, .dvd)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "episodeOrdering")
        XCTAssertNil(try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: object)).episodeOrdering)
        object["episodeOrdering"] = "future-order"
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: object)).episodeOrdering, .unknown)
    }

    private func parameters(_ query: CommunitySkipMarkerQuery) throws -> [String: String] {
        let url = try XCTUnwrap(TheIntroDBClient.url(for: query))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "api.theintrodb.org")
        XCTAssertEqual(components.path, "/v4/media")
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}
