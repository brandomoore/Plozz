import CoreModels
import Foundation
import XCTest
@testable import MetadataKit

final class TMDbDiscoveryProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_779_494_400) // 2026-05-23 UTC

    func testSeedUsageIsVisibleThroughDiscoveryContract() {
        let tmdb: any HeroDiscoveryProviding = TMDbDiscoveryProvider(access: .disabled)
        let tvdb: any HeroDiscoveryProviding = TVDBDiscoveryProvider(config: .init(apiKey: nil))
        XCTAssertTrue(tmdb.usesTitleSeeds)
        XCTAssertFalse(tvdb.usesTitleSeeds)
    }

    func testDisabledAndZeroLimitDoNotRequest() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in
            XCTFail("Disabled/zero-limit discovery must not send requests")
            return .init(json: #"{"results":[]}"#)
        }
        let disabled = TMDbDiscoveryProvider(access: .disabled, http: fixture.http)
        XCTAssertFalse(disabled.isEnabled)
        let disabledItems = try await disabled.discover(.init())
        XCTAssertTrue(disabledItems.isEmpty)
        let enabled = TMDbDiscoveryProvider(access: .directToken("fixture"), http: fixture.http)
        let zeroItems = try await enabled.discover(.init(limit: 0))
        XCTAssertTrue(zeroItems.isEmpty)
        let requests = await fixture.recorded()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDirectAuthenticationAndDocumentedDateQualityLocaleFilters() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: #"{"results":[]}"#) }
        let provider = TMDbDiscoveryProvider(access: .directToken("fixture-application"), http: fixture.http)
        let items = try await provider.discover(.init(language: "fr_CA", region: "ca", now: now))
        XCTAssertTrue(items.isEmpty)
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.map { $0.url!.path }, [
            "/3/discover/movie", "/3/discover/tv", "/3/discover/movie", "/3/discover/tv"
        ])
        for request in requests {
            XCTAssertEqual(request.url?.host, "api.themoviedb.org")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-application")
            XCTAssertEqual(request.timeoutInterval, 12)
            let query = TMDbTVDBDiscoveryFixture.query(request)
            XCTAssertEqual(query["language"], "fr-CA")
            XCTAssertEqual(query["include_adult"], "false")
            XCTAssertEqual(query["page"], "1")
        }
        let recentMovie = TMDbTVDBDiscoveryFixture.query(requests[0])
        XCTAssertEqual(recentMovie["region"], "CA")
        XCTAssertEqual(recentMovie["include_video"], "false")
        XCTAssertEqual(recentMovie["sort_by"], "popularity.desc")
        XCTAssertEqual(recentMovie["vote_count.gte"], "100")
        XCTAssertEqual(recentMovie["vote_average.gte"], "6.0")
        XCTAssertEqual(recentMovie["primary_release_date.gte"], "2023-05-23")
        XCTAssertEqual(recentMovie["primary_release_date.lte"], "2026-05-23")
        let recentTV = TMDbTVDBDiscoveryFixture.query(requests[1])
        XCTAssertNil(recentTV["region"], "TV discovery has no documented region parameter")
        XCTAssertEqual(recentTV["first_air_date.gte"], "2023-05-23")
        XCTAssertEqual(recentTV["include_null_first_air_dates"], "false")
        XCTAssertEqual(recentTV["vote_count.gte"], "50")
        for request in requests.suffix(2) {
            let query = TMDbTVDBDiscoveryFixture.query(request)
            XCTAssertEqual(query["sort_by"], "vote_average.desc")
            XCTAssertEqual(query["vote_average.gte"], "7.0")
            XCTAssertNotNil(query["with_genres"])
        }
        XCTAssertEqual(TMDbTVDBDiscoveryFixture.query(requests[2])["primary_release_date.lte"], "2023-05-22")
        XCTAssertEqual(TMDbTVDBDiscoveryFixture.query(requests[3])["first_air_date.lte"], "2023-05-22")
    }

    func testProxyRetainsPathAndDoesNotSendBearer() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: #"{"results":[]}"#) }
        let provider = TMDbDiscoveryProvider(
            access: .proxy(baseURL: URL(string: "https://metadata.example/proxy/")!),
            http: fixture.http
        )
        _ = try await provider.discover(.init())
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.first?.url?.path, "/proxy/3/discover/movie")
        for request in requests {
            XCTAssertEqual(request.url?.host, "metadata.example")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testBYOKUsesApplicationEndpointsWithItsOwnCredential() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: #"{"results":[]}"#) }
        let provider = TMDbDiscoveryProvider(access: .userToken("fixture-byok"), http: fixture.http)
        _ = try await provider.discover(.init())
        let requests = await fixture.recorded()
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-byok"
        })
    }

    func testFingerprintSeparatesEveryCredentialModeAndProxy() {
        let accesses: [TMDbAccess] = [
            .disabled, .directToken("one"), .directToken("two"),
            .userToken("one"), .userToken("two"),
            .proxy(baseURL: URL(string: "https://one.example")!),
            .proxy(baseURL: URL(string: "https://two.example")!)
        ]
        let identities = accesses.map { TMDbDiscoveryProvider(access: $0).cacheIdentifier }
        XCTAssertEqual(Set(identities).count, accesses.count)
        XCTAssertTrue(identities.allSatisfy { $0.hasPrefix("tmdb:") && $0.count == 69 })
        XCTAssertEqual(
            TMDbDiscoveryProvider(access: .directToken("one")).cacheIdentifier,
            TMDbDiscoveryProvider(access: .directToken("one")).cacheIdentifier
        )
    }

    func testMappingDeduplicatesWithinKindAndKeepsMovieAndTVWithSameNumericID() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            if request.url!.path.hasSuffix("/movie") {
                return .init(json: """
                    {"results":[
                      {"id":42,"title":" Film ","original_title":"Original","overview":" Plot ",
                       "release_date":"2020-04-03","poster_path":"/poster.jpg","backdrop_path":"/wide.jpg"},
                      {"id":42,"title":"Duplicate"},
                      {"id":43,"title":"Second","poster_path":"/only-poster.jpg"}]}
                    """)
            }
            return .init(json: #"{"results":[{"id":42,"name":"Show","first_air_date":"2021-02-03"}]}"#)
        }
        let items = try await TMDbDiscoveryProvider(access: .directToken("fixture"), http: fixture.http)
            .discover(.init())
        XCTAssertEqual(items.map(\.id), ["tmdb:movie:42", "tmdb:series:42", "tmdb:movie:43"])
        let movie = try XCTUnwrap(items.first)
        XCTAssertEqual(movie.title, "Film")
        XCTAssertEqual(movie.originalTitle, "Original")
        XCTAssertEqual(movie.overview, "Plot")
        XCTAssertEqual(movie.productionYear, 2020)
        XCTAssertEqual(movie.releaseDate, ISO8601DateFormatter().date(from: "2020-04-03T00:00:00Z"))
        XCTAssertEqual(movie.providerIDs, ["Tmdb": "42"])
        XCTAssertEqual(movie.posterURL?.absoluteString, "https://image.tmdb.org/t/p/w500/poster.jpg")
        XCTAssertEqual(movie.backdropURL?.absoluteString, "https://image.tmdb.org/t/p/w1280/wide.jpg")
        XCTAssertEqual(movie.heroBackdropURL?.absoluteString, "https://image.tmdb.org/t/p/original/wide.jpg")
        XCTAssertNil(items.last?.backdropURL, "Poster-only records must never become landscape art")
        for item in items {
            XCTAssertEqual(item.discoverySources, [.tmdb])
            XCTAssertEqual(item.availability, .unknown)
            XCTAssertFalse(item.locallyValidatedPlayableSource)
            XCTAssertNil(item.sourceAccountID)
            XCTAssertTrue(item.sources.isEmpty)
        }
    }

    func testSkipsAdultInvalidIDUnknownKindAndMissingTitles() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in
            .init(json: """
                {"results":[
                  {"id":1,"title":"Adult","name":"Adult","adult":true},
                  {"id":0,"title":"Zero","name":"Zero"},
                  {"id":-2,"title":"Negative","name":"Negative"},
                  {"id":3,"title":"Person","name":"Person","media_type":"person"},
                  {"id":4,"title":"  ","name":""},
                  {"title":"Missing ID","name":"Missing ID"},
                  {"id":5,"title":"Movie","media_type":"movie","poster_path":"//evil.example/poster"},
                  {"id":6,"name":"Show","media_type":"tv"}]}
                """)
        }
        let items = try await TMDbDiscoveryProvider(access: .directToken("fixture"), http: fixture.http)
            .discover(.init())
        XCTAssertEqual(items.map(\.id), ["tmdb:movie:5", "tmdb:series:6"])
        XCTAssertNil(items[0].posterURL)
    }

    func testLimitAndBudgetPreserveFeedOrder() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            let field = request.url!.path.hasSuffix("movie") ? "title" : "name"
            let records = (1...60).map { #"{"id":\#($0),"\#(field)":"Title \#($0)"}"# }.joined(separator: ",")
            return .init(json: #"{"results":[\#(records)]}"#)
        }
        let provider = TMDbDiscoveryProvider(access: .directToken("fixture"), http: fixture.http)
        let items = try await provider.discover(.init(limit: 3))
        XCTAssertEqual(items.map(\.id), ["tmdb:movie:1", "tmdb:series:1", "tmdb:movie:2"])
        let many = try await provider.discover(.init(limit: 999))
        XCTAssertEqual(many.count, 48)
        XCTAssertEqual(many.filter { $0.kind == .movie }.map { $0.providerIDs["Tmdb"]! },
                       (1...24).map(String.init))
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 8, "Exactly four feeds per pass; never paginate")
    }

    func testChildSeedsOnlyUseSeriesIDAndRecommendationBudgetIsTwo() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: #"{"results":[]}"#) }
        let seeds = [
            MediaItem(id: "episode", title: "Episode", kind: .episode,
                      providerIDs: ["Tmdb": "999", "SeriesTmdb": "17"]),
            MediaItem(id: "season", title: "Season", kind: .season,
                      providerIDs: ["Tmdb": "888", "SeriesTmdb": "17"]),
            MediaItem(id: "movie", title: "Film", kind: .movie, providerIDs: ["Tmdb": "17"])
        ]
        _ = try await TMDbDiscoveryProvider(access: .directToken("fixture"), http: fixture.http)
            .discover(.init(language: "ja", seeds: seeds))
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 6)
        let related = requests.filter { $0.url!.path.hasSuffix("recommendations") }
        XCTAssertEqual(related.map { $0.url!.path }, ["/3/tv/17/recommendations", "/3/movie/17/recommendations"])
        XCTAssertTrue(related.allSatisfy { TMDbTVDBDiscoveryFixture.query($0)["language"] == "ja" })
        XCTAssertTrue(related.allSatisfy { TMDbTVDBDiscoveryFixture.query($0)["include_adult"] == nil },
                      "Recommendations do not document an include_adult parameter; mapping filters it")
    }

    func testInvalidAndChildOnlyIDsCannotSeedSeriesRecommendations() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: #"{"results":[]}"#) }
        let provider = TMDbDiscoveryProvider(access: .directToken("fixture"), http: fixture.http)
        _ = try await provider.discover(.init(seeds: [
            MediaItem(id: "e", title: "Episode", kind: .episode, providerIDs: ["Tmdb": "99"]),
            MediaItem(id: "s", title: "Season", kind: .season, providerIDs: ["Tmdb": "88"]),
            MediaItem(id: "m", title: "Film", kind: .movie, providerIDs: ["Tmdb": "-1"])
        ]))
        _ = try await provider.discover(.init(seeds: [
            MediaItem(id: "m", title: "Film", kind: .movie, providerIDs: ["Tmdb": "1/other"]),
            MediaItem(id: "s", title: "Show", kind: .series, providerIDs: ["Tmdb": "0"])
        ]))
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 8)
        XCTAssertFalse(requests.contains { $0.url!.path.hasSuffix("recommendations") })
    }

    func testThreeDistinctSeedsStillHaveSixRequestCeiling() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: #"{"results":[]}"#) }
        let seeds = (1...3).map {
            MediaItem(id: String($0), title: "Seed", kind: .movie, providerIDs: ["Tmdb": String($0)])
        }
        _ = try await TMDbDiscoveryProvider(access: .directToken("fixture"), http: fixture.http)
            .discover(.init(seeds: seeds))
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 6)
    }

    func testFailureAfterSuccessfulFeedPropagatesStatusAndRetryAfter() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, count in
            if count == 1 { return .init(json: #"{"results":[{"id":1,"title":"Partial"}]}"#) }
            return .init(json: "{}", status: 429, headers: ["Retry-After": "75"])
        }
        do {
            _ = try await TMDbDiscoveryProvider(access: .directToken("fixture"), http: fixture.http)
                .discover(.init())
            XCTFail("Partial success must not mask provider backoff")
        } catch let error as MetadataDiscoveryHTTPError {
            XCTAssertEqual(error, .status(429, retryAfter: 75))
        }
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 2)
    }

    func testMalformedPayloadPropagatesInvalidResponse() async throws {
        for json in [
            "not json", #"{"results":{}}"#, #"{"success":false}"#,
            #"{"success":false,"results":[]}"#, #"{"results":[{"id":"wrong"}]}"#
        ] {
            let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: json) }
            do {
                _ = try await TMDbDiscoveryProvider(access: .directToken("fixture"), http: fixture.http)
                    .discover(.init())
                XCTFail("Malformed payload must not be cached as an empty success")
            } catch let error as MetadataDiscoveryHTTPError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
    }

    func testCancellationAndNetworkErrorsPropagate() async throws {
        for cancellation in [true, false] {
            let fixture = TMDbTVDBDiscoveryFixture { _, _ in
                if cancellation { throw CancellationError() }
                throw URLError(.notConnectedToInternet)
            }
            do {
                _ = try await TMDbDiscoveryProvider(access: .directToken("fixture"), http: fixture.http)
                    .discover(.init())
                XCTFail("Transport failure must propagate")
            } catch is CancellationError {
                XCTAssertTrue(cancellation)
            } catch let error as URLError {
                XCTAssertFalse(cancellation)
                XCTAssertEqual(error.code, .notConnectedToInternet)
            }
        }
    }
}
