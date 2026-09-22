import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderSilo

private actor AlphabetHTTPStub: HTTPClient {
    struct Title: Sendable {
        let id: String
        let display: String
        let sort: String
    }
    let titles: [Title]
    private(set) var requests: [Endpoint] = []

    init(_ titles: [Title]) { self.titles = titles }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        let body: [String: Any]
        if endpoint.path == "/api/v2/catalog" {
            let query = Dictionary(uniqueKeysWithValues: endpoint.queryItems.map { ($0.name, $0.value ?? "") })
            guard query["library_id"] == "library", query["type"] == "movie",
                  let offset = Int(query["seek"] ?? ""), let limit = Int(query["limit"] ?? ""),
                  offset >= 0, limit > 0, limit <= 200 else { throw AppError.invalidResponse }
            let prefix = query["name_prefix"]?.lowercased()
            let selected = titles.filter {
                guard let prefix else { return true }
                return $0.sort.lowercased().hasPrefix(prefix) || $0.display.lowercased().hasPrefix(prefix)
            }.sorted { query["sort"] == "-title" ? $0.sort > $1.sort : $0.sort < $1.sort }
            let items = selected.dropFirst(offset).prefix(limit).map {
                ["content_id": $0.id, "title": $0.display, "type": "movie"]
            }
            body = ["items": items, "total": selected.count, "total_exact": true, "window_cursor": "opaque"]
        } else if let item = titles.first(where: { endpoint.path == "/api/v2/catalog/items/\($0.id)" }) {
            body = ["content_id": item.id, "title": item.display, "sort_title": item.sort, "type": "movie"]
        } else { throw AppError.notFound }
        return (try JSONSerialization.data(withJSONObject: body),
                HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

extension SiloProviderTests {
    func testAlphabetIsDeferredAndDoesNotScanOnFirstPaint() async throws {
        let raw = try credential().encoded()
        let http = AlphabetHTTPStub([])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let entries = try await provider.letterIndex(in: "library", kind: .movie, sort: .default)
        XCTAssertEqual(entries.count, 27)
        XCTAssertTrue(entries.allSatisfy { $0.startIndex == nil })
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
        let disabled = try await provider.letterIndex(in: "library", kind: .movie,
                                                    sort: .init(field: .dateAdded, direction: .descending))
        XCTAssertTrue(disabled.isEmpty)
    }

    func testAlphabetRespectsCustomSortTitlesDirectionAndCatchAll() async throws {
        let raw = try credential().encoded()
        let http = AlphabetHTTPStub([
            .init(id: "digits", display: "2001", sort: "2001"),
            .init(id: "alien", display: "The Alien", sort: "Alien"),
            .init(id: "matrix", display: "The Matrix", sort: "Matrix"),
            .init(id: "tiger", display: "Tiger", sort: "Tiger"),
            .init(id: "foreign", display: "映画", sort: "映画")
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        for (letter, ascending, descending) in [("T", 3, 1), ("M", 2, 2), ("A", 1, 3), ("#", 0, 0)] {
            let first = try await provider.letterPosition(in: "library", kind: .movie, letter: letter, sort: .default)
            XCTAssertEqual(first, ascending)
            let reverse = try await provider.letterPosition(in: "library", kind: .movie, letter: letter,
                                                          sort: .init(field: .name, direction: .descending))
            XCTAssertEqual(reverse, descending)
        }
        let missing = try await provider.letterPosition(in: "library", kind: .movie, letter: "Q", sort: .default)
        XCTAssertNil(missing)
    }

    func testAlphabetCrossesCandidateAndCatalogPageBoundaries() async throws {
        let raw = try credential().encoded()
        var titles = (0..<220).map {
            AlphabetHTTPStub.Title(id: "a\($0)", display: "The A\($0)", sort: String(format: "A%04d", $0))
        }
        titles.append(.init(id: "tiger", display: "Tiger", sort: "Tiger"))
        let http = AlphabetHTTPStub(titles)
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let position = try await provider.letterPosition(in: "library", kind: .movie, letter: "T", sort: .default)
        XCTAssertEqual(position, 220)
        let requests = await http.requests
        let catalogs = requests.filter { $0.path == "/api/v2/catalog" }
        XCTAssertTrue(catalogs.contains { $0.queryItems.contains(.init(name: "seek", value: "200")) })
        XCTAssertEqual(catalogs.filter { !$0.queryItems.contains(where: { $0.name == "name_prefix" }) }.count, 2)
    }
}
