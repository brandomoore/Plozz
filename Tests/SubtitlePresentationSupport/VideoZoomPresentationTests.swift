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
    func testAudioBorderAddsOnePointToTwoPixelsAndOnlyAppearsWithoutFocus() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = VideoAudioGlowState()
        let fixture = { (focused: Bool, active: Bool, scale: CGFloat, background: Color) in
            VideoAudioGlow(state: state, isActive: active, cornerRadius: 20, isFocused: focused)
                .frame(width: 640, height: 360)
                .overlay { RoundedRectangle(cornerRadius: 20).fill(background) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background)
                .environment(\.displayScale, scale)
                .environment(\._accessibilityReduceMotion, true)
                .ignoresSafeArea()
        }
        let host = UIHostingController(rootView: fixture(true, true, 1, .black))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func intensity(scale: CGFloat, pixel: Int) throws -> Float {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let region = CGRect(x: (window.bounds.midX - 100) * scale,
                                y: (window.bounds.midY + 180) * scale + CGFloat(pixel),
                                width: 200 * scale, height: 1)
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: region))
            let ci = CIImage(cgImage: crop)
            let average = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
            var value = [Float](repeating: 0, count: 4)
            CIContext().render(average, toBitmap: &value, rowBytes: 16,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (value[0] + value[1] + value[2]) / 3
        }
        try await Task.sleep(for: .milliseconds(1300))
        for scale: CGFloat in [1, 2] {
            let borderPixels = 2 + Int(scale)
            let samplePixels = 0..<(borderPixels + 3)
            host.rootView = fixture(true, true, scale, .black)
            try await Task.sleep(for: .milliseconds(100))
            let focused = try samplePixels.map { try intensity(scale: scale, pixel: $0) }
            host.rootView = fixture(false, true, scale, .black)
            try await Task.sleep(for: .milliseconds(100))
            let unfocused = try samplePixels.map { try intensity(scale: scale, pixel: $0) }
            let border = zip(unfocused, focused).map { $0 - $1 }
            let peak = try XCTUnwrap(border.max())
            XCTAssertEqual(peak, 0.44, accuracy: 0.04,
                           "The outline must be 20% dimmer than its previous 55% opacity.")
            XCTAssertGreaterThan(peak, 0)
            // Snapshot scaling can distribute an edge pixel across two samples.
            XCTAssertEqual(border.reduce(0, +) / peak, Float(borderPixels), accuracy: 0.25,
                           "Integrated stroke coverage must equal two physical pixels plus one point.")
            XCTAssertLessThan(abs(border[borderPixels]), 0.08)
            for value in border.dropFirst(borderPixels + 1) {
                XCTAssertEqual(value, 0, accuracy: 0.015,
                               "Only faint edge antialiasing may extend beyond two pixels plus one point.")
            }
        }
        for (background, sample) in [
            (Color.white, SIMD4<Float>(0, 0, 0, 0)),
            (.red, SIMD4<Float>(1, 0.52, 0.52, 0.9)),
            (.cyan, SIMD4<Float>(0.52, 1, 1, 0.9)),
            (.yellow, SIMD4<Float>(1, 1, 0.52, 0.9))
        ] {
            state.updatePalette(Array(repeating: sample, count: 3))
            host.rootView = fixture(true, true, 1, background)
            try await Task.sleep(for: .milliseconds(100))
            let focused = try (0..<5).map { try intensity(scale: 1, pixel: $0) }
            host.rootView = fixture(false, true, 1, background)
            try await Task.sleep(for: .milliseconds(100))
            let outlined = try (0..<5).map { try intensity(scale: 1, pixel: $0) }
            let contrast = zip(outlined, focused).map { abs($0 - $1) }
            XCTAssertGreaterThan(try XCTUnwrap(contrast.max()), 0.04,
                                 "The tinted rim and fine dark edge must remain distinct on bright, saturated backgrounds.")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Audio outline contrast \(background)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        host.rootView = fixture(false, false, 1, .black)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try intensity(scale: 1, pixel: 0), 0, accuracy: 0.004)
    }

    func testAudioGlowFadesOutsideTheNativeFocusedPictureWithoutResizingIt() async throws {
        try await assertAudioGlowTransitions(reduceMotion: false)
    }

    func testAudioGlowKeepsItsDwellDelayButSkipsFadesWithReducedMotion() async throws {
        try await assertAudioGlowTransitions(reduceMotion: true)
    }

    private func assertAudioGlowTransitions(reduceMotion: Bool) async throws {
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
                    .videoCardFocusSurface { focused in
                        VideoAudioGlow(state: glow, isActive: active, cornerRadius: 20, isFocused: focused)
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
        let fixture = { (active: Bool) in
            Fixture(surface: surface, glow: glow, active: active)
                .environment(\._accessibilityReduceMotion, reduceMotion)
        }
        let host = UIHostingController(rootView: fixture(false))
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
        func edgeIntensity(distance: CGFloat = 80) throws -> Float {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let ci = try XCTUnwrap(CIImage(image: image))
            let scale = image.scale
            let region = CGRect(x: (frame.midX - 100) * scale,
                                y: (window.bounds.height - frame.maxY - distance) * scale,
                                width: 200 * scale, height: 7 * scale)
            let average = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
            var pixel = [Float](repeating: 0, count: 4)
            CIContext().render(average, toBitmap: &pixel, rowBytes: 16,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())
            return (pixel[0] + pixel[1] + pixel[2]) / 3
        }
        let initial = try edgeIntensity()
        host.rootView = fixture(true)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(try edgeIntensity(), initial, accuracy: 0.001,
                       "A newly audible picture must wait before showing its glow.")
        try await Task.sleep(for: .milliseconds(1250))
        let entering = try edgeIntensity()
        try await Task.sleep(for: .milliseconds(800))
        let midway = try edgeIntensity()
        try await Task.sleep(for: .milliseconds(1700))
        let active = try edgeIntensity()
        if !reduceMotion {
            XCTAssertGreaterThan(entering, initial)
            XCTAssertGreaterThan(midway, entering)
            XCTAssertGreaterThan(active, midway, "The three-second fade-in must continue beyond its old 1.5-second duration.")
        } else {
            XCTAssertEqual(entering, active, accuracy: 0.001)
        }
        let distances: [CGFloat] = [32, 80, 140, 280]
        let activeFalloff = try distances.map { try edgeIntensity(distance: $0) }
        host.rootView = fixture(false)
        try await Task.sleep(for: .milliseconds(700))
        let fading = try edgeIntensity()
        try await Task.sleep(for: .milliseconds(1000))
        let inactive = try edgeIntensity()
        let inactiveFalloff = try distances.map { try edgeIntensity(distance: $0) }
        let falloff = zip(activeFalloff, inactiveFalloff).map { $0 - $1 }
        XCTAssertGreaterThan(active - inactive, 0.005, "The glow must remain visible 73-80 points beyond the lifted picture.")
        XCTAssertGreaterThan(falloff[1], falloff[0] * 0.25, "The outer glow must fade gradually, not end at a narrow rim.")
        XCTAssertGreaterThan(falloff[2], 0.0006, "A soft tail must remain visible 133-140 points beyond the picture.")
        XCTAssertLessThan(falloff[3], 0.002, "The glow must eventually fade into the surrounding black.")
        for (near, far) in zip(falloff, falloff.dropFirst()) {
            XCTAssertGreaterThan(near, far, "The glow must weaken smoothly with distance: \(falloff)")
        }
        if !reduceMotion {
            XCTAssertGreaterThan(active, fading)
            XCTAssertGreaterThan(fading, inactive, "Fade-out must remain visible beyond the old 0.6-second duration.")
        } else {
            XCTAssertEqual(fading, inactive, accuracy: 0.001)
        }
        host.rootView = fixture(true)
        try await Task.sleep(for: .milliseconds(350))
        host.rootView = fixture(false)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(try edgeIntensity(), inactive, accuracy: 0.001,
                       "Passing briefly over a picture must cancel its pending glow.")
        host.rootView = fixture(true)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(try edgeIntensity(), inactive, accuracy: 0.001,
                       "Returning to the picture must start a fresh dwell delay.")
        try await Task.sleep(for: .milliseconds(1250))
        let appearing = try edgeIntensity()
        try await Task.sleep(for: .milliseconds(2500))
        let restored = try edgeIntensity()
        XCTAssertGreaterThan(restored - inactive, 0.005)
        if !reduceMotion {
            XCTAssertGreaterThan(appearing, inactive)
            XCTAssertGreaterThan(restored, appearing)
        } else {
            XCTAssertEqual(appearing, restored, accuracy: 0.001)
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

    func testConfirmedCropWaitsForPositiveEvidenceAcrossUnavailableSeekFrames() {
        let source = UUID()
        let crop = CGRect(x: 0, y: 0.15, width: 1, height: 0.7)
        let size = CGSize(width: 320, height: 180)
        var picture = VideoActivePicturePresentation()
        picture.receive(.measured(normalizedRect: crop, displaySize: size),
                        sourceID: source, aspectRatio: 16 / 9)
        picture.reconcile(sourceID: source, aspectRatio: nil)
        for ratio: Double? in [nil, 16 / 9, nil] {
            picture.receive(.unavailable, sourceID: source, aspectRatio: ratio)
            XCTAssertEqual(picture.normalizedRect, crop)
            XCTAssertEqual(picture.displayAspectRatio, 16 / 9)
        }
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        picture.receive(.measured(normalizedRect: full, displaySize: size),
                        sourceID: source, aspectRatio: 16 / 9)
        XCTAssertEqual(picture.normalizedRect, full, "Real edge content must expand the retained crop.")
        picture.receive(.measured(normalizedRect: crop, displaySize: size),
                        sourceID: source, aspectRatio: 16 / 9)
        XCTAssertEqual(picture.normalizedRect, crop, "Later confirmed bars can establish different framing.")
    }

    func testCropHostKeepsFramingWithoutSamplingWhileSeekDimensionsAreProvisional() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let engine = CropSeekVideoEngine()
        let view = VideoPresentationView(frame: CGRect(x: 0, y: 0, width: 1000, height: 400))
        controller.view.addSubview(view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            view.update(zoom: PlayerVideoZoom())
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        view.attach(engine)
        view.update(zoom: PlayerVideoZoom(mode: .picture))
        try await waitUntil { engine.output.transform.a > 1.1 }
        let cropped = engine.output.transform
        let samples = engine.samples
        engine.isPlaybackPositionReady = false
        engine.videoAspectRatio = 4 / 3
        view.update(zoom: PlayerVideoZoom(mode: .picture))
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(engine.samples, samples, "A seek must not admit analysis of transitional output.")
        XCTAssertEqual(view.sourceAspectRatio, 16 / 9)
        XCTAssertEqual(engine.output.transform, cropped)

        engine.activePictureSourceID = UUID()
        view.update(zoom: PlayerVideoZoom(mode: .picture))
        XCTAssertEqual(view.activePictureRect, view.videoRect, "Even an unready new source must discard old framing.")
        engine.videoAspectRatio = 16 / 9
        engine.isPlaybackPositionReady = true
        engine.result = .unavailable
        view.update(zoom: PlayerVideoZoom(mode: .picture))
        try await waitUntil { engine.samples > samples }
        XCTAssertEqual(engine.output.transform, .identity)
        engine.result = .measured(normalizedRect: CGRect(x: 0, y: 0.15, width: 1, height: 0.7),
                                  displaySize: CGSize(width: 320, height: 180))
        try await waitUntil { engine.output.transform == cropped }
        view.update(zoom: PlayerVideoZoom())
        let stoppedSamples = engine.samples
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(engine.samples, stoppedSamples)
        XCTAssertEqual(engine.output.transform, .identity)
    }

    func testRetainedCropCannotCrossSourcesOrKnownGeometryChanges() {
        let source = UUID()
        let crop = CGRect(x: 0, y: 0.15, width: 1, height: 0.7)
        for (nextSource, ratio) in [(UUID(), Double?.none), (source, 4 / 3), (source, Double.nan)] {
            var picture = VideoActivePicturePresentation()
            picture.receive(.measured(normalizedRect: crop, displaySize: CGSize(width: 320, height: 180)),
                            sourceID: source, aspectRatio: 16 / 9)
            picture.reconcile(sourceID: nextSource, aspectRatio: ratio)
            XCTAssertNil(picture.normalizedRect)
            XCTAssertNil(picture.displayAspectRatio)
            picture.receive(.unavailable, sourceID: nextSource, aspectRatio: ratio)
            XCTAssertNil(picture.normalizedRect)
        }

    }

    func testUnsupportedInvalidAndUnscopedPictureEvidenceCannotRetainACrop() {
        let source = UUID()
        let size = CGSize(width: 320, height: 180)
        let crop = CGRect(x: 0, y: 0.15, width: 1, height: 0.7)
        let cases: [(UUID?, VideoActivePictureState)] = [
            (source, .unsupported),
            (source, .measured(normalizedRect: .zero, displaySize: size)),
            (source, .measured(normalizedRect: crop, displaySize: CGSize(width: 180, height: 320))),
            (source, .measured(normalizedRect: crop, displaySize: .zero)),
            (nil, .unavailable)
        ]
        for (sourceID, result) in cases {
            var picture = VideoActivePicturePresentation()
            picture.receive(.measured(normalizedRect: crop, displaySize: size),
                            sourceID: sourceID, aspectRatio: 16 / 9)
            picture.receive(result, sourceID: sourceID, aspectRatio: 16 / 9)
            XCTAssertNil(picture.normalizedRect)
            XCTAssertNil(picture.displayAspectRatio)
        }
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

        try await assertCropSurvivesSeek(engine: engine, viewport: viewport, to: 3)
        try await assertCropSurvivesSeek(engine: engine, viewport: viewport, to: 1)
        await engine.seek(to: 10)
        _ = try await waitForPicture(engine: engine, cropped: false)
        try await waitUntil {
            guard let picture = viewport.activePictureRect, let video = viewport.videoRect else { return false }
            return picture.height > video.height * 0.98
        }
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
        let sourceID = try XCTUnwrap(engine.activePictureSourceID)
        engine.stop()
        XCTAssertNotEqual(engine.activePictureSourceID, sourceID, "Retiring the source invalidates retained framing.")
    }

    private func assertCropSurvivesSeek(
        engine: any VideoEngine, viewport: VideoPresentationView, to time: TimeInterval
    ) async throws {
        let picture = try XCTUnwrap(viewport.activePictureRect)
        let video = try XCTUnwrap(viewport.videoRect)
        let expectedFraction = picture.height / video.height
        let sourceID = try XCTUnwrap(engine.activePictureSourceID)
        var observedFrames = 0
        var uncroppedFrames = 0
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                observedFrames += 1
                if let nextPicture = viewport.activePictureRect, let nextVideo = viewport.videoRect {
                    if abs(nextPicture.height / nextVideo.height - expectedFraction) >= 0.01 {
                        uncroppedFrames += 1
                    }
                } else {
                    uncroppedFrames += 1
                }
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { return }
            }
        }
        defer { observer.cancel() }
        await engine.seek(to: time)
        try await Task.sleep(for: .seconds(2.2))
        observer.cancel()
        await observer.value
        XCTAssertEqual(engine.activePictureSourceID, sourceID)
        XCTAssertGreaterThan(observedFrames, 20)
        XCTAssertEqual(uncroppedFrames, 0, "Seeking to \(time)s must keep the confirmed crop while analysis restarts.")
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

    func testDarkPictureCropsWhilePlaybackAdvancesWithoutABrightScene() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
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
        for native in [true, false] {
            let engine: any VideoEngine
            if native {
                engine = NativeVideoEngine(startsMuted: true, activePictureAnalyzer: PlozzigenNativePictureAnalyzer())
            } else {
                let aether = try PlozzigenVideoEngine()
                aether.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
                engine = aether
            }
            let view = VideoPresentationView(frame: host.view.bounds)
            host.view.addSubview(view)
            view.attach(engine)
            view.update(zoom: PlayerVideoZoom(mode: .picture))
            defer {
                view.removeFromSuperview()
                engine.stopActivePictureAnalysis()
                engine.stop()
            }
            let started = ProcessInfo.processInfo.systemUptime
            await engine.load(request: PlaybackRequest(
                item: MediaItem(id: "dark-picture", title: "Synthetic dark picture", kind: .movie, runtime: 6),
                streamURL: folder.appendingPathComponent("active-picture-dark.mp4"),
                sourceMetadata: .init(video: .init(codec: "h264", videoRange: "SDR"))
            ), startPosition: 0)
            try await waitUntil(timeout: 30) { engine.hasPresentedVideoFrame && engine.isPlaybackPositionReady }
            XCTAssertEqual(engine.nowPlayingPlayer != nil, native)
            let firstFrame = ProcessInfo.processInfo.systemUptime
            let firstPosition = engine.currentTime
            view.update(zoom: PlayerVideoZoom(mode: .picture))
            try await waitUntil(timeout: 3) {
                guard let picture = view.activePictureRect, let video = view.videoRect else { return false }
                return picture.height < video.height * 0.75 && picture.height > video.height * 0.65
            }
            XCTAssertGreaterThan(engine.currentTime - firstPosition, 0.5, "Detection must not pause playback.")
            XCTContext.runActivity(named: native ? "Dark native crop" : "Dark software crop") { activity in
                let evidence = XCTAttachment(string:
                    "firstFrameMilliseconds=\((firstFrame - started) * 1000)\n"
                    + "cropAfterFirstFrameMilliseconds=\((ProcessInfo.processInfo.systemUptime - firstFrame) * 1000)")
                evidence.lifetime = .keepAlways
                activity.add(evidence)
            }
        }
    }

    func testLocalSDRActivePictureSceneReproduction() async throws {
        guard let path = ProcessInfo.processInfo.environment["PLOZZ_CROP_MEDIA_REPRO"] else {
            throw XCTSkip("Requires an explicitly supplied local crop reproduction configuration.")
        }
        struct Configuration: Decodable {
            let url: URL
            let start: Double
        }
        let configuration = try JSONDecoder().decode(
            Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard configuration.url.isFileURL || configuration.url.host == "127.0.0.1",
              configuration.start.isFinite, configuration.start >= 0 else {
            XCTFail("Supply local SDR media and a finite nonnegative start time.")
            throw CocoaError(.fileReadCorruptFile)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let engine = try PlozzigenVideoEngine()
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        let view = VideoPresentationView(frame: host.view.bounds)
        host.view.addSubview(view)
        view.attach(engine)
        defer {
            view.removeFromSuperview()
            engine.stopActivePictureAnalysis()
            engine.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        await engine.load(request: PlaybackRequest(
            item: MediaItem(id: "local-crop-scene", title: "Local crop reproduction", kind: .movie),
            streamURL: configuration.url,
            sourceMetadata: .init(video: .init(codec: "hevc", videoRange: "SDR"))
        ), startPosition: configuration.start)
        try await waitUntil(timeout: 30) { engine.hasPresentedVideoFrame && engine.isPlaybackPositionReady }
        let originalItem = engine.nowPlayingPlayer?.currentItem
        let originalSurface = engine.makeVideoOutputView()
        let firstFrame = ProcessInfo.processInfo.systemUptime
        let firstPosition = engine.currentTime
        view.update(zoom: PlayerVideoZoom(mode: .picture))
        var observations: [[String: Any]] = []
        var firstMeasured: Double?
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            var observation: [String: Any] = [
                "elapsed": ProcessInfo.processInfo.systemUptime - firstFrame,
                "position": engine.currentTime,
                "usesNativePlayer": engine.nowPlayingPlayer != nil,
            ]
            switch await engine.sampleActivePicture() {
            case let .measured(rect, size):
                if firstMeasured == nil { firstMeasured = ProcessInfo.processInfo.systemUptime - firstFrame }
                observation["rect"] = [rect.minX, rect.minY, rect.width, rect.height]
                observation["displaySize"] = [size.width, size.height]
            case let result:
                observation["state"] = String(describing: result)
            }
            observations.append(observation)
            try await Task.sleep(for: .milliseconds(500))
        }
        let data = try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
        XCTContext.runActivity(named: "Local scene active-picture observations") { activity in
            let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            evidence.lifetime = .keepAlways
            activity.add(evidence)
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(firstMeasured), 3, "Do not wait for a later bright scene.")
        XCTAssertGreaterThan(engine.currentTime - firstPosition, 10)
        XCTAssertTrue(engine.makeVideoOutputView() === originalSurface)
        if let originalItem { XCTAssertTrue(engine.nowPlayingPlayer?.currentItem === originalItem) }
    }

    private struct CropReference: Decodable {
        let from: Double
        let to: Double
        let rect: [CGFloat]
    }

    private struct CropScene: Decodable {
        let label: String
        let url: URL
        let start: Double
        let videoRange: String
        let references: [CropReference]
    }

    func testLocalActivePictureVariety() async throws {
        guard let path = ProcessInfo.processInfo.environment["PLOZZ_CROP_VARIETY_REPRO"] else {
            throw XCTSkip("Requires explicitly supplied local media and independently checked frame boundaries.")
        }
        let scenes = try JSONDecoder().decode(
            [CropScene].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard !scenes.isEmpty, scenes.count <= 12 else { throw CocoaError(.fileReadCorruptFile) }
        for scene in scenes {
            do {
                try await replayCropScene(scene)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                XCTFail("\(scene.label): \(error)")
            }
        }
    }

    private func replayCropScene(_ configuration: CropScene) async throws {
        guard configuration.url.isFileURL || configuration.url.host == "127.0.0.1",
              configuration.start.isFinite, configuration.start >= 0,
              ["SDR", "HDR10", "DolbyVision"].contains(configuration.videoRange),
              !configuration.references.isEmpty,
              configuration.references.allSatisfy({
                  $0.from.isFinite && $0.to.isFinite && $0.from >= 0 && $0.to > $0.from
                      && $0.rect.count == 4 && $0.rect.allSatisfy(\.isFinite)
                      && VideoActivePictureGeometry.isValid(CGRect(
                          x: $0.rect[0], y: $0.rect[1], width: $0.rect[2], height: $0.rect[3]))
              }) else { throw CocoaError(.fileReadCorruptFile) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
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
        let engine = try PlozzigenVideoEngine()
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        let view = VideoPresentationView(frame: host.view.bounds)
        host.view.addSubview(view)
        view.attach(engine)
        defer {
            view.removeFromSuperview()
            engine.stopActivePictureAnalysis()
            engine.stop()
        }
        let loadStarted = ProcessInfo.processInfo.systemUptime
        await engine.load(request: PlaybackRequest(
            item: MediaItem(id: "local-crop-variety", title: "Local crop variety", kind: .movie),
            streamURL: configuration.url,
            sourceMetadata: .init(video: .init(codec: "hevc", videoRange: configuration.videoRange))
        ), startPosition: configuration.start)
        try await waitUntil(timeout: 30) { engine.hasPresentedVideoFrame && engine.isPlaybackPositionReady }
        let firstFrameMilliseconds = (ProcessInfo.processInfo.systemUptime - loadStarted) * 1000
        let player = engine.nowPlayingPlayer
        let item = player?.currentItem
        let surface = engine.makeVideoOutputView()
        var nativeLayer: AVPlayerLayer?
        var layers = [surface.layer]
        while let layer = layers.popLast() {
            if let candidate = layer as? AVPlayerLayer, candidate.player === player, player != nil {
                nativeLayer = candidate
                break
            }
            layers.append(contentsOf: layer.sublayers ?? [])
        }
        let referenceTime = player?.currentTime()
        func snapshot() async throws -> (format: OSType, pixels: [Float])? {
            guard let player, let referenceTime else { return nil }
            let layer = try XCTUnwrap(nativeLayer, "Native playback must expose its presenting layer.")
            return try await snapshotDisplayedPicture(player: player, layer: layer, time: referenceTime)
        }
        var baseline: (format: OSType, pixels: [Float])?
        var colorError: String?
        do {
            baseline = try await snapshot()
        } catch {
            colorError = String(describing: error)
            XCTFail("\(configuration.label): native baseline capture failed: \(error)")
        }
        engine.play()
        let firstPosition = engine.currentTime
        let analysisStarted = ProcessInfo.processInfo.systemUptime
        view.update(zoom: PlayerVideoZoom(mode: .picture))
        var observations: [[String: Any]] = []
        var firstAccurate: Double?
        var overcropped = 0
        var inaccurate = 0
        var confidenceDropouts = 0
        var hadMeasurement = false
        var accurateReferenceSamples = [Int](repeating: 0, count: configuration.references.count)
        let deadline = ContinuousClock.now + .seconds(12)
        while true {
            let elapsed = ProcessInfo.processInfo.systemUptime - analysisStarted
            let position = engine.currentTime
            var observation: [String: Any] = ["elapsed": elapsed, "position": position]
            if let video = view.videoRect {
                observation["presentedVideoRect"] = [video.minX, video.minY, video.width, video.height]
            }
            switch await engine.sampleActivePicture() {
            case let .measured(rect, size):
                hadMeasurement = true
                observation["rect"] = [rect.minX, rect.minY, rect.width, rect.height]
                observation["displaySize"] = [size.width, size.height]
                if let referenceIndex = configuration.references.firstIndex(where: {
                    let relative = position - configuration.start
                    return relative >= $0.from && relative < $0.to
                }) {
                    let reference = configuration.references[referenceIndex]
                    let expected = CGRect(x: reference.rect[0], y: reference.rect[1],
                                          width: reference.rect[2], height: reference.rect[3])
                    let error = max(abs(rect.minX - expected.minX), abs(rect.maxX - expected.maxX),
                                    abs(rect.minY - expected.minY), abs(rect.maxY - expected.maxY))
                    let cutsPicture = !rect.contains(expected.insetBy(dx: 0.015, dy: 0.015))
                    observation["boundaryError"] = error
                    observation["cutsPicture"] = cutsPicture
                    if cutsPicture { overcropped += 1 }
                    if error > 0.015 {
                        inaccurate += 1
                    } else {
                        accurateReferenceSamples[referenceIndex] += 1
                        if firstAccurate == nil { firstAccurate = elapsed }
                    }
                }
            case let result:
                observation["state"] = String(describing: result)
                if hadMeasurement { confidenceDropouts += 1 }
            }
            observations.append(observation)
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        let advanced = engine.currentTime - firstPosition
        var report: [String: Any] = [
            "label": configuration.label, "videoRange": configuration.videoRange,
            "nativePlayback": player != nil, "firstFrameMilliseconds": firstFrameMilliseconds,
            "advancedSeconds": advanced, "overcroppedSamples": overcropped,
            "inaccurateSamples": inaccurate, "confidenceDropoutSamples": confidenceDropouts,
            "accurateReferenceSamples": accurateReferenceSamples,
            "observations": observations,
        ]
        if let firstAccurate { report["firstAccurateSeconds"] = firstAccurate }
        if let baseline {
            do {
                let activeSnapshot = try await snapshot()
                let active = try XCTUnwrap(activeSnapshot)
                view.update(zoom: PlayerVideoZoom())
                let stoppedSnapshot = try await snapshot()
                let stopped = try XCTUnwrap(stoppedSnapshot)
                let differences = [active, stopped].flatMap {
                    zip($0.pixels, baseline.pixels).map { abs($0 - $1) }
                }
                let finite = differences.allSatisfy(\.isFinite)
                if finite { report["nativeColorMaxDifference"] = differences.max() }
                report["nativeColorFinite"] = finite
                report["nativeFormatUnchanged"] = active.format == baseline.format && stopped.format == baseline.format
                XCTAssertTrue(finite && differences.allSatisfy { $0 <= 0.00001 }, configuration.label)
                XCTAssertEqual(active.format, baseline.format, configuration.label)
                XCTAssertEqual(stopped.format, baseline.format, configuration.label)
            } catch {
                colorError = String(describing: error)
                XCTFail("\(configuration.label): native color comparison failed: \(error)")
            }
        } else {
            report["colorComparison"] = player == nil
                ? "Unavailable on software presentation; no native displayed-buffer readback."
                : "Native baseline capture failed; see colorComparisonError."
        }
        if let colorError { report["colorComparisonError"] = colorError }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        XCTContext.runActivity(named: configuration.label) { activity in
            let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            evidence.lifetime = .keepAlways
            activity.add(evidence)
        }
        XCTAssertLessThanOrEqual(try XCTUnwrap(firstAccurate, configuration.label), 3, configuration.label)
        XCTAssertEqual(overcropped, 0, configuration.label)
        XCTAssertEqual(inaccurate, 0, configuration.label)
        XCTAssertEqual(confidenceDropouts, 0, configuration.label)
        XCTAssertTrue(accurateReferenceSamples.allSatisfy { $0 > 0 },
                      "\(configuration.label): every reference interval must be exercised.")
        XCTAssertGreaterThan(advanced, 10, configuration.label)
        XCTAssertTrue(engine.makeVideoOutputView() === surface)
        if let item { XCTAssertTrue(engine.nowPlayingPlayer?.currentItem === item) }
    }

    private func snapshotDisplayedPicture(
        player: AVPlayer, layer: AVPlayerLayer, time: CMTime
    ) async throws -> (format: OSType, pixels: [Float]) {
        player.pause()
        let landed = await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        guard landed else { throw CocoaError(.coderValueNotFound) }
        try await Task.sleep(for: .milliseconds(400))
        let buffer = try XCTUnwrap(layer.displayedPixelBuffer())
        let image = CIImage(cvPixelBuffer: buffer)
        let sampled = image.transformed(by: CGAffineTransform(
            scaleX: 32 / image.extent.width, y: 18 / image.extent.height))
        var pixels = [Float](repeating: 0, count: 32 * 18 * 4)
        CIContext(options: [.cacheIntermediates: false]).render(
            sampled, toBitmap: &pixels, rowBytes: 32 * 16,
            bounds: CGRect(x: 0, y: 0, width: 32, height: 18),
            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        return (CVPixelBufferGetPixelFormatType(buffer), pixels)
    }

    func testNativeHDRPictureAnalysisLeavesDisplayedPixelsUnchanged() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
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
        let url = try XCTUnwrap(SubtitleHDRPreview.assetURL)
        // Exercise both native conversion policies on the same authored HDR frame.
        for range in [SourceDynamicRange.hdr10, .dolbyVision] {
            let engine = NativeVideoEngine(startsMuted: true)
            let analyzer = PlozzigenNativePictureAnalyzer()
            let surface = engine.makeVideoOutputView()
            surface.frame = host.view.bounds
            host.view.addSubview(surface)
            defer {
                analyzer.stop()
                engine.stop()
                surface.removeFromSuperview()
            }
            await engine.load(request: PlaybackRequest(
                item: MediaItem(id: "hdr-crop", title: "Synthetic HDR", kind: .movie, runtime: 16),
                streamURL: url
            ), startPosition: 0)
            try await waitUntil(timeout: 30) { engine.hasPresentedVideoFrame }
            let player = try XCTUnwrap(engine.nowPlayingPlayer)
            let item = try XCTUnwrap(player.currentItem)
            let layer = try XCTUnwrap(surface.layer as? AVPlayerLayer)
            func snapshot() async throws -> (format: OSType, pixels: [Float]) {
                try await snapshotDisplayedPicture(
                    player: player, layer: layer, time: CMTime(seconds: 2, preferredTimescale: 600))
            }
            let baseline = try await snapshot()
            player.play()
            var measured = false
            let deadline = ContinuousClock.now + .seconds(8)
            while !measured && ContinuousClock.now < deadline {
                if case .measured = await analyzer.sample(player: player, generation: 0, dynamicRange: range) {
                    measured = true
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            XCTAssertTrue(measured, "Color isolation must not disable border detection.")
            XCTAssertEqual(item.outputs.filter { $0 is AVPlayerItemVideoOutput }.count, 1)
            let active = try await snapshot()
            analyzer.stop()
            player.play()
            try await Task.sleep(for: .milliseconds(500))
            let stopped = try await snapshot()
            for result in [active, stopped] {
                XCTAssertEqual(result.format, baseline.format, "Analysis must not renegotiate the displayed format.")
                let differences = zip(result.pixels, baseline.pixels).map { abs($0 - $1) }
                XCTAssertTrue(differences.allSatisfy { $0.isFinite && $0 <= 0.00001 },
                              "Only private analysis pixels may be converted; maximum difference: \(differences.max() ?? 0).")
            }
            XCTAssertFalse(item.outputs.contains { $0 is AVPlayerItemVideoOutput })
            XCTAssertTrue(player.currentItem === item)
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
            XCTAssertEqual(CVPixelBufferGetWidth(buffer), fixture.contains("rotated") ? 320 : 720)
            XCTAssertEqual(CVPixelBufferGetHeight(buffer), fixture.contains("rotated") ? 180 : 576,
                           "The native tap must retain source sizing; only the worker's private copy is downscaled.")
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

@MainActor
private final class CropSeekVideoEngine: VideoEngine {
    let output = UIView()
    var videoAspectRatio: Double? = 16 / 9
    var supportsActivePictureAnalysis: Bool { true }
    var activePictureSourceID: UUID? = UUID()
    var isPlaybackPositionReady = true
    var samples = 0
    var result = VideoActivePictureState.measured(
        normalizedRect: CGRect(x: 0, y: 0.15, width: 1, height: 0.7),
        displaySize: CGSize(width: 320, height: 180)
    )
    var status: VideoEngineStatus = .ready
    var isPaused = true
    var currentTime: TimeInterval = 10
    var duration: TimeInterval = 100
    var furthestObservedPosition: TimeInterval = 10
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    func sampleActivePicture() async -> VideoActivePictureState { samples += 1; return result }
    func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to seconds: TimeInterval) async {}
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView { output }
}
