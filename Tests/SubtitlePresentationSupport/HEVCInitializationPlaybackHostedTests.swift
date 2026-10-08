import AVFoundation
import CoreModels
import FeaturePlayback
import Foundation
import XCTest

@MainActor
final class HEVCInitializationPlaybackHostedTests: XCTestCase {
    func testManagedHEVCRepairsEmptyDependencyTableAndDecodesAfterSeek() async throws {
        let initialization = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "hevc-empty-sdtp-init", withExtension: "mp4", subdirectory: "Fixtures"
        ))
        let segment = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "hevc-empty-sdtp-0", withExtension: "m4s", subdirectory: "Fixtures"
        ))
        let server = try IPTVTestHTTPServer { request in
            if request.contains("/master.m3u8") {
                return .init(data: Data("""
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-STREAM-INF:BANDWIDTH=500000
                media.m3u8

                """.utf8), headers: ["Content-Type": "application/vnd.apple.mpegurl"])
            }
            if request.contains("/media.m3u8") {
                return .init(data: Data("""
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:6
                #EXT-X-PLAYLIST-TYPE:VOD
                #EXT-X-MAP:URI="init.mp4"
                #EXTINF:6,
                segment.m4s
                #EXT-X-ENDLIST

                """.utf8), headers: ["Content-Type": "application/vnd.apple.mpegurl"])
            }
            if request.contains("/init.mp4") {
                return .init(file: initialization, headers: ["Content-Type": "video/mp4"])
            }
            if request.contains("/segment.m4s") {
                return .init(file: segment, headers: ["Content-Type": "video/mp4"])
            }
            return .init(status: 404)
        }
        addTeardownBlock { await server.stop() }
        let base = try await server.start()

        // The exact same synthetic stream must reproduce Apple's header rejection.
        let original = AVPlayerItem(url: base.appendingPathComponent("media.m3u8"))
        let originalPlayer = AVPlayer(playerItem: original)
        defer {
            originalPlayer.pause()
            originalPlayer.replaceCurrentItem(with: nil)
        }
        originalPlayer.isMuted = true
        originalPlayer.play()
        let failureDeadline = ContinuousClock.now + .seconds(15)
        while original.status != .failed, ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        originalPlayer.pause()
        originalPlayer.replaceCurrentItem(with: nil)
        XCTAssertEqual(original.status, .failed)
        XCTAssertEqual((original.error as NSError?)?.domain, AVFoundationErrorDomain)
        XCTAssertEqual((original.error as NSError?)?.code, -11829)

        let engine = NativeVideoEngine()
        defer { engine.stop() }
        var request = PlaybackRequest(
            item: .init(id: "synthetic-hevc", title: "Synthetic HEVC", kind: .movie, runtime: 6),
            streamURL: base.appendingPathComponent("master.m3u8"),
            playSessionID: "fixture", isTranscoding: true, sourceProvider: .emby
        )
        request.streamingOptions = .init(quality: .low)
        request.negotiatedStreamingVideoCodec = .hevc
        await engine.load(request: request, startPosition: 0)
        let player = try XCTUnwrap(engine.underlyingPlayer)
        player.isMuted = true
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertEqual((item.asset as? AVURLAsset)?.url.scheme, "plozz-stream")
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        defer { item.remove(output) }
        try await requireFrame(output, player: player, after: 0.2)
        await engine.seek(to: 3)
        try await requireFrame(output, player: player, after: 3.2)
        engine.stop()
        XCTAssertNil(engine.underlyingPlayer)
    }

    private func requireFrame(
        _ output: AVPlayerItemVideoOutput, player: AVPlayer, after position: TimeInterval
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline, player.currentItem?.status != .failed {
            if player.currentTime().seconds > position,
               output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Expected a decoded video frame after \(position)s; readiness alone is not playback.")
    }
}
