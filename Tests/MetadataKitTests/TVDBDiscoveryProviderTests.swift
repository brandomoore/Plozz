import CoreModels
import Foundation
import XCTest
@testable import MetadataKit

final class TVDBDiscoveryProviderTests: XCTestCase {
    private var config: TVDBConfig {
        TVDBConfig(apiKey: "fixture-api-key", apiBaseURL: URL(string: "https://tvdb.example/v4")!)
    }

    func testUnconfiguredAndZeroLimitDoNotLogin() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in
            XCTFail("Disabled/zero-limit discovery must not send requests")
            return .init(json: "{}")
        }
        let disabled = TVDBDiscoveryProvider(config: .init(apiKey: nil), http: fixture.http)
        XCTAssertFalse(disabled.isEnabled)
        let disabledItems = try await disabled.discover(.init())
        XCTAssertTrue(disabledItems.isEmpty)
        let enabled = TVDBDiscoveryProvider(config: config, http: fixture.http)
        XCTAssertTrue(enabled.isEnabled)
        let zeroItems = try await enabled.discover(.init(limit: 0))
        XCTAssertTrue(zeroItems.isEmpty)
        let requests = await fixture.recorded()
        XCTAssertTrue(requests.isEmpty)
    }

    func testLoginLocaleResolutionAndDocumentedFilterParameters() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            TMDbTVDBDiscoveryFixture.tvdbReply(request)
        }
        let provider = TVDBDiscoveryProvider(config: config, http: fixture.http)
        let items = try await provider.discover(.init(
            language: "fr-CA", region: "ca", now: Date(timeIntervalSince1970: 1_779_494_400)
        ))
        XCTAssertTrue(items.isEmpty)
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.map { $0.url!.path }, [
            "/v4/login", "/v4/countries", "/v4/languages", "/v4/movies/filter", "/v4/series/filter"
        ])
        let login = try XCTUnwrap(requests.first)
        XCTAssertEqual(login.httpMethod, "POST")
        XCTAssertEqual(login.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(login.value(forHTTPHeaderField: "Authorization"))
        let body = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(login.httpBody))
        XCTAssertEqual(body, ["apikey": "fixture-api-key"], "No subscriber PIN or user account required")
        for request in requests.dropFirst() {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-jwt")
            XCTAssertEqual(request.url?.host, "tvdb.example")
            XCTAssertEqual(request.timeoutInterval, 12)
            XCTAssertNil(TMDbTVDBDiscoveryFixture.query(request)["apikey"])
        }
        let movie = TMDbTVDBDiscoveryFixture.query(requests[3])
        XCTAssertEqual(movie, ["country": "can", "lang": "fra", "sort": "score", "year": "2026"])
        let series = TMDbTVDBDiscoveryFixture.query(requests[4])
        XCTAssertEqual(series, ["country": "can", "lang": "fra", "sort": "score", "sortType": "desc", "year": "2026"])
    }

    func testJWTAndLocaleCatalogsAreCachedAcrossPasses() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            TMDbTVDBDiscoveryFixture.tvdbReply(request)
        }
        let provider = TVDBDiscoveryProvider(config: config, http: fixture.http)
        _ = try await provider.discover(.init())
        _ = try await provider.discover(.init(language: "ja_JP", region: "JP"))
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 7, "Five cold calls, two warm calls, no result-detail fanout")
        XCTAssertEqual(requests.filter { $0.url!.lastPathComponent == "login" }.count, 1)
        for request in requests.suffix(2) {
            let query = TMDbTVDBDiscoveryFixture.query(request)
            XCTAssertEqual(query["country"], "jpn")
            XCTAssertEqual(query["lang"], "jpn")
        }
    }

    func testProductionRegistryReusesWarmStateAndSeparatesCredentials() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            TMDbTVDBDiscoveryFixture.tvdbReply(request)
        }
        let registry = TVDBDiscoveryProviderRegistry(http: fixture.http)
        let first = await registry.provider(config: config)
        _ = try await first.discover(.init())
        let next = await registry.provider(config: config)
        _ = try await next.discover(.init(language: "ja", region: "JP"))
        var requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 7)
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "login" }.count, 1)
        let rotated = await registry.provider(config: .init(
            apiKey: "replacement-key", apiBaseURL: config.apiBaseURL
        ))
        _ = try await rotated.discover(.init())
        requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 12)
        XCTAssertEqual(requests.filter { $0.url?.lastPathComponent == "login" }.count, 2)
    }

    func testAlphaThreeIdentifiersAndUnknownLocaleFallbackUseCatalogIDs() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            TMDbTVDBDiscoveryFixture.tvdbReply(request)
        }
        let provider = TVDBDiscoveryProvider(config: config, http: fixture.http)
        _ = try await provider.discover(.init(language: "fra", region: "FRA"))
        _ = try await provider.discover(.init(language: "unknown", region: "??"))
        let requests = await fixture.recorded()
        let french = TMDbTVDBDiscoveryFixture.query(requests[3])
        XCTAssertEqual(french["country"], "fra")
        XCTAssertEqual(french["lang"], "fra")
        let fallback = TMDbTVDBDiscoveryFixture.query(requests[5])
        XCTAssertEqual(fallback["country"], "usa")
        XCTAssertEqual(fallback["lang"], "eng")
    }

    func testConfigurationFingerprintChangesForKeyAndBaseURLWithoutExposingEither() {
        let first = TVDBDiscoveryProvider(config: config).cacheIdentifier
        let differentKey = TVDBDiscoveryProvider(config: .init(
            apiKey: "different-key", apiBaseURL: config.apiBaseURL
        )).cacheIdentifier
        let differentHost = TVDBDiscoveryProvider(config: .init(
            apiKey: config.apiKey, apiBaseURL: URL(string: "https://other.example/v4")!
        )).cacheIdentifier
        XCTAssertEqual(first, TVDBDiscoveryProvider(config: config).cacheIdentifier)
        XCTAssertNotEqual(first, differentKey)
        XCTAssertNotEqual(first, differentHost)
        XCTAssertEqual(first.count, 69)
        XCTAssertFalse(first.contains("fixture"))
        XCTAssertFalse(first.contains("tvdb.example"))
    }

    func testMapsPosterAndAuthoritativeTVDBOnlyWithoutInventingPlaybackOrLandscape() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            if request.url!.path == "/v4/movies/filter" {
                return .init(json: """
                    {"data":[{"id":42,"name":" Movie ","year":"2020","image":"/banners/poster.jpg"},
                             {"id":42,"name":"Duplicate"},{"id":43,"name":"Second Movie"}]}
                    """)
            }
            if request.url!.path == "/v4/series/filter" {
                return .init(json: """
                    {"data":[{"id":42,"name":"Show","year":"2021","firstAired":"2021-04-03",
                              "overview":" Story ","image":"https://artworks.thetvdb.com/poster.jpg"}]}
                    """)
            }
            return TMDbTVDBDiscoveryFixture.tvdbReply(request)
        }
        let items = try await TVDBDiscoveryProvider(config: config, http: fixture.http).discover(.init())
        XCTAssertEqual(items.map(\.id), ["tvdb:movie:42", "tvdb:series:42", "tvdb:movie:43"])
        XCTAssertEqual(items[0].title, "Movie")
        XCTAssertEqual(items[0].productionYear, 2020)
        XCTAssertEqual(items[0].posterURL?.absoluteString, "https://artworks.thetvdb.com/banners/poster.jpg")
        XCTAssertEqual(items[1].releaseDate, ISO8601DateFormatter().date(from: "2021-04-03T00:00:00Z"))
        XCTAssertEqual(items[1].overview, "Story")
        let service = HeroDiscoveryService()
        let composed = await service.discover(
            .init(), sources: [.tvdb],
            providers: [TVDBDiscoveryProvider(config: config, http: fixture.http)]
        )
        XCTAssertEqual(composed.first { $0.kind == .movie }?.discoveryURLs["tvdb"]?.absoluteString,
                       "https://thetvdb.com/dereferrer/movie/42")
        XCTAssertEqual(composed.first { $0.kind == .series }?.discoveryURLs["tvdb"]?.absoluteString,
                       "https://thetvdb.com/dereferrer/series/42")
        for item in items {
            XCTAssertEqual(item.providerIDs.count, 1)
            XCTAssertNotNil(item.providerIDs["Tvdb"])
            XCTAssertEqual(item.discoverySources, [.tvdb])
            XCTAssertEqual(item.availability, .unknown)
            XCTAssertFalse(item.locallyValidatedPlayableSource)
            XCTAssertNil(item.backdropURL)
            XCTAssertNil(item.heroBackdropURL)
            XCTAssertNil(item.sourceAccountID)
            XCTAssertTrue(item.sources.isEmpty)
        }
    }

    func testInvalidIDsTitlesAdultFlagsAndImageSchemesAreRejected() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            guard request.url!.lastPathComponent == "filter" else {
                return TMDbTVDBDiscoveryFixture.tvdbReply(request)
            }
            return .init(json: """
                {"data":[{"id":0,"name":"Zero"},{"id":-1,"name":"Negative"},
                         {"id":2,"name":" "},{"name":"Missing ID"},
                         {"id":3,"name":"Adult","adult":true},
                         {"id":4,"name":"Adult","isAdult":true},
                         {"id":5,"name":"Good","image":"file:///private/poster"}]}
                """)
        }
        let items = try await TVDBDiscoveryProvider(config: config, http: fixture.http).discover(.init())
        XCTAssertEqual(items.map(\.id), ["tvdb:movie:5", "tvdb:series:5"])
        XCTAssertTrue(items.allSatisfy { $0.posterURL == nil })
    }

    func testLimitAndProviderOrderWithoutPaginationOrDetailFanout() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            guard request.url!.lastPathComponent == "filter" else {
                return TMDbTVDBDiscoveryFixture.tvdbReply(request)
            }
            let records = (1...60).map { #"{"id":\#($0),"name":"Title \#($0)"}"# }.joined(separator: ",")
            return .init(json: #"{"data":[\#(records)]}"#)
        }
        let provider = TVDBDiscoveryProvider(config: config, http: fixture.http)
        let items = try await provider.discover(.init(limit: 3))
        XCTAssertEqual(items.map(\.id), ["tvdb:movie:1", "tvdb:series:1", "tvdb:movie:2"])
        let many = try await provider.discover(.init(limit: 999))
        XCTAssertEqual(many.count, 48)
        XCTAssertEqual(many.filter { $0.kind == .movie }.map { $0.providerIDs["Tvdb"]! },
                       (1...24).map(String.init))
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 7)
        XCTAssertTrue(requests.allSatisfy { TMDbTVDBDiscoveryFixture.query($0)["page"] == nil })
    }

    func testLoginFailureRetainsHTTPStatus() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: "{}", status: 401) }
        do {
            _ = try await TVDBDiscoveryProvider(config: config, http: fixture.http).discover(.init())
            XCTFail("Authentication failures must propagate")
        } catch let error as MetadataDiscoveryHTTPError {
            XCTAssertEqual(error, .status(401, retryAfter: nil))
        }
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 1)
    }

    func testExpiredTokenIsInvalidatedWithoutMaskingOriginalFailure() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, count in
            if count == 5 { return .init(json: "{}", status: 401) }
            return TMDbTVDBDiscoveryFixture.tvdbReply(request)
        }
        let provider = TVDBDiscoveryProvider(config: config, http: fixture.http)
        do {
            _ = try await provider.discover(.init())
            XCTFail("Original 401 must reach the parent cache")
        } catch let error as MetadataDiscoveryHTTPError {
            XCTAssertEqual(error, .status(401, retryAfter: nil))
        }
        let retry = try await provider.discover(.init())
        XCTAssertTrue(retry.isEmpty)
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 8, "Next pass logs in once; locale catalogs remain reusable")
        XCTAssertEqual(requests[5].url?.lastPathComponent, "login")
    }

    func testPartialFilterSuccessDoesNotMaskRateLimit() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            if request.url!.path == "/v4/movies/filter" {
                return .init(json: #"{"data":[{"id":1,"name":"Partial"}]}"#)
            }
            if request.url!.path == "/v4/series/filter" {
                return .init(json: "{}", status: 429, headers: ["Retry-After": "90"])
            }
            return TMDbTVDBDiscoveryFixture.tvdbReply(request)
        }
        do {
            _ = try await TVDBDiscoveryProvider(config: config, http: fixture.http).discover(.init())
            XCTFail("Rate limiting must propagate even after one successful filter")
        } catch let error as MetadataDiscoveryHTTPError {
            XCTAssertEqual(error, .status(429, retryAfter: 90))
        }
    }

    func testMalformedLoginCannotBecomeEmptyDiscovery() async throws {
        for json in ["{}", #"{"data":{"token":""}}"#, #"{"data":{"token":"  "}}"#, "not json"] {
            let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: json) }
            do {
                _ = try await TVDBDiscoveryProvider(config: config, http: fixture.http).discover(.init())
                XCTFail("Missing/invalid JWT must propagate")
            } catch let error as MetadataDiscoveryHTTPError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
    }

    func testMalformedFilterPayloadCannotBecomeSuccessfulEmptyResult() async throws {
        for json in [
            "{}", #"{"data":null}"#, #"{"data":[{"id":"bad"}]}"#,
            #"{"status":"failure","data":[]}"#, "not json"
        ] {
            let fixture = TMDbTVDBDiscoveryFixture { request, _ in
                if request.url!.lastPathComponent == "filter" { return .init(json: json) }
                return TMDbTVDBDiscoveryFixture.tvdbReply(request)
            }
            do {
                _ = try await TVDBDiscoveryProvider(config: config, http: fixture.http).discover(.init())
                XCTFail("Malformed payload must not be cached as an empty success")
            } catch let error as MetadataDiscoveryHTTPError {
                XCTAssertEqual(error, .invalidResponse)
            }
        }
    }

    func testMissingLocaleCatalogFailsInsteadOfSendingInvalidRequiredParameters() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, _ in
            if request.url!.lastPathComponent == "countries" { return .init(json: #"{"data":[]}"#) }
            return TMDbTVDBDiscoveryFixture.tvdbReply(request)
        }
        do {
            _ = try await TVDBDiscoveryProvider(config: config, http: fixture.http).discover(.init())
            XCTFail("Required country must resolve from the official catalog")
        } catch let error as MetadataDiscoveryHTTPError {
            XCTAssertEqual(error, .invalidResponse)
        }
        let requests = await fixture.recorded()
        XCTAssertFalse(requests.contains { $0.url!.lastPathComponent == "filter" })
    }

    func testInvalidLocaleCatalogIsNotCachedAcrossRecovery() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, count in
            if count == 2 { return .init(json: #"{"data":[]}"#) }
            return TMDbTVDBDiscoveryFixture.tvdbReply(request)
        }
        let provider = TVDBDiscoveryProvider(config: config, http: fixture.http)
        do {
            _ = try await provider.discover(.init())
            XCTFail("Invalid catalog must fail")
        } catch let error as MetadataDiscoveryHTTPError {
            XCTAssertEqual(error, .invalidResponse)
        }
        let items = try await provider.discover(.init())
        XCTAssertTrue(items.isEmpty)
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.filter { $0.url!.lastPathComponent == "countries" }.count, 2)
        XCTAssertEqual(requests.filter { $0.url!.lastPathComponent == "login" }.count, 1)
        XCTAssertEqual(requests.count, 6)
    }

    func testCancellationAndNetworkFailuresAreNotSwallowedByAuthentication() async throws {
        for cancellation in [true, false] {
            let fixture = TMDbTVDBDiscoveryFixture { _, _ in
                if cancellation { throw CancellationError() }
                throw URLError(.notConnectedToInternet)
            }
            do {
                _ = try await TVDBDiscoveryProvider(config: config, http: fixture.http).discover(.init())
                XCTFail("Transport errors must remain visible")
            } catch is CancellationError {
                XCTAssertTrue(cancellation)
            } catch let error as URLError {
                XCTAssertFalse(cancellation)
                XCTAssertEqual(error.code, .notConnectedToInternet)
            }
        }
    }
}
