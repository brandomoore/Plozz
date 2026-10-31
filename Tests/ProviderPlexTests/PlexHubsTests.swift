import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

/// `PlexProvider.libraryHubs` maps `/hubs/sections/{id}` into the additive
/// discovery rows unmerged Home shows for a library, dropping hubs the uniform
/// base rows already cover (Recently Added, On Deck) and hubs with no playable
/// items. The fixture mirrors the shape a real Plex Media Server returns.
final class PlexHubsTests: XCTestCase {
    func testExactShelfContinuationLoadsPastPreviewAndHundredItemCap() async throws {
        let stub = StubHTTPClient()
        func payload(_ start: Int, _ end: Int) -> String {
            let items = (start..<end).map {
                #"{"ratingKey":"\#($0)","type":"movie","title":"Title \#($0)","librarySectionID":1}"#
            }.joined(separator: ",")
            return #"{"MediaContainer":{"offset":\#(start),"totalSize":135,"Metadata":[\#(items)]}}"#
        }
        stub.stubSequence(pathSuffix: "/library/sections/1/all", jsons: [
            payload(0, 60), payload(60, 120), payload(120, 135)
        ])
        let provider = PlexProvider(session: makeSession(), http: stub)
        let feed = HomeRowFeed.recommendation(
            libraryID: "1", kind: .movie,
            browseID: "/library/sections/1/all?genre=123&X-Plex-Token=UNTRUSTED"
        )
        let first = try await provider.homeRowPage(feed, startIndex: 0, limit: 60)
        let second = try await provider.homeRowPage(feed, startIndex: 60, limit: 60)
        let last = try await provider.homeRowPage(feed, startIndex: 120, limit: 60)
        XCTAssertEqual(first.items.count, 60)
        XCTAssertEqual(first.nextOffset, 60)
        XCTAssertEqual(second.nextOffset, 120)
        XCTAssertEqual(last.items.map(\.id), (120..<135).map(String.init))
        XCTAssertNil(last.nextOffset)
        XCTAssertTrue(last.items.allSatisfy { $0.libraryID == "1" })
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/library/sections/1/all"))
        XCTAssertTrue(query.contains(.init(name: "genre", value: "123")))
        XCTAssertTrue(query.contains(.init(name: "X-Plex-Container-Size", value: "60")))
        XCTAssertFalse(query.contains { $0.name.lowercased() == "x-plex-token" })
    }

    func testShelfContinuationRejectsForeignOriginAndNonAdvancingPage() async throws {
        for key in ["https://other.invalid/library/sections/1/all", "//other.invalid/library/sections/1/all"] {
            let stub = StubHTTPClient()
            let provider = PlexProvider(session: makeSession(), http: stub)
            do {
                _ = try await provider.homeRowPage(
                    .recommendation(libraryID: "1", kind: .movie, browseID: key),
                    startIndex: 0, limit: 60
                )
                XCTFail("Foreign shelf paths must not receive server credentials")
            } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
            XCTAssertTrue(stub.sentPaths.isEmpty)
        }
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/library/1/genre", json: """
        {"MediaContainer":{"Hub":[{"offset":60,"more":true,"Metadata":[]}]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)
        do {
            _ = try await provider.homeRowPage(
                .recommendation(libraryID: "1", kind: .movie, browseID: "/hubs/library/1/genre"),
                startIndex: 60, limit: 60
            )
            XCTFail("An unfinished empty page is not exhaustion")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    }

    func testStableShelfIdentityIsSeparateFromRecommendationSlot() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/promoted", json: """
        {"MediaContainer":{"Hub":[{
          "hubIdentifier":"movie.similar.abc","title":"Similar","key":"/library/metadata/abc/similar?X-Plex-Token=SECRET",
          "Metadata":[{"ratingKey":"7","type":"movie","title":"Title","librarySectionID":1}]
        }]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)
        let shelves = try await provider.homeHubs(libraryID: "1", kind: .movie, limit: 20, includeUnpromoted: false)
        XCTAssertEqual(shelves.first?.id, "recommendation:similar:0")
        XCTAssertEqual(shelves.first?.browseID, "/library/metadata/abc/similar")
    }

    func testWrappedShelfUsesItemPaginationRatherThanOuterHubCount() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/library/1/genre", json: """
        {"MediaContainer":{"size":1,"totalSize":1,"Hub":[{
          "offset":60,"totalSize":62,"more":true,"Metadata":[
            {"ratingKey":"60","type":"movie","title":"One","librarySectionID":1}
          ]
        }]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)
        let page = try await provider.homeRowPage(
            .recommendation(libraryID: "1", kind: .movie, browseID: "/hubs/library/1/genre"),
            startIndex: 60, limit: 60
        )
        XCTAssertEqual(page.items.map(\.id), ["60"])
        XCTAssertEqual(page.nextOffset, 61)
    }

    func testShelfWithoutItemsOrExplicitEmptySizeIsNotSuccessfulExhaustion() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/library/1/genre", json: #"{"MediaContainer":{}}"#)
        let provider = PlexProvider(session: makeSession(), http: stub)
        do {
            _ = try await provider.homeRowPage(
                .recommendation(libraryID: "1", kind: .movie, browseID: "/hubs/library/1/genre"),
                startIndex: 0, limit: 60
            )
            XCTFail("An unrelated or incomplete container is not an empty shelf")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    }

    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    /// A representative `/hubs/sections/1` payload:
    ///  - Recently Added  → dropped (base row duplicate)
    ///  - On Deck         → dropped (base row duplicate)
    ///  - More in Drama   → kept (genre discovery hub, 3 items)
    ///  - Because You Watched → kept (similar hub, 3 items)
    ///  - Top Rated       → kept (3 items)
    ///  - Top Movies by Kyle Balda → dropped (director/person hub, even with 3 items)
    ///  - Top Movies with an Actor → dropped (person hub with a single title)
    ///  - Genres          → dropped (Directory-only, no playable items)
    ///  - Recently Released (empty) → dropped (no items)
    private let hubsJSON = """
    {"MediaContainer":{"size":9,"Hub":[
      {"hubIdentifier":"movie.recentlyadded.1","context":"hub.movie.recentlyadded","title":"Recently Added Movies","type":"movie","more":true,
       "Metadata":[{"ratingKey":"1","type":"movie","title":"New Arrival","librarySectionID":1}]},
      {"hubIdentifier":"movie.ondeck.1","context":"hub.movie.ondeck","title":"On Deck","type":"movie","more":false,
       "Metadata":[{"ratingKey":"2","type":"movie","title":"Half-Watched","librarySectionID":1,"viewOffset":1000,"duration":7200000}]},
      {"hubIdentifier":"movie.genre.drama","context":"hub.movie.genre","title":"More in Drama","type":"movie","more":true,
       "Metadata":[
         {"ratingKey":"10","type":"movie","title":"Drama A","librarySectionID":1},
         {"ratingKey":"11","type":"movie","title":"Drama B","librarySectionID":1},
         {"ratingKey":"12","type":"movie","title":"Drama C","librarySectionID":1}
       ]},
      {"hubIdentifier":"movie.similar.10","context":"hub.movie.similar","title":"Because You Watched Drama A","type":"movie","more":true,
       "Metadata":[
         {"ratingKey":"20","type":"movie","title":"Similar One","librarySectionID":1},
         {"ratingKey":"21","type":"movie","title":"Similar Two","librarySectionID":1},
         {"ratingKey":"22","type":"movie","title":"Similar Three","librarySectionID":1}
       ]},
      {"hubIdentifier":"movie.toprated","context":"hub.movie.toprated","title":"Top Rated","type":"movie","more":true,
       "Metadata":[
         {"ratingKey":"30","type":"movie","title":"Acclaimed","librarySectionID":1},
         {"ratingKey":"31","type":"movie","title":"Acclaimed Two","librarySectionID":1},
         {"ratingKey":"32","type":"movie","title":"Acclaimed Three","librarySectionID":1}
       ]},
      {"hubIdentifier":"movie.by.director.7","context":"hub.movie.director","title":"Top Movies by Kyle Balda","type":"movie","more":true,
       "Metadata":[
         {"ratingKey":"50","type":"movie","title":"Minions","librarySectionID":1},
         {"ratingKey":"51","type":"movie","title":"Despicable Me 3","librarySectionID":1},
         {"ratingKey":"52","type":"movie","title":"Minions: The Rise of Gru","librarySectionID":1}
       ]},
      {"hubIdentifier":"movie.by.actor.99","context":"hub.movie.byactor","title":"Top Movies with Misa Koide","type":"movie","more":false,
       "Metadata":[{"ratingKey":"40","type":"movie","title":"Her Only Film","librarySectionID":1}]},
      {"hubIdentifier":"movie.genres","context":"hub.movie.genres","title":"Genres","type":"movie","more":false,
       "Directory":[{"key":"/library/sections/1/genre/1","title":"Drama"}]},
      {"hubIdentifier":"movie.recentlyReleased","context":"hub.movie.recentlyReleased","title":"Recently Released","type":"movie","more":false,
       "Metadata":[]}
    ]}}
    """

    func testFiltersDuplicatePersonSparseAndEmptyHubsAndMapsTheRest() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/sections/1", json: hubsJSON)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let sections = try await provider.libraryHubs(libraryID: "1", kind: .movie, limit: 20)

        // The three populated NON-person discovery hubs survive, in server order.
        // Dropped: base duplicates (recently added / on deck), both person hubs
        // (director w/ 3 items AND single-title actor), Directory-only, empty.
        XCTAssertEqual(sections.map(\.title), ["More in Drama", "Because You Watched Drama A", "Top Rated"])
        XCTAssertEqual(sections.map(\.id), ["movie.genre.drama", "movie.similar.10", "movie.toprated"])
        XCTAssertFalse(sections.contains { $0.title.contains("Kyle Balda") || $0.title.contains("Misa Koide") },
                       "Auto-generated person hubs must never become rows")
        XCTAssertEqual(sections.first?.items.map(\.title), ["Drama A", "Drama B", "Drama C"])
        XCTAssertEqual(sections.first?.items.first?.libraryID, "1")
        XCTAssertTrue(sections.allSatisfy { $0.style == .poster && $0.items.count >= 3 })
    }

    func testMalformedHubResponseKeepsTypedErrorAndSafeRouteDiagnostic() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/sections/1", json: #"{"MediaContainer":{"Hub":false}}"#)
        let provider = PlexProvider(session: makeSession(), http: stub)
        let captured = await HTTPResponseDiagnostics.capture {
            try await provider.libraryHubs(libraryID: "1", kind: .movie, limit: 20)
        }
        guard case .failure(let error) = captured.result else { return XCTFail("Malformed hubs must fail") }
        XCTAssertEqual(error as? AppError, .decoding)
        let response = try XCTUnwrap(captured.responses.last)
        XCTAssertEqual(response.route, .libraryHubs)
        XCTAssertEqual(response.path, "MediaContainer.Hub")
        XCTAssertEqual(response.reason, .wrongType)
    }

    func testCapsItemsPerHubToLimit() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/sections/1", json: hubsJSON)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let sections = try await provider.libraryHubs(libraryID: "1", kind: .movie, limit: 2)
        // "More in Drama" has 3 items in the fixture; the limit clamps it to 2.
        XCTAssertEqual(sections.first?.items.count, 2)
    }

    func testHomeRequestsPromotedHubsWithoutFetchingTheLibraryRecommendationMenu() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/promoted", json: hubsJSON)
        let provider = PlexProvider(session: makeSession(), http: stub)
        let sections = try await provider.homeHubs(
            libraryID: "1", kind: .movie, limit: 20, includeUnpromoted: false
        )
        XCTAssertTrue(sections.contains { $0.id == "recommendation:director:0" },
                      "A genuinely Home-promoted row is not suppressed by a person-title heuristic.")
        XCTAssertTrue(sections.allSatisfy { $0.isHomeDefault == true })
        XCTAssertFalse(stub.sentPaths.contains { $0.contains("/hubs/sections/") })
        let query = try XCTUnwrap(stub.queryItems(forPathSuffix: "/hubs/promoted"))
        XCTAssertEqual(query.first { $0.name == "contentDirectoryID" }?.value, "1")
        XCTAssertEqual(query.first { $0.name == "pinnedContentDirectoryID" }?.value, "1")
    }

    func testArrangerIncludesOptionalRowsWithoutCallingThemHomeDefaults() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/promoted", json: #"{"MediaContainer":{"Hub":[]}}"#)
        stub.stub(pathSuffix: "/hubs/sections/1", json: hubsJSON)
        let provider = PlexProvider(session: makeSession(), http: stub)
        let sections = try await provider.homeHubs(
            libraryID: "1", kind: .movie, limit: 8, includeUnpromoted: true
        )
        XCTAssertTrue(sections.contains { $0.id == "recommendation:actor:0" })
        XCTAssertTrue(sections.allSatisfy { $0.isHomeDefault == false })
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
    }

    func testHomeDynamicRecommendationIdentitySurvivesANewSubject() async throws {
        let beforeStub = StubHTTPClient()
        beforeStub.stub(pathSuffix: "/hubs/promoted", json: hubsJSON)
        let afterStub = StubHTTPClient()
        afterStub.stub(pathSuffix: "/hubs/promoted", json: hubsJSON
            .replacingOccurrences(of: "movie.similar.10", with: "movie.similar.900")
            .replacingOccurrences(of: "movie.by.director.7", with: "movie.by.director.800")
            .replacingOccurrences(of: "Drama A", with: "A different movie"))
        let before = try await PlexProvider(session: makeSession(), http: beforeStub)
            .homeHubs(libraryID: "1", kind: .movie, limit: 20, includeUnpromoted: false)
        let after = try await PlexProvider(session: makeSession(), http: afterStub)
            .homeHubs(libraryID: "1", kind: .movie, limit: 20, includeUnpromoted: false)
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertNotEqual(before.map(\.title), after.map(\.title))
    }

    func testIsBaseDuplicateHubMatchesStableTokensOnly() {
        // Duplicates of the uniform base rows are dropped…
        XCTAssertTrue(PlexProvider.isBaseDuplicateHub(identifier: "movie.recentlyadded.1", context: "hub.movie.recentlyadded"))
        XCTAssertTrue(PlexProvider.isBaseDuplicateHub(identifier: "movie.ondeck.1", context: "hub.movie.ondeck"))
        XCTAssertTrue(PlexProvider.isBaseDuplicateHub(identifier: nil, context: "hub.continueWatching"))
        XCTAssertTrue(PlexProvider.isBaseDuplicateHub(identifier: "movie.inprogress", context: nil))
        // …including an identifier-less Continue Watching hub caught by title…
        XCTAssertTrue(PlexProvider.isBaseDuplicateHub(identifier: nil, context: nil, title: "Continue Watching"))
        XCTAssertTrue(PlexProvider.isBaseDuplicateHub(identifier: "", context: "", title: "On Deck"))
        // …while genre / similar / "start watching" discovery hubs are kept.
        XCTAssertFalse(PlexProvider.isBaseDuplicateHub(identifier: "movie.genre.drama", context: "hub.movie.genre"))
        XCTAssertFalse(PlexProvider.isBaseDuplicateHub(identifier: "movie.similar.10", context: "hub.movie.similar", title: "Because You Watched X"))
        XCTAssertFalse(PlexProvider.isBaseDuplicateHub(identifier: "tv.startWatching", context: "hub.tv.startWatching", title: "Start Watching"))
    }

    func testIsPersonHubDetectsActorAndDirectorHubs() {
        // Role tokens in identifier/context…
        XCTAssertTrue(PlexProvider.isPersonHub(identifier: "movie.by.director.7", context: "hub.movie.director"))
        XCTAssertTrue(PlexProvider.isPersonHub(identifier: "movie.by.actor.99", context: "hub.movie.byactor"))
        XCTAssertTrue(PlexProvider.isPersonHub(identifier: nil, context: "hub.movie.writer"))
        // …and the "Top <Movies|Shows> with/by <person>" title fallback when the
        // identifier is missing.
        XCTAssertTrue(PlexProvider.isPersonHub(identifier: nil, context: nil, title: "Top Movies by Kyle Balda"))
        XCTAssertTrue(PlexProvider.isPersonHub(identifier: "", context: "", title: "Top Shows with Misa Koide"))
        // Non-person discovery hubs are NOT person hubs.
        XCTAssertFalse(PlexProvider.isPersonHub(identifier: "movie.genre.drama", context: "hub.movie.genre", title: "More in Drama"))
        XCTAssertFalse(PlexProvider.isPersonHub(identifier: "movie.similar.1", context: "hub.movie.similar", title: "Because You Watched X"))
        XCTAssertFalse(PlexProvider.isPersonHub(identifier: "movie.toprated", context: "hub.movie.toprated", title: "Top Rated"))
    }

    func testDropsContinueWatchingHubToAvoidDuplicateRow() async throws {
        // A Plex "Continue Watching" hub (identifier-less, title only) must not
        // become a second CW row alongside Plozz's own per-library CW slice.
        let json = """
        {"MediaContainer":{"size":2,"Hub":[
          {"title":"Continue Watching","type":"show","more":true,
           "Metadata":[
             {"ratingKey":"1","type":"episode","title":"Ep1","librarySectionID":2},
             {"ratingKey":"2","type":"episode","title":"Ep2","librarySectionID":2},
             {"ratingKey":"3","type":"episode","title":"Ep3","librarySectionID":2}
           ]},
          {"hubIdentifier":"show.genre.comedy","context":"hub.show.genre","title":"More in Comedy","type":"show","more":true,
           "Metadata":[
             {"ratingKey":"10","type":"show","title":"Com A","librarySectionID":2},
             {"ratingKey":"11","type":"show","title":"Com B","librarySectionID":2},
             {"ratingKey":"12","type":"show","title":"Com C","librarySectionID":2}
           ]}
        ]}}
        """
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/hubs/sections/2", json: json)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let sections = try await provider.libraryHubs(libraryID: "2", kind: .series, limit: 20)
        XCTAssertEqual(sections.map(\.title), ["More in Comedy"],
                       "The Continue Watching hub must be dropped; only the genre discovery hub remains")
    }
}
