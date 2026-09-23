import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

/// Verifies the Jellyfin alphabet fast-scroll index issues the right count
/// queries. The stub matches by path suffix only (it can't vary a response by
/// query param), so the *offset math* is proven in `CoreModelsTests`; here we
/// assert the request **shape**: a name sort fans out one `NameLessThan` count
/// per letter A–Z, and non-name sorts issue nothing at all.
final class JellyfinLetterIndexTests: XCTestCase {
    func testBothProvidersResolveConcreteAscendingAndDescendingOffsets() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let provider = JellyfinProvider(session: makeSession(kind: kind), http: AlphabetCountHTTP())
            let ascending = try await provider.letterIndex(in: "lib", kind: .movie, sort: .default)
            XCTAssertEqual(ascending, [.init(letter: "#", startIndex: 0), .init(letter: "A", startIndex: 1),
                                       .init(letter: "M", startIndex: 3), .init(letter: "Z", startIndex: 4)])
            let descending = try await provider.letterIndex(in: "lib", kind: .movie,
                                                            sort: .init(field: .name, direction: .descending))
            XCTAssertEqual(descending, [.init(letter: "#", startIndex: 0), .init(letter: "Z", startIndex: 1),
                                        .init(letter: "M", startIndex: 2), .init(letter: "A", startIndex: 3)])
        }
    }

    private func makeSession(kind: ProviderKind = .jellyfin) -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: kind),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testEmbySeriesCountsMatchLibraryScope() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(kind: .emby), http: stub)
        _ = try await provider.letterIndex(in: "tv", kind: .series,
                                          sort: .init(field: .name, direction: .descending))
        XCTAssertEqual(stub.sentQueryItems.count, 28)
        for items in stub.sentQueryItems {
            XCTAssertTrue(items.contains(.init(name: "ParentId", value: "tv")))
            XCTAssertTrue(items.contains(.init(name: "IncludeItemTypes", value: "Series")))
            XCTAssertTrue(items.contains(.init(name: "Recursive", value: "true")))
            XCTAssertTrue(items.contains(.init(name: "Limit", value: "0")))
        }
        XCTAssertTrue(stub.sentPaths.allSatisfy { $0.hasSuffix("/Users/u1/Items") })
    }

    func testMissingCountIsNotSilentlyTreatedAsEmptyIndex() async {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items", json: #"{"Items":[]}"#)
        let provider = JellyfinProvider(session: makeSession(kind: .emby), http: stub)
        do {
            _ = try await provider.letterIndex(in: "movies", kind: .movie, sort: .default)
            XCTFail("Missing counts must allow the user to retry")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    }

    func testNameSortIssuesNameLessThanCountPerLetter() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        _ = try await provider.letterIndex(
            in: "lib1", kind: .movie,
            sort: CoreModels.SortDescriptor(field: .name, direction: .ascending)
        )

        // Every letter A…Z must be probed with a NameLessThan count query.
        let nameLessThanValues = stub.sentQueryItems
            .compactMap { items in items.first(where: { $0.name == "NameLessThan" })?.value }
        let expected = (UnicodeScalar("A").value...UnicodeScalar("Z").value)
            .compactMap { UnicodeScalar($0).map(String.init) }
        XCTAssertEqual(Set(nameLessThanValues), Set(expected))
        XCTAssertEqual(nameLessThanValues.count, 26)

        // Plus exactly one total-count query (no NameLessThan) for the upper bound.
        let totalQueries = stub.sentQueryItems.filter { items in
            !items.contains(where: { $0.name == "NameLessThan" || $0.name == "NameStartsWith" })
        }
        XCTAssertEqual(totalQueries.count, 1)
        XCTAssertEqual(stub.sentQueryItems.filter {
            $0.contains(.init(name: "NameStartsWith", value: "Z"))
        }.count, 1, "Separate Z from a trailing non-Latin bucket")

        // Count queries must scope to the library and request no rows.
        for items in stub.sentQueryItems {
            XCTAssertTrue(items.contains(URLQueryItem(name: "ParentId", value: "lib1")))
            XCTAssertTrue(items.contains(URLQueryItem(name: "Limit", value: "0")))
            XCTAssertTrue(items.contains(URLQueryItem(name: "EnableTotalRecordCount", value: "true")))
        }
    }

    func testNonNameSortIssuesNoRequestsAndReturnsEmpty() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items", json: #"{"Items":[],"TotalRecordCount":50}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let entries = try await provider.letterIndex(
            in: "lib1", kind: .movie,
            sort: CoreModels.SortDescriptor(field: .dateAdded, direction: .descending)
        )
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(stub.sentPaths.isEmpty, "Non-name sorts must not issue any count queries")
    }
}

private actor AlphabetCountHTTP: HTTPClient {
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let names = ["123", "ALIEN", "ALIEN 3", "MATRIX", "ZULU", "映画"]
        let query = Dictionary(uniqueKeysWithValues: endpoint.queryItems.map { ($0.name, $0.value ?? "") })
        let count: Int
        if let prefix = query["NameStartsWith"] { count = names.filter { $0.hasPrefix(prefix) }.count }
        else if let upperBound = query["NameLessThan"] { count = names.filter { $0 < upperBound }.count }
        else { count = names.count }
        return (Data("{\"Items\":[],\"TotalRecordCount\":\(count)}".utf8),
                HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
