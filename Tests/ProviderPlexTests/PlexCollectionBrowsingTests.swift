import CoreModels
import XCTest
@testable import ProviderPlex

final class PlexCollectionBrowsingTests: XCTestCase {
    private func provider(_ http: StubHTTPClient) -> PlexProvider {
        PlexProvider(
            session: UserSession(
                server: MediaServer(
                    id: "collections-server", name: "Server",
                    baseURL: URL(string: "https://plex.example")!, provider: .plex
                ),
                userID: "user", userName: "Viewer", deviceID: "device", accessToken: "test-token"
            ),
            accountID: "account", http: http
        )
    }

    func testCollectionLibrariesRetainDistinctSectionIdentity() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections", json: """
        {"MediaContainer":{"Directory":[
          {"key":"1","title":"Movies","type":"movie"},
          {"key":"2","title":"Shows","type":"show"},
          {"key":"3","title":"Music","type":"artist"}
        ]}}
        """)
        let libraries = try await provider(http).libraries()
        let collections = libraries.filter { $0.kind == .collection }
        XCTAssertEqual(collections.map(\.id), ["plex:collections:1", "plex:collections:2"])
        XCTAssertEqual(collections.map(\.collectionSourceTitle), ["Movies", "Shows"])
        XCTAssertEqual(collections.map(\.synthesizedName), [.collections, .collections])
        XCTAssertEqual(libraries.filter(\.isMusic).count, 1)
        let tagged = collections[0].taggingSource("account")
        XCTAssertEqual(tagged.containerID(forSourceAccountID: "account"), "plex:collections:1")
        XCTAssertEqual(try JSONDecoder().decode(MediaLibrary.self, from: JSONEncoder().encode(tagged)), tagged)
    }

    func testMissingOrBlankSectionTitleUsesPlainLocalizedCollectionsName() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections", json: """
        {"MediaContainer":{"Directory":[
          {"key":"1","type":"movie"},
          {"key":"2","title":"   ","type":"show"},
          {"key":"3","title":"  Movies  ","type":"movie"}
        ]}}
        """)
        let collections = try await provider(http).libraries().filter { $0.kind == .collection }
        XCTAssertEqual(collections.map(\.collectionSourceTitle), [nil, nil, "Movies"])
        XCTAssertEqual(collections.map(\.title), ["Collections", "Collections", "Collections in Movies"])
        XCTAssertEqual(collections.map(\.synthesizedName), [.collections, .collections, .collections])
        for library in collections.prefix(2) {
            var title = try XCTUnwrap(library.localizedTitle)
            title.locale = Locale(identifier: "en")
            XCTAssertEqual(String(localized: title), "Collections")
        }
    }

    func testDiscoveryUsesSectionType18WithPagingAndOrder() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/2/all", json: """
        {"MediaContainer":{"size":2,"totalSize":70,"Metadata":[
          {"ratingKey":"12","type":"collection","title":"Static","smart":0},
          {"ratingKey":"13","type":"collection","title":"Smart","smart":1}
        ]}}
        """)
        let result = try await provider(http).items(
            in: "plex:collections:2", kind: .collection,
            page: PageRequest(startIndex: 60, limit: 10)
        )
        XCTAssertEqual(result.items.map(\.id), ["12", "13"])
        XCTAssertEqual(result.items.map(\.kind), [.collection, .collection])
        XCTAssertEqual(result.items.map(\.libraryID), ["2", "2"])
        XCTAssertEqual(result.totalCount, 70)
        XCTAssertEqual(result.startIndex, 60)
        let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/library/sections/2/all"))
        XCTAssertTrue(query.contains(URLQueryItem(name: "type", value: "18")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "X-Plex-Container-Start", value: "60")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "X-Plex-Container-Size", value: "10")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "sort", value: "titleSort:asc")))
    }

    func testStaticAndSmartCollectionsUseMemberEndpointWithoutTypeOrSortFilter() async throws {
        for id in ["static", "smart"] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/library/metadata/\(id)/children", json: """
            {"MediaContainer":{"size":2,"totalSize":64,"Metadata":[
              {"ratingKey":"z","type":"movie","title":"Z","librarySectionID":2},
              {"ratingKey":"a","type":"show","title":"A","librarySectionID":2}
            ]}}
            """)
            let result = try await provider(http).collectionMembers(
                of: id, page: PageRequest(startIndex: 60, limit: 2)
            )
            XCTAssertEqual(result.items.map(\.id), ["z", "a"], "Keep server-defined order")
            XCTAssertEqual(result.items.map(\.kind), [.movie, .series])
            XCTAssertEqual(result.items.map(\.libraryID), ["2", "2"])
            XCTAssertEqual(result.totalCount, 64)
            let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/\(id)/children"))
            XCTAssertFalse(query.contains { ["type", "sort"].contains($0.name) })
            XCTAssertTrue(query.contains(URLQueryItem(name: "X-Plex-Container-Start", value: "60")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "X-Plex-Container-Size", value: "2")))
        }
    }

    func testNormalMovieLibraryStillUsesMovieType() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/2/all", json: """
        {"MediaContainer":{"size":0,"totalSize":0}}
        """)
        _ = try await provider(http).items(in: "2", kind: .movie, page: PageRequest())
        XCTAssertTrue(try XCTUnwrap(http.queryItems(forPathSuffix: "/2/all"))
            .contains(URLQueryItem(name: "type", value: "1")))
    }

    func testDirectCollectionPagingDoesNotConfuseMemberIDWithSectionID() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/metadata/12/children", json: """
        {"MediaContainer":{"size":1,"totalSize":1,"Metadata":[
          {"ratingKey":"movie","type":"movie","title":"Member"}
        ]}}
        """)
        let result = try await provider(http).items(
            in: "12", kind: .collection, page: PageRequest()
        )
        XCTAssertEqual(result.items.map(\.kind), [.movie])
        XCTAssertFalse(http.sentPaths.contains { $0.contains("/library/sections/") })
    }

    func testMissingTotalDoesNotTruncateAFullMemberPage() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/metadata/12/children", json: """
        {"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"a","type":"movie","title":"A"}]}}
        """)
        let page = try await provider(http).collectionMembers(
            of: "12", page: PageRequest(startIndex: 4, limit: 1)
        )
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.totalCount, 6)
    }

    func testDiscoveryMissingTotalUsesFullPageSentinelAtNonzeroOffset() async throws {
        let http = StubHTTPClient()
        http.stubSequence(pathSuffix: "/library/sections/2/all", jsons: [
            """
            {"MediaContainer":{"size":2,"Metadata":[
              {"ratingKey":"a","type":"collection","title":"A"},
              {"ratingKey":"b","type":"collection","title":"B"}
            ]}}
            """,
            """
            {"MediaContainer":{"size":1,"Metadata":[
              {"ratingKey":"c","type":"collection","title":"C"}
            ]}}
            """
        ])
        let provider = provider(http)
        let full = try await provider.items(
            in: "plex:collections:2", kind: .collection,
            page: PageRequest(startIndex: 60, limit: 2)
        )
        XCTAssertEqual(full.startIndex, 60)
        XCTAssertEqual(full.totalCount, 63)
        XCTAssertTrue(full.hasMore)
        let last = try await provider.items(
            in: "plex:collections:2", kind: .collection,
            page: PageRequest(startIndex: 62, limit: 2)
        )
        XCTAssertEqual(last.totalCount, 63)
        XCTAssertFalse(last.hasMore)
    }

    func testOrdinaryLibraryRetainsExistingSizeFallback() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/2/all", json: """
        {"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"a","type":"movie","title":"A"}]}}
        """)
        let page = try await provider(http).items(
            in: "2", kind: .movie, page: PageRequest(startIndex: 4, limit: 1)
        )
        XCTAssertEqual(page.totalCount, 1)
    }

    func testDiscoveryAndMembershipFailuresAreNotEmptySuccesses() async {
        let http = StubHTTPClient()
        http.error = .unauthorized
        do {
            _ = try await provider(http).items(
                in: "plex:collections:2", kind: .collection, page: PageRequest()
            )
            XCTFail("Expected discovery error")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthorized)
        }
        do {
            _ = try await provider(http).collectionMembers(of: "12", page: PageRequest())
            XCTFail("Expected membership error")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthorized)
        }
    }
}
