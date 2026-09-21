import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinStreamingQualityTests: XCTestCase {
    private func fixture(kind: ProviderKind, rendition: Bool, bitrate: Int = 30_000_000) -> (JellyfinProvider, StubHTTPClient) {
        let http = StubHTTPClient()
        http.stub(pathSuffix: "/Users/user/Items/movie", json: #"{"Id":"movie","Name":"Movie","Type":"Movie"}"#)
        http.stub(pathSuffix: "/Videos/ActiveEncodings", json: "{}")
        let url = rendition ? #""TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=hevc&VideoBitrate=30000000&AudioBitrate=384000&MaxHeight=2160","# : ""
        http.stub(pathSuffix: "/Items/movie/PlaybackInfo", json: """
        {"PlaySessionId":"session","MediaSources":[{
          "Id":"version","Container":"mp4","SupportsDirectPlay":true,
          \(url)
          "Bitrate":\(bitrate),"MediaStreams":[
            {"Index":0,"Type":"Video","Codec":"h264","Width":1280,"Height":720},
            {"Index":2,"Type":"Audio","Codec":"aac","Language":"eng","IsDefault":true}
          ]}]}
        """)
        let provider = JellyfinProvider(session: .init(
            server: .init(id: "server", name: "Server", baseURL: URL(string: "https://media.example.test")!, provider: kind),
            userID: "user", userName: "User", deviceID: "device", accessToken: "fixture"
        ), http: http)
        return (provider, http)
    }

    func testJellyfinAndEmbyApplySameTotalBudgetAndResolutionWithoutRemuxEscape() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let (provider, http) = fixture(kind: kind, rendition: true)
            let request = try await provider.playbackInfo(
                for: "movie", mediaSourceID: "version", forceTranscode: false,
                streaming: .init(quality: .hd720, codec: .preferHEVC)
            )
            let body = try XCTUnwrap(http.sentBodies.first { $0.key.hasSuffix("/PlaybackInfo") }?.value)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["MaxStreamingBitrate"] as? Int, 2_000_000)
            guard case let .authenticatedHTTP(locator) = request.playbackSource else {
                return XCTFail("Expected managed HTTP")
            }
            let query = Dictionary(locator.resource.queryItems.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
            XCTAssertEqual(query["VideoBitrate"], "1872000")
            XCTAssertEqual(query["AudioBitrate"], "128000")
            XCTAssertEqual(query["MaxWidth"], "1280")
            XCTAssertEqual(query["MaxHeight"], "720")
            XCTAssertEqual(query["AllowVideoStreamCopy"], "false")
            XCTAssertEqual(query["AudioStreamIndex"], "2")
            XCTAssertNil(request.localRemuxSource)
            XCTAssertNil(request.originalFileSource)
            XCTAssertTrue(request.isTranscoding)
            XCTAssertEqual(locator.mediaSourceID, "version")
        }
    }

    func testSmallSourcesRetainDirectPlaybackButRefusedTranscodesFailClosed() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let (small, _) = fixture(kind: kind, rendition: false, bitrate: 1_500_000)
            let direct = try await small.playbackInfo(
                for: "movie", mediaSourceID: "version", forceTranscode: false, streaming: .init(quality: .hd720)
            )
            XCTAssertFalse(direct.isTranscoding)
            let (large, http) = fixture(kind: kind, rendition: false)
            do {
                _ = try await large.playbackInfo(
                    for: "movie", mediaSourceID: "version", forceTranscode: false, streaming: .init(quality: .hd720)
                )
                XCTFail("No unconstrained direct fallback is allowed")
            } catch is StreamingQualityError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(http.sentPaths.contains { $0.hasSuffix("/Videos/ActiveEncodings") })
            XCTAssertEqual(http.sentPaths.filter { $0.hasSuffix("/PlaybackInfo") }.count, 2)
        }
    }

    func testPerRequestProfileCannotChangeOtherPlaybackOrLiveTVDefaults() {
        let original = JellyfinCapabilityProfile.appleTV()
        let limited = original.applying(.init(quality: .hd720, codec: .preferH264))
        XCTAssertEqual(limited.maxStreamingBitrate, 2_000_000)
        XCTAssertEqual(limited.maxStaticBitrate, 2_000_000)
        XCTAssertEqual(limited.transcodingProfiles.first?.videoCodec, "h264")
        XCTAssertEqual(original.maxStreamingBitrate, JellyfinCapabilityProfile.defaultMaxBitrate)
        XCTAssertEqual(original, JellyfinCapabilityProfile.appleTV())
    }

    func testOptionalTranscodeURLDoesNotOverrideAProvenDirectPlayFit() async throws {
        let (provider, _) = fixture(kind: .jellyfin, rendition: true, bitrate: 1_000_000)
        let request = try await provider.playbackInfo(
            for: "movie", mediaSourceID: "version", forceTranscode: false,
            streaming: .init(quality: .hd720)
        )
        XCTAssertFalse(request.isTranscoding)
        guard case let .authenticatedHTTP(locator) = request.playbackSource else {
            return XCTFail("Expected original managed source")
        }
        XCTAssertEqual(locator.deliveryMode, .directFile)
    }

    func testCodecAndBitmapSelectionsAreAppliedToTheBoundedRendition() throws {
        let source = try JSONDecoder().decode(MediaSourceInfo.self, from: Data(
            #"{"Id":"version","TranscodingUrl":"/Videos/movie/master.m3u8?VideoCodec=hevc&VideoBitrate=30000000"}"#.utf8
        ))
        var options = StreamingPlaybackOptions(quality: .sd480, codec: .preferH264)
        options.audioTrack = .init(id: 4, kind: .audio, displayTitle: "Japanese", language: "jpn")
        options.subtitleTrack = .init(id: 6, kind: .subtitle, displayTitle: "English", language: "eng", codec: "pgssub")
        let url = try XCTUnwrap(URLComponents(string: source.boundedTranscodingURL(options)))
        let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(query["VideoCodec"], "h264")
        XCTAssertEqual(query["VideoBitrate"], "872000")
        XCTAssertEqual(query["SubtitleStreamIndex"], "6")
        XCTAssertEqual(query["SubtitleMethod"], "Encode")
        XCTAssertEqual(query["AudioStreamIndex"], "4")
        options.subtitlesOff = true
        let off = try XCTUnwrap(URLComponents(string: source.boundedTranscodingURL(options)))
        XCTAssertEqual(off.queryItems?.first { $0.name == "SubtitleStreamIndex" }?.value, "-1")
    }

    func testSelectedVersionMustNotSilentlyChange() async {
        let (provider, _) = fixture(kind: .jellyfin, rendition: true)
        do {
            _ = try await provider.playbackInfo(
                for: "movie", mediaSourceID: "missing", forceTranscode: false, streaming: .init(quality: .hd720)
            )
            XCTFail("Wrong source should fail")
        } catch is StreamingQualityError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
