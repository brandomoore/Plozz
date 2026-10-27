import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderJellyfin
@testable import TestSupportPerformance

final class ServerRatingsLatencyTests: XCTestCase {
    @MainActor
    func testPerformanceRequiredItemAndPlayback() async throws {
        try PerformanceProbe.requireEnabled()
        try await PerformanceProbe.measure(self, scenario: "server-ratings-critical-path") {
            let http = RatingsLatencyHTTP()
            let provider = JellyfinProvider(session: UserSession(
                server: MediaServer(
                    id: "fixture", name: "Fixture",
                    baseURL: URL(string: "https://fixture.invalid")!, provider: .jellyfin
                ),
                userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
            ), http: http)
            for _ in 0..<4 {
                let item = try await provider.item(id: RatingsLatencyHTTP.itemID)
                let playback = try await provider.playbackItem(id: RatingsLatencyHTTP.itemID)
                XCTAssertEqual(item.id, RatingsLatencyHTTP.itemID)
                XCTAssertEqual(item.title, "Title")
                XCTAssertEqual(item.runtime, 1_680)
                XCTAssertEqual(playback.versions.map(\.id), ["source", "alternate"])
            }
            let counts = await http.counts
            XCTAssertEqual(counts.native, 8)
            XCTAssertEqual(counts.playback, 4)
            return [
                "items": 4, "playbackItems": 4, "nativeRequests": counts.native,
                "playbackRequests": counts.playback, "cacheRequests": counts.cache
            ]
        }
    }
}

private actor RatingsLatencyHTTP: HTTPClient {
    static let itemID = "0123456789abcdef0123456789abcdef"
    private(set) var counts = (native: 0, playback: 0, cache: 0)

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let body: String
        switch endpoint.path {
        case "/Users/viewer/Items/\(Self.itemID)":
            counts.native += 1
            body = """
            {"Id":"\(Self.itemID)","Name":"Title","Type":"Movie","RunTimeTicks":16800000000,
             "CommunityRating":7.2}
            """
        case "/Items/\(Self.itemID)/PlaybackInfo":
            counts.playback += 1
            body = """
            {"MediaSources":[{"Id":"source","Container":"mp4","SupportsDirectPlay":true,
             "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264"}]},
             {"Id":"alternate","Container":"mp4","SupportsDirectPlay":true,
              "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264"}]}]}
            """
        case "/Plugins/MdbListRatings/CachedByItemId":
            counts.cache += 1
            try await Task.sleep(for: .milliseconds(150))
            body = #"{"hasCache":true,"ratings":[{"source":"imdb","score":87}]}"#
        default:
            throw AppError.notFound
        }
        return (
            Data(body.utf8),
            HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
