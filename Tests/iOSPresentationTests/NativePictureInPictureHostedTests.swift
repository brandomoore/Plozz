#if os(iOS)
import AVFoundation
import AVKit
import CoreModels
import FeaturePlayback
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class NativePictureInPictureHostedTests: XCTestCase {
    func testLocalAudioInventoryLoadsWithoutProviderTracksAndClearsOnStop() async throws {
        let engine = NativeVideoEngine(startsMuted: true)
        defer { engine.stop() }
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        var changes = 0
        engine.onTracksChanged = { changes += 1 }
        await engine.load(request: .init(
            item: .init(id: "local-audio", title: "Synthetic video", kind: .movie),
            streamURL: folder.appendingPathComponent("live-continuity.mp4")
        ), startPosition: 0)
        try await waitUntil { engine.audioTracks.count == 1 }
        let track = try XCTUnwrap(engine.audioTracks.first)
        engine.selectAudioTrack(track)
        try await waitUntil { engine.currentAudioTrackID == track.id }
        XCTAssertGreaterThan(changes, 0)
        engine.stop()
        XCTAssertTrue(engine.audioTracks.isEmpty)
        XCTAssertNil(engine.currentAudioTrackID)
    }

    func testLocalVideoWithSidecarsKeepsItsNativeAsset() async throws {
        let engine = NativeVideoEngine(startsMuted: true)
        defer { engine.stop() }
        var request = try fixture()
        let source = try XCTUnwrap(request.streamURL)
        request.subtitleTracks.append(.init(
            id: 100_000, kind: .subtitle, displayTitle: "Saved captions", language: "fr", codec: "srt",
            deliverySource: .localFile(source.deletingLastPathComponent().appendingPathComponent("saved.srt")),
            isExternal: true
        ))
        await engine.load(request: request, startPosition: 0)
        let asset = try XCTUnwrap(engine.nowPlayingPlayer?.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(asset.url, source, "A local MP4 cannot be served as an injected HLS segment")
        try await waitUntil { engine.status == .ready }
    }

    func testNativePresentationSurvivesPlayerReplacementAndClearsOnStop() async throws {
        let engine = NativeVideoEngine(startsMuted: true)
        defer { engine.stop() }
        let presentation: any PictureInPicturePresentingEngine = engine
        let surface = engine.makeVideoOutputView()
        XCTAssertNil(presentation.pictureInPicturePlayerLayer())
        var changes = 0
        engine.onPresentationLayerChanged = { changes += 1 }
        let request = try fixture()
        await engine.load(request: request, startPosition: 0)
        let firstLayer = try XCTUnwrap(presentation.pictureInPicturePlayerLayer())
        let firstPlayer = try XCTUnwrap(firstLayer.player)
        XCTAssertTrue(firstLayer === surface.layer)
        XCTAssertTrue(firstPlayer === engine.nowPlayingPlayer)
        XCTAssertGreaterThan(changes, 0)

        engine.setPictureInPictureActive(true)
        engine.setNativeSubtitlesActive(true)
        engine.selectSubtitleTrack(request.subtitleTracks.first)
        try await waitUntil { self.rendersNativeSubtitles(engine) }
        XCTAssertTrue(engine.continuesPlaybackInBackground)
        XCTAssertEqual(firstPlayer.audiovisualBackgroundPlaybackPolicy, .continuesIfPossible)

        let beforeReload = changes
        await engine.load(request: request, startPosition: 0)
        XCTAssertTrue(engine.pictureInPicturePlayerLayer() === firstLayer)
        XCTAssertFalse(firstLayer.player === firstPlayer)
        XCTAssertGreaterThan(changes, beforeReload, "The controller must observe a new player on the same layer")
        XCTAssertTrue(engine.continuesPlaybackInBackground)
        XCTAssertEqual(engine.nowPlayingPlayer?.audiovisualBackgroundPlaybackPolicy, .continuesIfPossible)
        try await waitUntil { self.rendersNativeSubtitles(engine) }

        engine.setPictureInPictureActive(false)
        engine.setNativeSubtitlesActive(false)
        try await waitUntil { !self.rendersNativeSubtitles(engine) }
        XCTAssertEqual(engine.nowPlayingPlayer?.currentItem?.textStyleRules?.isEmpty, true)
        XCTAssertFalse(engine.continuesPlaybackInBackground)
        XCTAssertEqual(engine.nowPlayingPlayer?.audiovisualBackgroundPlaybackPolicy, .automatic)
        engine.setBackgroundAudioEnabled(true)
        engine.setPictureInPictureActive(true)
        engine.setPictureInPictureActive(false)
        XCTAssertEqual(engine.nowPlayingPlayer?.audiovisualBackgroundPlaybackPolicy, .continuesIfPossible)
        engine.setPictureInPictureActive(true)
        engine.setBackgroundAudioEnabled(false)
        XCTAssertEqual(engine.nowPlayingPlayer?.audiovisualBackgroundPlaybackPolicy, .continuesIfPossible)

        let beforeStop = changes
        engine.stop()
        XCTAssertNil(firstLayer.player)
        XCTAssertNil(engine.pictureInPicturePlayerLayer())
        XCTAssertFalse(engine.continuesPlaybackInBackground)
        XCTAssertNil(engine.externalPlaybackRouteName)
        XCTAssertGreaterThan(changes, beforeStop)
        await engine.load(request: request, startPosition: 0)
        XCTAssertNil(engine.pictureInPicturePlayerLayer(), "A stopped surface must not be resurrected")
        XCTAssertFalse(engine.continuesPlaybackInBackground)
        XCTAssertEqual(engine.nowPlayingPlayer?.audiovisualBackgroundPlaybackPolicy, .automatic)
    }

    func testNativeLayerAppearingAfterAttachMakesTheRealPiPControllerAvailable() async throws {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            throw XCTSkip("System Picture in Picture is unsupported on this destination.")
        }
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let engine = NativeVideoEngine(startsMuted: true)
        let pip = PlozziOSPictureInPictureController()
        defer {
            pip.detach()
            engine.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        pip.attach(engine: engine)
        XCTAssertFalse(pip.isAvailable)
        await engine.load(request: try fixture(), startPosition: 0)
        let surface = engine.makeVideoOutputView()
        surface.frame = host.view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(surface)
        try await waitUntil { engine.hasPresentedVideoFrame && pip.isAvailable }
        XCTAssertTrue(pip.isAvailable)
        pip.toggle()
        try await waitUntil { pip.isActive }
        XCTAssertTrue(engine.continuesPlaybackInBackground)
        pip.toggle()
        try await waitUntil { !pip.continuesPlayback }
        pip.detach()
        XCTAssertFalse(pip.isAvailable)
        XCTAssertFalse(engine.continuesPlaybackInBackground)
        XCTAssertNil(engine.onPresentationLayerChanged)
    }

    private func fixture() throws -> PlaybackRequest {
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        return PlaybackRequest(
            item: MediaItem(id: "native-pip", title: "Synthetic video", kind: .movie, runtime: 12),
            streamURL: folder.appendingPathComponent("embedded.mp4"),
            subtitleTracks: [.init(id: 2, kind: .subtitle, displayTitle: "English", language: "en", codec: "mov_text")]
        )
    }

    private func rendersNativeSubtitles(_ engine: NativeVideoEngine) -> Bool {
        let outputs = engine.nowPlayingPlayer?.currentItem?.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput } ?? []
        return !outputs.isEmpty && outputs.allSatisfy { !$0.suppressesPlayerRendering }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Native presentation did not reach the expected state")
    }
}
#endif
