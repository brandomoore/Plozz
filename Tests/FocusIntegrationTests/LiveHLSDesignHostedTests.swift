import CoreModels
import CoreUI
import EnginePlozzigen
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class LiveHLSDesignHostedTests: XCTestCase {
    func testLivePlaybackButtonMatchesOnDemandWithMenuOpen() async throws {
        try await comparePlaybackButtons(menuOpen: true)
    }

    func testLivePlaybackButtonMatchesOnDemandWhenFocused() async throws {
        try await comparePlaybackButtons(menuOpen: false)
    }

    private func comparePlaybackButtons(menuOpen: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.makeKeyAndVisible()
        let input = LiveChannelInput.stream(url: try XCTUnwrap(URL(string: "https://fixture.invalid/live.m3u8")), httpHeaders: [:])
        let tracks = LiveChannelPlayerModel(engine: try PlozzigenVideoEngine(), input: input)
        defer {
            PlayerScreenshotHook.pendingPanel = nil
            LiveChannelScreenshotHook.pendingSurface = nil
            tracks.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        for backdrop in [Color.black, .white] {
            // Make More the sole VOD control regardless of simulator audio settings.
            let audio = SystemPlaybackAudio(backend: SystemPlaybackAudioPreferences(readState: { .init(values: [:]) }))
            let model = PlayerControlsModel(systemAudio: audio)
            model.controlsVisible = true
            model.duration = 3600
            model.currentSeconds = 600
            model.engineCapabilities = [.videoZoom]
            PlayerScreenshotHook.pendingPanel = menuOpen ? .playback : nil
            host.rootView = AnyView(
                PlayerControls(model: model, palette: .dark, actions: .init(), onExitToSurface: {})
                    .environment(\.plozzReducePanelGlass, false)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .background(backdrop)
            )
            try await Task.sleep(for: .milliseconds(1800))
            let referenceFrame = try XCTUnwrap(model.subtitleLayout.frame(for: .trackControls))
            XCTAssertEqual(model.trackControlCategories, [.playback])
            try assertFocus(window, controls: referenceFrame, menuOpen: menuOpen)
            let reference = try buttonSnapshot(window, frame: referenceFrame, name: "vod-menu-\(menuOpen)-\(backdrop)")

            LiveChannelScreenshotHook.pendingSurface = menuOpen ? .playback : nil
            host.rootView = AnyView(
                LiveHLSDesignFixture(
                    input: input, tracks: tracks, showsDiagnostics: false,
                    canGoLive: false, backdrop: backdrop, initialFocus: .playback
                )
                    .tint(ThemePalette.dark.accent)
                    .environment(\.playerCardMetrics, .tv)
                    .environment(\.plozzReducePanelGlass, false)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
            try await Task.sleep(for: .milliseconds(1800))
            // Live may also offer Audio; More is the trailing native button.
            let row = try XCTUnwrap(tracks.subtitles.controlsLayout.frame(for: .trackControls))
            let liveFrame = CGRect(x: row.maxX - referenceFrame.width, y: row.minY,
                                   width: referenceFrame.width, height: row.height)
            try assertFocus(window, controls: liveFrame, menuOpen: menuOpen)
            let live = try buttonSnapshot(window, frame: liveFrame, name: "live-menu-\(menuOpen)-\(backdrop)")
            XCTAssertEqual(live.darkPixels, reference.darkPixels, accuracy: 100,
                           "The selected Live TV glyph must retain the same contrast as on-demand playback.")
            XCTAssertEqual(live.meanLuminance, reference.meanLuminance, accuracy: 0.08,
                           "The Live TV guide's accent must not recolor native playback buttons.")
        }
    }

    private func assertFocus(_ window: UIWindow, controls: CGRect, menuOpen: Bool) throws {
        let item = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        var environment: (any UIFocusEnvironment)? = item
        var focusFrame: CGRect?
        while let current = environment {
            if let container = current.focusItemContainer {
                focusFrame = container.coordinateSpace.convert(item.frame, to: window)
                break
            }
            environment = current.parentFocusEnvironment
        }
        let frame = try XCTUnwrap(focusFrame)
        if menuOpen {
            XCTAssertLessThan(frame.maxY, controls.minY, "Native focus must enter the menu above the buttons.")
        } else {
            XCTAssertTrue(controls.contains(CGPoint(x: frame.midX, y: frame.midY)),
                          "Compare the same native focus highlight on both playback buttons.")
        }
    }

    private func buttonSnapshot(
        _ window: UIWindow, frame: CGRect, name: String
    ) throws -> (darkPixels: Double, meanLuminance: Double) {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
            x: frame.midX - 24, y: frame.midY - 18, width: 48, height: 36
        ).integral))
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        let luminance = stride(from: 0, to: bytes.count, by: 4).map {
            (Double(bytes[$0]) * 0.2126 + Double(bytes[$0 + 1]) * 0.7152 + Double(bytes[$0 + 2]) * 0.0722) / 255
        }
        return (
            Double(luminance.filter { $0 < 0.25 }.count),
            luminance.reduce(0, +) / Double(luminance.count)
        )
    }

    func testLiveWindowAndDiagnosticsRemainVisible() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.makeKeyAndVisible()
        let input = LiveChannelInput.stream(url: try XCTUnwrap(URL(string: "https://fixture.invalid/live.m3u8")), httpHeaders: [:])
        let tracks = LiveChannelPlayerModel(engine: try PlozzigenVideoEngine(), input: input)
        defer {
            tracks.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for showsDiagnostics in [false, true] {
            host.rootView = AnyView(
                LiveHLSDesignFixture(input: input, tracks: tracks, showsDiagnostics: showsDiagnostics)
                    .environment(\.playerCardMetrics, .tv)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .transaction { $0.disablesAnimations = true }
            )
            window.layoutIfNeeded()
            window.setNeedsFocusUpdate()
            window.updateFocusIfNeeded()
            let deadline = ContinuousClock.now + .seconds(3)
            while UIFocusSystem.focusSystem(for: window)?.focusedItem == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = showsDiagnostics ? "live-hls-playback-info" : "live-hls-rewind-timeline"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

private struct LiveHLSDesignFixture: View {
    let input: LiveChannelInput
    let tracks: LiveChannelPlayerModel
    let showsDiagnostics: Bool
    var canGoLive = true
    var backdrop = Color(white: 0.08)
    var initialFocus: LiveChannelControl = .timeline
    private let now = Date()
    @FocusState private var focus: LiveChannelControl?

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            LiveChannelOverlay(
                title: "Sample Channel", logoURL: nil, plozzChannelID: nil, channelID: "sample",
                input: input,
                program: .init(title: "Evening News", start: now.addingTimeInterval(-900), end: now.addingTimeInterval(900)),
                earlierPrograms: [
                    .init(title: "World Report", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800)),
                    .init(title: "Weather", start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(-900))
                ],
                libraryItem: nil, openLibraryItem: nil, phase: .playing,
                isAtLiveEdge: false, behindLiveSeconds: 1200, canPause: true, canGoLive: canGoLive,
                seekWindowSeconds: 3600, onSeekBy: { _ in }, onSeekBehindLive: { _ in },
                focus: $focus, onClose: {}, onPrevious: {}, onPlayPause: {}, onGoLive: {}, onNext: {},
                onMultiview: {}, guideContent: nil, pendingGuideOpen: false, consumeGuideOpen: {},
                onGuideCardChange: { _ in }, loadOnNow: { [] }, onTuneChannel: nil,
                tracks: tracks, diagnosticsEnabled: showsDiagnostics, toggleDiagnostics: {},
                onTracksPresentationChange: { _ in }, onControlActivity: {}, onDismissControls: {}
            )
            if showsDiagnostics {
                PlaybackDiagnosticsOverlay(diagnostics: diagnostics)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .onAppear { focus = .timeline }
        .task {
            guard initialFocus != .timeline else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            focus = initialFocus
        }
    }

    private var diagnostics: PlaybackDiagnostics {
        var result = PlaybackDiagnostics()
        result.mode = .directPlay
        result.engineName = "AetherEngine v7.44.0"
        result.sourceProvider = .iptv
        result.serverName = "Sample IPTV"
        result.resolution = .init(width: 1920, height: 1080)
        result.videoCodec = "H.264"
        result.frameRate = 25
        result.audioCodec = "AAC"
        result.audioChannels = 2
        result.liveStream = .init(
            route: "Native HLS (AVPlayer)", playlistType: "LIVE",
            behindLiveSeconds: 1200, windowSeconds: 3600, programDate: now.addingTimeInterval(-1200),
            startupSeconds: 1.2, tuneToFirstFrameSeconds: 1.8,
            variantSwitches: 1, segmentRequests: 42, bytesTransferred: 32_000_000, overdueSegments: 0
        )
        result.liveStream?.variantWidth = 1920
        result.liveStream?.variantHeight = 1080
        result.liveStream?.variantBitrate = 5_000_000
        return result
    }
}
