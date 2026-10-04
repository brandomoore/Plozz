import CoreModels
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinLibraryQueryTests: XCTestCase {
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
