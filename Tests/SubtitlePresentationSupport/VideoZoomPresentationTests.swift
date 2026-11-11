import AVFoundation
import CoreImage
import CoreModels
@testable import EnginePlozzigen
import SwiftUI
import UIKit
import XCTest
@testable import CoreUI
@testable import FeaturePlayback

@MainActor
final class VideoZoomPresentationTests: XCTestCase {
    #if os(tvOS)
    func testAudioGlowFadesOutsideTheNativeFocusedPictureWithoutResizingIt() async throws {
        struct Surface: UIViewRepresentable {
            let view: UIView
            func makeUIView(context: Context) -> UIView { view }
            func updateUIView(_ uiView: UIView, context: Context) {}
        }
        struct Fixture: View {
            let surface: UIView
            let glow: VideoAudioGlowState
            let active: Bool
            var body: some View {
                Surface(view: surface)
                    .videoCardFocusSurface {
                        VideoAudioGlow(state: glow, isActive: active, cornerRadius: 20)
                    }
                    .environment(\.videoCardFocus, VideoCardFocus(
                        identifier: "audio-glow-test", title: "Video", audible: active, presentsEffect: true,
                        cornerRadius: 20, horizontalInset: 0, request: 1, prefersFocus: true,
                        focused: { _ in }, activate: {}, promote: {}, replace: {}))
                    .frame(width: 640, height: 360)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let surface = UIView()
        surface.backgroundColor = .blue
        let glow = VideoAudioGlowState()
        let host = UIHostingController(rootView: Fixture(surface: surface, glow: glow, active: true))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { surface.window != nil && surface.convert(surface.bounds, to: window).width > 650 }
        try await Task.sleep(for: .milliseconds(700))
        let frame = surface.convert(surface.bounds, to: window)
        func edgeIntensity() throws -> Float {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let ci = try XCTUnwrap(CIImage(image: image))
            let scale = image.scale
            let region = CGRect(x: (frame.midX - 100) * scale,
                                y: (window.bounds.height - frame.maxY - 8) * scale,
                                width: 200 * scale, height: 7 * scale)
            let average = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
            var pixel = [Float](repeating: 0, count: 4)
            CIContext().render(average, toBitmap: &pixel, rowBytes: 16,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (pixel[0] + pixel[1] + pixel[2]) / 3
        }
        let active = try edgeIntensity()
        host.rootView = Fixture(surface: surface, glow: glow, active: false)
        try await Task.sleep(for: .milliseconds(300))
        let fading = try edgeIntensity()
        try await Task.sleep(for: .milliseconds(600))
        let inactive = try edgeIntensity()
        XCTAssertGreaterThan(active - inactive, 0.001, "The glow must extend past the lifted native picture.")
        if !UIAccessibility.isReduceMotionEnabled {
            XCTAssertGreaterThan(active, fading)
            XCTAssertGreaterThan(fading, inactive)
        }
        host.rootView = Fixture(surface: surface, glow: glow, active: true)
        try await Task.sleep(for: .milliseconds(300))
        let appearing = try edgeIntensity()
        try await Task.sleep(for: .milliseconds(600))
        let restored = try edgeIntensity()
        XCTAssertGreaterThan(restored - inactive, 0.001)
        if !UIAccessibility.isReduceMotionEnabled {
            XCTAssertGreaterThan(appearing, inactive)
            XCTAssertGreaterThan(restored, appearing)
        }
        XCTAssertEqual(surface.convert(surface.bounds, to: window), frame)
    }

    func testAudioGlowBorrowsBothDecodersAndStopsWhenInactive() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        let engines: [(any VideoEngine, String)] = [
            (NativeVideoEngine(startsMuted: true), "glow-hd.mp4"),
            (try PlozzigenVideoEngine(), "glow-software.mkv"),
            (LibraryLiveChannelEngine(engine: try PlozzigenVideoEngine()), "glow-software.mkv")
        ]
        for (engine, filename) in engines {
            let video = VideoPresentationView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
            host.view.addSubview(video)
            video.attach(engine)
            let glow = VideoAudioGlowState()
            defer { glow.stop(); video.removeFromSuperview(); engine.stop() }
            await engine.load(request: PlaybackRequest(
                item: MediaItem(id: filename, title: "Synthetic video", kind: .movie),
                streamURL: folder.appendingPathComponent(filename)), startPosition: 0)
            try await waitUntil(timeout: 20) { engine.hasPresentedVideoFrame }
            let item = engine.nowPlayingPlayer?.currentItem
            let outputs = item?.outputs.count
            let neutral = glow.colors
            glow.update(engine: engine, enabled: true)
            try await waitUntil(timeout: 5) { glow.sampleCount > 0 }
            XCTAssertNotEqual(glow.colors, neutral, "The indicator must use decoded picture colors.")
            if filename.hasSuffix("mkv") {
                XCTAssertNil(item)
                XCTAssertNotNil(engine.previewVideoFrame())
                XCTAssertNotNil(engine.previewFrameGeneration)
            } else {
                XCTAssertNotNil(item)
                XCTAssertEqual(item?.outputs.count, try XCTUnwrap(outputs) + 1)
            }
            engine.pause()
            try await Task.sleep(for: .milliseconds(700))
            let pausedCount = glow.sampleCount
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(glow.sampleCount, pausedCount)
            let retainedColors = glow.colors
            glow.update(engine: engine, enabled: false)
            XCTAssertFalse(glow.isSampling)
            XCTAssertEqual(glow.colors, retainedColors, "Keep the last palette available during the fade-out.")
            XCTAssertEqual(item?.outputs.count, outputs)
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(glow.sampleCount, pausedCount)
        }
    }
    #endif

    func testPerformancePictureEnabled() async throws {
        try await measurePicture(players: 1, enabled: true)
    }

    func testPerformancePictureDisabled() async throws {
        try await measurePicture(players: 1, enabled: false)
    }

    func testPerformanceFourPicturesEnabled() async throws {
        try await measurePicture(players: 4, enabled: true)
    }

    func testPerformanceFourPicturesDisabled() async throws {
        try await measurePicture(players: 4, enabled: false)
    }

    private func measurePicture(players count: Int, enabled: Bool) async throws {
        try PerformanceProbe.requireEnabled()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        var engines: [PlozzigenVideoEngine] = []
        var views: [VideoPresentationView] = []
        defer {
            for view in views { view.removeFromSuperview() }
            for engine in engines { engine.stopActivePictureAnalysis(); engine.stop() }
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        let server = try SubtitleFixtureServer(directory: folder.appendingPathComponent("active-picture-hls"))
        let port = try await server.start()
        defer { server.stop() }
        let stream = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/glow-hd.m3u8"))
        for index in 0..<count {
            let engine = try PlozzigenVideoEngine()
            engines.append(engine)
            engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
            let columns = count == 1 ? 1 : 2
            let size = CGSize(width: window.bounds.width / CGFloat(columns), height: window.bounds.height / CGFloat(columns))
            let view = VideoPresentationView(frame: CGRect(
                x: CGFloat(index % columns) * size.width, y: CGFloat(index / columns) * size.height,
                width: size.width, height: size.height
            ))
            views.append(view)
            host.view.addSubview(view)
            view.attach(engine)
            await engine.loadLive(url: stream, httpHeaders: [:])
            try await waitUntil(timeout: 30) { engine.isPlaybackPositionReady }
            engine.pause()
            XCTAssertNotNil(engine.nowPlayingPlayer, "The native output tap must be exercised.")
        }
        for engine in engines { await engine.seek(to: 0) }
        for (engine, view) in zip(engines, views) {
            engine.play()
            view.update(zoom: PlayerVideoZoom(mode: enabled ? .picture : .fit))
        }
        try await Task.sleep(for: .seconds(2))
        let scenario = "active-picture-\(count)-\(enabled ? "enabled" : "disabled")"
        try await PerformanceProbe.measure(self, scenario: scenario) {
            let positions = engines.map(\.currentTime)
            let counts = engines.map(\.pictureSampleCountForTesting)
            try await Task.sleep(for: .milliseconds(2300))
            var completed = 0
            for (index, engine) in engines.enumerated() {
                XCTAssertGreaterThan(engine.currentTime - positions[index], 1.8)
                let samples = engine.pictureSampleCountForTesting - counts[index]
                completed += samples
                let item = try XCTUnwrap(engine.nowPlayingPlayer?.currentItem)
                XCTAssertEqual(item.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, enabled ? 1 : 0)
                if enabled {
                    XCTAssertGreaterThan(samples, 0, "A cached result is not new frame analysis.")
                    XCTAssertLessThanOrEqual(samples, 5)
                } else {
                    XCTAssertEqual(samples, 0)
                }
                XCTAssertLessThanOrEqual(engine.picturePeakWorkersForTesting, 4)
            }
            return ["players": count, "samples": completed, "windowMilliseconds": 2300]
        }
        for view in views { view.update(zoom: PlayerVideoZoom()) }
        try await waitUntil { engines.allSatisfy { $0.pictureWorkersForTesting == 0 } }
        for engine in engines {
            let item = try XCTUnwrap(engine.nowPlayingPlayer?.currentItem)
            XCTAssertFalse(item.outputs.contains { $0 is AVPlayerItemVideoOutput },
                           "Disabled analysis must release its video output, not the independent subtitle output.")
        }
    }

    private func presentationView(for surface: UIView) -> VideoPresentationView? {
        var ancestor = surface.superview
        while let view = ancestor {
            if let presentation = view as? VideoPresentationView { return presentation }
            ancestor = view.superview
        }
        return nil
    }
    func testLiveSubtitleViewportIsAttachedInFullscreenInlineAndMultiview() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        for (expanded, multiview) in [(true, false), (false, false), (true, true)] {
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let engine = try PlozzigenVideoEngine()
            let host = UIHostingController(rootView: LiveChannelPlayerView(
                channelID: "picture-viewport", title: "Synthetic channel",
                input: .stream(url: folder.appendingPathComponent("active-picture.mp4"), httpHeaders: [:]), logoURL: nil,
                makeEngine: { engine }, onPreviousChannel: {}, onNextChannel: {},
                isFavorite: false, canToggleFavorite: false, onToggleFavorite: {},
                isExpanded: expanded, onExpandPreview: {}, isAudible: false, isMultiview: multiview,
                trackPreferences: LiveChannelTrackPreferences()
            ).environment(\.scenePhase, .active))
            host.safeAreaRegions = []
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                engine.stop()
                previous?.makeKeyAndVisible()
            }
            try await waitUntil {
                window.layoutIfNeeded()
                return self.presentationView(for: engine.makeVideoOutputView())?.subtitleViewport != nil
            }
        }
    }

    func testActivePictureDetectionAndSeekOnNativeAndSoftwareRoutes() async throws {
        for fixture in ["active-picture.m3u8", "active-picture.webm"] {
            try await verifyActivePicture(fixture: fixture)
        }
    }

    func testSeparateNativeEngineDetectsPictureAndPositionsCaptions() async throws {
        try await verifyActivePicture(fixture: "active-picture.m3u8", separateNative: true)
    }

    private func verifyActivePicture(fixture: String, separateNative: Bool = false) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let engine: any VideoEngine
        if separateNative {
            engine = NativeVideoEngine(startsMuted: true, activePictureAnalyzer: PlozzigenNativePictureAnalyzer())
        } else {
            let aether = try PlozzigenVideoEngine()
            aether.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
            engine = aether
        }
        let controls = PlayerControlsModel()
        let subtitles = LiveSubtitleModel()
        subtitles.style.followsSystemStyle = false
        subtitles.style.fontFamily = .system
        subtitles.style.positionReference = .picture
        subtitles.loadPrimary(SubtitleCueParser.parse(
            "WEBVTT\n\n00:00:00.000 --> 00:01:00.000\nPicture-relative caption.\n", id: 1
        ))
        let controller = PlayerInputViewController(engine: engine, model: controls, actions: PlayerActions())
        controller.loadViewIfNeeded()
        controller.attachVideoSurface()
        controller.attachSubtitleOverlay(subtitles)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            engine.stopActivePictureAnalysis()
            engine.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        let server = try SubtitleFixtureServer(directory: folder.appendingPathComponent("active-picture-hls"))
        let port = try await server.start()
        defer { server.stop() }
        if fixture.hasSuffix(".m3u8") {
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(fixture)"))
            if let aether = engine as? PlozzigenVideoEngine {
                await aether.loadLive(url: url, httpHeaders: [:])
            } else {
                await engine.load(request: PlaybackRequest(
                    item: MediaItem(id: "native-picture", title: "Synthetic picture", kind: .movie, runtime: 18),
                    streamURL: url, sourceMetadata: .init(video: .init(codec: "h264", videoRange: "SDR"))
                ), startPosition: 0)
            }
        } else {
            await engine.load(request: PlaybackRequest(
                item: MediaItem(id: "active-picture", title: "Synthetic picture", kind: .movie, runtime: 18),
                streamURL: folder.appendingPathComponent(fixture)
            ), startPosition: 0)
        }
        try await waitUntil(timeout: 30) { engine.hasPresentedVideoFrame && engine.videoAspectRatio != nil }
        XCTAssertEqual(engine.nowPlayingPlayer != nil, fixture.hasSuffix(".m3u8"), "Exercise both engine routes.")
        await engine.seek(to: 2)
        let initial = try await waitForPicture(engine: engine, cropped: true)
        XCTAssertGreaterThan(initial.minY, 0.12)
        XCTAssertLessThan(initial.maxY, 0.88)
        let surface = engine.makeVideoOutputView()
        let viewport = try XCTUnwrap(presentationView(for: surface))
        let originalItem = engine.nowPlayingPlayer?.currentItem
        controls.videoZoom.settings.mode = .picture
        try await waitUntil {
            guard let active = viewport.activePictureRect, let video = viewport.videoRect else { return false }
            return active.height < video.height * 0.9 && subtitles.activePictureRect == active
        }
        try await waitUntil { !self.captionFrames(in: controller.view, relativeTo: window).isEmpty }
        let caption = try XCTUnwrap(captionFrames(in: controller.view, relativeTo: window).first)
        let picture = viewport.convert(try XCTUnwrap(viewport.activePictureRect), to: window)
        XCTAssertGreaterThanOrEqual(caption.minY, picture.minY - 1)
        XCTAssertLessThanOrEqual(caption.maxY, picture.maxY + 1)
        XCTAssertTrue(engine.nowPlayingPlayer?.currentItem === originalItem)
        XCTAssertTrue(engine.makeVideoOutputView() === surface)

        await engine.seek(to: 10)
        _ = try await waitForPicture(engine: engine, cropped: false)
        await engine.seek(to: 2)
        _ = try await waitForPicture(engine: engine, cropped: true)
        engine.pause()
        // Consume the final displayed frame before checking paused evidence lifetime.
        _ = await engine.sampleActivePicture()
        try await Task.sleep(for: .milliseconds(600))
        let paused = await engine.sampleActivePicture()
        try await Task.sleep(for: .seconds(2.2))
        let stillPaused = await engine.sampleActivePicture()
        XCTAssertEqual(stillPaused, paused, "Pause must not age a valid observation.")
        controls.videoZoom.settings.mode = .fit
        subtitles.style.positionReference = .screen
        try await waitUntil { surface.transform == .identity }
    }

    private func waitForPicture(engine: any VideoEngine, cropped: Bool) async throws -> CGRect {
        let deadline = ContinuousClock.now + .seconds(7)
        while ContinuousClock.now < deadline {
            if case let .measured(rect, _) = await engine.sampleActivePicture(),
               cropped ? rect.height < 0.9 : rect.height > 0.98 { return rect }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("No \(cropped ? "cropped" : "full-frame") measurement from actual playback")
        throw CocoaError(.coderValueNotFound)
    }

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

    func testFourByThreeStretchKeepsTheWholePictureOnBothEngines() async throws {
        try await verify(engine: NativeVideoEngine(), fixture: "four-three.mp4", expectedAspect: 4 / 3)
        let engine = try PlozzigenVideoEngine()
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        try await verify(engine: engine, fixture: "four-three.mp4", expectedAspect: 4 / 3)
    }

    func testNativePictureAnalysisPreservesAnamorphicAndRotatedDisplayGeometry() async throws {
        let fixtures: [(String, Double)] = [("anamorphic.mp4", 16 / 9), ("active-picture-rotated.mp4", 9 / 16)]
        for (fixture, aspect) in fixtures {
            let engine = NativeVideoEngine(startsMuted: true, activePictureAnalyzer: PlozzigenNativePictureAnalyzer())
            try await verify(engine: engine, fixture: fixture, expectedAspect: aspect, analyzePicture: true)
        }
    }

    #if os(iOS)
    func testNativeSafeAreaFittingKeepsPlaybackAndOrdinarySubtitleLayoutStable() async throws {
        try await verify(engine: NativeVideoEngine(), fitsInsideSafeArea: true)
    }

    func testPlozzigenSafeAreaFittingKeepsPlaybackAndOrdinarySubtitleLayoutStable() async throws {
        let engine = try PlozzigenVideoEngine()
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        try await verify(engine: engine, fixture: "anamorphic.mp4", expectedAspect: 16 / 9, fitsInsideSafeArea: true)
    }
    #endif

    private func verify(
        engine: any VideoEngine, fixture: String = "embedded.mp4", expectedAspect: Double? = nil,
        fitsInsideSafeArea: Bool = false, analyzePicture: Bool = false
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
        let controller = PlayerInputViewController(
            engine: engine, model: controls, actions: PlayerActions(), fitsInsideSafeArea: fitsInsideSafeArea
        )
        if fitsInsideSafeArea {
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: 13, left: 61, bottom: 17, right: 7)
        }
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
        if analyzePicture {
            await engine.seek(to: fixture.contains("rotated") ? 2 : 0)
            let deadline = ContinuousClock.now + .seconds(7)
            var measured = false
            while ContinuousClock.now < deadline {
                if case let .measured(rect, display) = await engine.sampleActivePicture() {
                    XCTAssertEqual(display.width / display.height, try XCTUnwrap(expectedAspect), accuracy: 0.0001)
                    if fixture.contains("rotated") {
                        XCTAssertLessThan(rect.width, 0.9)
                        XCTAssertEqual(rect.height, 1, accuracy: 0.02)
                    }
                    measured = true
                    break
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            XCTAssertTrue(measured, "Resized analysis must retain the original display canvas.")
            let player = try XCTUnwrap(engine.nowPlayingPlayer)
            let output = try XCTUnwrap(player.currentItem?.outputs.compactMap { $0 as? AVPlayerItemVideoOutput }.first)
            var displayed = CMTime.invalid
            let buffer = try XCTUnwrap(output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: &displayed))
            XCTAssertLessThanOrEqual(CVPixelBufferGetWidth(buffer), 320)
            XCTAssertLessThanOrEqual(CVPixelBufferGetHeight(buffer), 180)
            engine.stopActivePictureAnalysis()
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
        let viewport = try XCTUnwrap(presentationView(for: surface))
        try await waitUntil {
            window.layoutIfNeeded()
            return !self.captionFrames(in: controller.view, relativeTo: window).isEmpty
        }
        let caption = try XCTUnwrap(captionFrames(in: controller.view, relativeTo: window).first)
        let position = engine.currentTime

        for zoom in [PlayerVideoZoom(mode: .fill), PlayerVideoZoom(mode: .stretch),
                     PlayerVideoZoom(mode: .custom, customPercent: 150),
                     PlayerVideoZoom(mode: .custom, customPercent: 90), PlayerVideoZoom()] {
            controls.videoZoom.settings = zoom
            let expected = zoom.surfaceFrame(
                in: viewport.bounds, aspectRatio: engine.videoAspectRatio, fitBounds: viewport.fitBounds
            )
            try await waitUntil {
                window.layoutIfNeeded()
                return abs(surface.frame.minX - expected.minX) < 0.001
                    && abs(surface.frame.minY - expected.minY) < 0.001
                    && abs(surface.frame.width - expected.width) < 0.001
                    && abs(surface.frame.height - expected.height) < 0.001
                    && subtitles.videoRect == viewport.videoRect
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
            let sourceRect = try XCTUnwrap(SubtitleOverlayGeometry.aspectFitRect(
                in: surface.bounds, aspectRatio: engine.videoAspectRatio.map { CGFloat($0) }
            ))
            let mappedPicture = surface.convert(sourceRect, to: viewport)
            let expectedPicture = try XCTUnwrap(viewport.videoRect)
            XCTAssertEqual(mappedPicture.minX, expectedPicture.minX, accuracy: 0.001)
            XCTAssertEqual(mappedPicture.minY, expectedPicture.minY, accuracy: 0.001)
            XCTAssertEqual(mappedPicture.width, expectedPicture.width, accuracy: 0.001)
            XCTAssertEqual(mappedPicture.height, expectedPicture.height, accuracy: 0.001)
            if zoom.mode == .stretch {
                XCTAssertEqual(subtitles.sourceVideoAspectRatio, engine.videoAspectRatio)
                XCTAssertEqual(mappedPicture.width, viewport.bounds.width, accuracy: 0.001)
                XCTAssertEqual(mappedPicture.height, viewport.bounds.height, accuracy: 0.001)
            } else {
                XCTAssertNil(subtitles.sourceVideoAspectRatio)
            }
            if fitsInsideSafeArea, zoom.mode == .fit {
                let safe = try XCTUnwrap(viewport.fitBounds)
                XCTAssertTrue(safe.insetBy(dx: -0.001, dy: -0.001).contains(mappedPicture))
                let safePicture = try XCTUnwrap(SubtitleOverlayGeometry.aspectFitRect(
                    in: safe, aspectRatio: engine.videoAspectRatio.map { CGFloat($0) }
                ))
                XCTAssertEqual(mappedPicture.minX, safePicture.minX, accuracy: 0.001)
                XCTAssertEqual(mappedPicture.minY, safePicture.minY, accuracy: 0.001)
                XCTAssertEqual(mappedPicture.width, safePicture.width, accuracy: 0.001)
                XCTAssertEqual(mappedPicture.height, safePicture.height, accuracy: 0.001)
            }
            for layer in [surface.layer] + layers {
                if let native = layer as? AVPlayerLayer { XCTAssertEqual(native.videoGravity, .resizeAspect) }
                if let software = layer as? AVSampleBufferDisplayLayer { XCTAssertEqual(software.videoGravity, .resizeAspect) }
            }
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
        guard condition() else {
            XCTFail("Video or subtitle presentation did not settle.")
            throw CocoaError(.coderValueNotFound)
        }
    }
}
