import CoreModels
import Foundation
import XCTest
@testable import ProviderPlex

final class PlexLibraryQueryTests: XCTestCase {
    func testRandomFilterInventoryUsesStablePagingWithoutChangingNativeRandomBrowse() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/all",
                  json: #"{"MediaContainer":{"totalSize":0,"Metadata":[]}}"#)
        let source = provider(http)
        let random = SortDescriptor(field: .random, direction: .descending)
        for offset in [0, 120] {
            _ = try await source.libraryQueryInventory(
                in: "1", kind: .movie,
                page: .init(startIndex: offset, sort: random, filters: .init(filter: .atmos)))
            let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/all"))
            XCTAssertEqual(query.first { $0.name == "sort" }?.value, "titleSort:asc")
        }
        _ = try await source.items(in: "1", kind: .movie, page: .init(sort: random))
        let native = try XCTUnwrap(http.queryItems(forPathSuffix: "/all"))
        XCTAssertEqual(native.first { $0.name == "sort" }?.value, "random")
    }

    func testGenreAndYearFacetsRemainNativeAndLibraryScoped() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/genre",
                  json: #"{"MediaContainer":{"Directory":[{"key":"42","title":"Drama"}]}}"#)
        http.stub(pathSuffix: "/library/sections/1/year",
                  json: #"{"MediaContainer":{"Directory":[{"key":"2024","title":"2024"},{"key":"2023","title":"2023"}]}}"#)
        let facets = try await provider(http).libraryQueryFacets(in: "1", kind: .movie)
        XCTAssertEqual(facets.genres, ["Drama"])
        XCTAssertEqual(facets.years, [2024, 2023])
        XCTAssertEqual(Set(http.sentPaths), ["/library/sections/1/genre", "/library/sections/1/year"])
        for suffix in ["/genre", "/year"] {
            XCTAssertTrue(try XCTUnwrap(http.queryItems(forPathSuffix: suffix)).contains(.init(name: "type", value: "1")))
        }
    }

    private func provider(_ http: StubHTTPClient) -> PlexProvider {
        PlexProvider(session: UserSession(
            server: MediaServer(id: "plex", name: "Plex", baseURL: URL(string: "https://plex.test")!, provider: .plex),
            userID: "user", userName: "User", deviceID: "device", accessToken: "test"
        ), http: http)
    }

    func testNativePredicatesUseProviderGenreIDsAndCacheTheirResolution() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/genre",
                  json: #"{"MediaContainer":{"Directory":[{"key":"42","title":"Drama"}]}}"#)
        http.stub(pathSuffix: "/library/sections/1/all",
                  json: #"{"MediaContainer":{"totalSize":0,"Metadata":[]}}"#)
        let source = provider(http)
        let request = PageRequest(filters: .init(filter: .unwatched, genre: "Drama", year: 2024))
        _ = try await source.items(in: "1", kind: .movie, page: request)
        _ = try await source.items(in: "1", kind: .movie, page: request.next())
        let query = try XCTUnwrap(http.queryItems(forPathSuffix: "/all"))
        XCTAssertTrue(query.contains(.init(name: "unwatched", value: "1")))
        XCTAssertTrue(query.contains(.init(name: "genre", value: "42")))
        XCTAssertTrue(query.contains(.init(name: "year", value: "2024")))
        XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/genre") }.count, 1)
    }

    func testInventoryRejectsAnUnverifiedTotal() async {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/all",
                  json: #"{"MediaContainer":{"size":1,"Metadata":[{"ratingKey":"1","title":"Movie","type":"movie"}]}}"#)
        do {
            _ = try await provider(http).libraryQueryInventory(in: "1", kind: .movie, page: .init())
            XCTFail("Missing total must not look like a complete one-item library")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    }

    func testInventoryRecognizesAtmosOnANondefaultAudioTrack() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/sections/1/all", json: """
        {"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"1","title":"Movie","type":"movie",
        "Media":[{"id":1,"Part":[{"Stream":[{"streamType":2,"codec":"aac","selected":true},
        {"streamType":2,"codec":"eac3","displayTitle":"English (Dolby Atmos)"}]}]}]}]}}
        """)
        let page = try await provider(http).libraryQueryInventory(in: "1", kind: .movie,
                                                                 page: .init(filters: .init(filter: .atmos)))
        XCTAssertTrue(try XCTUnwrap(page.items.first).librarySortValues?.hasAtmos == true)
    }
}
