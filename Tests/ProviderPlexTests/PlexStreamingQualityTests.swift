import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderPlex

final class PlexStreamingQualityTests: XCTestCase {
    private func fixture(bitrate: Int? = 30_000, width: Int = 3840, height: Int = 2160) -> PlexProvider {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/library/metadata/movie", json: """
        {"MediaContainer":{"Metadata":[{"ratingKey":"movie","title":"Movie","type":"movie","Media":[
          {"id":7,"container":"mp4","videoCodec":"h264","audioCodec":"aac",
           "bitrate":\(bitrate.map(String.init) ?? "null"),"width":\(width),"height":\(height),
           "Part":[{"id":8,"key":"/library/parts/8/file.mp4","Stream":[
             {"id":2,"streamType":2,"codec":"aac","languageCode":"eng","default":true}]}]}]}]}}
        """)
        return PlexProvider(session: .init(
            server: .init(id: "plex", name: "Plex", baseURL: URL(string: "https://plex.example.test")!, provider: .plex),
            userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
        ), http: http)
    }

    private func locator(_ request: PlaybackRequest) throws -> AuthenticatedHTTPPlaybackLocator {
        guard case let .authenticatedHTTP(locator) = request.playbackSource else {
            XCTFail("Expected credential-free HTTP playback")
            throw AppError.invalidResponse
        }
        return locator
    }

    func testCellularRequestConstrainsBitrateResolutionAndPreventsOriginalFallback() async throws {
        let request = try await fixture().playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .hd720, codec: .preferHEVC)
        )
        let source = try locator(request)
        let query = Dictionary(source.resource.queryItems.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(source.mediaSourceID, "7")
        XCTAssertEqual(query["maxVideoBitrate"], "1872")
        XCTAssertEqual(query["audioBitrate"], "128")
        XCTAssertEqual(query["videoResolution"], "1280x720")
        XCTAssertEqual(query["directStream"], "0")
        XCTAssertEqual(query["directPlay"], "0")
        XCTAssertEqual(query["autoAdjustQuality"], "0")
        XCTAssertTrue(request.isTranscoding)
        XCTAssertNil(request.localRemuxSource)
        XCTAssertNil(request.originalFileSource)
        XCTAssertNotNil(request.streamingSessionID)
        XCTAssertEqual(request.streamingOptions?.quality, .hd720)
    }

    func testAlreadySmallOriginalDoesNotNeedAConversion() async throws {
        let request = try await fixture(bitrate: 1_500, width: 1280, height: 720).playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false, streaming: .init(quality: .hd720)
        )
        XCTAssertFalse(request.isTranscoding)
        XCTAssertEqual(try locator(request).deliveryMode, .directFile)
    }

    func testUnknownBitrateCannotBypassTheLimitAndForceConversionAlsoWorksAtMaximum() async throws {
        for options in [StreamingPlaybackOptions(quality: .hd720), .init(quality: .original, forceTranscoding: true)] {
            let request = try await fixture(bitrate: nil, width: 1280, height: 720).playbackInfo(
                for: "movie", mediaSourceID: "7", forceTranscode: false, streaming: options
            )
            XCTAssertTrue(request.isTranscoding)
        }
    }

    func testMissingSelectedVersionFailsInsteadOfPlayingAnotherFile() async {
        do {
            _ = try await fixture().playbackInfo(
                for: "movie", mediaSourceID: "missing", forceTranscode: false, streaming: .init(quality: .hd720)
            )
            XCTFail("Must not replace the explicitly chosen version")
        } catch is StreamingQualityError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testH264FallbackKeepsTheSameBudgetAndUsesUniqueSessions() async throws {
        let provider = fixture()
        let first = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .sd480, codec: .preferHEVC)
        )
        let second = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "7", forceTranscode: false,
            streaming: .init(quality: .sd480, codec: .preferH264)
        )
        XCTAssertNotEqual(first.streamingSessionID, second.streamingSessionID)
        let query = try locator(second).resource.queryItems
        XCTAssertEqual(query.first { $0.name == "maxVideoBitrate" }?.value, "872")
        XCTAssertTrue(query.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value?.contains("videoCodec=h264&") == true)
    }
}
