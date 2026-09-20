import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MetadataKit

final class TVmazeDiscoveryProviderTests: XCTestCase {
    func testBroadcastAndEmbeddedWebPremieresDeduplicateByShowNotEpisode() async throws {
        let today = "2026-09-19"
        let tomorrow = "2026-09-20"
        let fixture = PublicFeedDiscoveryTestTransport([
            .json("[\(Self.episode(showID: 42, episodeID: 900, day: today))]"),
            .json("""
            [\(Self.episode(showID: 42, episodeID: 901, day: today, embedded: true)),
             \(Self.episode(showID: 43, episodeID: 902, day: today, embedded: true))]
            """),
            .json("[\(Self.episode(showID: 42, episodeID: 903, day: tomorrow))]"),
            .json("[]"),
        ])
        let items = try await TVmazeDiscoveryProvider(http: fixture.http).discover(
            .init(now: Self.date("2026-09-19T23:59:59Z"))
        )
        XCTAssertEqual(items.map(\.id), ["tvmaze:series:42", "tvmaze:series:43"])
        XCTAssertEqual(items[0].providerID(.tvmaze), "42")
        XCTAssertEqual(items[0].providerID(.tvdb), "366924")
        XCTAssertEqual(items[0].providerID(.imdb), "tt9288030")
        for item in items {
            XCTAssertEqual(item.kind, .series)
            XCTAssertEqual(item.title, "Returning Show")
            XCTAssertEqual(item.productionYear, 2018)
            XCTAssertEqual(item.releaseDate, Self.date("2018-12-31T00:00:00Z"))
            XCTAssertEqual(item.overview, "Show summary & details.")
            XCTAssertEqual(item.posterURL?.absoluteString, "https://static.tvmaze.com/uploads/images/original_untouched/42/poster.jpg")
            XCTAssertNil(item.backdropURL)
            XCTAssertNil(item.heroBackdropURL)
            XCTAssertNil(item.scheduledAirDate)
            XCTAssertNil(item.episodeNumber)
            XCTAssertNil(item.seasonNumber)
            XCTAssertEqual(item.discoverySources, [.tvmaze])
            XCTAssertEqual(item.availability, .unknown)
            XCTAssertFalse(item.locallyValidatedPlayableSource)
            XCTAssertNil(item.sourceAccountID)
            XCTAssertTrue(item.sources.isEmpty)
            XCTAssertTrue(item.ratings.isEmpty)
        }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.compactMap { $0.url?.path }, ["/schedule", "/schedule/web", "/schedule", "/schedule/web"])
        for request in requests {
            XCTAssertEqual(request.url?.host, "api.tvmaze.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.httpBody)
            XCTAssertFalse(request.url?.path.contains("full") == true)
        }
    }

    func testUTCDateAndRegionNormalizationCrossYearBoundary() async throws {
        let fixture = PublicFeedDiscoveryTestTransport(Array(repeating: .json("[]"), count: 4))
        let provider = TVmazeDiscoveryProvider(http: fixture.http)
        _ = try await provider.discover(.init(region: " uk ", now: Self.date("2026-01-01T00:30:00+14:00")))
        let requests = await fixture.requests
        let queries = try requests.map { request -> [String: String] in
            let url = try XCTUnwrap(request.url)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }
        XCTAssertEqual(queries.map { $0["date"] }, ["2025-12-31", "2025-12-31", "2026-01-01", "2026-01-01"])
        XCTAssertEqual(queries.map { $0["country"] }, ["GB", "", "GB", ""])
        XCTAssertTrue(queries.allSatisfy { Set($0.keys) == ["date", "country"] })
    }

    func testInvalidRegionFallsBackWithoutQueryInjectionAndValidRegionIsUppercased() async throws {
        for (region, expected) in [("not-a-region&date=1900-01-01", "US"), ("ca", "CA"), ("", "US")] {
            let fixture = PublicFeedDiscoveryTestTransport(Array(repeating: .json("[]"), count: 4))
            _ = try await TVmazeDiscoveryProvider(http: fixture.http).discover(.init(region: region))
            let requests = await fixture.requests
            let url = try XCTUnwrap(requests.first?.url)
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(query.count, 2)
            XCTAssertEqual(query.first { $0.name == "country" }?.value, expected)
        }
    }

    func testOnlyEpisodeOneRegularPremieresQualifyAndNoEligibleIsSuccess() async throws {
        let today = "2026-09-19"
        let fixture = PublicFeedDiscoveryTestTransport([
            .json("""
            [\(Self.episode(showID: 1, day: today, number: "2")),
             \(Self.episode(showID: 2, day: today, number: "null")),
             \(Self.episode(showID: 3, day: today, season: 0)),
             \(Self.episode(showID: 4, day: today, type: "significant_special")),
             \(Self.episode(showID: 5, day: "2026-09-18")),
             \(Self.episode(showID: 6, day: today, adult: true)),
             {"number":1,"season":1,"type":"regular","airdate":"2026-09-19"}]
            """),
            .json("[]"), .json("[]"), .json("[]"),
        ])
        let items = try await TVmazeDiscoveryProvider(http: fixture.http).discover(
            .init(now: Self.date("2026-09-19T00:00:00Z"))
        )
        XCTAssertTrue(items.isEmpty)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 4)
    }

    func testMissingPremiereDoesNotUseUpcomingEpisodeYearOrInventIDs() async throws {
        let fixture = PublicFeedDiscoveryTestTransport([.json("""
        [{"id":1000,"number":1,"season":4,"airdate":"2026-09-19","show":{
          "id":44,"name":"Undated","premiered":null,"externals":{"thetvdb":0,"imdb":null},"image":null
        }}]
        """)])
        let items = try await TVmazeDiscoveryProvider(http: fixture.http).discover(
            .init(limit: 1, now: Self.date("2026-09-19T00:00:00Z"))
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].providerIDs, [ProviderIDNamespace.tvmaze.canonicalKey: "44"])
        XCTAssertNil(items[0].productionYear)
        XCTAssertNil(items[0].releaseDate)
        XCTAssertNil(items[0].posterURL)
    }

    func testStopsAtLimitWithoutFetchingRemainingDaysAndCapsAt48() async throws {
        let episodes = (1...60).map { Self.episode(showID: $0, day: "2026-09-19") }.joined(separator: ",")
        let fixture = PublicFeedDiscoveryTestTransport([.json("[\(episodes)]"), .json("[\(episodes)]")])
        let provider = TVmazeDiscoveryProvider(http: fixture.http)
        let now = Self.date("2026-09-19T00:00:00Z")
        let limited = try await provider.discover(.init(limit: 1, now: now))
        let clamped = try await provider.discover(.init(limit: 500, now: now))
        XCTAssertEqual(limited.count, 1)
        XCTAssertEqual(clamped.count, 48)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testZeroLimitAndDisabledDoNotRequestSchedules() async throws {
        let fixture = PublicFeedDiscoveryTestTransport([])
        let zero = try await TVmazeDiscoveryProvider(http: fixture.http).discover(.init(limit: 0))
        let disabled = try await TVmazeDiscoveryProvider(http: fixture.http, isEnabled: false).discover(.init())
        XCTAssertTrue(zero.isEmpty)
        XCTAssertTrue(disabled.isEmpty)
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testHTTP429CancellationAndMalformedResponsesPropagate() async throws {
        let fixture = PublicFeedDiscoveryTestTransport([
            .response("{}", 429, ["Retry-After": "10"]), .cancelled, .json("{}"),
        ])
        let provider = TVmazeDiscoveryProvider(http: fixture.http)
        do {
            _ = try await provider.discover(.init())
            XCTFail("HTTP failure must propagate")
        } catch {
            XCTAssertEqual(error as? MetadataDiscoveryHTTPError, .status(429, retryAfter: 10))
        }
        do {
            _ = try await provider.discover(.init())
            XCTFail("Cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        do {
            _ = try await provider.discover(.init())
            XCTFail("A missing schedule is not an empty schedule")
        } catch {
            XCTAssertEqual(error as? MetadataDiscoveryHTTPError, .invalidResponse)
        }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 3)
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func episode(
        showID: Int,
        episodeID: Int = 900,
        day: String,
        number: String = "1",
        season: Int = 2,
        type: String = "regular",
        embedded: Bool = false,
        adult: Bool = false
    ) -> String {
        let show = """
        {"id":\(showID),"name":"Returning Show","premiered":"2018-12-31","isAdult":\(adult),
         "summary":"<p>Show summary &amp; details.</p>","genres":["Drama"],
         "externals":{"thetvdb":366924,"imdb":"tt9288030"},
         "image":{"original":"https://static.tvmaze.com/uploads/images/original_untouched/42/poster.jpg"}}
        """
        let envelope = embedded ? #""_embedded":{"show":\#(show)}"# : #""show":\#(show)"#
        return """
        {"id":\(episodeID),"name":"Premiere episode","season":\(season),"number":\(number),
         "type":"\(type)","airdate":"\(day)","airtime":"20:00",
         "image":{"original":"https://static.tvmaze.com/episode-still.jpg"},\(envelope)}
        """
    }
}
