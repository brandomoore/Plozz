import CoreModels
import XCTest
@testable import ProviderJellyfin

final class MediaBrowserCollectionBrowsingTests: XCTestCase {
    private func provider(_ kind: ProviderKind, _ http: StubHTTPClient) -> JellyfinProvider {
        JellyfinProvider(
            session: UserSession(
                server: MediaServer(
                    id: "collections-server", name: "Server",
                    baseURL: URL(string: "https://media.example")!, provider: kind
                ),
                userID: "user", userName: "Viewer", deviceID: "device", accessToken: "test-token"
            ),
            accountID: "account", http: http
        )
    }

    func testJellyfinAndEmbyKeepNativeCollectionsLibraryAndBoxSetList() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/user/Views", json: """
            {"Items":[{"Id":"boxsets","Name":"Collections","CollectionType":"boxsets"}]}
            """)
            http.stub(pathSuffix: "/Users/user/Items", json: """
            {"Items":[{"Id":"set","Name":"Collection","Type":"BoxSet"}],"TotalRecordCount":61}
            """)
            let provider = provider(kind, http)
            let libraries = try await provider.libraries()
            XCTAssertEqual(libraries.map(\.id), ["boxsets"])
            XCTAssertEqual(libraries.map(\.kind), [.collection])
            let page = try await provider.items(
                in: "boxsets", kind: .collection, page: PageRequest(startIndex: 60, limit: 1)
            )
            XCTAssertEqual(page.items.map(\.kind), [.collection])
            XCTAssertEqual(page.totalCount, 61)
            let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Users/user/Items"))
            XCTAssertTrue(query.contains(URLQueryItem(name: "ParentId", value: "boxsets")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "StartIndex", value: "60")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "Limit", value: "1")))
        }
    }

    func testJellyfinAndEmbyPageMixedMembersInServerOrder() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/user/Items", json: """
            {"Items":[
              {"Id":"z","Name":"Z","Type":"Movie"},
              {"Id":"a","Name":"A","Type":"Series"},
              {"Id":"nested","Name":"Nested","Type":"BoxSet"}
            ],"TotalRecordCount":63}
            """)
            let result = try await provider(kind, http).collectionMembers(
                of: "set", page: PageRequest(startIndex: 60, limit: 3)
            )
            XCTAssertEqual(result.items.map(\.id), ["z", "a", "nested"])
            XCTAssertEqual(result.items.map(\.kind), [.movie, .series, .collection])
            XCTAssertEqual(result.totalCount, 63)
            let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Users/user/Items"))
            XCTAssertTrue(query.contains(URLQueryItem(name: "ParentId", value: "set")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "Recursive", value: "false")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "StartIndex", value: "60")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "Limit", value: "3")))
            XCTAssertFalse(query.contains { ["SortBy", "SortOrder", "IncludeItemTypes"].contains($0.name) })
        }
    }

    func testJellyfinAndEmbyDistinguishFailureFromEmptyCollection() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/user/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
            let provider = provider(kind, http)
            let result = try await provider.collectionMembers(of: "set", page: PageRequest())
            XCTAssertEqual(result.totalCount, 0)
            XCTAssertTrue(result.items.isEmpty)
            http.error = .unauthorized
            do {
                _ = try await provider.collectionMembers(of: "set", page: PageRequest())
                XCTFail("Expected membership error")
            } catch {
                XCTAssertEqual(error as? AppError, .unauthorized)
            }
        }
    }
}
