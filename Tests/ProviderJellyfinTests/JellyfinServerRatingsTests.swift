import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

final class JellyfinServerRatingsTests: XCTestCase {
    private let itemID = "0123456789abcdef0123456789abcdef"
    private let cachePath = "/Plugins/MdbListRatings/CachedByItemId"

    private func session(kind: ProviderKind = .jellyfin, token: String = "test-token") -> UserSession {
        UserSession(
            server: MediaServer(
                id: "server", name: "Server", baseURL: URL(string: "https://server.invalid/jellyfin")!,
                provider: kind
            ),
            userID: "viewer", userName: "Viewer", deviceID: "test-device", accessToken: token
        )
    }

    private func stubItem(_ http: StubHTTPClient, type: String = "Movie", id: String? = nil) {
        let id = id ?? itemID
        http.stub(pathSuffix: "/Users/viewer/Items/\(id)", json: """
        {"Id":"\(id)","Name":"Title","Type":"\(type)","CommunityRating":7.2,"CriticRating":74,
         "ProviderIds":{"Tmdb":"123","Imdb":"tt1234567"}}
        """)
    }

    private func response(_ entries: String) -> String {
        #"{"hasCache":true,"ratings":["# + entries + "]}"
    }

    private func ratedItem(_ provider: JellyfinProvider, id: String? = nil) async throws -> MediaItem {
        var authorized = try await provider.item(id: id ?? itemID)
        if let supplied = try await provider.serverRatings(for: authorized) {
            authorized.ratings = supplied
            authorized.usesProviderRatings = true
        }
        return authorized
    }

    func testReadsOnlyAuthenticatedServerCacheAndUsesExistingDisplayContract() async throws {
        let http = StubHTTPClient()
        stubItem(http)
        http.stub(pathSuffix: cachePath, json: response("""
        {"source":"imdb","value":8.7,"score":87,"votes":1234},
        {"source":"tomatoes","value":94,"score":94},
        {"source":"popcorn","value":88,"score":88},
        {"source":"letterboxd","value":4.1,"score":82},
        {"source":"tmdb","value":87,"score":87},
        {"source":"custom_service","value":9,"score":90}
        """))
        let provider = JellyfinProvider(session: session(), http: http)

        let item = try await ratedItem(provider)

        XCTAssertTrue(item.usesProviderRatings)
        XCTAssertEqual(item.ratings.map(\.id), ["imdb", "tomatoes", "popcorn", "letterboxd", "tmdb", "custom_service"])
        XCTAssertEqual(item.ratings.map(\.displayValue), ["8.7", "94%", "88%", "4.1/5", "8.7", "90/100"])
        XCTAssertEqual(item.ratings.map(\.sortRank), Array(0..<6))
        XCTAssertEqual(item.ratings.map(\.displayName), ["IMDb", "Rotten Tomatoes", "RT Audience", "Letterboxd", "TMDB", "custom_service"])
        XCTAssertEqual(item.ratings.first?.ratingCount, 1234)
        XCTAssertFalse(item.ratings.contains { $0.source == .community })
        XCTAssertEqual(http.sentPaths, ["/Users/viewer/Items/\(itemID)", cachePath])
        XCTAssertTrue(http.sentBaseURLs.allSatisfy { $0 == session().server.baseURL })
        XCTAssertEqual(http.sentMethods, [.get, .get])
        XCTAssertEqual(http.queryItems(forPathSuffix: cachePath), [URLQueryItem(name: "itemId", value: itemID)])
        XCTAssertTrue(http.sentHeaders.last?["Authorization"]?.contains("test-token") == true)
        XCTAssertEqual(http.sentRedirectPolicies.last, .sameOrigin)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item)).ratings, item.ratings)
    }

    func testSupportsEachItemsOwnCacheWithoutUsingParentOrExternalIDs() async throws {
        for type in ["Movie", "Series", "Season", "Episode"] {
            let http = StubHTTPClient()
            stubItem(http, type: type)
            http.stub(pathSuffix: cachePath, json: response(#"{"source":"imdb","score":81}"#))
            let item = try await ratedItem(JellyfinProvider(session: session(), http: http))
            XCTAssertTrue(item.usesProviderRatings, type)
            XCTAssertEqual(http.queryItems(forPathSuffix: cachePath), [URLQueryItem(name: "itemId", value: itemID)], type)
            XCTAssertEqual(item.ratings.first?.displayValue, "8.1", type)
        }
    }

    func testDeduplicatesEquivalentSourcesByVotesAndKeepsFirstOnTies() throws {
        let decoded = try JSONDecoder().decode(MdbListCachedRatings.self, from: Data(response("""
        {"source":"imdb","score":80,"votes":100},
        {"source":"tmdb","score":75},
        {"source":"whatson_imdb","score":85,"votes":200},
        {"source":"simkl_imdb","score":90,"votes":200},
        {"source":"whatson_tmdb","score":77,"votes":10},
        {"source":"metacriticus","score":65},
        {"source":"whatson_metacriticuser","score":70,"votes":25}
        """).utf8))
        let ratings = decoded.displayRatings()
        XCTAssertEqual(ratings.map(\.id), ["imdb", "tmdb", "metacriticuser"])
        XCTAssertEqual(ratings.map(\.displayValue), ["8.5", "7.7", "70/100"])
        XCTAssertEqual(ratings.map(\.sortRank), [0, 1, 2])
        XCTAssertEqual(ratings.first?.displayName, "IMDb (WhatsOn)")
    }

    func testNativeFallbackUsesKnownPluginScalesRatherThanGuessingFromMagnitude() throws {
        let decoded = try JSONDecoder().decode(MdbListCachedRatings.self, from: Data(response("""
        {"source":"imdb","value":8},
        {"source":"tmdb","value":8},
        {"source":"whatson_tmdb","value":8},
        {"source":"tomatoes","value":8},
        {"source":"letterboxd","value":4},
        {"source":"unknown","value":4}
        """).utf8))
        let ratings = decoded.displayRatings()
        XCTAssertEqual(ratings.map(\.id), ["imdb", "tmdb", "tomatoes", "letterboxd"])
        XCTAssertEqual(ratings.map(\.displayValue), ["8.0", "0.8", "8%", "4/5"])
        XCTAssertEqual(ratings[1].displayName, "TMDB")
    }

    func testMalformedEntriesDoNotDiscardUsableRatingsOrInventUnknownScales() throws {
        let decoded = try JSONDecoder().decode(MdbListCachedRatings.self, from: Data(response("""
        null, {"source":12,"score":80}, {"source":"imdb","score":"N/A"},
        {"source":"tomatoes","score":-1}, {"source":"letterboxd","score":101},
        {"source":" ","score":80}, {"source":"unknown","value":4},
        {"source":"metacritic","score":0,"votes":-1},
        {"source":"other_service","score":45}
        """).utf8))
        let ratings = decoded.displayRatings()
        XCTAssertEqual(ratings.map(\.id), ["metacritic", "other_service"])
        XCTAssertEqual(ratings.map(\.displayValue), ["0/100", "45/100"])
        XCTAssertNil(ratings.first?.ratingCount)
    }

    func testMissingEmptyOrUnusableCachePreservesNativeRatings() async throws {
        for json in [
            #"{"hasCache":false}"#,
            response(""),
            response(#"{"source":"imdb","score":101}"#)
        ] {
            let http = StubHTTPClient()
            stubItem(http)
            http.stub(pathSuffix: cachePath, json: json)
            let item = try await ratedItem(JellyfinProvider(session: session(), http: http))
            XCTAssertFalse(item.usesProviderRatings)
            XCTAssertEqual(item.ratings.map(\.value), [7.2, 74])
        }
    }

    func testMissingPluginIsNotReprobedForEveryItem() async throws {
        let http = StubHTTPClient()
        stubItem(http)
        let provider = JellyfinProvider(session: session(), http: http)
        let first = try await ratedItem(provider)
        let second = try await ratedItem(provider)
        XCTAssertEqual(first.ratings, second.ratings)
        XCTAssertEqual(http.sentPaths.filter { $0 == cachePath }.count, 1)
    }

    func testPluginFailuresDoNotHideUsableItemAndTransientFailuresAreRetried() async throws {
        for status in [200, 401, 500] {
            let http = StubHTTPClient()
            stubItem(http)
            http.stub(pathSuffix: cachePath, json: #"{"unexpected":true}"#, status: status)
            let provider = JellyfinProvider(session: session(), http: http)
            let first = try await ratedItem(provider)
            XCTAssertFalse(first.usesProviderRatings)
            XCTAssertEqual(first.ratings.map(\.value), [7.2, 74])
            _ = try await ratedItem(provider)
            XCTAssertEqual(http.sentPaths.filter { $0 == cachePath }.count, 2)
        }
    }

    func testAvailabilityAndScoresAreNotSharedAcrossAuthenticatedProviders() async throws {
        let absent = StubHTTPClient()
        stubItem(absent)
        _ = try await ratedItem(JellyfinProvider(session: session(), http: absent))
        let available = StubHTTPClient()
        stubItem(available)
        available.stub(pathSuffix: cachePath, json: response(#"{"source":"imdb","score":91}"#))
        let item = try await ratedItem(JellyfinProvider(session: session(token: "other-token"), http: available))
        XCTAssertEqual(item.ratings.first?.displayValue, "9.1")
        XCTAssertTrue(available.sentHeaders.last?["Authorization"]?.contains("other-token") == true)
    }

    func testDoesNotProbeEmbyUnsupportedTypesOrSyntheticIDs() async throws {
        for (kind, type, id) in [
            (ProviderKind.emby, "Movie", itemID),
            (.jellyfin, "CollectionFolder", itemID),
            (.jellyfin, "Movie", "synthetic-movie")
        ] {
            let http = StubHTTPClient()
            stubItem(http, type: type, id: id)
            _ = try await ratedItem(JellyfinProvider(session: session(kind: kind), http: http), id: id)
            XCTAssertEqual(http.sentPaths, ["/Users/viewer/Items/\(id)"])
        }
    }

    func testDoesNotReadCacheWhenAuthorizedItemFetchFails() async {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/viewer/Items/\(itemID)", json: "{}", status: 403)
        do {
            _ = try await JellyfinProvider(session: session(), http: http).item(id: itemID)
            XCTFail("Expected item authorization to fail.")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthorized)
        }
        XCTAssertEqual(http.sentPaths, ["/Users/viewer/Items/\(itemID)"])
    }

    func testRequiredItemFetchNeverCallsTheOptionalCache() async throws {
        let http = StubHTTPClient()
        stubItem(http)
        http.stub(pathSuffix: cachePath, json: response(#"{"source":"imdb","score":87}"#))
        let item = try await JellyfinProvider(session: session(), http: http).item(id: itemID)
        XCTAssertFalse(item.usesProviderRatings)
        XCTAssertEqual(item.ratings.map(\.value), [7.2, 74])
        XCTAssertEqual(http.sentPaths, ["/Users/viewer/Items/\(itemID)"])
    }

    func testRepeatedPresentationReadsReuseScopedServerMetadata() async throws {
        let http = StubHTTPClient()
        stubItem(http)
        http.stub(pathSuffix: cachePath, json: response(#"{"source":"imdb","score":87}"#))
        let provider = JellyfinProvider(session: session(), http: http)
        let first = try await ratedItem(provider)
        let second = try await ratedItem(provider)
        XCTAssertEqual(first.ratings, second.ratings)
        XCTAssertEqual(http.sentPaths.filter { $0 == cachePath }.count, 1)
        XCTAssertEqual(http.sentPaths.filter { $0 == "/Users/viewer/Items/\(itemID)" }.count, 2)
    }

    func testCacheDeadlineCancelsRequestAndPreservesFallback() async throws {
        let started = expectation(description: "Cache request started")
        let http = SlowRatingsHTTPClient(started: started)
        let client = JellyfinClient(
            baseURL: session().server.baseURL, deviceProfile: JellyfinDeviceProfile(deviceID: "test"),
            token: "test-token", http: http
        )
        let resolver = JellyfinServerRatings(timeout: .milliseconds(30))
        let ratings = try await resolver.ratings(
            for: MediaItem(id: itemID, title: "Title", kind: .movie), client: client
        )
        await fulfillment(of: [started], timeout: 2)
        let cancelled = await http.cancelled
        XCTAssertNil(ratings)
        XCTAssertTrue(cancelled)
    }

    func testCancellationDoesNotReturnSuccessfulItemOrPoisonAvailability() async throws {
        let started = expectation(description: "Cache request started")
        let http = SlowRatingsHTTPClient(started: started)
        let client = JellyfinClient(
            baseURL: session().server.baseURL, deviceProfile: JellyfinDeviceProfile(deviceID: "test"),
            token: "test-token", http: http
        )
        let resolver = JellyfinServerRatings()
        let item = MediaItem(id: itemID, title: "Title", kind: .episode)
        let task = Task { try await resolver.ratings(for: item, client: client) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let cancelled = await http.cancelled
        XCTAssertTrue(cancelled)

        let available = StubHTTPClient()
        available.stub(pathSuffix: cachePath, json: response(#"{"source":"imdb","score":80}"#))
        let retryClient = JellyfinClient(
            baseURL: session().server.baseURL, deviceProfile: JellyfinDeviceProfile(deviceID: "test"),
            token: "test-token", http: available
        )
        let retry = try await resolver.ratings(for: item, client: retryClient)
        XCTAssertEqual(retry?.first?.displayValue, "8.0")
    }
}

private actor SlowRatingsHTTPClient: HTTPClient {
    let started: XCTestExpectation
    private(set) var cancelled = false

    init(started: XCTestExpectation) { self.started = started }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        started.fulfill()
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            cancelled = true
            throw error
        }
        throw AppError.serverUnreachable
    }
}
