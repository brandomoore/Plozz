#if os(iOS)
import AVFoundation
import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class VideoSafeAreaPresentationTests: XCTestCase {
    func testAutoCropUsesAllSafeWidthAndRetainsItsSeparatePictureFitting() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = VideoSafeAreaTestWindow(windowScene: scene)
        let engine = SafeAreaVideoEngine()
        engine.supportsActivePictureAnalysis = true
        let zoom = PlayerVideoZoomModel()
        zoom.supportsActivePicture = true
        zoom.settings.mode = .picture
        let viewport = VideoSubtitleViewport()
        let host = UIHostingController(rootView: VideoSafeAreaFixture(engine: engine, zoom: zoom, viewport: viewport))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { viewport.videoRect != nil }
        let video = try XCTUnwrap(firstView(VideoPresentationView.self, in: host.view))
        let layer = engine.output.layer
        for (size, insets) in [
            (CGSize(width: 874, height: 402), UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)),
            (CGSize(width: 844, height: 390), UIEdgeInsets(top: 0, left: 44, bottom: 21, right: 0)),
            (CGSize(width: 844, height: 390), UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 44)),
            (CGSize(width: 1366, height: 1024), UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0))
        ] {
            window.testInsets = insets
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            video.safeAreaInsetsDidChange()
            zoom.settings.mode = .picture
            try await waitUntil {
                window.layoutIfNeeded()
                guard video.bounds.size == size, let safe = video.fitBounds,
                      let picture = video.activePictureRect else { return false }
                return abs(picture.width - safe.width) < 0.001
                    && abs(picture.height / picture.width - 0.75 * 9 / 16) < 0.001
            }
            let safe = try XCTUnwrap(video.fitBounds)
            let picture = try XCTUnwrap(video.activePictureRect)
            let source = try XCTUnwrap(SubtitleOverlayGeometry.aspectFitRect(
                in: engine.output.bounds, aspectRatio: 16 / 9
            ))
            assertRect(engine.output.convert(source.insetBy(dx: 0, dy: source.height * 0.125), to: video),
                       equals: picture)
            XCTAssertEqual(picture.minX, safe.minX, accuracy: 0.001)
            XCTAssertEqual(picture.maxX, safe.maxX, accuracy: 0.001)
            XCTAssertEqual(picture.midY, video.bounds.midY, accuracy: 0.001)
            XCTAssertEqual(video.fitBounds?.height, size.height, "The home indicator must not shrink landscape video.")
            let normal = try XCTUnwrap(PlayerVideoZoom().videoRect(
                in: video.bounds, aspectRatio: 16 / 9, fitBounds: safe
            ))
            if size.width < 1000 {
                XCTAssertGreaterThan(picture.width, normal.width)
            }
            zoom.setPinchZoom(fillsScreen: true)
            try await waitUntil {
                window.layoutIfNeeded()
                guard let rect = video.videoRect else { return false }
                return rect.insetBy(dx: -0.001, dy: -0.001).contains(video.bounds)
                    && abs(min(rect.width / size.width, rect.height / size.height) - 1) < 0.001
            }
            zoom.settings.mode = .picture
            try await waitUntil {
                window.layoutIfNeeded()
                return video.activePictureRect.map { self.rect($0, matches: picture) } ?? false
            }
            XCTAssertTrue(engine.output.layer === layer)
            XCTAssertTrue(engine.transportCalls.isEmpty)
        }
    }

    func testFirstLiveFrameUsesItsLateDimensionsWithoutChangingZoom() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = VideoSafeAreaTestWindow(windowScene: scene)
        window.testInsets = UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)
        let engine = SafeAreaVideoEngine()
        engine.videoAspectRatio = nil
        engine.liveSnapshot.firstFrameReady = false
        let host = UIHostingController(rootView: LiveChannelPlayerView(
            channelID: "late-dimensions", title: "Live channel",
            streamURL: URL(string: "https://fixture.invalid/live.m3u8")!, logoURL: nil,
            makeEngine: { engine }, onPreviousChannel: {}, onNextChannel: {},
            isFavorite: false, canToggleFavorite: false, onToggleFavorite: {}
        ).environment(\.scenePhase, .active))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil("Live output must mount before dimensions arrive") {
            window.layoutIfNeeded()
            guard let video = self.firstView(VideoPresentationView.self, in: host.view) else { return false }
            return engine.output.isDescendant(of: video) && engine.output.bounds.width > 0
                && engine.transportCalls.contains("loadLive")
        }
        let video = try XCTUnwrap(firstView(VideoPresentationView.self, in: host.view))
        let layer = engine.output.layer
        let initialCalls = engine.transportCalls
        engine.videoAspectRatio = 16 / 9
        engine.liveSnapshot.firstFrameReady = true
        let expected = try XCTUnwrap(PlayerVideoZoom().videoRect(
            in: video.bounds, aspectRatio: 16 / 9, fitBounds: video.fitBounds
        ))
        func usesExpectedGeometry() -> Bool {
            window.layoutIfNeeded()
            guard let actual = video.videoRect else { return false }
            return self.rect(actual, matches: expected)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !usesExpectedGeometry(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(usesExpectedGeometry(),
                      "Normal must refresh without a zoom change: actual=\(String(describing: video.videoRect)) "
                          + "expected=\(expected) bounds=\(video.bounds) fit=\(String(describing: video.fitBounds)) "
                          + "aspect=\(String(describing: video.sourceAspectRatio)) calls=\(engine.transportCalls)")
        let source = try XCTUnwrap(SubtitleOverlayGeometry.aspectFitRect(
            in: engine.output.bounds, aspectRatio: 16 / 9
        ))
        let initialPicture = engine.output.convert(source, to: video)
        assertRect(initialPicture, equals: expected)
        video.update(zoom: PlayerVideoZoom(mode: .fill), fitsInsideSafeArea: false)
        video.update(zoom: PlayerVideoZoom(), fitsInsideSafeArea: false)
        assertRect(engine.output.convert(source, to: video), equals: initialPicture)
        XCTAssertTrue(engine.output.layer === layer)
        XCTAssertEqual(engine.transportCalls, initialCalls)
    }

    func testHostedWindowInsetsAndSubtitleCoordinatesAcrossPhoneAndTabletViewports() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = VideoSafeAreaTestWindow(windowScene: scene)
        let engine = SafeAreaVideoEngine()
        let zoom = PlayerVideoZoomModel()
        let viewport = VideoSubtitleViewport()
        let host = UIHostingController(rootView: VideoSafeAreaFixture(engine: engine, zoom: zoom, viewport: viewport))
        // Emulates the fullscreen SwiftUI video host. The window remains the
        // authoritative inset source even when the hosting view ignores them.
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil {
            guard let video = self.firstView(VideoPresentationView.self, in: host.view) else { return false }
            return engine.output.isDescendant(of: video) && viewport.videoRect != nil
        }
        let video = try XCTUnwrap(firstView(VideoPresentationView.self, in: host.view))
        let marker = try XCTUnwrap(firstView(VideoSubtitleViewportView.self, in: host.view))
        let outputLayer = engine.output.layer
        let outputParent = try XCTUnwrap(engine.output.superview)

        let cases: [(CGSize, UIEdgeInsets)] = [
            (CGSize(width: 390, height: 844), UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)),
            (CGSize(width: 844, height: 390), UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 0)),
            (CGSize(width: 844, height: 390), UIEdgeInsets(top: 0, left: 0, bottom: 21, right: 59)),
            (CGSize(width: 844, height: 390), UIEdgeInsets(top: 17, left: 63, bottom: 29, right: 11)),
            (CGSize(width: 1024, height: 1366), .zero),
            (CGSize(width: 1366, height: 1024), UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0))
        ]
        for (size, insets) in cases {
            host.traitOverrides.userInterfaceIdiom = size.width >= 1000 ? .pad : .phone
            window.testInsets = insets
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            video.safeAreaInsetsDidChange()
            window.layoutIfNeeded()
            try await waitUntil {
                window.layoutIfNeeded()
                return video.bounds.size == size && marker.bounds.width > 0
            }
            let subtitleFrame = marker.convert(marker.bounds, to: window)
            for setting in [
                PlayerVideoZoom(), PlayerVideoZoom(mode: .fill),
                PlayerVideoZoom(mode: .custom, customPercent: 100),
                PlayerVideoZoom(mode: .custom, customPercent: 150)
            ] {
                if setting.mode == .fit {
                    zoom.setPinchZoom(fillsScreen: false, platform: size.width >= 1000 ? .tablet : .phone)
                } else {
                    zoom.settings = setting
                }
                var safe = video.convert(window.bounds.inset(by: insets), from: window)
                    .intersection(video.bounds.inset(by: video.safeAreaInsets))
                if size.width > size.height {
                    safe = CGRect(x: safe.minX, y: 0, width: safe.width, height: size.height)
                }
                let expected = try XCTUnwrap(setting.videoRect(
                    in: video.bounds, aspectRatio: engine.videoAspectRatio, fitBounds: safe,
                    fillsWidth: size.width < 1000
                ))
                try await waitUntil {
                    window.layoutIfNeeded()
                    guard let actual = video.videoRect, let subtitle = viewport.videoRect else { return false }
                    return self.rect(actual, matches: expected)
                        && self.rect(subtitle, matches: video.convert(expected, to: marker))
                }
                let source = try XCTUnwrap(SubtitleOverlayGeometry.aspectFitRect(
                    in: engine.output.bounds, aspectRatio: 16 / 9
                ))
                assertRect(engine.output.convert(source, to: video), equals: expected)
                let subtitle = try XCTUnwrap(viewport.videoRect)
                let expectedSubtitle = video.convert(expected, to: marker)
                assertRect(subtitle, equals: expectedSubtitle)
                let image = SubtitleOverlayGeometry.bitmapRect(
                    normalizedRect: CGRect(x: 0.15, y: 0.65, width: 0.5, height: 0.15),
                    canvasSize: CGSize(width: 1920, height: 1080), videoRect: subtitle
                )
                assertRect(image, equals: CGRect(
                    x: expectedSubtitle.minX + expectedSubtitle.width * 0.15,
                    y: expectedSubtitle.minY + expectedSubtitle.height * 0.65,
                    width: expectedSubtitle.width * 0.5, height: expectedSubtitle.height * 0.15
                ))
                let authoredOrigin = SubtitleOverlayGeometry.anchoredOrigin(
                    anchor: CGPoint(x: 0.5, y: 0.5), alignment: .topLeft,
                    contentSize: CGSize(width: 10, height: 10), videoRect: subtitle, limits: marker.bounds
                )
                XCTAssertEqual(authoredOrigin.x, expectedSubtitle.midX, accuracy: 0.001)
                XCTAssertEqual(authoredOrigin.y, expectedSubtitle.midY, accuracy: 0.001)
                XCTAssertTrue(engine.output.superview === outputParent)
                XCTAssertTrue(engine.output.isDescendant(of: video))
                XCTAssertTrue(engine.output.layer === outputLayer)
                assertRect(marker.convert(marker.bounds, to: window), equals: subtitleFrame)
                XCTAssertTrue(engine.transportCalls.isEmpty)
                XCTAssertEqual(engine.currentTime, 10)
                XCTAssertEqual(engine.output.bounds.size, video.bounds.size)
                if setting.mode == .fit {
                    if size.width > size.height && size.width < 1000 {
                        XCTAssertEqual(expected.minX, safe.minX, accuracy: 0.001)
                        XCTAssertEqual(expected.maxX, safe.maxX, accuracy: 0.001)
                        XCTAssertEqual(expected.height, safe.width * 9 / 16, accuracy: 0.001)
                        XCTAssertLessThan(expected.minY, video.bounds.minY)
                        XCTAssertGreaterThan(expected.maxY, video.bounds.maxY)
                    } else {
                        XCTAssertTrue(safe.insetBy(dx: -0.001, dy: -0.001).contains(expected))
                    }
                    if size.width > size.height {
                        XCTAssertEqual(expected.midY, video.bounds.midY, accuracy: 0.001)
                    }
                }
                if setting.mode == .fill {
                    XCTAssertTrue(expected.insetBy(dx: -0.001, dy: -0.001).contains(video.bounds))
                }
            }
        }
    }

    func testSafeAreaOptInDoesNotChangeInlineOrExternalPresentation() throws {
        let window = VideoSafeAreaTestWindow(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        window.testInsets = UIEdgeInsets(top: 0, left: 63, bottom: 21, right: 0)
        let video = VideoPresentationView(frame: window.bounds)
        let engine = SafeAreaVideoEngine()
        window.addSubview(video)
        video.attach(engine)
        video.layoutIfNeeded()
        let normal = try XCTUnwrap(PlayerVideoZoom().videoRect(in: video.bounds, aspectRatio: 16 / 9))
        assertRect(try XCTUnwrap(video.videoRect), equals: normal)
        video.update(zoom: PlayerVideoZoom(), fitsInsideSafeArea: true)
        XCTAssertNotEqual(video.videoRect, normal)
        engine.continuesPlaybackInBackground = true
        video.update(zoom: PlayerVideoZoom(), fitsInsideSafeArea: true)
        assertRect(try XCTUnwrap(video.videoRect), equals: normal)
        XCTAssertNil(video.fitBounds)
        engine.continuesPlaybackInBackground = false
        video.update(zoom: PlayerVideoZoom(), fitsInsideSafeArea: true)
        XCTAssertNotEqual(video.videoRect, normal)
        video.update(zoom: PlayerVideoZoom(), fitsInsideSafeArea: false)
        assertRect(try XCTUnwrap(video.videoRect), equals: normal)
        XCTAssertTrue(engine.transportCalls.isEmpty)
    }

    private func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = firstView(type, in: child) { return match }
        }
        return nil
    }

    private func rect(_ actual: CGRect, matches expected: CGRect) -> Bool {
        abs(actual.minX - expected.minX) < 0.001 && abs(actual.minY - expected.minY) < 0.001
            && abs(actual.width - expected.width) < 0.001 && abs(actual.height - expected.height) < 0.001
    }

    private func assertRect(
        _ actual: CGRect, equals expected: CGRect, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(rect(actual, matches: expected), "\(actual) != \(expected)", file: file, line: line)
    }

    private func waitUntil(
        _ message: String = "Video/subtitle safe-area geometry did not settle.",
        file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }
}

private struct VideoSafeAreaFixture: View {
    let engine: SafeAreaVideoEngine
    let zoom: PlayerVideoZoomModel
    let viewport: VideoSubtitleViewport

    var body: some View {
        ZStack {
            VideoSurfaceContainer(
                engine: engine, zoom: zoom.settings, fitsInsideSafeArea: true, subtitleViewport: viewport
            )
            .ignoresSafeArea()
            Color.clear
                .background(VideoSubtitleViewportReader(viewport: viewport))
                .padding(EdgeInsets(top: 13, leading: 17, bottom: 19, trailing: 23))
        }
        .ignoresSafeArea()
    }
}

private final class VideoSafeAreaTestWindow: UIWindow {
    var testInsets = UIEdgeInsets.zero
    override var safeAreaInsets: UIEdgeInsets { testInsets }
}

@MainActor
private final class SafeAreaVideoEngine: LiveChannelEngine, PictureInPicturePresentingEngine {
    let output = UIView()
    var videoAspectRatio: Double? = 16 / 9
    var supportsActivePictureAnalysis = false
    var activePictureSourceID: UUID? = UUID()
    func sampleActivePicture() async -> VideoActivePictureState {
        .measured(normalizedRect: CGRect(x: 0, y: 0.125, width: 1, height: 0.75),
                  displaySize: CGSize(width: 320, height: 180))
    }
    var transportCalls: [String] = []
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
    var continuesPlaybackInBackground = false
    var externalPlaybackRouteName: String?
    var onPresentationLayerChanged: (() -> Void)?
    var onLiveSourceReset: (@MainActor () -> Void)?
    var liveSnapshot = LiveChannelEngineSnapshot(
        phase: .playing, firstFrameReady: true, position: 10,
        bufferedPosition: 20, seekableRange: 0...20, route: .nativeHLS
    )
    func loadLive(url: URL, httpHeaders: [String: String]) async { transportCalls.append("loadLive") }
    func seekToLiveEdge() async { transportCalls.append("liveEdge") }
    func load(request: PlaybackRequest, startPosition: TimeInterval) async { transportCalls.append("load") }
    func play() { transportCalls.append("play") }
    func pause() { transportCalls.append("pause") }
    func stop() { transportCalls.append("stop") }
    func seek(to seconds: TimeInterval) async { transportCalls.append("seek") }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView { output }
    func pictureInPicturePlayerLayer() -> AVPlayerLayer? { nil }
    func setPictureInPictureActive(_ active: Bool) { continuesPlaybackInBackground = active }
    func setNativeSubtitlesActive(_ active: Bool) {}
}
#endif
