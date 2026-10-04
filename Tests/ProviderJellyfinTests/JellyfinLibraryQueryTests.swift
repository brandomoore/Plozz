import CoreModels
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinLibraryQueryTests: XCTestCase {
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
