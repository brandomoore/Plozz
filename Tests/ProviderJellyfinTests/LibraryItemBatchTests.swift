import CoreModels
import XCTest
@testable import ProviderJellyfin

final class LibraryItemBatchTests: XCTestCase {
    private func provider(_ kind: ProviderKind, http: StubHTTPClient) -> JellyfinProvider {
        JellyfinProvider(session: .init(
            server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.test")!,
                          provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        ), http: http)
    }

    func testJellyfinAndEmbyBatchNativeCardsWithoutPlaybackProbes() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/viewer/Items", json: """
            {"Items":[
              {"Id":"2","Type":"Series","Name":"Curated series","ProviderIds":{"Tmdb":"22"}},
              {"Id":"1","Type":"Movie","Name":"Curated movie","ProviderIds":{"Tmdb":"11"},
               "ImageTags":{"Primary":"poster"},"RunTimeTicks":1000000000,
               "UserData":{"Played":true,"PlaybackPositionTicks":370000000}}
            ]}
            """)
            let items = try await provider(kind, http: http).libraryItems(ids: ["1", "2", "1"])
            XCTAssertEqual(items.map(\.title), ["Curated series", "Curated movie"])
            let movie = try XCTUnwrap(items.first { $0.id == "1" })
            XCTAssertEqual(movie.providerIDs["Tmdb"], "11")
            XCTAssertFalse(movie.isPlayed)
            XCTAssertTrue(movie.hasBeenPlayed)
            XCTAssertEqual(movie.resumePosition, 37)
            XCTAssertNotNil(movie.posterURL)
            XCTAssertEqual(http.sentPaths, ["/Users/viewer/Items"])
            let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(http.sentQueryItems.first).map {
                ($0.name, $0.value ?? "")
            })
            XCTAssertEqual(query["Ids"], "1,2")
            XCTAssertEqual(query["Limit"], "2")
            XCTAssertEqual(query["EnableUserData"], "true")
            XCTAssertEqual(query["EnableImages"], "true")
            XCTAssertFalse(query["Fields", default: ""].contains("MediaSources"))
            XCTAssertEqual(query["EnableTotalRecordCount"], "false")
        }
    }

    func testPartialBatchRemainsPartialAndNeverInventsAnItem() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/viewer/Items", json: #"{"Items":[{"Id":"2","Type":"Movie","Name":"Native"}]}"#)
            let items = try await provider(kind, http: http).libraryItems(ids: ["1", "2"])
            XCTAssertEqual(items.map(\.id), ["2"])
        }
    }

    func testUnexpectedAndDuplicateResponsesFailExplicitly() async {
        for kind in [ProviderKind.jellyfin, .emby] {
            for body in [
                #"{"Items":[{"Id":"other","Type":"Movie"}]}"#,
                #"{"Items":[{"Id":"1","Type":"Movie"},{"Id":"1","Type":"Movie"}]}"#
            ] {
                let http = StubHTTPClient()
                http.stub(pathSuffix: "/Users/viewer/Items", json: body)
                do {
                    _ = try await provider(kind, http: http).libraryItems(ids: ["1"])
                    XCTFail("Unrequested or ambiguous metadata must be rejected.")
                } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
            }
        }
    }

    func testInvalidAndOversizedRequestsNeverReachEitherServer() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let http = StubHTTPClient()
            let provider = provider(kind, http: http)
            let empty = try await provider.libraryItems(ids: [])
            XCTAssertTrue(empty.isEmpty)
            for ids in [[""], ["1,2"], [" 1"], (0..<51).map(String.init)] {
                do {
                    _ = try await provider.libraryItems(ids: ids)
                    XCTFail("Invalid request must fail before transport.")
                } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
            }
            XCTAssertTrue(http.sentPaths.isEmpty)
        }
    }
}
