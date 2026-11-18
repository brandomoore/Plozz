#if os(iOS)
import CoreModels
import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class PlayerChapterPresentationTests: XCTestCase {
    func testTouchTabsKeepInfoWhenEveryOptionalTabIsHidden() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for enabled in [true, false] {
            var settings = PlaybackSettings.default
            for tab in PlayerOptionalTab.allCases {
                settings[keyPath: tab.visibilityKeyPath] = enabled
            }
            let provider = ChapterPresentationProvider()
            let episode = MediaItem(id: "episode", title: "Episode", kind: .episode, seriesID: "series")
            let player = PlayerViewModel(
                provider: provider, itemID: episode.id, episodeItem: episode, playbackSettings: settings,
                playlistContext: .init(
                    origin: .init(playlistID: "playlist", accountID: "account", index: 0, totalCount: 1, item: episode),
                    provider: provider
                )
            )
            let controls = PlayerControlsModel()
            controls.infoCard.chapters = [.init(start: 0, title: "Chapter")]
            controls.infoCard.cast = [.init(id: "person", name: "Person", role: "Character")]
            player.continueWatchingSnapshot = { [MediaItem(id: "other", title: "Other", kind: .movie)] }
            let size = CGSize(width: 1024, height: 768)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = UIHostingController(rootView:
                PlayerTouchCardStrip(
                    model: controls, availableSize: size, isCardOpen: .constant(false), player: player,
                    onRestart: {}, onNextEpisode: {}, onPreviousEpisode: {}
                )
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.themePalette, .dark)
            )
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNotNil(controls.subtitleLayout.frame(for: .tab("info")))
            for name in ["chapters", "cast", "episodes", "playlist", "continueWatching"] {
                XCTAssertEqual(controls.subtitleLayout.frame(for: .tab(name)) != nil, enabled, name)
            }
            await player.stop()
        }
    }

    func testOverflowingChaptersAlignWithTheTabsAndOpenAtTheCurrentChapter() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let player = PlayerViewModel(provider: ChapterPresentationProvider(), itemID: "fixture")
        await player.load()
        player.controls.infoCard.chapters = (0..<20).map {
            MediaChapter(start: Double($0) * 180, title: "Scene \($0 + 1)")
        }
        player.controls.duration = 3_600
        for size in [CGSize(width: 320, height: 568), .init(width: 568, height: 320), .init(width: 1024, height: 768)] {
            for chapterIndex in [0, 5] {
                player.controls.currentSeconds = Double(chapterIndex) * 180 + 10
                let probe = ChapterLayoutProbe()
                let host = UIHostingController(rootView:
                    MobileChapterFixture(
                        player: player, size: size, probe: probe,
                        backdrop: Color(red: 0.25, green: 0.45, blue: 0.65)
                    )
                        .environment(\.colorScheme, .dark)
                        .environment(\.locale, Locale(identifier: "en_US"))
                        .environment(\.plozzReduceTransparency, true)
                )
                host.safeAreaRegions = []
                window.frame = CGRect(origin: .zero, size: size)
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = window.bounds
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(500))
                let metrics = PlayerCardMetrics.resolved(forWidth: size.width, height: size.height)
                let scroll = try XCTUnwrap(scrollViews(in: host.view).first {
                    metrics.isVertical ? $0.contentSize.height > $0.bounds.height + 100
                        : $0.contentSize.width > $0.bounds.width + 100 && $0.bounds.height > 64
                })
                let frame = scroll.convert(scroll.bounds, to: window)
                XCTAssertEqual(frame.minX, probe.panelFrame.minX, accuracy: 1)
                XCTAssertEqual(frame.minY, probe.panelFrame.minY, accuracy: 1)
                XCTAssertEqual(frame.maxX, probe.panelFrame.maxX, accuracy: 1)
                XCTAssertEqual(frame.maxY, probe.panelFrame.maxY, accuracy: 1)
                let infoTab = try XCTUnwrap(player.controls.subtitleLayout.frame(for: .tab("info")))
                XCTAssertEqual(frame.minX, infoTab.minX, accuracy: 1, "Cards must share the tab strip's leading edge.")

                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLevel = .accurate
                recognition.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([recognition])
                let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                XCTAssertTrue(text.contains("Scene \(chapterIndex + 1)"), "The current chapter must be visible on opening: \(text)")
                if metrics.isVertical {
                    func band(_ offset: CGFloat) -> CGRect {
                        CGRect(x: size.width - 30, y: frame.minY + offset, width: 4, height: 2)
                    }
                    let backdrop = try brightestPixel(in: image, rect: band(-6))
                    let top = try brightestPixel(in: image, rect: band(2))
                    let interior = try brightestPixel(in: image, rect: band(23))
                    XCTAssertGreaterThan(Double(backdrop) - Double(top), (Double(backdrop) - Double(interior)) * 0.85,
                                         "Auto-positioning chapter \(chapterIndex + 1) must not fade its opening row.")
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Overflowing chapters \(Int(size.width))x\(Int(size.height)) start \(chapterIndex + 1)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        await player.stop()
    }

    func testPortraitPanelSpacingAndDirectionalOverflowFades() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let player = PlayerViewModel(provider: ChapterPresentationProvider(), itemID: "fixture")
        await player.load()
        player.controls.duration = 3_600
        player.controls.title = "Fixture"
        player.controls.infoCard.overview = "A short description."
        let size = CGSize(width: 320, height: 568)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        func capture(_ name: String) -> UIImage {
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return image
        }
        for count in [3, 20] {
            player.controls.infoCard.chapters = (0..<count).map {
                .init(start: Double($0) * 180, title: "Scene \($0 + 1)")
            }
            player.controls.infoCard.cast = (0..<count).map {
                .init(id: "\($0)", name: "Person \($0 + 1)", role: "Character")
            }
            for panel in [MobileChapterTestPanel.info, .cast, .chapters] {
                let probe = ChapterLayoutProbe()
                let host = UIHostingController(rootView:
                    MobileChapterFixture(
                        player: player, size: size, probe: probe, panel: panel,
                        backdrop: Color(red: 0.25, green: 0.45, blue: 0.65)
                    )
                    .playerPlatformAppearance()
                    .environment(\.colorScheme, .dark)
                    .environment(\.plozzReduceTransparency, true)
                )
                host.safeAreaRegions = []
                window.frame = CGRect(origin: .zero, size: size)
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = window.bounds
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(500))
                let tab = try XCTUnwrap(player.controls.subtitleLayout.frame(for: .tab("info")))
                XCTAssertEqual(probe.panelFrame.minY - tab.maxY, PlayerTouchLayout.cardSpacing, accuracy: 1)

                let initial = capture("\(panel) \(count) rows at top")
                func band(_ offset: CGFloat) -> CGRect {
                    CGRect(x: size.width - 30, y: probe.panelFrame.minY + offset, width: 4, height: 2)
                }
                let backdrop = try brightestPixel(in: initial, rect: band(-6))
                let top = try brightestPixel(in: initial, rect: band(2))
                XCTAssertLessThan(Int(top), Int(backdrop) - 8,
                                  "\(panel): The first surface must start at the panel edge, without an extra top gutter.")
                guard panel != .info else { continue }
                let interior = try brightestPixel(in: initial, rect: band(23))
                XCTAssertGreaterThan(Double(backdrop) - Double(top), (Double(backdrop) - Double(interior)) * 0.85,
                                     "\(panel): The opening row must retain its surface contrast, not fade into the backdrop.")
                if count == 20 {
                    let scroll = try XCTUnwrap(scrollViews(in: host.view).first {
                        $0.contentSize.height > $0.bounds.height + 100
                    })
                    scroll.setContentOffset(CGPoint(x: 0, y: 20), animated: false)
                    try await Task.sleep(for: .milliseconds(300))
                    let scrolled = capture("\(panel) overflow fade")
                    let edge = try brightestPixel(in: scrolled, rect: band(2))
                    let middle = try brightestPixel(in: scrolled, rect: band(12))
                    let interior = try brightestPixel(in: scrolled, rect: band(23))
                    if panel == .chapters {
                        XCTAssertGreaterThan(Double(backdrop) - Double(edge),
                                             (Double(backdrop) - Double(interior)) * 0.85,
                                             "Programmatic positioning is not a user scroll.")
                    } else {
                        XCTAssertGreaterThan(Int(edge), Int(middle) + 8)
                        XCTAssertGreaterThan(Int(middle), Int(interior) + 8,
                                             "Overflow must fade progressively rather than stop at a hard clip.")
                    }
                    scroll.setContentOffset(.zero, animated: false)
                    try await Task.sleep(for: .milliseconds(300))
                    let restored = capture("\(panel) returned to top")
                    XCTAssertEqual(Double(try brightestPixel(in: restored, rect: band(2))), Double(top), accuracy: 3)
                }
            }
        }
        await player.stop()
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func brightestPixel(in image: UIImage, rect: CGRect) throws -> UInt8 {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect.integral))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
            bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(crop.width * crop.height * 4)).filter { $0 % 4 != 3 }.map { bytes[$0] }.max() ?? 0
    }

    func testChapterCardsAndConditionalTabsFitPhoneAndTabletWindows() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let player = PlayerViewModel(provider: ChapterPresentationProvider(), itemID: "fixture")
        await player.load()
        player.controls.duration = 7_200
        for size in [CGSize(width: 320, height: 568), .init(width: 568, height: 320), .init(width: 1024, height: 768)] {
            for (reduced, hasArtwork) in [(false, false), (true, false), (false, true), (true, true)] {
                let probe = ChapterLayoutProbe()
                player.controls.infoCard.chapters = [
                    .init(start: 0, title: "Opening"), .init(start: 180, title: "The journey"),
                    .init(start: 4_910, imageURL: hasArtwork ? URL(string: "https://chapters.invalid/still.jpg") : nil)
                ]
                let host = UIHostingController(rootView:
                    MobileChapterFixture(player: player, size: size, probe: probe)
                        .environment(\.plozzReducePanelGlass, reduced)
                        .environment(\.colorScheme, .dark)
                        .environment(\.locale, Locale(identifier: "en_US"))
                )
                host.safeAreaRegions = []
                window.frame = CGRect(origin: .zero, size: size)
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = window.bounds
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertGreaterThan(probe.stripHeight, 20)
                XCTAssertLessThan(probe.stripHeight, 64, "Horizontal scrolling must not expand the tab strip vertically.")
                let chapterTab = try XCTUnwrap(player.controls.subtitleLayout.frame(for: .tab("chapters")))
                XCTAssertTrue(window.bounds.contains(chapterTab))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLevel = .accurate
                recognition.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([recognition])
                let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                for expected in ["Chapters", "Opening", "The journey", "Chapter 3", "1:21:50"] {
                    XCTAssertTrue(text.localizedCaseInsensitiveContains(expected), "Missing chapter content: \(text)")
                }
                for (title, time) in [("Opening", "0:00"), ("The journey", "3:00")] {
                    let titleBox = try XCTUnwrap(recognition.results?.first {
                        $0.topCandidates(1).first?.string == title
                    }?.boundingBox)
                    let timeBox = try XCTUnwrap(recognition.results?.first {
                        $0.topCandidates(1).first?.string.contains(time) == true
                    }?.boundingBox)
                    XCTAssertEqual(titleBox.minX * size.width, timeBox.minX * size.width, accuracy: 4,
                                   "Chapter titles and timestamps must share a leading edge.")
                    let metrics = PlayerCardMetrics.resolved(forWidth: size.width, height: size.height)
                    if metrics.isVertical, title == "Opening" {
                        let leading = titleBox.minX * size.width - probe.panelFrame.minX
                        if hasArtwork {
                            XCTAssertGreaterThan(leading, metrics.castHeadshot * 16 / 9)
                        } else {
                            XCTAssertEqual(leading, metrics.contentPadding, accuracy: 4,
                                           "No artwork must mean no placeholder or reserved thumbnail column.")
                        }
                    } else if title == "Opening" {
                        let horizontalInset = hasArtwork
                            ? metrics.contentPadding + 4 : max(metrics.contentPadding, metrics.panelCornerRadius / 2)
                        XCTAssertGreaterThanOrEqual(
                            (titleBox.minX * size.width - probe.panelFrame.minX).rounded(), horizontalInset - 2
                        )
                        if hasArtwork {
                            // Vision includes extra space around glyphs; the layout probe verifies exact insets.
                            XCTAssertGreaterThanOrEqual(
                                (probe.panelFrame.maxY - (1 - timeBox.minY) * size.height).rounded(),
                                metrics.contentPadding - 4,
                                "The timestamp must stay comfortably inside the rounded bottom corner."
                            )
                        } else {
                            let captionTop = (1 - titleBox.maxY) * size.height
                            let captionBottom = (1 - timeBox.minY) * size.height
                            XCTAssertEqual((captionTop + captionBottom) / 2, probe.panelFrame.midY, accuracy: 4,
                                           "Text-only captions must be centered in the full-height horizontal card.")
                            let nextTitle = try XCTUnwrap(recognition.results?.first {
                                $0.topCandidates(1).first?.string == "The journey"
                            }?.boundingBox)
                            let cardWidth = (nextTitle.minX - titleBox.minX) * size.width - metrics.columnSpacing
                            XCTAssertLessThan(cardWidth, metrics.cardHeight,
                                              "Text-only cards must be narrow rectangles, not thumbnail-width tiles.")
                        }
                    }
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Chapters \(Int(size.width))x\(Int(size.height)) \(reduced ? "reduced" : "native") \(hasArtwork ? "mixed" : "text")"
                attachment.lifetime = .keepAlways
                add(attachment)
                player.controls.infoCard.chapters = []
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertNil(player.controls.subtitleLayout.frame(for: .tab("chapters")))
            }
        }
        await player.stop()
    }
}

@MainActor
private final class ChapterLayoutProbe {
    var stripHeight: CGFloat = 0
    var panelFrame: CGRect = .zero
}

private struct MobileChapterFixture: View {
    let player: PlayerViewModel
    let size: CGSize
    let probe: ChapterLayoutProbe
    var panel: MobileChapterTestPanel = .chapters
    var backdrop: Color = .black
    @FocusState private var focus: PlayerControls.FocusSlot?

    var body: some View {
        VStack(spacing: PlayerTouchLayout.cardSpacing) {
            Spacer(minLength: 0)
            PlayerTouchCardStrip(
                model: player.controls, availableSize: size, isCardOpen: .constant(false), player: player,
                onRestart: {}, onNextEpisode: {}, onPreviousEpisode: {}
            )
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { probe.stripHeight = $0 }
            panelContent
                .environment(\.playerCardMetrics, .resolved(forWidth: size.width, height: size.height))
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { probe.panelFrame = $0 }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backdrop)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch panel {
        case .chapters:
            PlayerChapterPanel(model: player.controls, spoilerSettings: .default, focus: $focus) { _ in }
        case .cast:
            CastPanelView(
                model: player.controls, focus: $focus, detailPerson: .constant(nil),
                closeRequest: .constant(0), isCardOpen: true, revealClock: .linear(duration: 0)
            )
        case .info:
            InfoPanelView(model: player.controls, actions: .init(), focus: $focus, onClose: {})
        }
    }
}

private enum MobileChapterTestPanel {
    case info, cast, chapters
}

private struct ChapterPresentationProvider: MediaProvider {
    let kind = ProviderKind.jellyfin
    let session = UserSession(
        server: .init(id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!, provider: .jellyfin),
        userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
