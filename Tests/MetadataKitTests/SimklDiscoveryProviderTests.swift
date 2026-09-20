import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MetadataKit

final class SimklDiscoveryProviderTests: XCTestCase {
    func testCombinedWeeklyShapeMapsCanonicalIDsAndActualFanart() async throws {
        let fixture = PublicFeedDiscoveryTestTransport([.json("""
        {"movies":[{
          "title":"The End of Oak Street","release_date":"08/12/2026",
          "poster":"20/2036989114a175eae4","fanart":"19/19818287730a769e81",
          "ids":{"simkl_id":2123791,"slug":"the-end-of-oak-street","imdb":"tt27165187",
                 "tmdb":"1101383","tvdb":"358926"},
          "genres":["Mystery"],"overview":"A public synopsis.","watched":1777
        }],"tv":[{
          "title":"Reacher","release_date":"02/04/2022",
          "poster":"14/14805333a4805c1d33","fanart":null,
          "ids":{"simkl_id":1130204,"slug":"reacher","imdb":"tt9288030",
                 "tmdb":"108978","tvdb":"366924"},"genres":["Action"],"watched":6966
        }],"anime":[]}
        """)])
        let provider = SimklDiscoveryProvider(http: fixture.http, clientID: "test-registration")
        let items = try await provider.discover(.init())
        XCTAssertEqual(items.map(\.id), ["simkl:movie:2123791", "simkl:series:1130204"])
        XCTAssertEqual(items.map(\.kind), [.movie, .series])
        XCTAssertEqual(items.map(\.productionYear), [2026, 2022])
        XCTAssertEqual(items[0].providerID(.tmdb), "1101383")
        XCTAssertEqual(items[0].providerID(.tvdb), "358926")
        XCTAssertEqual(items[1].providerID(.tmdb), "108978")
        XCTAssertEqual(items[1].providerID(.imdb), "tt9288030")
        XCTAssertEqual(items[0].posterURL?.absoluteString, "https://simkl.in/posters/20/2036989114a175eae4_m.webp")
        XCTAssertEqual(items[0].backdropURL?.absoluteString, "https://simkl.in/fanart/19/19818287730a769e81_medium.webp")
        XCTAssertNil(items[1].backdropURL)
        XCTAssertNil(items[1].heroBackdropURL)
        XCTAssertEqual(items[0].metadataProvenance[.title]?.sourceURL?.absoluteString, "https://simkl.com/movies/2123791/the-end-of-oak-street")
        for item in items {
            XCTAssertEqual(item.discoverySources, [.simkl])
            XCTAssertEqual(item.availability, .unknown)
            XCTAssertFalse(item.locallyValidatedPlayableSource)
            XCTAssertNil(item.sourceAccountID)
            XCTAssertTrue(item.sources.isEmpty)
            XCTAssertTrue(item.ratings.isEmpty)
        }
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "data.simkl.in")
        XCTAssertEqual(url.path, "/discover/trending/week_100.json")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Set(query.map(\.name)), ["client_id", "app-name", "app-version"])
        XCTAssertEqual(query.first { $0.name == "client_id" }?.value, "test-registration")
        XCTAssertEqual(query.first { $0.name == "app-name" }?.value, "Plozz")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Plozz/") == true)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.httpBody)
    }

    func testMovieAndSeriesIDsCannotCollideAndAnimeIsOptIn() async throws {
        let feed = """
        {"movies":[{"title":"Movie","ids":{"simkl_id":1,"tmdb":42}}],
         "tv":[{"title":"Series","ids":{"simkl_id":"1","tmdb":"42"}}],
         "anime":[
           {"title":"Anime Movie","anime_type":"movie","ids":{"simkl_id":3,"mal":"0","anilist":"5"}},
           {"title":"Anime Series","anime_type":"tv","ids":{"simkl_id":4,"mal":"21","anidb":"69"}},
           {"title":"Original Video","anime_type":"ova","ids":{"simkl_id":5,"mal":null}},
           {"title":"Unknown format","ids":{"simkl_id":6}},
           {"title":"Music video","anime_type":"music video","ids":{"simkl_id":7}}
         ]}
        """
        let fixture = PublicFeedDiscoveryTestTransport([.json(feed), .json(feed)])
        let general = SimklDiscoveryProvider(http: fixture.http, clientID: "test")
        let optedIn = SimklDiscoveryProvider(http: fixture.http, clientID: "test", includesAnime: true)
        let ordinary = try await general.discover(.init())
        let anime = try await optedIn.discover(.init())
        XCTAssertEqual(ordinary.map(\.id), ["simkl:movie:1", "simkl:series:1"])
        XCTAssertEqual(anime.map(\.id), ["simkl:movie:1", "simkl:series:1", "simkl:movie:3", "simkl:series:4", "simkl:series:5"])
        XCTAssertEqual(anime[2].providerID(.aniList), "5")
        XCTAssertNil(anime[2].providerID(.myAnimeList))
        XCTAssertEqual(anime[3].providerID(.myAnimeList), "21")
        XCTAssertEqual(anime[3].providerID(.aniDB), "69")
        XCTAssertNotEqual(general.cacheIdentifier, optedIn.cacheIdentifier)
    }

    func testFiltersExplicitAdultFlagsMissingIDsAndDuplicateEntries() async throws {
        let fixture = PublicFeedDiscoveryTestTransport([.json("""
        {"movies":[
          {"title":"Adult","adult":true,"ids":{"simkl_id":1}},
          {"title":"Adult alias","is_adult":true,"ids":{"simkl_id":2}},
          {"title":"Adult camel","isAdult":true,"ids":{"simkl_id":3}},
          {"title":"No ID","ids":{"imdb":"tt123"}},
          {"title":"Zero","ids":{"simkl_id":0}},
          {"title":"Negative","ids":{"simkl_id":-1}},
          {"title":" ","ids":{"simkl_id":9}},
          {"title":"Valid","ids":{"simkl_id":10,"tmdb":"0","mal":"-1","tvdb":"missing","imdb":"bad"},
           "release_date":"02/30/2026","poster":"https://untrusted.invalid/image.jpg","fanart":"../wrong"},
          {"title":"Duplicate","ids":{"simkl_id":10}}
        ],"tv":[],"anime":[
          {"title":"Adult genre","anime_type":"tv","genres":["Hentai"],"ids":{"simkl_id":20}}
        ]}
        """)])
        let items = try await SimklDiscoveryProvider(
            http: fixture.http, clientID: "test", includesAnime: true
        ).discover(.init())
        XCTAssertEqual(items.map(\.id), ["simkl:movie:10"])
        XCTAssertTrue(items[0].providerIDs.isEmpty)
        XCTAssertNil(items[0].productionYear)
        XCTAssertNil(items[0].releaseDate)
        XCTAssertNil(items[0].posterURL)
        XCTAssertNil(items[0].backdropURL)
    }

    func testBoundedSingleRequestAndOutputClamp() async throws {
        let movies = (1...100).map { #"{"title":"Movie","ids":{"simkl_id":\#($0)}}"# }
        let feed = #"{"movies":[\#(movies.joined(separator: ","))],"tv":[],"anime":[]}"#
        let fixture = PublicFeedDiscoveryTestTransport([.json(feed), .json(feed)])
        let provider = SimklDiscoveryProvider(http: fixture.http, clientID: "test")
        let limited = try await provider.discover(.init(limit: 2))
        let clamped = try await provider.discover(.init(limit: 1_000))
        XCTAssertEqual(limited.count, 2)
        XCTAssertEqual(clamped.count, 48)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path.hasSuffix("week_100.json") == true })
    }

    func testUnconfiguredDisabledAndZeroLimitPerformNoIOAndFingerprintIsOpaque() async throws {
        let fixture = PublicFeedDiscoveryTestTransport([])
        let providers = [
            SimklDiscoveryProvider(http: fixture.http, clientID: ""),
            SimklDiscoveryProvider(http: fixture.http, clientID: "$(SIMKL_CLIENT_ID)"),
            SimklDiscoveryProvider(http: fixture.http, clientID: "test", isEnabled: false),
        ]
        for provider in providers {
            XCTAssertFalse(provider.isEnabled)
            let items = try await provider.discover(.init())
            XCTAssertTrue(items.isEmpty)
        }
        let provider = SimklDiscoveryProvider(http: fixture.http, clientID: "registration-one")
        let zero = try await provider.discover(.init(limit: 0))
        XCTAssertTrue(zero.isEmpty)
        XCTAssertFalse(provider.cacheIdentifier.contains("registration-one"))
        XCTAssertNotEqual(provider.cacheIdentifier,
                          SimklDiscoveryProvider(clientID: "registration-two").cacheIdentifier)
        let requests = await fixture.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testFailuresPropagateWithoutRetriesOrFakeEmptyResults() async throws {
        let fixture = PublicFeedDiscoveryTestTransport([
            .response("{}", 429, ["Retry-After": "90"]),
            .cancelled, .networkFailure, .json("{}"),
            .json(#"{"movies":[],"tv":[],"anime":[]}"#),
        ])
        let provider = SimklDiscoveryProvider(http: fixture.http, clientID: "test")
        do {
            _ = try await provider.discover(.init())
            XCTFail("HTTP failure must propagate")
        } catch {
            XCTAssertEqual(error as? MetadataDiscoveryHTTPError, .status(429, retryAfter: 90))
        }
        do {
            _ = try await provider.discover(.init())
            XCTFail("Cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        do {
            _ = try await provider.discover(.init())
            XCTFail("Network failure must propagate")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        do {
            _ = try await provider.discover(.init())
            XCTFail("A missing feed envelope is not an empty feed")
        } catch {
            XCTAssertEqual(error as? MetadataDiscoveryHTTPError, .invalidResponse)
        }
        let empty = try await provider.discover(.init())
        XCTAssertTrue(empty.isEmpty)
        let requests = await fixture.requests
        XCTAssertEqual(requests.count, 5)
    }
}
