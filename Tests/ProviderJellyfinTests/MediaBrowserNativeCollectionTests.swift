import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderJellyfin

final class MediaBrowserNativeCollectionTests: XCTestCase {
    func testCollectionPrimaryAspectRatioIsPreservedForJellyfinAndEmby() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/user/Items", json: """
            {"Items":[
                {"Id":"wide","Name":"Wide","Type":"BoxSet","PrimaryImageAspectRatio":1.7777777777777777,
                 "ImageTags":{"Primary":"cover","Backdrop":"background"}},
                {"Id":"unknown","Name":"Unknown","Type":"BoxSet"}
            ],"TotalRecordCount":2}
            """)
            let page = try await provider(http, kind: kind).collections(in: "movies", page: .init())
            XCTAssertEqual(page.items.first?.primaryImageAspectRatio, 16.0 / 9)
            XCTAssertNil(page.items.last?.primaryImageAspectRatio)
            XCTAssertEqual(page.items.first?.posterURL?.path, "/Items/wide/Images/Primary")
        }
    }
    func testCompatibleServersGetOneCollectionDirectoryWithOneExistenceRequest() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/user/Views", json: """
            {"Items":[
              {"Id":"movies","Name":"Movies","CollectionType":"movies"},
              {"Id":"shows","Name":"TV Shows","CollectionType":"tvshows"}
            ]}
            """)
            http.stub(pathSuffix: "/Users/user/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
            let provider = provider(http, kind: kind)
            let libraries = try await provider.libraries()
            XCTAssertEqual(libraries.map(\.id), ["movies", "shows", provider.collectionDirectoryID])
            let directory = try XCTUnwrap(libraries.last)
            XCTAssertEqual(directory.kind, .collection)
            XCTAssertEqual(directory.synthesizedName, .collections)
            XCTAssertTrue(directory.isServerCollectionDirectory)
            XCTAssertEqual(directory.hasCollections, false)
            XCTAssertEqual(http.sentPaths, ["/Users/user/Views", "/Users/user/Items"])
            let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Users/user/Items"))
            XCTAssertTrue(query.contains(URLQueryItem(name: "Limit", value: "1")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "IncludeItemTypes", value: "BoxSet")))
            XCTAssertFalse(query.contains { $0.name == "ParentId" })
        }
    }

    func testCollectionExistenceRefreshDetectsFirstAdditionWithoutScanningMembers() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/user/Views", json: #"{"Items":[{"Id":"movies","CollectionType":"movies"}]}"#)
        http.stubSequence(pathSuffix: "/Users/user/Items", jsons: [
            #"{"Items":[],"TotalRecordCount":0}"#,
            #"{"Items":[{"Id":"new","Type":"BoxSet"}],"TotalRecordCount":1}"#
        ])
        let provider = provider(http)
        let before = try await provider.libraries()
        let after = try await provider.libraries()
        XCTAssertEqual(before.last?.hasCollections, false)
        XCTAssertEqual(after.last?.hasCollections, true)
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertEqual(http.sentPaths, ["/Users/user/Views", "/Users/user/Items", "/Users/user/Views", "/Users/user/Items"])
        XCTAssertTrue(http.sentPaths.indices.filter { http.sentPaths[$0].hasSuffix("/Items") }.allSatisfy {
            http.sentQueryItems[$0].contains(URLQueryItem(name: "Limit", value: "1"))
        })
    }

    func testUnavailableOrInvalidCollectionProbeNeverMeansEmpty() async throws {
        for response in [
            #"{"Items":[],"TotalRecordCount":1}"#,
            #"{"Items":[{"Id":"wrong-kind","Type":"Movie"}]}"#,
            #"{"Items":[],"TotalRecordCount":-1}"#
        ] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/user/Views", json: #"{"Items":[{"Id":"movies","CollectionType":"movies"}]}"#)
            http.stub(pathSuffix: "/Users/user/Items", json: response)
            let libraries = try await provider(http).libraries()
            XCTAssertEqual(libraries.count, 2)
            XCTAssertNil(libraries.last?.hasCollections)
        }
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/user/Views", json: #"{"Items":[{"Id":"movies","CollectionType":"movies"}]}"#)
        http.stub(pathSuffix: "/Users/user/Items", json: "{}", status: 404)
        let libraries = try await provider(http).libraries()
        XCTAssertNil(libraries.last?.hasCollections)
    }

    func testCollectionDirectoryIsNotAddedForEmptyOrMusicOnlyAccounts() async throws {
        for json in [
            #"{"Items":[]}"#,
            #"{"Items":[{"Id":"music","Name":"Music","CollectionType":"music"}]}"#
        ] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/user/Views", json: json)
            let libraries = try await provider(http).libraries()
            XCTAssertFalse(libraries.contains(where: \.isServerCollectionDirectory))
            XCTAssertEqual(http.sentPaths, ["/Users/user/Views"])
        }
    }

    func testDirectoryUsesOneUnscopedBoxSetRequestAndKeepsTheLibraryShortcut() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let http = NativeCollectionsHTTP(honorsLibrary: true)
            let provider = provider(http, kind: kind)
            let directory = provider.collectionDirectoryID
            let result = try await provider.items(in: directory, kind: .collection, page: .init(limit: 500))
            XCTAssertEqual(result.totalCount, 356)
            XCTAssertEqual(result.items.count, 356)
            let cached = try await provider.items(in: directory, kind: .collection, page: .init(startIndex: 20, limit: 10))
            XCTAssertEqual(cached.items.map(\.id), (20..<30).map { "collection-\($0)" })
            let beforeShortcut = await http.queries
            XCTAssertEqual(beforeShortcut.count, 1)
            XCTAssertNil(beforeShortcut[0]["ParentId"], "Never send a synthetic directory ID to the server.")
            XCTAssertEqual(beforeShortcut[0]["IncludeItemTypes"], "BoxSet")
            let shortcut = try await provider.collections(in: "movies", page: .init())
            XCTAssertEqual(shortcut.items.map(\.id), ["movie-collection"])
            let queries = await http.queries
            XCTAssertEqual(queries.count, 2)
            XCTAssertEqual(queries[1]["ParentId"], "movies")
        }
    }

    func testDirectoryDoesNotRequestTitleFeedsFiltersOrAnAlphabetIndex() async throws {
        let http = NativeCollectionsHTTP()
        let provider = provider(http)
        let directory = provider.collectionDirectoryID
        let capabilities = provider.libraryQueryCapabilities(in: directory, kind: .collection)
        XCTAssertEqual(capabilities.filters, [.all])
        XCTAssertFalse(capabilities.supportsGenres)
        XCTAssertFalse(capabilities.supportsYears)
        XCTAssertFalse(capabilities.needsIndex(for: .init()))
        let recent = try await provider.latest(limit: 10, inLibraries: [directory])
        let watching = try await provider.continueWatching(limit: 10, inLibraries: [directory])
        let resume = try await provider.homeContinueWatching(limit: 10, inLibraries: [directory], separateNextUp: true)
        let letters = try await provider.letterIndex(in: directory, kind: .collection, sort: .default)
        let facets = try await provider.libraryQueryFacets(in: directory, kind: .collection)
        XCTAssertTrue(recent.isEmpty && watching.isEmpty && resume.isEmpty && letters.isEmpty)
        XCTAssertEqual(facets, LibraryQueryFacets())
        let queries = await http.queries
        XCTAssertTrue(queries.isEmpty)
    }

    func testHiddenLibrarySearchNeverUsesTheUnscopedDirectoryAsAMediaLibrary() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/user/Views", json: """
        {"Items":[{"Id":"movies","CollectionType":"movies"},{"Id":"hidden","CollectionType":"movies"}]}
        """)
        http.stub(
            pathSuffix: "/Users/user/Items",
            requiring: [URLQueryItem(name: "IncludeItemTypes", value: "BoxSet")],
            json: #"{"Items":[],"TotalRecordCount":0}"#
        )
        http.stub(pathSuffix: "/Users/user/Items", json: """
        {"Items":[{"Id":"visible-movie","Type":"Movie"}],"TotalRecordCount":1}
        """)
        let items = try await provider(http).search(query: "film", limit: 10, excludingLibraries: ["hidden"])
        XCTAssertEqual(items.map(\.libraryID), ["movies"])
        XCTAssertEqual(http.sentPaths, ["/Users/user/Views", "/Users/user/Items", "/Users/user/Items"])
        let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Users/user/Items"))
        XCTAssertEqual(query.first { $0.name == "ParentId" }?.value, "movies")
    }

    func testBothProvidersUseTheNativeListWithoutLibraryOrMemberEnumeration() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let http = NativeCollectionsHTTP()
            let result = try await provider(http, kind: kind).collections(in: "movies", page: PageRequest(limit: 20))
            XCTAssertEqual(result.totalCount, 356)
            XCTAssertEqual(result.items.map(\.id), (0..<20).map { "collection-\($0)" })
            XCTAssertTrue(result.items.allSatisfy { $0.kind == .collection && $0.libraryID == "movies" && $0.posterURL != nil })
            let queries = await http.queries
            XCTAssertEqual(queries.count, 1, "A collection list must not trigger hundreds of membership requests.")
            XCTAssertEqual(queries.first?["ParentId"], "movies")
            XCTAssertEqual(queries.first?["Limit"], "500")
            XCTAssertEqual(queries.first?["IncludeItemTypes"], "BoxSet")
            XCTAssertFalse(queries.first?["Fields"]?.contains("MediaSources") ?? true)
        }
    }

    func testServerLibraryFilteringIsRespectedWithoutReconstructingIt() async throws {
        let http = NativeCollectionsHTTP(honorsLibrary: true)
        let provider = provider(http)
        let movies = try await provider.collections(in: "movies", page: PageRequest())
        let shows = try await provider.collections(in: "shows", page: PageRequest())
        XCTAssertEqual(movies.items.map(\.id), ["movie-collection"])
        XCTAssertEqual(shows.items.map(\.id), ["show-collection"])
        XCTAssertEqual(shows.items.first?.libraryID, "shows")
        let queries = await http.queries
        XCTAssertEqual(queries.map { $0["ParentId"] }, ["movies", "shows"])
    }

    func testCompletedPagesReuseTheSnapshotAndPageZeroRefreshes() async throws {
        let http = NativeCollectionsHTTP()
        let provider = provider(http)
        _ = try await provider.collections(in: "movies", page: PageRequest(limit: 20))
        let second = try await provider.collections(in: "movies", page: PageRequest(startIndex: 20, limit: 20))
        XCTAssertEqual(second.items.map(\.id), (20..<40).map { "collection-\($0)" })
        var count = await http.queries.count
        XCTAssertEqual(count, 1)
        _ = try await provider.collections(in: "movies", page: PageRequest(limit: 20))
        count = await http.queries.count
        XCTAssertEqual(count, 2, "A genuine first-page refresh must observe server changes.")
    }

    func testDifferentServerUsersNeverShareCollectionSnapshots() async throws {
        let http = NativeCollectionsHTTP()
        _ = try await provider(http, userID: "parent").collections(in: "movies", page: PageRequest())
        _ = try await provider(http, userID: "child").collections(in: "movies", page: PageRequest(startIndex: 20))
        let paths = await http.paths
        XCTAssertEqual(paths, ["/Users/parent/Items", "/Users/child/Items"])
    }

    func testServerCapsAndMissingTotalsStillEnumerateTheCompleteList() async throws {
        for totals in [true, false] {
            let http = NativeCollectionsHTTP(count: 201, cap: 47, includesTotals: totals)
            let result = try await provider(http).collections(in: "movies", page: PageRequest(limit: 500))
            XCTAssertEqual(result.items.map(\.id), (0..<201).map { "collection-\($0)" })
            let queries = await http.queries
            XCTAssertEqual(queries.compactMap { $0["StartIndex"] }, totals
                ? ["0", "47", "94", "141", "188"] : ["0", "47", "94", "141", "188", "201"])
        }
    }

    func testSparsePrefixAndTerminalOverlapsPreserveAllNativeCollections() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            for hole in [40, 199] {
                let http = NativeCollectionsHTTP(count: 201, cap: 47, hole: hole)
                let result = try await provider(http, kind: kind).collections(in: "movies", page: PageRequest(limit: 500))
                XCTAssertEqual(result.items.map(\.id), (0..<201).filter { $0 != hole }.map { "collection-\($0)" })
                XCTAssertEqual(result.totalCount, 200)
                let queries = await http.queries
                if hole == 199 {
                    XCTAssertEqual(queries.last?["StartIndex"], "201", "A repeated terminal row requires an empty boundary response.")
                }
            }
        }
    }

    func testMalformedListingCannotBecomeACompletedCachedSnapshot() async throws {
        for fault: NativeCollectionsHTTP.Fault in [
            .duplicates, .wrongType, .earlyEmpty, .repeatWithoutTotal,
            .negativeTotal, .emptyID, .nonPrefixOverlap, .itemsPastEnd
        ] {
            let http = NativeCollectionsHTTP(count: 5, cap: 2, fault: fault)
            let provider = provider(http)
            let captured = await HTTPResponseDiagnostics.capture {
                try await provider.collections(in: "movies", page: PageRequest())
            }
            guard case .failure(let error) = captured.result else { XCTFail("Malformed list accepted: \(fault)"); continue }
            XCTAssertEqual(error as? AppError, .invalidResponse)
            XCTAssertEqual(captured.paging.first?.stage, .collectionCandidates)
            await http.clearFault()
            let recovered = try await provider.collections(in: "movies", page: PageRequest())
            XCTAssertEqual(recovered.totalCount, 5)
        }
    }

    func testCollectionSortIsForwardedWithoutReorderingTheServerList() async throws {
        let http = NativeCollectionsHTTP(count: 3)
        let result = try await provider(http).collections(
            in: "movies", page: PageRequest(sort: .init(field: .dateAdded, direction: .descending))
        )
        XCTAssertEqual(result.items.map(\.id), ["collection-0", "collection-1", "collection-2"])
        let query = await http.queries.first
        XCTAssertEqual(query?["SortBy"], "DateCreated")
        XCTAssertEqual(query?["SortOrder"], "Descending")
    }

    func testConnectionRetryIsBoundedAndOtherFailuresAreNotRetried() async throws {
        for error: AppError in [.serverUnreachable, .cancelled, .invalidResponse] {
            let http = NativeCollectionsHTTP(error: error, failures: 2)
            do {
                _ = try await provider(http).collections(in: "movies", page: PageRequest())
                XCTFail("Permanent failure accepted")
            } catch let actual as AppError { XCTAssertEqual(actual, error) }
            let count = await http.queries.count
            XCTAssertEqual(count, error == .serverUnreachable ? 2 : 1)
        }
        let http = NativeCollectionsHTTP(error: .serverUnreachable, failures: 1)
        let result = try await provider(http).collections(in: "movies", page: PageRequest())
        XCTAssertEqual(result.totalCount, 356)
        let count = await http.queries.count
        XCTAssertEqual(count, 2)
    }

    func testCold356CollectionListingFinishesWithinOneSecondWith200msNetworkLatency() async throws {
        let http = NativeCollectionsHTTP(delay: .milliseconds(200))
        let start = ContinuousClock.now
        let provider = provider(http)
        let result = try await provider.collections(in: "movies", page: PageRequest(limit: 500))
        XCTAssertEqual(result.items.count, 356)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let cached = try await provider.collections(in: "movies", page: PageRequest(startIndex: 100, limit: 50))
        XCTAssertEqual(cached.items.count, 50)
        let count = await http.queries.count
        XCTAssertEqual(count, 1, "Warm grid pages must perform no network work.")
    }

    private func provider(
        _ http: any HTTPClient, kind: ProviderKind = .jellyfin, userID: String = "user"
    ) -> JellyfinProvider {
        JellyfinProvider(session: UserSession(
            server: MediaServer(id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!, provider: kind),
            userID: userID, userName: "Viewer", deviceID: "device", accessToken: "fixture"
        ), http: http)
    }
}

private actor NativeCollectionsHTTP: HTTPClient {
    enum Fault {
        case duplicates, wrongType, earlyEmpty, repeatWithoutTotal
        case negativeTotal, emptyID, nonPrefixOverlap, itemsPastEnd
    }
    let count: Int
    let cap: Int
    let includesTotals: Bool
    let honorsLibrary: Bool
    let hole: Int?
    let delay: Duration
    let error: AppError
    var failures: Int
    var fault: Fault?
    private(set) var queries: [[String: String]] = []
    private(set) var paths: [String] = []

    init(
        count: Int = 356, cap: Int = 500, includesTotals: Bool = true,
        honorsLibrary: Bool = false, hole: Int? = nil, fault: Fault? = nil,
        delay: Duration = .zero, error: AppError = .serverUnreachable, failures: Int = 0
    ) {
        self.count = count
        self.cap = cap
        self.includesTotals = includesTotals
        self.honorsLibrary = honorsLibrary
        self.hole = hole
        self.fault = fault
        self.delay = delay
        self.error = error
        self.failures = failures
    }

    func clearFault() { fault = nil }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let query = Dictionary(uniqueKeysWithValues: endpoint.queryItems.map { ($0.name, $0.value ?? "") })
        queries.append(query)
        paths.append(endpoint.path)
        guard query["IncludeItemTypes"] == "BoxSet" else { throw AppError.invalidResponse }
        if failures > 0 { failures -= 1; throw error }
        try await Task.sleep(for: delay)
        var rows: [[String: Any]?] = (0..<count).map { index in
            index == hole ? nil : [
                "Id": "collection-\(index)", "Name": "Collection \(index)", "Type": "BoxSet",
                "ImageTags": ["Primary": "cover"], "PrimaryImageAspectRatio": 16.0 / 9.0
            ]
        }
        if honorsLibrary, query["ParentId"] != nil {
            rows = [["Id": query["ParentId"] == "movies" ? "movie-collection" : "show-collection", "Type": "BoxSet"]]
        }
        let start = Int(query["StartIndex"] ?? "") ?? 0
        let limit = min(cap, Int(query["Limit"] ?? "") ?? 500)
        var items = rows.dropFirst(start).prefix(limit).compactMap { $0 }
        if fault == .duplicates { items = [["Id": "duplicate", "Type": "BoxSet"], ["Id": "duplicate", "Type": "BoxSet"]] }
        if fault == .wrongType { items = [["Id": "movie", "Type": "Movie"]] }
        if fault == .emptyID { items = [["Id": "", "Type": "BoxSet"]] }
        if start > 0, fault == .earlyEmpty { items = [] }
        if start > 0, fault == .repeatWithoutTotal { items = [["Id": "collection-0", "Type": "BoxSet"]] }
        if start > 0, fault == .nonPrefixOverlap {
            items = [["Id": "collection-2", "Type": "BoxSet"], ["Id": "collection-0", "Type": "BoxSet"]]
        }
        var envelope: [String: Any] = ["Items": items]
        if includesTotals, fault != .repeatWithoutTotal { envelope["TotalRecordCount"] = rows.count }
        if fault == .negativeTotal { envelope["TotalRecordCount"] = -1 }
        if start > 0, fault == .itemsPastEnd { envelope["TotalRecordCount"] = start }
        return (
            try JSONSerialization.data(withJSONObject: envelope),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
