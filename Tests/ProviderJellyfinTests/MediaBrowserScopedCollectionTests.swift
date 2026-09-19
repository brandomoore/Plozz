import CoreModels
import CoreNetworking
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ProviderJellyfin

final class MediaBrowserScopedCollectionTests: XCTestCase {
    private func provider(
        _ kind: ProviderKind, http: any HTTPClient, userID: String = "user"
    ) -> JellyfinProvider {
        JellyfinProvider(
            session: UserSession(
                server: MediaServer(
                    id: "server", name: "Server",
                    baseURL: URL(string: "https://media.example")!, provider: kind
                ),
                userID: userID, userName: userID, deviceID: "device", accessToken: "test-token"
            ),
            accountID: userID, http: http
        )
    }

    func testBothProvidersScopeGlobalBoxSetsByActualLibraryMembers() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let http = ScopedCollectionsHTTPClient()
            let provider = provider(kind, http: http)
            XCTAssertTrue(provider.capabilities.contains(.libraryCollections))
            let result = try await provider.collections(in: "movies", page: PageRequest())
            XCTAssertEqual(result.items.map(\.id), ["in-a", "in-b"])
            XCTAssertEqual(result.items.map(\.libraryID), ["movies", "movies"])
            XCTAssertEqual(result.totalCount, 2)
            let queries = await http.queries
            let candidates = queries.filter { $0["IncludeItemTypes"] == "BoxSet" }
            XCTAssertFalse(candidates.isEmpty)
            XCTAssertTrue(candidates.allSatisfy { $0["ParentId"] == nil })
            XCTAssertTrue(queries.contains { $0["ParentId"] == "movies" && $0["Recursive"] == "true" })
            XCTAssertTrue(queries.allSatisfy { $0["Limit"] == "200" })
            let groupingKey = kind == .emby ? "GroupItemsIntoCollections" : "CollapseBoxSetItems"
            XCTAssertTrue(queries.filter { $0["ParentId"] != nil }.allSatisfy { $0[groupingKey] == "false" })
        }
    }

    func testGridPagesShareScopedSnapshotWithoutPerPosterMembershipRequests() async throws {
        let http = ScopedCollectionsHTTPClient()
        let provider = provider(.emby, http: http)
        let first = try await provider.collections(in: "movies", page: PageRequest(limit: 1))
        let firstRequestCount = await http.queries.count
        let second = try await provider.collections(
            in: "movies", page: PageRequest(startIndex: 1, limit: 1)
        )
        let secondRequestCount = await http.queries.count
        XCTAssertEqual(first.items.map(\.id), ["in-a"])
        XCTAssertEqual(second.items.map(\.id), ["in-b"])
        XCTAssertEqual(second.totalCount, 2)
        XCTAssertEqual(firstRequestCount, secondRequestCount)
        let maxConcurrent = await http.maximumConcurrentMemberRequests
        XCTAssertGreaterThan(maxConcurrent, 0)
        XCTAssertLessThanOrEqual(maxConcurrent, 4)
        _ = try await provider.collections(in: "movies", page: PageRequest(limit: 1))
        let refreshedRequestCount = await http.queries.count
        XCTAssertGreaterThan(refreshedRequestCount, secondRequestCount)
    }

    func testDifferentLibrariesCannotReuseEachOthersScope() async throws {
        let http = ScopedCollectionsHTTPClient()
        let provider = provider(.jellyfin, http: http)
        let movies = try await provider.collections(in: "movies", page: PageRequest())
        let shows = try await provider.collections(in: "shows", page: PageRequest())
        XCTAssertEqual(movies.items.map(\.id), ["in-a", "in-b"])
        XCTAssertEqual(shows.items.map(\.id), ["outside"])
        XCTAssertEqual(shows.items.first?.libraryID, "shows")
    }

    func testASecondUserCannotReuseAnotherProvidersCollectionSnapshot() async throws {
        let http = ScopedCollectionsHTTPClient()
        let first = provider(.jellyfin, http: http, userID: "parent")
        _ = try await first.collections(in: "movies", page: PageRequest(limit: 1))
        let second = provider(.jellyfin, http: http, userID: "child")
        let result = try await second.collections(
            in: "movies", page: PageRequest(startIndex: 1, limit: 1)
        )
        XCTAssertEqual(result.items.map(\.id), ["in-b"])
        let paths = await http.paths
        XCTAssertTrue(paths.contains("/Users/parent/Items"))
        XCTAssertTrue(paths.contains("/Users/child/Items"))
    }

    func testMissingTotalsAndShortServerPagesDoNotTruncateScope() async throws {
        let http = ScopedCollectionsHTTPClient(includesTotals: false)
        let result = try await provider(.jellyfin, http: http).collections(
            in: "movies", page: PageRequest()
        )
        XCTAssertEqual(result.items.map(\.id), ["in-a", "in-b"])
        let queries = await http.queries
        XCTAssertTrue(queries.contains { $0["IncludeItemTypes"] == "BoxSet" && $0["StartIndex"] == "6" })
        XCTAssertTrue(queries.contains { $0["ParentId"] == "movies" && $0["StartIndex"] == "2" })
    }

    func testFailedMembershipDoesNotProduceIncompleteSuccessAndCanRetry() async throws {
        let http = ScopedCollectionsHTTPClient()
        await http.setFailingParent("outside")
        let provider = provider(.emby, http: http)
        do {
            _ = try await provider.collections(in: "movies", page: PageRequest())
            XCTFail("An unknown candidate membership cannot be silently excluded")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthorized)
        }
        await http.setFailingParent(nil)
        let result = try await provider.collections(in: "movies", page: PageRequest())
        XCTAssertEqual(result.items.map(\.id), ["in-a", "in-b"])
    }

    func testRepeatedLibraryPageFailsInsteadOfLooping() async {
        let http = ScopedCollectionsHTTPClient()
        await http.setRepeatingParent("movies")
        do {
            _ = try await provider(.jellyfin, http: http).collections(
                in: "movies", page: PageRequest()
            )
            XCTFail("A repeated page is not complete membership")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
    }

    func testEmptyLibrarySkipsCollectionMemberFanout() async throws {
        let http = ScopedCollectionsHTTPClient()
        let result = try await provider(.emby, http: http).collections(
            in: "empty-library", page: PageRequest()
        )
        XCTAssertEqual(result.totalCount, 0)
        let queries = await http.queries
        XCTAssertFalse(queries.contains { ["in-a", "in-b", "outside", "empty"].contains($0["ParentId"] ?? "") })
    }

    func testCollectionListSortIsForwardedAndServerOrderPreserved() async throws {
        let http = ScopedCollectionsHTTPClient()
        let result = try await provider(.jellyfin, http: http).collections(
            in: "movies",
            page: PageRequest(sort: CoreModels.SortDescriptor(field: .dateAdded, direction: .descending))
        )
        XCTAssertEqual(result.items.map(\.title), ["Z collection", "A collection"])
        let queries = await http.queries
        XCTAssertTrue(queries.filter { $0["IncludeItemTypes"] == "BoxSet" }.allSatisfy {
            $0["SortBy"] == "DateCreated" && $0["SortOrder"] == "Descending"
        })
    }
}

private actor ScopedCollectionsHTTPClient: HTTPClient {
    let includesTotals: Bool
    private var failingParent: String?
    private var repeatingParent: String?
    private var activeMemberRequests = 0
    private(set) var maximumConcurrentMemberRequests = 0
    private(set) var queries: [[String: String]] = []
    private(set) var paths: [String] = []

    init(includesTotals: Bool = true) { self.includesTotals = includesTotals }
    func setFailingParent(_ value: String?) { failingParent = value }
    func setRepeatingParent(_ value: String?) { repeatingParent = value }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let query = Dictionary(uniqueKeysWithValues: endpoint.queryItems.map { ($0.name, $0.value ?? "") })
        queries.append(query)
        paths.append(endpoint.path)
        let parent = query["ParentId"]
        let isMemberRequest = ["in-a", "in-b", "outside", "empty", "outside-2", "outside-3"].contains(parent ?? "")
        if isMemberRequest {
            activeMemberRequests += 1
            maximumConcurrentMemberRequests = max(maximumConcurrentMemberRequests, activeMemberRequests)
        }
        defer { if isMemberRequest { activeMemberRequests -= 1 } }
        await Task.yield()
        try Task.checkCancellation()
        if let parent, parent == failingParent { throw AppError.unauthorized }

        let rows: [[String: Any]]
        if query["IncludeItemTypes"] == "BoxSet" {
            guard parent == nil else { throw AppError.invalidResponse }
            rows = [
                ["Id": "in-a", "Name": "Z collection", "Type": "BoxSet", "ParentId": "global-boxsets"],
                ["Id": "outside", "Name": "TV only", "Type": "BoxSet", "ParentId": "global-boxsets"],
                ["Id": "in-b", "Name": "A collection", "Type": "BoxSet", "ParentId": "global-boxsets"],
                ["Id": "empty", "Name": "Empty", "Type": "BoxSet", "ParentId": "global-boxsets"],
                ["Id": "outside-2", "Name": "Other", "Type": "BoxSet", "ParentId": "global-boxsets"],
                ["Id": "outside-3", "Name": "Another", "Type": "BoxSet", "ParentId": "global-boxsets"]
            ]
        } else {
            guard query["EnableImages"] == "false", query["EnableUserData"] == "false",
                  query["CollapseBoxSetItems"] == "false" || query["GroupItemsIntoCollections"] == "false" else {
                throw AppError.invalidResponse
            }
            let ids: [String]
            switch parent {
            case "movies":
                guard query["Recursive"] == "true" else { throw AppError.invalidResponse }
                ids = ["nested-movie", "movie-b"]
            case "shows": ids = ["episode"]
            case "in-a": ids = ["foreign", "nested-movie"]
            case "in-b": ids = ["movie-b"]
            case "outside": ids = ["episode"]
            case "outside-2", "outside-3": ids = ["foreign"]
            case "empty", "empty-library": ids = []
            default: throw AppError.notFound
            }
            if isMemberRequest, query["Recursive"] != "false" { throw AppError.invalidResponse }
            rows = ids.map { ["Id": $0, "Type": "Movie"] }
        }
        let start = parent == repeatingParent && parent != nil
            ? 0 : Int(query["StartIndex"] ?? "0") ?? 0
        var envelope: [String: Any] = ["Items": Array(rows.dropFirst(start).prefix(1))]
        if includesTotals { envelope["TotalRecordCount"] = rows.count }
        return (
            try JSONSerialization.data(withJSONObject: envelope),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
