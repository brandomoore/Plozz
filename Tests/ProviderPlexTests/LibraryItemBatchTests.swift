import CoreModels
import XCTest
@testable import ProviderPlex

final class LibraryItemBatchTests: XCTestCase {
    private func provider(http: StubHTTPClient) -> PlexProvider {
        PlexProvider(session: .init(
            server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.test")!,
                          provider: .plex),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        ), http: http)
    }

    func testBatchRetainsNativeTitlesArtworkIdentityAndWatchState() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/metadata/1,2", json: """
        {"MediaContainer":{"Metadata":[
          {"ratingKey":"2","type":"show","title":"Curated series","Guid":[{"id":"tmdb://22"}]},
          {"ratingKey":"1","type":"movie","title":"Curated movie","Guid":[{"id":"tmdb://11"}],
           "thumb":"/library/metadata/1/thumb/1","viewCount":1,"viewOffset":37000,"duration":100000}
        ]}}
        """)
        let items = try await provider(http: http).libraryItems(ids: ["2", "1", "1"])
        XCTAssertEqual(items.map(\.title), ["Curated series", "Curated movie"])
        let movie = try XCTUnwrap(items.first { $0.id == "1" })
        XCTAssertEqual(movie.providerIDs.providerID(.tmdb), "11")
        XCTAssertFalse(movie.isPlayed)
        XCTAssertTrue(movie.hasBeenPlayed)
        XCTAssertEqual(movie.resumePosition, 37)
        XCTAssertNotNil(movie.posterURL)
        XCTAssertEqual(http.sentPaths, ["/library/metadata/1,2"])
        XCTAssertTrue(http.sentQueryItems[0].contains(.init(name: "includeGuids", value: "1")))
    }

    func testPartialBatchDoesNotSynthesizeMissingCards() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/metadata/1,2", json: """
        {"MediaContainer":{"Metadata":[{"ratingKey":"2","type":"movie","title":"Native"}]}}
        """)
        let items = try await provider(http: http).libraryItems(ids: ["1", "2"])
        XCTAssertEqual(items.map(\.id), ["2"])
    }

    func testUnexpectedMissingAndDuplicateRatingKeysFail() async {
        for records in [
            #"[{"ratingKey":"3","type":"movie"}]"#,
            #"[{"type":"movie"}]"#,
            #"[{"ratingKey":"1","type":"movie"},{"ratingKey":"1","type":"movie"}]"#
        ] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/library/metadata/1", json: #"{"MediaContainer":{"Metadata":\#(records)}}"#)
            do {
                _ = try await provider(http: http).libraryItems(ids: ["1"])
                XCTFail("Unrequested or ambiguous metadata must be rejected.")
            } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
        }
    }

    func testOnlyBoundedNativeRatingKeysCanEnterBatchPath() async throws {
        let http = StubHTTPClient()
        let provider = provider(http: http)
        let empty = try await provider.libraryItems(ids: [])
        XCTAssertTrue(empty.isEmpty)
        for ids in [[""], ["1,2"], ["1/2"], ["plex:discover:123"], (0..<51).map(String.init)] {
            do {
                _ = try await provider.libraryItems(ids: ids)
                XCTFail("Invalid request must fail before transport.")
            } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
        }
        XCTAssertTrue(http.sentPaths.isEmpty)
    }
}
