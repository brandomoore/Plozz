import AVFoundation
import CoreModels
import EnginePlozzigen
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI
@testable import FeaturePlayback

@MainActor
final class VideoZoomPresentationTests: XCTestCase {
    func testNativeVideoZoomDoesNotReloadOrResizeTheSubtitleText() async throws {
        try await verify(engine: NativeVideoEngine())
    }

    func testPlozzigenVideoZoomDoesNotReloadOrResizeTheSubtitleText() async throws {
        let engine = try PlozzigenVideoEngine()
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        try await verify(engine: engine)
    }

    func testAnamorphicMediaUsesItsDisplayedAspectOnBothEngines() async throws {
        try await verify(engine: NativeVideoEngine(), fixture: "anamorphic.mp4", expectedAspect: 16 / 9)
        let engine = try PlozzigenVideoEngine()
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        try await verify(engine: engine, fixture: "anamorphic.mp4", expectedAspect: 16 / 9)
    }

    private func verify(
        engine: any VideoEngine, fixture: String = "embedded.mp4", expectedAspect: Double? = nil
    ) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controls = PlayerControlsModel()
        let subtitles = LiveSubtitleModel()
        subtitles.style.followsSystemStyle = false
        subtitles.style.fontFamily = .system
        subtitles.style.verticalPosition = 0.06
        subtitles.loadPrimary(SubtitleCueParser.parse(
            "WEBVTT\n\n00:00:00.000 --> 00:01:00.000\nUnchanged caption size.\n", id: 1
        ))
        let originalStyle = subtitles.style
        let controller = PlayerInputViewController(engine: engine, model: controls, actions: PlayerActions())
        controller.loadViewIfNeeded()
        controller.attachVideoSurface()
        controller.attachSubtitleOverlay(subtitles)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            engine.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        await engine.load(request: PlaybackRequest(
            item: MediaItem(id: "zoom-fixture", title: "Synthetic video", kind: .movie, runtime: 12),
            streamURL: folder.appendingPathComponent(fixture)
        ), startPosition: 0)
        try await waitUntil(timeout: 30) { engine.hasPresentedVideoFrame && engine.videoAspectRatio != nil }
        if let expectedAspect {
            XCTAssertEqual(try XCTUnwrap(engine.videoAspectRatio), expectedAspect, accuracy: 0.0001)
        }
        engine.pause()
        let player = engine.nowPlayingPlayer
        player?.isMuted = true
        let item = player?.currentItem
        let surface = engine.makeVideoOutputView()
        let layers = surface.layer.sublayers ?? []
        if player == nil {
            XCTAssertTrue(layers.contains { $0 is AVSampleBufferDisplayLayer },
                          "The software path must have its real display layer.")
        }
        let viewport = try XCTUnwrap(surface.superview as? VideoPresentationView)
        try await waitUntil {
            window.layoutIfNeeded()
            return !self.captionFrames(in: controller.view, relativeTo: window).isEmpty
        }
        let caption = try XCTUnwrap(captionFrames(in: controller.view, relativeTo: window).first)
        let position = engine.currentTime

        for zoom in [PlayerVideoZoom(mode: .fill),
                     PlayerVideoZoom(mode: .custom, customPercent: 150), PlayerVideoZoom()] {
            controls.videoZoom.settings = zoom
            let expected = zoom.surfaceFrame(in: viewport.bounds, aspectRatio: engine.videoAspectRatio)
            try await waitUntil {
                window.layoutIfNeeded()
                return surface.frame == expected && subtitles.videoRect == viewport.videoRect
            }
            let currentCaption = try XCTUnwrap(captionFrames(in: controller.view, relativeTo: window).first)
            XCTAssertEqual(currentCaption.width, caption.width, accuracy: 1)
            XCTAssertEqual(currentCaption.height, caption.height, accuracy: 1)
            XCTAssertEqual(currentCaption.minY, caption.minY, accuracy: 1)
            XCTAssertEqual(viewport.frame, controller.view.bounds)
            XCTAssertTrue(engine.makeVideoOutputView() === surface)
            XCTAssertTrue(engine.nowPlayingPlayer === player)
            XCTAssertTrue(player?.currentItem === item)
            XCTAssertTrue(layers.elementsEqual(surface.layer.sublayers ?? [], by: { $0 === $1 }))
            XCTAssertTrue(engine.isPaused)
            XCTAssertEqual(engine.currentTime, position, accuracy: 0.1)
            XCTAssertEqual(subtitles.style, originalStyle)
        }
    }

    private func captionFrames(in view: UIView, relativeTo window: UIWindow) -> [CGRect] {
        if let line = view as? SubtitleLineView { return [line.convert(line.bounds, to: window)] }
        return view.subviews.flatMap { captionFrames(in: $0, relativeTo: window) }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Video or subtitle presentation did not settle.")
    }
}
