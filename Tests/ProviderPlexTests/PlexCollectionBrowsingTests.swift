import CoreModels
import CoreNetworking
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ProviderPlex

final class PlexCollectionBrowsingTests: XCTestCase {
    private func provider(_ http: any HTTPClient) -> PlexProvider {
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

    func testLibrariesContainOnlyActualServerSections() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections", json: """
        {"MediaContainer":{"Directory":[
          {"key":"1","title":"Movies","type":"movie"},
          {"key":"2","title":"Shows","type":"show"},
          {"key":"3","title":"Music","type":"artist"}
        ]}}
        """)
        let libraries = try await provider(http).libraries()
        XCTAssertEqual(libraries.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(libraries.map(\.title), ["Movies", "Shows", "Music"])
        XCTAssertTrue(libraries.allSatisfy { $0.synthesizedName != .collections })
        XCTAssertEqual(libraries.filter(\.isMusic).count, 1)
        XCTAssertTrue(provider(http).capabilities.contains(.libraryCollections))
    }

    func testLegacyCollectionLibraryIDStillRoutesToDiscovery() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/2/collections", json: """
        {"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"12","title":"Collection","type":"collection"}]}}
        """)
        let result = try await provider(http).items(
            in: "plex:collections:2", kind: .collection, page: PageRequest()
        )
        XCTAssertEqual(result.items.map(\.id), ["12"])
        XCTAssertEqual(result.items.map(\.libraryID), ["2"])
    }

    func testDiscoveryUsesDedicatedCollectionsEndpointWithoutStreamFilter() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/2/collections", json: """
        {"MediaContainer":{"size":2,"totalSize":70,"offset":60,
          "librarySectionID":2,"viewGroup":"collection","Metadata":[
          {"ratingKey":"12","key":"/library/metadata/12/children",
           "type":"collection","subtype":"movie","title":"Static","smart":0,"childCount":3},
          {"ratingKey":"13","key":"/library/metadata/13/children",
           "type":"collection","subtype":"movie","title":"Smart","smart":1,"childCount":5}
        ]}}
        """)
        let result = try await provider(http).collections(
            in: "2",
            page: PageRequest(startIndex: 60, limit: 10)
        )
        XCTAssertEqual(result.items.map(\.id), ["12", "13"])
        XCTAssertEqual(result.items.map(\.kind), [.collection, .collection])
        XCTAssertEqual(result.items.map(\.libraryID), ["2", "2"])
        XCTAssertEqual(result.totalCount, 70)
        XCTAssertEqual(result.startIndex, 60)
        let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/library/sections/2/collections"))
        XCTAssertFalse(query.contains { ["type", "includeElements", "excludeElements"].contains($0.name) })
        XCTAssertTrue(query.contains(URLQueryItem(name: "X-Plex-Container-Start", value: "60")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "X-Plex-Container-Size", value: "10")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "sort", value: "titleSort:asc")))
    }

    func testLegacyCollectionListIDsNeverReachMetadataEndpoints() async {
        let http = StubHTTPClient()
        do {
            _ = try await provider(http).items(
                in: "plex:collections:", kind: .collection, page: PageRequest()
            )
            XCTFail("A malformed cached list ID is not a collection item")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        do {
            _ = try await provider(http).collectionMembers(
                of: "plex:collections:2", page: PageRequest()
            )
            XCTFail("A cached list ID cannot be used as a member container")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        XCTAssertTrue(http.sentPaths.isEmpty)
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
        http.stubSequence(pathSuffix: "/library/sections/2/collections", jsons: [
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
        let full = try await provider.collections(
            in: "2",
            page: PageRequest(startIndex: 60, limit: 2)
        )
        XCTAssertEqual(full.startIndex, 60)
        XCTAssertEqual(full.totalCount, 63)
        XCTAssertTrue(full.hasMore)
        let last = try await provider.collections(
            in: "2",
            page: PageRequest(startIndex: 62, limit: 2)
        )
        XCTAssertEqual(last.totalCount, 63)
        XCTAssertFalse(last.hasMore)
    }

    func testDiscoveryDoesNotSuppressRecordsWithStreamElementWhitelist() async throws {
        let result = try await provider(CollectionWhitelistHTTPClient()).collections(
            in: "2", page: PageRequest()
        )
        XCTAssertEqual(result.items.map(\.id), ["12"])
        XCTAssertEqual(result.totalCount, 1)
    }

    func testDiscoveryRejectsNonemptyEnvelopeWhoseMetadataWasOmitted() async {
        // Plex's documented includeElements whitelist can omit child elements
        // while leaving the successful container and its counts intact.
        for json in [
            #"{"MediaContainer":{"size":2}}"#,
            #"{"MediaContainer":{"size":2,"Metadata":[]}}"#,
            #"{"MediaContainer":{"size":0,"totalSize":2}}"#,
            #"{"MediaContainer":{"size":0,"Directory":[{"ratingKey":"12","type":"collection","title":"Collection"}]}}"#
        ] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/library/sections/2/collections", json: json)
            do {
                _ = try await provider(http).collections(
                    in: "2", page: PageRequest()
                )
                XCTFail("A filtered or unexpected response must not appear as an empty collection list")
            } catch {
                XCTAssertEqual(error as? AppError, .invalidResponse)
            }
        }

    }

    /// Models documented response customization on either discovery route, so
    /// this regression does not depend only on matching a chosen URL.
    private struct CollectionWhitelistHTTPClient: HTTPClient {
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            guard endpoint.path == "/library/sections/2/all"
                    || endpoint.path == "/library/sections/2/collections" else {
                throw AppError.notFound
            }
            let json: String
            if endpoint.queryItems.contains(URLQueryItem(name: "includeElements", value: "Stream")) {
                json = """
                {"MediaContainer":{"identifier":"com.plexapp.plugins.library","size":1,"librarySectionID":2}}
                """
            } else {
                json = """
                {"MediaContainer":{"identifier":"com.plexapp.plugins.library","size":1,"librarySectionID":2,
                  "Metadata":[{"ratingKey":"12","key":"/library/metadata/12/children","type":"collection",
                               "subtype":"movie","title":"Collection","smart":0,"childCount":3}]}}
                """
            }
            return (
                Data(json.utf8),
                HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
    }

    func testDiscoveryAcceptsGenuinelyEmptyEnvelopeWithoutMetadata() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/2/collections", json: #"{"MediaContainer":{"size":0}}"#)
        let result = try await provider(http).collections(
            in: "2", page: PageRequest()
        )
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.totalCount, 0)
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
            _ = try await provider(http).collections(
                in: "2", page: PageRequest()
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
