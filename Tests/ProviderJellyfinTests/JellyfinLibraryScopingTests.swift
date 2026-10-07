import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

/// Jellyfin's Resume / NextUp / Latest feeds don't report each item's owning
/// library (an episode's `ParentId` is its season), so the provider attributes —
/// and Home-filters — items by fetching **scoped per library** via `ParentId`
/// and stamping each result's `libraryID`. These pin down: the scoped path sends
/// `ParentId`, stamps `libraryID`, the unscoped path (nil) leaves it nil
/// (fail-open) and sends no `ParentId`, and an empty scope short-circuits.
final class JellyfinLibraryScopingTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    private func parentIDs(_ stub: StubHTTPClient, pathSuffix: String) -> [String] {
        stub.sentQueryItems.enumerated().compactMap { index, items in
            guard stub.sentPaths[index].hasSuffix(pathSuffix) else { return nil }
            return items.first(where: { $0.name == "ParentId" })?.value
        }
    }

    func testMovieRecommendationsUseLibraryScopeAndMapCategoriesForJellyfinAndEmby() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let categoryID = kind == .emby ? "9007199254740993" : "because-1"
            let categoryJSON = kind == .emby ? categoryID : "\"\(categoryID)\""
            let stub = StubHTTPClient()
            stub.stub(pathSuffix: "/Movies/Recommendations", json: """
            [{"Items":[{"Id":"m1","Name":"Suggested Movie","Type":"Movie"}],
              "RecommendationType":"SimilarToRecentlyPlayed",
              "BaselineItemName":"A Favorite","CategoryId":\(categoryJSON)},
             {"Items":[{"Id":"m2","Name":"Another Movie","Type":"Movie"}],
              "RecommendationType":"HasLikedDirector"}]
            """)
            let session = UserSession(
                server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: kind),
                userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
            )
            let provider = JellyfinProvider(session: session, http: stub)
            let sections = try await provider.libraryHubs(libraryID: "LIB1", kind: .movie, limit: 10)
            XCTAssertEqual(sections.map(\.id), [categoryID, "HasLikedDirector:"])
            XCTAssertEqual(sections.map(\.title), ["Because you watched A Favorite", "More from directors you like"])
            let expectedTitles: [LocalizedStringResource] = [
                "Because you watched \("A Favorite")", "More from directors you like"
            ]
            XCTAssertEqual(sections.compactMap(\.localizedTitle), expectedTitles)
            XCTAssertEqual(sections.map { $0.items.map(\.id) }, [["m1"], ["m2"]])

            let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/Movies/Recommendations"))
            XCTAssertEqual(query.first(where: { $0.name == "parentId" })?.value, "LIB1")
            XCTAssertEqual(query.first(where: { $0.name == "userId" })?.value, "u1")
            XCTAssertEqual(query.first(where: { $0.name == "itemLimit" })?.value, "10")
            XCTAssertEqual(query.first(where: { $0.name == "categoryLimit" })?.value, "5")
            let refreshedStub = StubHTTPClient()
            refreshedStub.stub(pathSuffix: "/Movies/Recommendations", json: """
            [{"Items":[{"Id":"m2","Name":"Another Movie","Type":"Movie"}],
              "RecommendationType":"HasLikedDirector"},
             {"Items":[{"Id":"m1","Name":"Suggested Movie","Type":"Movie"}],
              "RecommendationType":"SimilarToRecentlyPlayed",
              "BaselineItemName":"A Favorite","CategoryId":\(categoryJSON)}]
            """)
            let refreshed = try await JellyfinProvider(session: session, http: refreshedStub)
                .libraryHubs(libraryID: "LIB1", kind: .movie, limit: 10)
            XCTAssertEqual(refreshed.map(\.id), Array(sections.map(\.id).reversed()))
            let seriesHubs = try await provider.libraryHubs(libraryID: "LIB1", kind: .series, limit: 10)
            XCTAssertTrue(seriesHubs.isEmpty)
        }
    }

    func testMovieRecommendationCategoryIDsPreserveStringsAndExactEmbyIntegers() throws {
        let cases: [(json: String?, expected: String?)] = [
            (#""56a9f068-c965-40ee-939b-38bc1a5f12e9""#, "56a9f068-c965-40ee-939b-38bc1a5f12e9"),
            (#""00042""#, "00042"),
            ("0", "0"),
            ("42", "42"),
            ("-42", "-42"),
            ("9007199254740993", "9007199254740993"),
            ("9223372036854775807", "9223372036854775807"),
            ("-9223372036854775808", "-9223372036854775808"),
            ("null", nil),
            (nil, nil)
        ]
        for testCase in cases {
            let category = testCase.json.map { #","CategoryId":\#($0)"# } ?? ""
            let data = Data(#"[{"RecommendationType":"SimilarToRecentlyPlayed"\#(category)}]"#.utf8)
            let decoded = try JSONDecoder().decode([MovieRecommendationDto].self, from: data)
            XCTAssertEqual(decoded.first?.CategoryId, testCase.expected, testCase.json ?? "absent")
        }
    }

    func testMovieRecommendationCategoryIDsRejectMalformedValues() {
        for value in ["true", "false", "{}", "[]", "1.5", "9223372036854775808", "-9223372036854775809"] {
            let data = Data(#"[{"RecommendationType":"SimilarToRecentlyPlayed","CategoryId":\#(value)}]"#.utf8)
            XCTAssertThrowsError(try JSONDecoder().decode([MovieRecommendationDto].self, from: data), value) {
                XCTAssertTrue($0 is DecodingError)
            }
        }
    }

    // MARK: Continue Watching

    func testScopedContinueWatchingSendsParentIDAndStampsLibrary() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Resume", json: """
        {"Items":[{"Id":"i1","Name":"Movie","Type":"Movie",
        "UserData":{"PlaybackPositionTicks":18000000000,"Played":false}}],"TotalRecordCount":1}
        """)
        stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(limit: 10, inLibraries: ["LIB1"])
        XCTAssertEqual(items.map(\.id), ["i1"])
        XCTAssertEqual(items.first?.libraryID, "LIB1",
                       "A scoped fetch must stamp each item with the library it was fetched from")
        XCTAssertEqual(parentIDs(stub, pathSuffix: "/Users/u1/Items/Resume"), ["LIB1"])
    }

    func testScopedContinueWatchingFetchesEachVisibleLibrary() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Resume", json: #"{"Items":[],"TotalRecordCount":0}"#)
        stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        _ = try await provider.continueWatching(limit: 10, inLibraries: ["A", "B"])
        XCTAssertEqual(Set(parentIDs(stub, pathSuffix: "/Users/u1/Items/Resume")), ["A", "B"],
                       "Scoped Continue Watching must request each visible library")
    }

    func testNilScopeUsesUnscopedFeedAndLeavesLibraryNil() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Resume", json: """
        {"Items":[{"Id":"i1","Name":"Movie","Type":"Movie",
        "UserData":{"PlaybackPositionTicks":18000000000,"Played":false}}],"TotalRecordCount":1}
        """)
        stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(limit: 10, inLibraries: nil)
        XCTAssertEqual(items.map(\.id), ["i1"])
        XCTAssertNil(items.first?.libraryID, "Unscoped fetch must leave libraryID nil (fail-open)")
        XCTAssertTrue(parentIDs(stub, pathSuffix: "/Users/u1/Items/Resume").isEmpty,
                      "Unscoped fetch must not send a ParentId")
    }

    func testEmptyScopeReturnsNothingWithoutRequesting() async throws {
        let stub = StubHTTPClient()
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(limit: 10, inLibraries: [])
        XCTAssertTrue(items.isEmpty, "Hiding every library must yield an empty row")
        XCTAssertTrue(stub.sentPaths.isEmpty, "An empty scope must short-circuit before any request")
    }

    func testUnlimitedScopedContinueWatchingPagesWithinParentLibrary() async throws {
        let stub = StubHTTPClient()
        let firstPage = (0..<100).map {
            #"{"Id":"item-\#($0)","Name":"Item \#($0)","Type":"Movie"}"#
        }.joined(separator: ",")
        stub.stubSequence(pathSuffix: "/Users/u1/Items/Resume", jsons: [
            #"{"Items":[\#(firstPage)],"TotalRecordCount":101}"#,
            #"{"Items":[{"Id":"item-100","Name":"Item 100","Type":"Movie"}],"TotalRecordCount":101}"#
        ])
        stub.stub(pathSuffix: "/Shows/NextUp", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(
            limit: Int.max,
            inLibraries: ["LIB1"]
        )

        XCTAssertEqual(items.count, 101)
        XCTAssertTrue(items.allSatisfy { $0.libraryID == "LIB1" })
        let requests = Array(zip(stub.sentPaths, stub.sentQueryItems)).filter {
            $0.0.hasSuffix("/Users/u1/Items/Resume") || $0.0.hasSuffix("/Shows/NextUp")
        }
        XCTAssertTrue(requests.allSatisfy {
            $0.1.first { $0.name == "ParentId" }?.value == "LIB1"
        })
        let resumeStarts = requests
            .filter { $0.0.hasSuffix("/Users/u1/Items/Resume") }
            .compactMap { $0.1.first { $0.name == "StartIndex" }?.value }
        XCTAssertEqual(resumeStarts, ["0", "100"])
        XCTAssertFalse(requests.flatMap { $0.1 }.contains {
            $0.name == "Limit" && $0.value == String(Int.max)
        })
    }

    func testScopedContinueWatchingKeepsNextUpWhenResumeFails() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Resume", json: "{}", status: 500)
        stub.stub(pathSuffix: "/Shows/NextUp", json: """
        {"Items":[{"Id":"next1","Name":"Episode 2","Type":"Episode","SeriesId":"series1",
        "UserData":{"LastPlayedDate":"2026-01-01T00:00:00Z"}}],"TotalRecordCount":1}
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(
            limit: 10,
            inLibraries: ["LIB1"]
        )

        XCTAssertEqual(items.map(\.id), ["next1"])
        XCTAssertEqual(items.first?.libraryID, "LIB1")
    }

    func testFailedLibraryDoesNotEraseAnotherLibraryResults() async throws {
        let stub = StubHTTPClient()
        let libraryA = [URLQueryItem(name: "ParentId", value: "A")]
        let libraryB = [URLQueryItem(name: "ParentId", value: "B")]
        stub.stub(
            pathSuffix: "/Users/u1/Items/Resume",
            requiring: libraryA,
            json: "{}",
            status: 500
        )
        stub.stub(
            pathSuffix: "/Shows/NextUp",
            requiring: libraryA,
            json: "{}",
            status: 500
        )
        stub.stub(
            pathSuffix: "/Users/u1/Items/Resume",
            requiring: libraryB,
            json: #"{"Items":[{"Id":"b1","Name":"B","Type":"Movie"}],"TotalRecordCount":1}"#
        )
        stub.stub(
            pathSuffix: "/Shows/NextUp",
            requiring: libraryB,
            json: #"{"Items":[],"TotalRecordCount":0}"#
        )
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let items = try await provider.continueWatching(
            limit: 10,
            inLibraries: ["A", "B"]
        )

        XCTAssertEqual(items.map(\.id), ["b1"])
        XCTAssertEqual(items.first?.libraryID, "B")
    }

    // MARK: Latest

    func testScopedLatestSendsParentIDAndStampsLibrary() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Latest", json: """
        [{"Id":"m1","Name":"Dune","Type":"Movie"}]
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let latest = try await provider.latest(limit: 10, inLibraries: ["LIB2"])
        XCTAssertEqual(latest.map(\.id), ["m1"])
        XCTAssertEqual(latest.first?.libraryID, "LIB2")
        XCTAssertEqual(parentIDs(stub, pathSuffix: "/Users/u1/Items/Latest"), ["LIB2"])
    }

    func testNilScopeLatestLeavesLibraryNil() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Users/u1/Items/Latest", json: """
        [{"Id":"m1","Name":"Dune","Type":"Movie"}]
        """)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let latest = try await provider.latest(limit: 10, inLibraries: nil)
        XCTAssertEqual(latest.map(\.id), ["m1"])
        XCTAssertNil(latest.first?.libraryID)
        XCTAssertTrue(parentIDs(stub, pathSuffix: "/Users/u1/Items/Latest").isEmpty)
    }
}
