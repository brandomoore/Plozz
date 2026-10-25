#if os(iOS)
@testable import AppShelliOS
import CoreModels
import CoreUI
import EnginePlozzigen
@testable import FeaturePlayback
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class PlayerTransportPositionTests: XCTestCase {
    func testLivePresentationControlsWithoutExternalRoutesHaveNoStopButtonOrEmptyPill() async throws {
        let engine = try PlozzigenVideoEngine()
        defer { engine.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for permitsExternalPresentation in [true, false] {
            var invalidate: (@MainActor () -> Void)?
            let context = LiveChannelPresentationContext(
                engine: engine, sessionID: UUID(),
                permitsExternalPresentation: permitsExternalPresentation,
                isVisible: true, showsControls: true, intendsPlayback: false,
                hasSelectedSubtitle: false,
                continuationChanged: { _ in }, restoreUI: { true },
                registerInvalidation: { invalidate = $0 },
                stopPlayback: { XCTFail("Presentation controls must not stop playback.") }
            )
            let host = UIHostingController(rootView: PlozziOSLivePresentationControls(context: context))
            host.safeAreaRegions = []
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let size = host.sizeThatFits(in: CGSize(width: 400, height: 100))
            XCTAssertEqual(size.width, 0, accuracy: 0.5, "No Stop button or empty glass group may remain.")
            XCTAssertEqual(size.height, 0, accuracy: 0.5)
            XCTAssertNotNil(invalidate, "The presentation lifecycle must stay mounted without visible controls.")
            invalidate?()
            window.rootViewController = nil
        }
    }

    func testVODCaptionsClearTheActualCenterControlsOrRetainTheirOriginalPosition() async throws {
        let model = PlayerViewModel(provider: LayoutProvider(), itemID: "fixture")
        model.controls.duration = 1200
        model.controls.intendsPause = true
        model.controls.title = "A title"
        try await assertCaptionAvoidance(
            model: model.liveSubtitles, layout: model.controls.subtitleLayout, label: "VOD", supportsDual: true,
            captions: LiveSubtitleOverlay(model: model.liveSubtitles, controls: model.controls),
            chrome: PlozziOSPlayerControlsOverlay(
                viewModel: model, keyboardActions: PlozziOSPlayerKeyboardActions(),
                hasVersions: false, versionsPresented: false, onShowVersions: {}, onClose: {}
            )
        )
    }

    func testLiveCaptionsClearTheActualCenterControlsOrRetainTheirOriginalPosition() async throws {
        let input = LiveChannelInput.stream(
            url: try XCTUnwrap(URL(string: "https://fixture.invalid/live.m3u8")), httpHeaders: [:]
        )
        let tracks = LiveChannelPlayerModel(engine: try PlozzigenVideoEngine(), input: input)
        defer { tracks.stop() }
        for hasProgram in [true, false] {
            try await assertCaptionAvoidance(
                model: tracks.subtitles, layout: tracks.subtitles.controlsLayout,
                label: hasProgram ? "Live" : "Channel only", supportsDual: false,
                captions: LiveChannelSubtitleSurface(model: tracks),
                chrome: LiveLayoutFixture(input: input, tracks: tracks, hasProgram: hasProgram)
            )
        }
    }

    private func assertCaptionAvoidance(
        model: LiveSubtitleModel, layout: SubtitleControlsLayout, label: String, supportsDual: Bool,
        captions: some View, chrome: some View
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let visibility = CaptionChromeVisibility()
        let host = UIHostingController(rootView: CaptionAvoidanceFixture(
            visibility: visibility, captions: captions, chrome: chrome
        ))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func captionFrames(in view: UIView) -> [CGRect] {
            if let line = view as? SubtitleLineView { return [line.convert(line.bounds, to: window)] }
            return view.subviews.flatMap { captionFrames(in: $0) }
        }
        func captionBounds() throws -> CGRect {
            let frames = captionFrames(in: host.view)
            XCTAssertFalse(frames.isEmpty)
            return frames.reduce(CGRect.null) { $0.union($1) }
        }
        let sizes = [
            CGSize(width: 956, height: 440), CGSize(width: 440, height: 956),
            CGSize(width: 568, height: 320), CGSize(width: 320, height: 568),
            CGSize(width: 1024, height: 768), CGSize(width: 768, height: 1024)
        ]
        for mode in supportsDual ? ["single", "dual", "no-room"] : ["single", "no-room"] {
            model.style.followsSystemStyle = false
            model.style.fontFamily = .system
            model.style.fontScale = mode == "no-room" ? 4 : 1
            model.style.verticalPosition = 0.06
            model.style.secondary = mode == "dual" ? .init() : nil
            let text = mode == "no-room" ? "Larger subtitle\nLarger subtitle" : "A visible subtitle."
            model.loadPrimary(SubtitleCueParser.parse("WEBVTT\n\n00:00:00.000 --> 00:01:00.000\n\(text)\n", id: 1))
            model.loadSecondary(mode == "dual"
                ? SubtitleCueParser.parse("WEBVTT\n\n00:00:00.000 --> 00:01:00.000\nAnother subtitle.\n", id: 2)
                : nil)
            model.tick(1)
            let originalStyle = model.style
            for size in mode == "no-room" ? [sizes[0]] : sizes {
                visibility.visible = false
                window.frame = CGRect(origin: .zero, size: size)
                host.view.frame = window.bounds
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                let original = try captionBounds()
                XCTAssertEqual(captionFrames(in: host.view).count, mode == "dual" ? 2 : 1)
                XCTAssertTrue(layout.frames.isEmpty)
                visibility.visible = true
                try await Task.sleep(for: .milliseconds(500))
                window.layoutIfNeeded()
                let center = try XCTUnwrap(layout.frame(for: .centerTransport))
                let moved = try captionBounds()
                let expectedHeight: CGFloat = PlayerTouchLayout.usesCompactTransport(in: size) ? 44 : 92
                XCTAssertEqual(center.height, expectedHeight, accuracy: 1, "\(label) must use the shared transport geometry.")
                for region in [SubtitleControlsLayout.Region.title, .timeline] {
                    let frame = try XCTUnwrap(layout.frame(for: region))
                    XCTAssertFalse(center.intersects(frame), "\(label) \(size): \(region) \(frame) overlaps \(center).")
                }
                XCTAssertLessThan(center.height, 100, "Report the actual row, never its full-screen centering container.")
                if mode == "no-room" {
                    XCTAssertGreaterThan(original.height, center.minY)
                    XCTAssertEqual(moved, original, "Insufficient room must retain the original position, not a partial lift.")
                } else {
                    XCTAssertLessThanOrEqual(moved.maxY, center.minY - SubtitleOverlayGeometry.controlsClearance + 1)
                    XCTAssertTrue(window.bounds.contains(moved))
                    XCTAssertFalse(layout.frames.contains(where: { $0.intersects(moved) }))
                    let pixel = 1 / window.screen.scale + 0.001
                    XCTAssertEqual(moved.width, original.width, accuracy: pixel)
                    XCTAssertEqual(moved.height, original.height, accuracy: pixel)
                }
                XCTAssertEqual(model.style, originalStyle)
                let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                })
                attachment.name = "\(label) \(mode) subtitles \(Int(size.width))x\(Int(size.height))"
                attachment.lifetime = .keepAlways
                add(attachment)
                visibility.visible = false
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertTrue(layout.frames.isEmpty)
                XCTAssertEqual(try captionBounds(), original)
            }
        }
    }

    @Observable final class CaptionChromeVisibility {
        var visible = false
    }

    private struct CaptionAvoidanceFixture<Captions: View, Chrome: View>: View {
        let visibility: CaptionChromeVisibility
        let captions: Captions
        let chrome: Chrome

        var body: some View {
            ZStack {
                Color.black
                captions
                if visibility.visible { chrome }
            }
            .environment(\.themePalette, .light)
            .environment(\.colorScheme, .light)
            .ignoresSafeArea()
        }
    }

    func testScrubPreviewGrowsWithoutMovingTheTimelineInPhoneAndTabletWindows() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let model = PlayerViewModel(provider: LayoutProvider(), itemID: "fixture")
        model.controls.duration = 1200
        model.controls.currentSeconds = 600
        model.controls.title = "A title"
        model.controls.subtitle = "Season 1, Episode 2"
        let thumbnail = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).image { context in
            UIColor.cyan.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        }.cgImage)
        let host = UIHostingController(rootView: ScrubLayoutFixture(model: model, thumbnail: thumbnail))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for size in [
            CGSize(width: 956, height: 440), CGSize(width: 440, height: 956),
            CGSize(width: 568, height: 320), CGSize(width: 320, height: 568),
            CGSize(width: 1024, height: 768), CGSize(width: 768, height: 1024)
        ] {
            model.controls.isScrubbing = false
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let original = try XCTUnwrap(model.controls.subtitleLayout.frame(for: .timeline))
            model.controls.isScrubbing = true
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(model.controls.subtitleLayout.frame(for: .timeline), original)
            XCTAssertNil(model.controls.subtitleLayout.frame(for: .title))
            XCTAssertNil(model.controls.subtitleLayout.frame(for: .trackControls))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Larger scrub preview \(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
            let bitmap = try pixels(image)
            var minX = Int(size.width), minY = Int(size.height), maxX = 0, maxY = 0
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    let i = (y * Int(size.width) + x) * 4
                    if bitmap[i] < 80, bitmap[i + 1] > 200, bitmap[i + 2] > 200 {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            let preview = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            let expected = PlayerTouchLayout.scrubPreviewSize(availableSize: size)
            XCTAssertGreaterThan(preview.width, 240, "The rendered preview must be larger than the former 240-point preview.")
            XCTAssertEqual(preview.width, expected.width, accuracy: 2)
            XCTAssertEqual(preview.height, expected.height, accuracy: 2)
            XCTAssertGreaterThanOrEqual(preview.minX, 0)
            XCTAssertGreaterThanOrEqual(preview.minY, 0)
            XCTAssertLessThanOrEqual(preview.maxX, size.width)
            XCTAssertLessThan(preview.maxY, original.minY, "The thumbnail must never cover the bar or timestamps.")
            for columns in [21..<64, (Int(size.width) - 64)..<(Int(size.width) - 21)] {
                let ink = (Int(original.minY)..<Int(original.maxY)).flatMap { y in
                    columns.map { x in bitmap[(y * Int(size.width) + x) * 4] }
                }
                XCTAssertGreaterThan(ink.max() ?? 0, 200, "Scrubbing must not dim the timestamp labels.")
            }
            model.controls.isScrubbing = false
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(model.controls.subtitleLayout.frame(for: .timeline), original)
            XCTAssertNotNil(model.controls.subtitleLayout.frame(for: .title))
        }
    }

    func testTransportIsCenteredOnTheVideoAfterResizing() async throws {
        let model = PlayerViewModel(provider: LayoutProvider(), itemID: "fixture")
        model.controls.duration = 3600
        model.controls.currentSeconds = 600
        model.controls.title = "A title"
        model.controls.subtitle = "Season 1, Episode 2"
        model.controls.intendsPause = true
        try await assertCentered(
            PlozziOSPlayerControlsOverlay(
                viewModel: model, keyboardActions: PlozziOSPlayerKeyboardActions(),
                hasVersions: false, versionsPresented: false, onShowVersions: {}, onClose: {}
            ), label: "VOD", bottomFrame: { model.controls.subtitleLayout.frame(for: .transport) }
        )
    }

    func testLiveTransportUsesTheSameVideoCenterInPortraitAndLandscape() async throws {
        let input = LiveChannelInput.stream(
            url: try XCTUnwrap(URL(string: "https://fixture.invalid/live.m3u8")), httpHeaders: [:]
        )
        let tracks = LiveChannelPlayerModel(engine: try PlozzigenVideoEngine(), input: input)
        defer { tracks.stop() }
        try await assertCentered(
            LiveLayoutFixture(input: input, tracks: tracks), label: "Live",
            bottomFrame: {
                [SubtitleControlsLayout.Region.title, .trackControls]
                    .compactMap { tracks.subtitles.controlsLayout.frame(for: $0) }
                    .reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
            }
        )
    }

    func testLiveTrackControlsStayAtTheBottomTrailingEdgeAboveTheTimeline() async throws {
        for hasProgram in [false, true] {
            try await assertLiveTrackControls(hasProgram: hasProgram, opensMenu: false)
        }
    }

    func testLiveTrackMenusOpenAboveTheBottomControlsWithoutCoveringTheTimeline() async throws {
        try await assertLiveTrackControls(hasProgram: true, opensMenu: true)
    }

    private func assertLiveTrackControls(hasProgram: Bool, opensMenu: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let input = LiveChannelInput.stream(
            url: try XCTUnwrap(URL(string: "https://fixture.invalid/live.m3u8")), httpHeaders: [:]
        )
        let tracks = LiveChannelPlayerModel(engine: try PlozzigenVideoEngine(), input: input)
        LiveChannelScreenshotHook.pendingSurface = opensMenu ? .playback : nil
        let host = UIHostingController(rootView: LiveLayoutFixture(
            input: input, tracks: tracks, hasProgram: hasProgram, canGoLive: false, canMultiview: true
        )
            .background(.black)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
        )
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            LiveChannelScreenshotHook.pendingSurface = nil
            tracks.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for size in [
            CGSize(width: 440, height: 956), CGSize(width: 956, height: 440),
            CGSize(width: 393, height: 852), CGSize(width: 852, height: 393),
            CGSize(width: 320, height: 568),
            CGSize(width: 768, height: 1024), CGSize(width: 1024, height: 768)
        ] {
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let layout = tracks.subtitles.controlsLayout
            if opensMenu {
                let deadline = ContinuousClock.now + .seconds(5)
                while layout.frame(for: .menu) == nil, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await Task.sleep(for: .milliseconds(300))
            }
            let controls = try XCTUnwrap(layout.frame(for: .trackControls))
            let timeline = try XCTUnwrap(layout.frame(for: .timeline))
            let title = try XCTUnwrap(layout.frame(for: .title))
            let top = try XCTUnwrap(layout.frame(for: .topControls))
            XCTAssertGreaterThanOrEqual(controls.width, 100, "Both playback options and multiview must remain.")
            XCTAssertEqual(controls.height, 44, accuracy: 1)
            XCTAssertEqual(controls.maxX, timeline.maxX, accuracy: 1, "Keep actions at the trailing edge.")
            XCTAssertEqual(controls.maxY, timeline.minY, accuracy: 1, "Place actions directly above the seek bar.")
            XCTAssertGreaterThan(controls.minY, size.height / 2)
            XCTAssertEqual(top.width, 44, accuracy: 1, "Only Close belongs in this overlay's top bar.")
            if size.height > size.width {
                XCTAssertLessThanOrEqual(title.maxY + 8, controls.minY + 1, "Portrait keeps a separate title row.")
            }
            if opensMenu {
                let menu = try XCTUnwrap(layout.frame(for: .menu))
                XCTAssertGreaterThan(menu.height, 44)
                XCTAssertGreaterThanOrEqual(menu.minY, 0)
                XCTAssertLessThanOrEqual(menu.maxY + 18, controls.minY + 1)
                XCTAssertFalse(menu.intersects(timeline))
            } else {
                let center = try XCTUnwrap(layout.frame(for: .centerTransport))
                XCTAssertLessThan(center.maxY, min(title.minY, controls.minY))
            }
            if size.width == 440 || size.width == 956 || size.width == 768 {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Live bottom actions \(Int(size.width))x\(Int(size.height)) programme \(hasProgram) menu \(opensMenu)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testChannelOnlyLiveHeaderClearsTransportInCompactAndTabletWindows() async throws {
        let input = LiveChannelInput.stream(
            url: try XCTUnwrap(URL(string: "https://fixture.invalid/live.m3u8")), httpHeaders: [:]
        )
        let tracks = LiveChannelPlayerModel(engine: try PlozzigenVideoEngine(), input: input)
        defer { tracks.stop() }
        for phase in [LiveChannelPlaybackPhase.playing, .reconnecting] {
            try await assertCentered(
                LiveLayoutFixture(input: input, tracks: tracks, hasProgram: false, phase: phase),
                label: "Channel only \(phase)", hasActivityIndicator: phase == .reconnecting,
                bottomFrame: { tracks.subtitles.controlsLayout.frame(for: .title) }
            )
        }
    }

    private func assertCentered(
        _ content: some View, label: String, hasActivityIndicator: Bool = false, bottomFrame: () -> CGRect?
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: content
            .environment(\.plozzReduceTransparency, true)
            .environment(\.themePalette, .light)
            .environment(\.colorScheme, .light)
            .background(.black)
        )
        host.safeAreaRegions = []
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for size in [
            CGSize(width: 956, height: 440), CGSize(width: 440, height: 956),
            CGSize(width: 852, height: 393), CGSize(width: 393, height: 852),
            CGSize(width: 320, height: 568),
            CGSize(width: 1024, height: 768), CGSize(width: 768, height: 1024)
        ] {
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let bottom = try XCTUnwrap(bottomFrame())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(label) centered on video \(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
            let bitmap = try pixels(image)
            func bright(x: Int, y: Int) -> Bool {
                let offset = (y * Int(size.width) + x) * 4
                return min(bitmap[offset], bitmap[offset + 1], bitmap[offset + 2]) > 180
            }
            let centerRows = (Int(size.height / 2 - 50)..<Int(size.height / 2 + 50)).filter {
                bright(x: Int(size.width / 2) + 16, y: $0)
            }
            let centerY = CGFloat(try XCTUnwrap(centerRows.first) + XCTUnwrap(centerRows.last) + 1) / 2
            XCTAssertEqual(centerY, size.height / 2, accuracy: 1.5,
                           "Transport must match the native player's video center.")
            let compact = PlayerTouchLayout.usesCompactTransport(contentHeight: size.height - 48)
            XCTAssertLessThan(centerY + (compact ? 22 : 46), bottom.minY, "Transport must stay above bottom controls.")
            let offset = compact ? 64 : Int(78 + PlayerTouchLayout.transportSpacing(
                availableWidth: size.width - 42, portrait: size.height > size.width
            ))
            for offset in hasActivityIndicator ? [-offset, offset] : [-offset, 0, offset] {
                let x = Int(size.width / 2) + offset
                let y = Int(centerY)
                let darkPixels = ((y - 15)..<(y + 15)).reduce(0) { total, row in
                    total + ((x - 15)..<(x + 15)).filter { column in
                        bitmap[(row * Int(size.width) + column) * 4] < 60
                    }.count
                }
                XCTAssertGreaterThan(darkPixels, 50, "\(label): transport icons need dark ink on light fallback.")
            }
        }
    }

    private struct ScrubLayoutFixture: View {
        let model: PlayerViewModel
        let thumbnail: CGImage

        var body: some View {
            GeometryReader { geometry in
                VStack {
                    Spacer()
                    PlozziOSPlayerTransport(
                        viewModel: model, showsTransport: true, showsUpNext: false, playbackControls: EmptyView(),
                        timelineOnly: model.controls.isScrubbing, displayedSeconds: 600,
                        isScrubbing: model.controls.isScrubbing, scrubPreviewImage: thumbnail, showsScrubPreview: true,
                        pictureInPictureAvailable: false, onTogglePictureInPicture: {},
                        onScrubChanged: { _ in }, onScrubEditingChanged: { _ in },
                        onSkipBackward: {}, onPlayPause: {}, onSkipForward: {}, onShowSpeed: {},
                        supportsVideoZoom: false, onShowCustomZoom: {}, onShowSubtitles: {},
                        onShowQuality: {}, onShowTimestamps: nil, hasVersions: false, onShowVersions: {},
                        onOptionsMenuPresentationChange: { _ in }, isCardOpen: .constant(false),
                        onInteraction: {}, availableSize: geometry.size
                    )
                }
                .modifier(PlayerTouchChromePadding())
            }
            .background(.black)
            .environment(\.themePalette, .light)
            .environment(\.colorScheme, .light)
            .ignoresSafeArea()
        }
    }

    private struct LiveLayoutFixture: View {
        let input: LiveChannelInput
        let tracks: LiveChannelPlayerModel
        var hasProgram = true
        var phase = LiveChannelPlaybackPhase.playing
        var canGoLive = true
        var canMultiview = false
        @FocusState private var focus: LiveChannelControl?
        private let now = Date()

        var body: some View {
            LiveChannelOverlay(
                title: "Sample Channel", logoURL: nil, plozzChannelID: nil, channelID: "sample", input: input,
                program: hasProgram
                    ? .init(title: "Evening News", start: now.addingTimeInterval(-900), end: now.addingTimeInterval(900))
                    : nil,
                earlierPrograms: [], libraryItem: nil, openLibraryItem: nil, phase: phase,
                isAtLiveEdge: true, behindLiveSeconds: 0, canPause: true, canGoLive: canGoLive,
                seekWindowSeconds: 3600, onSeekBy: { _ in }, onSeekBehindLive: { _ in },
                focus: $focus, onClose: {}, onPrevious: {}, onPlayPause: {}, onGoLive: {}, onNext: {},
                onMultiview: canMultiview ? {} : nil, guideContent: nil, pendingGuideOpen: false, consumeGuideOpen: {},
                onGuideCardChange: { _ in }, loadOnNow: { [] }, onTuneChannel: nil,
                tracks: tracks, diagnosticsEnabled: false, toggleDiagnostics: {},
                onTracksPresentationChange: { _ in }, onControlActivity: {}, onDismissControls: {}
            )
        }
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let image = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}

private struct LayoutProvider: MediaProvider {
    let kind = ProviderKind.jellyfin
    let session = UserSession(
        server: MediaServer(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!,
                            provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
