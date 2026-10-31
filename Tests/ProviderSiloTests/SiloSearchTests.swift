import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderSilo

extension SiloProviderTests {
    func testSearchJournalRecordsLibrariesAndCursorPagesWithoutContent() async throws {
        let raw = try credential(profileToken: "private-profile-token").encoded()
        let http = SiloSearchHTTP(catalogs: ["private-library": searchCards(count: 6), "disabled": []], pageCapacity: 2)
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let journal = SearchDiagnosticJournal()
        journal.start()
        let source = try XCTUnwrap(journal.beginSearch()?.source(index: 0, provider: .silo, limit: 3, disabledLibraries: 1))
        let items = try await SearchDiagnosticJournal.$currentSource.withValue(source) {
            try await provider.search(query: "private-query", limit: 3, excludingLibraries: ["disabled"])
        }
        source.finish(resultCount: items.count)
        let report = journal.export(scope: DiagnosticExportScope())
        let facts = try XCTUnwrap(report.entries.first?.facts)
        XCTAssertEqual(facts.availableLibraryCount, 2)
        XCTAssertEqual(facts.excludedLibraryCount, 1)
        XCTAssertEqual(facts.librariesStarted, 1)
        XCTAssertEqual(facts.pageCount, 2)
        XCTAssertEqual(facts.pages.map(\.limit), [3, 3])
        XCTAssertEqual(facts.pages.map(\.usedCursor), [false, true])
        XCTAssertEqual(facts.pages.map(\.rows), [2, 2])
        XCTAssertEqual(facts.resultCount, 3)
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for value in ["private", "movie-tmdb", "Movie", "account1", "profile1", raw] {
            XCTAssertFalse(text.contains(value), value)
        }
    }

    func testSearchJournalDistinguishesNoLibrariesDisabledAndNoMatches() async throws {
        for (catalogs, disabled, available, excluded, searched): ([String: [String]], [String], Int, Int, Int) in [
            ([:], [], 0, 0, 0), (["1": []], ["1"], 1, 1, 0), (["1": []], [], 1, 0, 1)
        ] {
            let raw = try credential().encoded()
            let provider = try SiloProvider(
                context: context(raw), credentials: SiloCredentialStub(raw), http: SiloSearchHTTP(catalogs: catalogs)
            )
            let journal = SearchDiagnosticJournal()
            journal.start()
            let source = try XCTUnwrap(journal.beginSearch()?.source(
                index: 0, provider: .silo, limit: 40, disabledLibraries: disabled.count
            ))
            let items = try await SearchDiagnosticJournal.$currentSource.withValue(source) {
                try await provider.search(query: "missing", limit: 40, excludingLibraries: disabled)
            }
            source.finish(resultCount: items.count)
            let facts = try XCTUnwrap(journal.export(scope: DiagnosticExportScope()).entries.first?.facts)
            XCTAssertEqual(facts.outcome, .empty)
            XCTAssertEqual(facts.availableLibraryCount, available)
            XCTAssertEqual(facts.excludedLibraryCount, excluded)
            XCTAssertEqual(facts.librariesStarted, searched)
        }
    }

    func testSearchJournalKeepsHTTPAndDecodingFailureStages() async throws {
        let cases: [(String, String, Int, AppError, ResponseDecodingDiagnostic.Route)] = [
            (#"{"items":[{"id":"1","name":"Movies","type":"movie"}]}"#, "{}", 503, .invalidResponse, .searchCatalog),
            (#"{"items":[{"id":"1","name":"Movies","type":"movie"}]}"#, #"{"items":"private-secret"}"#, 200, .decoding, .searchCatalog),
            (#"{"items":"private-secret"}"#, "{}", 200, .decoding, .searchLibraries)
        ]
        for (libraries, catalog, status, expected, route) in cases {
            let raw = try credential().encoded()
            let http = SiloSearchFailureHTTP(libraries: libraries, catalog: catalog, catalogStatus: status)
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            let journal = SearchDiagnosticJournal()
            journal.start()
            let source = try XCTUnwrap(journal.beginSearch()?.source(index: 0, provider: .silo, limit: 40, disabledLibraries: 0))
            do {
                _ = try await SearchDiagnosticJournal.$currentSource.withValue(source) {
                    try await provider.search(query: "private-query", limit: 40)
                }
                XCTFail("Expected a provider failure")
            } catch {
                XCTAssertEqual(error as? AppError, expected)
                source.finish(error: expected)
            }
            let report = journal.export(scope: DiagnosticExportScope())
            let facts = try XCTUnwrap(report.entries.first?.facts)
            XCTAssertEqual(facts.outcome, .failed)
            if status == 503 {
                XCTAssertEqual(facts.http.last?.httpStatus, 503)
                XCTAssertEqual(facts.http.last?.route, route)
            } else {
                XCTAssertEqual(facts.responses.last?.reason, .wrongType)
                XCTAssertEqual(facts.responses.last?.path, "items")
                XCTAssertEqual(facts.responses.last?.route, route)
            }
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("private"))
        }
    }

    func testSearchJournalIdentifiesMissingAndRepeatedCursors() async throws {
        for (page, reason): (String, SearchDiagnosticJournal.PagingFailure) in [
            (#"{"has_more":true}"#, .missingCursor),
            (#"{"has_more":true,"next_cursor":"private-cursor"}"#, .repeatedCursor)
        ] {
            let raw = try credential().encoded()
            let http = SiloHTTPStub([
                "/api/v2/user/libraries": #"{"items":[{"id":"1","name":"Movies","type":"movie"}]}"#,
                "/api/v2/catalog": """
                {"items":[{"content_id":"movie-tmdb-1","type":"movie","title":"Movie"}],
                 "total":100,"total_exact":true,"window_cursor":"private-window","page":\(page)}
                """
            ])
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            let journal = SearchDiagnosticJournal()
            journal.start()
            let source = try XCTUnwrap(journal.beginSearch()?.source(index: 0, provider: .silo, limit: 40, disabledLibraries: 0))
            do {
                _ = try await SearchDiagnosticJournal.$currentSource.withValue(source) {
                    try await provider.search(query: "private-query", limit: 40)
                }
                XCTFail("Expected invalid continuation")
            } catch {
                XCTAssertEqual(error as? AppError, .invalidResponse)
                source.finish(error: .invalidResponse)
            }
            let report = journal.export(scope: DiagnosticExportScope())
            XCTAssertEqual(report.entries.first?.facts.pages.last?.failure, reason)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("private"))
        }
    }

    func testSearchUsesNativeCatalogWithProfileAndLibraryScope() async throws {
        let raw = try credential(profileToken: "profile-proof").encoded()
        let http = SiloSearchHTTP(catalogs: [
            "1": [#"{"content_id":"movie-tmdb-1","type":"movie","title":"Dune","year":2021}"#],
            "2": [
                #"{"content_id":"series-tvdb-2","type":"series","title":"Dune: Prophecy"}"#,
                #"{"content_id":"episode-tvdb-2-1-1","type":"episode","title":"Dune episode"}"#
            ]
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)

        let items = try await provider.search(query: "Dune & prophecy", limit: 40)

        XCTAssertEqual(items.map(\.kind), [.movie, .series, .episode])
        XCTAssertEqual(items.map(\.libraryID), ["1", "2", "2"])
        XCTAssertEqual(items.map(\.sourceAccountID), ["account1", "account1", "account1"])
        XCTAssertEqual(items.first?.providerIDs["Tmdb"], "1")
        XCTAssertEqual(items.last?.seriesID, "series-tvdb-2")
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v2/user/libraries", "/api/v2/catalog", "/api/v2/catalog"])
        XCTAssertTrue(requests.allSatisfy { $0.method == .get })
        XCTAssertTrue(requests.allSatisfy { $0.headers["X-Profile-Id"] == "profile1" })
        XCTAssertTrue(requests.allSatisfy { $0.headers["X-Profile-Token"] == "profile-proof" })
        XCTAssertTrue(requests.allSatisfy { $0.headers["Authorization"] != nil })
        XCTAssertTrue(requests.dropFirst().allSatisfy {
            $0.queryItems.contains(.init(name: "q", value: "Dune & prophecy"))
        })
    }

    func testSearchExcludesDisabledLibrariesAndDeduplicatesWithinLimit() async throws {
        let raw = try credential().encoded()
        let shared = #"{"content_id":"movie-tmdb-1","type":"movie","title":"Dune"}"#
        let second = #"{"content_id":"movie-tmdb-2","type":"movie","title":"Dune Part Two"}"#
        let http = SiloSearchHTTP(catalogs: [
            "1": [shared],
            "2": [shared, second],
            "3": [#"{"content_id":"movie-tmdb-3","type":"movie","title":"Hidden"}"#]
        ])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)

        let items = try await provider.search(query: "Dune", limit: 3, excludingLibraries: ["3"])

        XCTAssertEqual(items.map(\.id), ["movie-tmdb-1", "movie-tmdb-2"])
        XCTAssertEqual(items.map(\.libraryID), ["1", "2"])
        let requests = await http.requests.filter { $0.path == "/api/v2/catalog" }
        XCTAssertEqual(requests.map { $0.value(for: "library_id") }, ["1", "2"])
        XCTAssertEqual(requests.map { $0.value(for: "limit") }, ["3", "2"])
    }

    func testSearchKeepsCursorPageSizeWhenServerReturnsAShortPage() async throws {
        let raw = try credential().encoded()
        let http = SiloSearchHTTP(catalogs: ["1": searchCards(count: 6)], pageCapacity: 2)
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)

        let items = try await provider.search(query: "Movie", limit: 3)

        XCTAssertEqual(items.map(\.id), ["movie-tmdb-1", "movie-tmdb-2", "movie-tmdb-3"])
        let requests = await http.requests.filter { $0.path == "/api/v2/catalog" }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.value(for: "limit") }, ["3", "3"])
        XCTAssertNil(requests.first?.value(for: "cursor"))
        XCTAssertNotNil(requests.last?.value(for: "cursor"))
    }

    func testSearchKeepsCursorPageSizeBeyondNativeMaximumAndTrimsFinalPage() async throws {
        let raw = try credential().encoded()
        let http = SiloSearchHTTP(catalogs: ["1": searchCards(count: 450)])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)

        let items = try await provider.search(query: "Movie", limit: 201)

        XCTAssertEqual(items.count, 201)
        XCTAssertEqual(items.first?.id, "movie-tmdb-1")
        XCTAssertEqual(items.last?.id, "movie-tmdb-201")
        let requests = await http.requests.filter { $0.path == "/api/v2/catalog" }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.value(for: "limit") }, ["200", "200"])
    }

    func testSearchStopsAtLimitWithoutRequestingAnotherLibrary() async throws {
        let raw = try credential().encoded()
        let http = SiloSearchHTTP(catalogs: ["1": searchCards(count: 5), "2": searchCards(count: 5)])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)

        let items = try await provider.search(query: "Movie", limit: 2)

        XCTAssertEqual(items.count, 2)
        let requests = await http.requests.filter { $0.path == "/api/v2/catalog" }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(for: "library_id"), "1")
    }

    func testSearchWithAllLibrariesDisabledDoesNotQueryCatalog() async throws {
        let raw = try credential().encoded()
        let http = SiloSearchHTTP(catalogs: ["1": searchCards(count: 1)])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)

        let items = try await provider.search(query: "Movie", limit: 40, excludingLibraries: ["1"])

        XCTAssertTrue(items.isEmpty)
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v2/user/libraries"])
    }

    func testSearchEmptyResultsAndNonpositiveLimits() async throws {
        let raw = try credential().encoded()
        let http = SiloSearchHTTP(catalogs: ["1": []])
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)

        for limit in [0, -1] {
            let items = try await provider.search(query: "Movie", limit: limit)
            XCTAssertTrue(items.isEmpty)
        }
        let initialRequests = await http.requests
        XCTAssertTrue(initialRequests.isEmpty)
        let items = try await provider.search(query: "Missing", limit: 40)
        XCTAssertTrue(items.isEmpty)
        let requests = await http.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testSearchPreservesCatalogFailureInsteadOfReturningNoMatches() async throws {
        for (status, expected) in [(403, AppError.unauthorized), (503, AppError.invalidResponse)] {
            let raw = try credential().encoded()
            let http = SiloSearchHTTP(catalogs: ["1": []], catalogStatus: status)
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)

            do {
                _ = try await provider.search(query: "Movie", limit: 40)
                XCTFail("HTTP \(status) must remain a failed search")
            } catch {
                XCTAssertEqual(error as? AppError, expected)
            }
        }
    }

    func testSearchRejectsMissingOrRepeatedContinuationCursors() async throws {
        for page in [#"{"has_more":true}"#, #"{"has_more":true,"next_cursor":"repeated"}"#] {
            let raw = try credential().encoded()
            let http = SiloHTTPStub([
                "/api/v2/user/libraries": #"{"items":[{"id":"1","name":"Movies","type":"movie"}]}"#,
                "/api/v2/catalog": """
                {"items":[{"content_id":"movie-tmdb-1","type":"movie","title":"Movie"}],
                 "total":100,"total_exact":true,"window_cursor":"window","page":\(page)}
                """
            ])
            let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
            do {
                _ = try await provider.search(query: "Movie", limit: 40)
                XCTFail("Invalid continuation must not loop or silently truncate")
            } catch {
                XCTAssertEqual(error as? AppError, .invalidResponse)
            }
            let requests = await http.requests
            XCTAssertLessThanOrEqual(requests.count, 3)
        }
    }

    private func searchCards(count: Int) -> [String] {
        (1...count).map {
            #"{"content_id":"movie-tmdb-\#($0)","type":"movie","title":"Movie \#($0)"}"#
        }
    }
}

private extension Endpoint {
    func value(for name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }
}

private struct SiloSearchFailureHTTP: HTTPClient {
    let libraries: String
    let catalog: String
    let catalogStatus: Int

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let isCatalog = endpoint.path == "/api/v2/catalog"
        return (Data((isCatalog ? catalog : libraries).utf8), try XCTUnwrap(HTTPURLResponse(
            url: baseURL, statusCode: isCatalog ? catalogStatus : 200, httpVersion: nil, headerFields: nil
        )))
    }
}

private actor SiloSearchHTTP: HTTPClient {
    private(set) var requests: [Endpoint] = []
    let catalogs: [String: [String]]
    let pageCapacity: Int
    let catalogStatus: Int

    init(catalogs: [String: [String]], pageCapacity: Int = 200, catalogStatus: Int = 200) {
        self.catalogs = catalogs
        self.pageCapacity = pageCapacity
        self.catalogStatus = catalogStatus
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(endpoint)
        if endpoint.path == "/api/v2/user/libraries" {
            let libraries = catalogs.keys.sorted().map {
                #"{"id":"\#($0)","name":"Library \#($0)","type":"video"}"#
            }
            return try response(#"{"items":[\#(libraries.joined(separator: ","))]}"#, baseURL: baseURL)
        }
        guard endpoint.path == "/api/v2/catalog",
              let libraryID = endpoint.value(for: "library_id"),
              let cards = catalogs[libraryID],
              let limit = endpoint.value(for: "limit").flatMap(Int.init),
              (1...200).contains(limit) else { throw AppError.invalidResponse }
        if catalogStatus != 200 {
            return try response("{}", status: catalogStatus, baseURL: baseURL)
        }
        var offset = 0
        if let cursor = endpoint.value(for: "cursor") {
            let fields = cursor.split(separator: ":")
            // Native Silo cursor scope binds limit along with the query/library.
            guard fields.count == 3, fields[0] == libraryID,
                  Int(fields[2]) == limit, let start = Int(fields[1]) else {
                return try response("{}", status: 409, baseURL: baseURL)
            }
            offset = start
        }
        let page = Array(cards.dropFirst(offset).prefix(min(limit, pageCapacity)))
        let next = offset + page.count
        let hasMore = next < cards.count
        let continuation = hasMore ? #","next_cursor":"\#(libraryID):\#(next):\#(limit)""# : ""
        return try response("""
            {"items":[\(page.joined(separator: ","))],"total":\(cards.count),"total_exact":true,
             "window_cursor":"window","page":{"has_more":\(hasMore)\(continuation)}}
            """, baseURL: baseURL)
    }

    private func response(_ body: String, status: Int = 200, baseURL: URL) throws -> (Data, HTTPURLResponse) {
        (Data(body.utf8), try XCTUnwrap(HTTPURLResponse(
            url: baseURL, statusCode: status, httpVersion: nil, headerFields: nil
        )))
    }
}
