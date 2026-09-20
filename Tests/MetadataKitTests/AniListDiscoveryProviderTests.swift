import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MetadataKit

final class AniListDiscoveryProviderTests: XCTestCase {
    func testPublicGraphQLShapeMixesSeasonalTrendingAndPreservesMovieIdentity() async throws {
        let movie = Self.media(id: 16498, format: "MOVIE", mal: 0)
        let series = Self.media(id: 21, format: "TV", mal: 21)
        let seasonal = Self.media(id: 178789, format: "ONA", mal: 59193)
        let fixture = PublicFeedDiscoveryTestTransport([
            .json(Self.response(trending: [movie, series], seasonal: [movie, seasonal])),
        ])
        let provider = AniListDiscoveryProvider(http: fixture.http)
        let items = try await provider.discover(.init(limit: 3, language: "ja-JP"))

        XCTAssertEqual(items.map(\.id), ["anilist:movie:16498", "anilist:series:21", "anilist:series:178789"])
        XCTAssertEqual(items.map(\.kind), [.movie, .series, .series])
        XCTAssertEqual(items[0].title, "日本語")
        XCTAssertEqual(items[0].providerID(.aniList), "16498")
        XCTAssertNil(items[0].providerID(.myAnimeList))
        XCTAssertEqual(items[1].providerID(.myAnimeList), "21")
        XCTAssertEqual(items[0].productionYear, 2024)
        XCTAssertEqual(items[0].releaseDate, Self.date("2024-04-01T00:00:00Z"))
        XCTAssertEqual(items[0].posterURL?.absoluteString, "https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/a.jpg")
        XCTAssertEqual(items[0].backdropURL?.absoluteString, "https://s4.anilist.co/file/anilistcdn/media/anime/banner/a.jpg")
        XCTAssertEqual(items[0].metadataProvenance[.title]?.sourceURL?.absoluteString, "https://anilist.co/anime/16498")
        for item in items {
            XCTAssertEqual(item.discoverySources, [.anilist])
            XCTAssertEqual(item.availability, .unknown)
            XCTAssertFalse(item.locallyValidatedPlayableSource)
            XCTAssertNil(item.sourceAccountID)
            XCTAssertTrue(item.sources.isEmpty)
            XCTAssertTrue(item.ratings.isEmpty)
        }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://graphql.anilist.co")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        let body = try XCTUnwrap(request.httpBody)
        let query = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let document = try XCTUnwrap(query["query"] as? String)
        XCTAssertTrue(document.contains("isAdult: false"))
        XCTAssertTrue(document.contains("TRENDING_DESC"))
        XCTAssertTrue(document.contains("POPULARITY_DESC"))
        XCTAssertFalse(document.contains("onList"))
    }

    func testRejectsAdultUnsupportedFormatsAndInvalidIDsWithoutPosterBackdropFallback() async throws {
        let valid = """
        {"id":7,"idMal":null,"type":"ANIME","format":"TV_SHORT","isAdult":false,
         "title":{"english":" ","romaji":"Fallback"},"startDate":{"year":2026,"month":0,"day":0},
         "coverImage":{"large":"https://s4.anilist.co/poster.jpg"},"bannerImage":null}
        """
        let fixture = PublicFeedDiscoveryTestTransport([
            .json(Self.response(trending: [
                Self.media(id: 1, adult: true), Self.media(id: 0),
                Self.media(id: 2, format: "MUSIC"), Self.media(id: 3, format: "SPECIAL"),
                Self.media(id: 4, format: "MANGA"), valid,
            ], seasonal: [])),
        ])
        let items = try await AniListDiscoveryProvider(http: fixture.http).discover(.init())
        XCTAssertEqual(items.map(\.id), ["anilist:series:7"])
        XCTAssertEqual(items.first?.title, "Fallback")
        XCTAssertEqual(items.first?.productionYear, 2026)
        XCTAssertNil(items.first?.releaseDate)
        XCTAssertNil(items.first?.backdropURL)
        XCTAssertNil(items.first?.heroBackdropURL)
        XCTAssertNotNil(items.first?.posterURL)
    }

    func testUTCSeasonAndYearBoundaries() async throws {
        let dates: [(String, String, Int)] = [
            ("2025-12-31T23:59:59Z", "FALL", 2025),
            ("2026-01-01T00:00:00Z", "WINTER", 2026),
            ("2026-04-01T00:00:00Z", "SPRING", 2026),
            ("2026-07-01T00:00:00Z", "SUMMER", 2026),
            ("2026-10-01T00:00:00Z", "FALL", 2026),
        ]
        let fixture = PublicFeedDiscoveryTestTransport(
            dates.map { _ in .json(Self.response(trending: [], seasonal: [])) }
        )
        let provider = AniListDiscoveryProvider(http: fixture.http)
        for (instant, _, _) in dates {
            _ = try await provider.discover(.init(limit: 2, now: Self.date(instant)))
        }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, dates.count)
        for (request, expected) in zip(requests, dates) {
            let body = try XCTUnwrap(request.httpBody)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let variables = try XCTUnwrap(root["variables"] as? [String: Any])
            XCTAssertEqual(variables["season"] as? String, expected.1)
            XCTAssertEqual(variables["year"] as? Int, expected.2)
            XCTAssertEqual(variables["perPage"] as? Int, 2)
        }
    }

    func testLimitClampUsesOneBoundedRequestAndNoPrivateSeeds() async throws {
        let media = (1...60).map { Self.media(id: $0) }
        let fixture = PublicFeedDiscoveryTestTransport([.json(Self.response(trending: media, seasonal: media))])
        let seed = MediaItem(id: "private-id", title: "Private library title", kind: .movie, sourceAccountID: "account-secret")
        let items = try await AniListDiscoveryProvider(http: fixture.http).discover(.init(limit: 999, seeds: [seed]))
        XCTAssertEqual(items.count, 48)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.first?.httpBody)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((root["variables"] as? [String: Any])?["perPage"] as? Int, 48)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(bodyText.contains("Private library title"))
        XCTAssertFalse(bodyText.contains("account-secret"))
    }

    func testDisabledAndZeroLimitPerformNoIO() async throws {
        let fixture = PublicFeedDiscoveryTestTransport([])
        let disabled = AniListDiscoveryProvider(http: fixture.http, isEnabled: false)
        let enabled = AniListDiscoveryProvider(http: fixture.http)
        let disabledItems = try await disabled.discover(.init())
        let zeroItems = try await enabled.discover(.init(limit: 0))
        let negativeItems = try await enabled.discover(.init(limit: -1))
        XCTAssertTrue(disabledItems.isEmpty)
        XCTAssertTrue(zeroItems.isEmpty)
        XCTAssertTrue(negativeItems.isEmpty)
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testGraphQLErrorsRejectPartialDataAndMissingDataIsNotEmptySuccess() async throws {
        let fixture = PublicFeedDiscoveryTestTransport([
            .json("""
            {"data":{"trending":{"media":[]},"seasonal":{"media":[]}},
             "errors":[{"message":"Too Many Requests.","status":429}]}
            """),
            .json(#"{"data":null}"#),
            .json(Self.response(trending: [], seasonal: [])),
        ])
        let provider = AniListDiscoveryProvider(http: fixture.http)
        do {
            _ = try await provider.discover(.init())
            XCTFail("GraphQL errors must reach the compositor")
        } catch {
            XCTAssertEqual(error as? AniListDiscoveryError, .graphQL)
        }
        do {
            _ = try await provider.discover(.init())
            XCTFail("Missing data is a malformed response")
        } catch {
            XCTAssertEqual(error as? MetadataDiscoveryHTTPError, .invalidResponse)
        }
        let empty = try await provider.discover(.init())
        XCTAssertTrue(empty.isEmpty)
    }

    func testHTTP429AndCancellationPropagateWithoutRetries() async throws {
        let fixture = PublicFeedDiscoveryTestTransport([
            .response("{}", 429, ["Retry-After": "60"]), .cancelled,
        ])
        let provider = AniListDiscoveryProvider(http: fixture.http)
        do {
            _ = try await provider.discover(.init())
            XCTFail("HTTP failure must propagate")
        } catch {
            XCTAssertEqual(error as? MetadataDiscoveryHTTPError, .status(429, retryAfter: 60))
        }
        do {
            _ = try await provider.discover(.init())
            XCTFail("Cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func response(trending: [String], seasonal: [String]) -> String {
        """
        {"data":{"trending":{"media":[\(trending.joined(separator: ","))]},
                 "seasonal":{"media":[\(seasonal.joined(separator: ","))]}}}
        """
    }

    private static func media(id: Int, format: String = "TV", mal: Int = 0, adult: Bool = false) -> String {
        """
        {"id":\(id),"idMal":\(mal),"type":"ANIME","format":"\(format)","isAdult":\(adult),
         "title":{"english":"English","romaji":"Romaji","native":"日本語"},
         "startDate":{"year":2024,"month":4,"day":1},"description":"A public synopsis.",
         "genres":["Action"],"bannerImage":"https://s4.anilist.co/file/anilistcdn/media/anime/banner/a.jpg",
         "coverImage":{"extraLarge":"https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/a.jpg"}}
        """
    }
}

/// Per-test actor transport shared only by the three public-feed fixture suites.
actor PublicFeedDiscoveryTestTransport {
    enum Reply: Sendable {
        case response(String, Int, [String: String])
        case cancelled
        case networkFailure

        static func json(_ body: String) -> Reply { .response(body, 200, [:]) }
    }
    enum Failure: Error { case unexpectedRequest }
    private let replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    nonisolated var http: MetadataDiscoveryHTTPClient {
        MetadataDiscoveryHTTPClient { request in try await self.send(request) }
    }

    private func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        guard index < replies.count else { throw Failure.unexpectedRequest }
        switch replies[index] {
        case let .response(body, status, headers):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers) else {
                throw Failure.unexpectedRequest
            }
            return (Data(body.utf8), response)
        case .cancelled:
            throw CancellationError()
        case .networkFailure:
            throw URLError(.notConnectedToInternet)
        }
    }
}
