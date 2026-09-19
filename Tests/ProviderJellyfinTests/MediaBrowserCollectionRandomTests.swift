import CoreModels
import CoreNetworking
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ProviderJellyfin

final class MediaBrowserCollectionRandomTests: XCTestCase {
    func testRandomScopesAll201CandidatesBeforeOneStableSnapshotShuffle() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            for serverCap in [200, 47] {
                let http = RandomCollectionPagesHTTPClient(serverCap: serverCap)
                let provider = JellyfinProvider(
                    session: UserSession(
                        server: MediaServer(
                            id: "server", name: "Server",
                            baseURL: URL(string: "https://media.example")!, provider: kind
                        ),
                        userID: "user", userName: "Viewer", deviceID: "device", accessToken: "test-token"
                    ),
                    http: http
                )
                let sort = CoreModels.SortDescriptor(field: .random, direction: .ascending)
                let first = try await provider.collections(
                    in: "movies", page: PageRequest(limit: 37, sort: sort)
                )
                let requestCount = await http.queries.count
                var ids = first.items.map(\.id)
                for start in stride(from: 37, to: 201, by: 37) {
                    let page = try await provider.collections(
                        in: "movies", page: PageRequest(startIndex: start, limit: 37, sort: sort)
                    )
                    XCTAssertEqual(page.totalCount, 201)
                    ids.append(contentsOf: page.items.map(\.id))
                }
                XCTAssertEqual(first.totalCount, 201)
                XCTAssertEqual(ids.count, 201)
                XCTAssertEqual(Set(ids), Set((0..<201).map {
                    "collection-\(String(format: "%03d", $0))"
                }))
                let again = try await provider.collections(
                    in: "movies", page: PageRequest(startIndex: 37, limit: 37, sort: sort)
                )
                XCTAssertEqual(again.items.map(\.id), Array(ids[37..<74]))
                let queries = await http.queries
                XCTAssertEqual(queries.count, requestCount, "Grid pages must reuse the single shuffled snapshot")
                let candidateQueries = queries.filter { $0["IncludeItemTypes"] == "BoxSet" }
                XCTAssertGreaterThan(candidateQueries.count, 1)
                XCTAssertTrue(candidateQueries.allSatisfy {
                    $0["SortBy"] == "SortName" && $0["SortOrder"] == "Ascending"
                })
                XCTAssertTrue(candidateQueries.contains { (Int($0["StartIndex"] ?? "0") ?? 0) > 0 })
                XCTAssertTrue(queries.filter { $0["ParentId"] != nil }.allSatisfy {
                    $0["SortBy"] == "SortName" && $0["SortOrder"] == "Ascending"
                })
            }
        }
    }
}

private actor RandomCollectionPagesHTTPClient: HTTPClient {
    let serverCap: Int
    private(set) var queries: [[String: String]] = []

    init(serverCap: Int) { self.serverCap = serverCap }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        guard endpoint.path == "/Users/user/Items" else { throw AppError.notFound }
        let query = Dictionary(uniqueKeysWithValues: endpoint.queryItems.map { ($0.name, $0.value ?? "") })
        queries.append(query)
        let rows: [[String: Any]]
        if query["IncludeItemTypes"] == "BoxSet" {
            rows = (0..<201).map {
                let suffix = String(format: "%03d", $0)
                return ["Id": "collection-\(suffix)", "Name": "Collection \(suffix)", "Type": "BoxSet"]
            }
        } else if query["ParentId"] == "movies" {
            rows = (0..<201).map {
                ["Id": "movie-\(String(format: "%03d", $0))", "Type": "Movie"]
            }
        } else if let parent = query["ParentId"], parent.hasPrefix("collection-") {
            rows = [["Id": "movie-\(parent.dropFirst("collection-".count))", "Type": "Movie"]]
        } else {
            throw AppError.notFound
        }
        let start = Int(query["StartIndex"] ?? "0") ?? 0
        let limit = Int(query["Limit"] ?? "200") ?? 200
        let count = min(serverCap, min(limit, max(0, rows.count - start)))
        let page: [[String: Any]]
        if query["SortBy"] == "Random", start > 0 {
            // A valid new server shuffle can place previously returned items in
            // this page's window. With cap 200, item 201 becomes item 1 again.
            page = Array(rows.prefix(count))
        } else {
            page = Array(rows.dropFirst(start).prefix(count))
        }
        return (
            try JSONSerialization.data(withJSONObject: ["Items": page, "TotalRecordCount": rows.count]),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
