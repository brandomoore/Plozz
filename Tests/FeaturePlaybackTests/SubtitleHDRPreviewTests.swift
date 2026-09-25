#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import CoreMedia
import XCTest
@testable import FeaturePlayback

@MainActor
final class SubtitleHDRPreviewTests: XCTestCase {
    func testBundledSceneIsSilentHDR10VideoAtSixtyFramesPerSecond() async throws {
        let url = try XCTUnwrap(SubtitleHDRPreview.assetURL)
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertTrue(audio.isEmpty, "A settings preview must not introduce an audio session or sound.")
        let track = try XCTUnwrap(video.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(dimensions.width, 1920)
        XCTAssertEqual(dimensions.height, 1080)
        let range = NativeStreamDetailsReader.videoStream(format)
        XCTAssertEqual(range.videoRangeType, "HDR10")
        let frameRate = try await track.load(.nominalFrameRate)
        XCTAssertEqual(frameRate, 60, accuracy: 0.01)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 8, accuracy: 0.02)
    }

    func testMissingAssetIsAnExplicitFailureAndDoesNotClaimHDRReadiness() {
        let preview = SubtitleHDRPreview(assetURL: { nil })
        XCTAssertEqual(preview.state, .idle)
        preview.start(animate: false)
        XCTAssertEqual(preview.state, .failed(.missingAsset))
        XCTAssertNil(preview.makeSurface().playerLayer.player)
        preview.stop()
        XCTAssertEqual(preview.state, .idle)
    }

    func testSceneAndPresentationLifecycleRetainOnlyOneHDRPlayer() {
        let options = SubtitlePreviewOptions()
        options.showsHDRBrightness = true
        XCTAssertEqual(options.hdrPreview.state, .idle, "A hidden settings page must not start video.")
        options.setVisible(true, fullscreen: false, sceneActive: true)
        let surface = options.hdrPreview.makeSurface()
        let player = surface.playerLayer.player
        XCTAssertNotNil(player)
        options.beginFullscreenPresentation()
        options.setVisible(false, fullscreen: false, sceneActive: true)
        options.setVisible(true, fullscreen: true, sceneActive: true)
        XCTAssertTrue(options.hdrPreview.makeSurface() === surface)
        XCTAssertTrue(surface.playerLayer.player === player)
        options.setVisible(false, fullscreen: true, sceneActive: true)
        options.finishFullscreenPresentation()
        options.setVisible(true, fullscreen: false, sceneActive: true)
        XCTAssertTrue(surface.playerLayer.player === player, "Changing preview size must not restart the decoder.")
        options.setSceneActive(false)
        XCTAssertEqual(options.hdrPreview.state, .idle)
        XCTAssertNil(surface.playerLayer.player)
        options.setVisible(false, fullscreen: false, sceneActive: false)
    }

    func testStopReleasesThePlayerAndCannotBeResurrectedByLateCallbacks() async throws {
        let preview = SubtitleHDRPreview()
        let surface = preview.makeSurface()
        for _ in 0..<3 {
            preview.start(animate: false)
            XCTAssertNotNil(surface.playerLayer.player)
            XCTAssertEqual(preview.state, .loading)
            preview.stop()
            for _ in 0..<5 { await Task.yield() }
            XCTAssertNil(surface.playerLayer.player)
            XCTAssertEqual(preview.state, .idle)
        }
    }
}
#endif
