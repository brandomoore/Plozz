import Foundation
import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

final class PlexEditionIdentityTests: XCTestCase {
    private func provider(_ http: StubHTTPClient) -> PlexProvider {
        PlexProvider(session: UserSession(
            server: MediaServer(
                id: "fixture-server", name: "Fixture",
                baseURL: URL(string: "https://plex.example")!, provider: .plex
            ),
            userID: "viewer", userName: "Viewer", deviceID: "fixture",
            accessToken: "fixture-token"
        ), http: http)
    }

    private func payload(_ id: String, edition: String?, mediaIDs: [Int]) -> String {
        let editionField = edition.map { #""editionTitle":"\#($0)","# } ?? ""
        let media = mediaIDs.enumerated().map { offset, mediaID in
            """
            {"id":\(mediaID),"container":"mp4","videoCodec":"h264",
             "audioCodec":"aac","height":\(offset == 0 ? 720 : 1080),"width":1920,
             "Part":[{"id":\(mediaID),"key":"/library/parts/\(mediaID)/file.mp4",
                      "file":"/movies/Fixture-\(mediaID).mp4"}]}
            """
        }.joined(separator: ",")
        return """
        {"MediaContainer":{"Metadata":[{
          "ratingKey":"\(id)","type":"movie","title":"Fixture",
          \(editionField)
          "Guid":[{"id":"tmdb://99"}],"Media":[\(media)]
        }]}}
        """
    }

    func testSingleFileEditionSurvivesProviderMappingSynthesisAndCache() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/metadata/10",
                  json: payload("10", edition: "Director's Cut", mediaIDs: [101]))
        let item = try await provider(http).item(id: "10").taggingSource("plex")
        XCTAssertEqual(item.edition, "Director's Cut")
        XCTAssertTrue(item.versions.isEmpty, "One file must not manufacture a picker")
        let restored = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        let version = MediaVersion.synthesized(from: restored)
        XCTAssertEqual(version.editionLabel, "Director's Cut")
        XCTAssertEqual(version.menuTitle, "Director's Cut")
        XCTAssertEqual(version.fileName, "Fixture-101.mp4")
    }

    func testDistinctEditionItemsWithMultipleEncodingsResolveExactChosenFile() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/metadata/10",
                  json: payload("10", edition: "Theatrical", mediaIDs: [101, 102]))
        http.stub(pathSuffix: "/library/metadata/20",
                  json: payload("20", edition: "Extended", mediaIDs: [201, 202]))
        let provider = provider(http)
        let first = try await provider.item(id: "10").taggingSource("plex")
        let second = try await provider.item(id: "20").taggingSource("plex")
        let merged = try XCTUnwrap(MediaItemMerger.merge([first, second]).first)
        XCTAssertEqual(merged.sources.flatMap(\.versions).count, 4)
        let extended = try XCTUnwrap(merged.sources.first { $0.itemID == "20" })
        let choice = try XCTUnwrap(extended.selectableVersions.first { $0.playbackMediaSourceID == "202" })
        XCTAssertEqual(choice.editionLabel, "Extended")
        let playItem = MediaItem.retargetedForPlayback(
            item: merged, sources: merged.sources,
            activeAccountID: "plex", versionID: choice.id, explicit: true
        )
        let request = try await provider.playbackInfo(
            for: playItem.id, mediaSourceID: playItem.selectedVersionID, forceTranscode: false
        )
        XCTAssertEqual(playItem.id, "20")
        XCTAssertEqual(playItem.selectedVersionID, "202")
        XCTAssertEqual(request.item.id, "20")
        XCTAssertEqual(request.sourceFileName, "Fixture-202.mp4")
        XCTAssertEqual(http.sentPaths.last, "/library/metadata/20")
    }

    func testMissingEditionDoesNotBecomeAProviderEdition() async throws {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/metadata/10",
                  json: payload("10", edition: nil, mediaIDs: [101]))
        let item = try await provider(http).item(id: "10")
        XCTAssertNil(item.edition)
        XCTAssertNil(MediaVersion.synthesized(from: item).editionLabel)
    }
}
