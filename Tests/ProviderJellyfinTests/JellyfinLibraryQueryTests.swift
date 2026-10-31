import CoreModels
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinLibraryQueryTests: XCTestCase {
    func testBrowseLeavesCollectionPolicyToEachServerWithoutForcingItOn() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            for serverType in ["BoxSet", "Movie"] {
                let http = StubHTTPClient()
                http.stub(pathSuffix: "/Users/user/Items", json: """
                {"Items":[{"Id":"original-id","Name":"Server result","Type":"\(serverType)"}],"TotalRecordCount":7}
                """)
                let page = try await provider(http, kind: kind).items(
                    in: "library", kind: .movie,
                    page: .init(startIndex: 2, limit: 1, collectionPresentation: .serverDefault)
                )
                XCTAssertEqual(page.items.map(\.id), ["original-id"])
                XCTAssertEqual(page.items.first?.kind, serverType == "BoxSet" ? .collection : .movie)
                XCTAssertEqual(page.totalCount, 7)
                XCTAssertEqual(page.startIndex, 2)
                XCTAssertEqual(http.sentPaths, ["/Users/user/Items"])
                let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Items"))
                XCTAssertFalse(query.contains {
                    ["CollapseBoxSetItems", "GroupItemsIntoCollections"].contains($0.name)
                }, "Omitting the override follows the server policy; true would force grouping.")
                XCTAssertTrue(query.contains(.init(name: "ParentId", value: "library")))
                XCTAssertTrue(query.contains(.init(name: "IncludeItemTypes", value: "Movie")))
                XCTAssertTrue(query.contains(.init(name: "StartIndex", value: "2")))
            }
        }
    }

    func testInventoriesFiltersOtherSortsAndNonmovieQueriesKeepIndividualItems() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/user/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
            let source = provider(http, kind: kind)
            let parameter = kind == .emby ? "GroupItemsIntoCollections" : "CollapseBoxSetItems"
            let requests: [(MediaItemKind, PageRequest)] = [
                (.movie, .init()),
                (.movie, .init(sort: .init(field: .year, direction: .descending), collectionPresentation: .serverDefault)),
                (.movie, .init(filters: .init(filter: .unwatched), collectionPresentation: .serverDefault)),
                (.movie, .init(filters: .init(genre: "Drama"), collectionPresentation: .serverDefault)),
                (.movie, .init(filters: .init(year: 2024), collectionPresentation: .serverDefault)),
                (.series, .init(collectionPresentation: .serverDefault)),
                (.episode, .init(collectionPresentation: .serverDefault))
            ]
            for (itemKind, request) in requests {
                _ = try await source.items(in: "library", kind: itemKind, page: request)
                XCTAssertTrue(try XCTUnwrap(http.queryItems(forPathSuffix: "/Items"))
                    .contains(.init(name: parameter, value: "false")))
            }
            _ = try await source.libraryQueryInventory(
                in: "library", kind: .movie, page: .init(collectionPresentation: .serverDefault)
            )
            XCTAssertTrue(try XCTUnwrap(http.queryItems(forPathSuffix: "/Items"))
                .contains(.init(name: parameter, value: "false")))
        }
    }

    func testGroupedAlphabetUsesBoxSetNamesAndOffsetsInsteadOfMemberPredicates() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            for direction: SortDirection in [.ascending, .descending] {
                let http = StubHTTPClient()
                let movie = #"{"Id":"movie","Name":"Apple","Type":"Movie"}"#
                let collection = #"{"Id":"set","Name":"Zebra cuts","Type":"BoxSet"}"#
                let rows = direction == .ascending ? [movie, collection] : [collection, movie]
                http.stubSequence(pathSuffix: "/Users/user/Items", jsons: rows.map {
                    #"{"Items":["# + $0 + #"],"TotalRecordCount":2}"#
                })
                let source = provider(http, kind: kind)
                let request = PageRequest(
                    sort: .init(field: .name, direction: direction), collectionPresentation: .serverDefault
                )
                let entries = try await source.libraryQueryLetterIndex(in: "library", kind: .movie, page: request)
                XCTAssertEqual(entries, LibraryLetterIndex.deferredEntries(direction: direction))
                XCTAssertTrue(http.sentPaths.isEmpty)
                let position = try await source.libraryQueryLetterPosition(
                    in: "library", kind: .movie, letter: "Z", page: request
                )
                XCTAssertEqual(position, direction == .ascending ? 1 : 0)
                XCTAssertTrue(http.sentQueryItems.allSatisfy { query in
                    !query.contains {
                        ["CollapseBoxSetItems", "GroupItemsIntoCollections", "NameLessThan", "NameStartsWith"].contains($0.name)
                    }
                })
            }
        }
    }

    func testRandomFilterInventoryUsesStablePagingOnBothBackends() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/user/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
            let source = provider(http, kind: kind)
            let random = SortDescriptor(field: .random, direction: .descending)
            for offset in [0, 120] {
                _ = try await source.libraryQueryInventory(
                    in: "library", kind: .movie,
                    page: .init(startIndex: offset, sort: random, filters: .init(filter: .atmos)))
                let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Items"))
                XCTAssertEqual(query.first { $0.name == "SortBy" }?.value, "SortName")
                XCTAssertEqual(query.first { $0.name == "SortOrder" }?.value, "Ascending")
            }
            _ = try await source.items(in: "library", kind: .movie, page: .init(sort: random))
            let native = try XCTUnwrap(http.queryItems(forPathSuffix: "/Items"))
            XCTAssertEqual(native.first { $0.name == "SortBy" }?.value, "Random")
        }
    }

    func testGenreAndYearFacetsUseTheMatchingScopedEndpointForJellyfinAndEmby() async throws {
        for kind: ProviderKind in [.jellyfin, .emby] {
            for (itemKind, serverType): (MediaItemKind, String) in [(.movie, "Movie"), (.series, "Series")] {
                let http = StubHTTPClient()
                http.stub(pathSuffix: "/Items/Filters2",
                          json: #"{"Genres":[{"Name":"Drama","Id":"genre-id"}],"Tags":[]}"#)
                http.stub(pathSuffix: "/Items/Filters",
                          json: #"{"Genres":["Drama","Action","Drama"],"Years":[2023,2024,2023]}"#)
                let facets = try await provider(http, kind: kind).libraryQueryFacets(in: "library", kind: itemKind)
                XCTAssertEqual(facets.genres, ["Action", "Drama"])
                XCTAssertEqual(facets.years, [2024, 2023])
                XCTAssertEqual(http.sentPaths, ["/Items/Filters"])
                let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Items/Filters"))
                XCTAssertTrue(query.contains(.init(name: "UserId", value: "user")))
                XCTAssertTrue(query.contains(.init(name: "ParentId", value: "library")))
                XCTAssertTrue(query.contains(.init(name: "IncludeItemTypes", value: serverType)))
            }
        }
    }

    func testFacetFailureIsNotDisguisedAsAnEmptySuccessfulMenu() async {
        let http = StubHTTPClient()
        http.error = .serverUnreachable
        do {
            _ = try await provider(http).libraryQueryFacets(in: "library", kind: .movie)
            XCTFail("A failed facet request must remain retryable.")
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
    }

    private func provider(_ http: StubHTTPClient, kind: ProviderKind = .jellyfin) -> JellyfinProvider {
        JellyfinProvider(session: UserSession(
            server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://jellyfin.test")!, provider: kind),
            userID: "user", userName: "User", deviceID: "device", accessToken: "test"
        ), http: http)
    }

    func testNativeFilterRequestsStaySmallAndIntersectFacets() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/user/Items", json: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await provider(http).items(in: "library", kind: .movie,
                                          page: .init(filters: .init(filter: .unwatched, genre: "Drama", year: 2024)))
        let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/Items"))
        XCTAssertTrue(query.contains(.init(name: "IsPlayed", value: "false")))
        XCTAssertTrue(query.contains(.init(name: "Genres", value: "Drama")))
        XCTAssertTrue(query.contains(.init(name: "Years", value: "2024")))
        let fields = try XCTUnwrap(query.first { $0.name == "Fields" }?.value)
        XCTAssertFalse(fields.contains("MediaSources"))
        XCTAssertFalse(fields.contains("MediaStreams"))
    }

    func testFormatInventoryIncludesAllAudioTracksAndHistoryFacts() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/user/Items", json: """
        {"Items":[{"Id":"movie","Name":"Movie","Type":"Movie","DateCreated":"2024-01-02T00:00:00Z",
        "UserData":{"Played":false,"PlayCount":3},"MediaStreams":[
        {"Index":0,"Type":"Audio","Codec":"aac","IsDefault":true},
        {"Index":1,"Type":"Audio","Codec":"eac3","Profile":"Dolby Atmos"}]}],"TotalRecordCount":1}
        """)
        let page = try await provider(http).libraryQueryInventory(in: "library", kind: .movie,
                                                                 page: .init(filters: .init(filter: .atmos)))
        let item = try XCTUnwrap(page.items.first)
        XCTAssertTrue(item.librarySortValues?.hasAtmos == true)
        XCTAssertEqual(item.librarySortValues?.playCount, 3)
        XCTAssertNotNil(item.librarySortValues?.dateAdded)
    }

    func testEmbySeriesHistoryUsesEpisodeInventoryInsteadOfUnverifiedNativeKey() {
        let source = provider(StubHTTPClient(), kind: .emby)
        XCTAssertTrue(source.libraryQueryCapabilities(in: "library", kind: .series).needsIndex(
            for: .init(sort: .init(field: .lastPlayed, direction: .descending))))
    }
}
