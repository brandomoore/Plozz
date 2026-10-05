#if os(iOS)
import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS
@testable import FeatureLiveTV

@MainActor
final class MobileHomeAndMultiviewPresentationTests: XCTestCase {
    func testHomeCaptionDefaultPreservesExplicitProfileChoices() throws {
        let suite = "MobileHomeCaptions.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = HeroSettingsStore(defaults: defaults)
        let other = HeroSettingsStore(defaults: defaults, namespace: "other")
        XCTAssertFalse(primary.load().showsCardCaptions)
        XCTAssertFalse(other.load().showsCardCaptions)
        var settings = other.load()
        settings.showsCardCaptions = true
        other.save(settings)
        XCTAssertTrue(HeroSettingsStore(defaults: defaults, namespace: "other").load().showsCardCaptions)
        XCTAssertFalse(HeroSettingsStore(defaults: defaults).load().showsCardCaptions)
        XCTAssertFalse(try JSONDecoder().decode(HeroSettings.self, from: Data("{}".utf8)).showsCardCaptions)
    }

    func testHomePostersShowThreeAndAPeekAcrossPhoneWidthsAndGrowColumnCountOnTablets() async throws {
        let app = PlozziOSAppModel()
        let original = app.settings.hero.settings
        defer { app.settings.hero.settings = original }
        app.settings.hero.settings.showsCardCaptions = false
        let artwork = try await posterArtwork()
        let items = (0..<12).map { MediaItem(id: "poster-\($0)", title: "Title \($0)", kind: .movie, posterURL: artwork) }
        for style in [CardStyle.borderless, .framed] {
            try await withWindow { window, host in
                // Reuse the same hierarchy while resizing, including iPad split widths.
                for width in [CGFloat(320), 375, 390, 402, 440, 507, 768, 1024, 1366] {
                    window.frame.size = CGSize(width: width, height: 1024)
                    let sizeClass: UserInterfaceSizeClass = width < 600 ? .compact : .regular
                    host.rootView = AnyView(
                        ScrollView {
                            PlozziOSHomeMediaRail(title: Text("Recently added"), items: items, style: .poster, appModel: app)
                        }
                        .environment(app)
                        .environment(\.horizontalSizeClass, sizeClass)
                        .environment(\.plozzCardStyle, style)
                        .environment(\.plozzMetrics, .touch(density: .standard))
                        .environment(\.themePalette, .dark)
                    )
                    try await settle(window)
                    let rail = try XCTUnwrap(scrollViews(window).first { $0.contentSize.width > $0.bounds.width + 10 })
                    let y = rail.convert(.zero, to: window).y + rail.bounds.height / 2
                    // Lazy cards publish their cached artwork asynchronously after layout.
                    let deadline = Date().addingTimeInterval(4)
                    while Date() < deadline {
                        let runs = try posterRuns(snapshot(window), y: y)
                        if runs.last?.upperBound == Int(width) { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    let image = snapshot(window, name: "home-\(Int(width))-\(style)")
                    let runs = try posterRuns(image, y: y)
                    let full = Array(runs.dropLast())
                    let peek = try XCTUnwrap(runs.last)
                    XCTAssertGreaterThanOrEqual(full.count, width < 600 ? 3 : 4)
                    if width < 600 { XCTAssertEqual(full.count, 3) }
                    let first = try XCTUnwrap(full.first)
                    XCTAssertEqual(CGFloat(first.lowerBound), PlozziOSPageLayout.horizontalInset(for: sizeClass), accuracy: 2,
                                   "The first poster artwork must share the heading's leading keyline.")
                    XCTAssertLessThan(first.count, 210, "Wide windows add columns instead of oversized posters.")
                    for run in full { XCTAssertEqual(run.count, first.count, accuracy: 1) }
                    XCTAssertGreaterThan(Double(peek.count) / Double(first.count), 0.20)
                    XCTAssertLessThan(Double(peek.count) / Double(first.count), 0.42)
                    XCTAssertEqual(peek.upperBound, Int(width), "The next poster must peek at the physical rail edge.")
                }
            }
        }
    }

    func testHomeCaptionPreferenceAndSkeletonMatchWithoutChangingLandscapeSizes() async throws {
        let app = PlozziOSAppModel()
        let original = app.settings.hero.settings
        defer { app.settings.hero.settings = original }
        let artwork = try await posterArtwork()
        let items = (0..<8).map { MediaItem(id: "caption-\($0)", title: "Title", kind: .movie, posterURL: artwork) }
        for style in [CardStyle.borderless, .framed] {
            try await withWindow { window, host in
                window.frame.size = CGSize(width: 390, height: 844)
                for captions in [false, true, false] {
                    app.settings.hero.settings.showsCardCaptions = captions
                    host.rootView = AnyView(
                        ScrollView {
                            VStack {
                                PlozziOSHomeMediaRail(title: Text("Loaded"), items: items, style: .poster, appModel: app)
                                PlozziOSHomeSkeletonRail(title: Text("Loading"), style: .poster, showsCaption: captions)
                            }
                        }
                        .environment(app)
                        .environment(\.horizontalSizeClass, .compact)
                        .environment(\.plozzCardStyle, style)
                        .environment(\.plozzMetrics, .touch(density: .standard))
                        .environment(\.themePalette, .dark)
                    )
                    try await settle(window)
                    let rails = scrollViews(window).filter { $0.contentSize.width > $0.bounds.width + 10 }
                    XCTAssertEqual(rails.count, 2)
                    if !captions {
                        XCTAssertEqual(rails[0].bounds.height, rails[1].bounds.height, accuracy: 1)
                    }
                    let observations = try text(snapshot(window, name: "home-captions-\(captions)-\(style)"))
                    XCTAssertEqual(observations.contains { $0.candidate.string.contains("Title") }, captions)
                }
            }
        }
        for density in UIDensity.allCases {
            let base = PlozzMetrics.touch(density: density)
            let small = PlozziOSHomeRailLayout<EmptyView>.posterMetrics(in: 390, inset: 22, metrics: base, cardStyle: .borderless)
            XCTAssertEqual(small.landscapeWidth, base.landscapeWidth)
            XCTAssertEqual(small.continueWatchingWidth, base.continueWatchingWidth)
            XCTAssertEqual(small.cardTitleFontSize, base.cardTitleFontSize)
        }
        let small = PlozziOSHomeRailLayout<EmptyView>.posterMetrics(
            in: 390, inset: 22, metrics: .touch(density: .compact), cardStyle: .borderless)
        let large = PlozziOSHomeRailLayout<EmptyView>.posterMetrics(
            in: 390, inset: 22, metrics: .touch(density: .extraLarge), cardStyle: .borderless)
        XCTAssertLessThan(small.posterWidth, large.posterWidth, "The profile's display-size choice remains effective.")
    }

    func testMultiviewActionsStayInsideSafeAreasOnPhonesTabletsAndLargeText() async throws {
        let primary = LiveTVPlaybackPreparation()
        let channel = LiveTVPrototypeChannel(
            id: "touch-1", number: 1, name: "Channel 1", category: "Sports",
            symbol: "tv", accent: 0, source: .iptv, tagline: "",
            streamURL: URL(string: "https://example.invalid/touch-1.m3u8")!
        )
        let loaded = await primary.prepare(channel, isAuthorized: { true }, accept: { true })
        XCTAssertTrue(loaded)
        let coordinator = LiveTVMultiviewCoordinator(
            primary: primary, makePreparation: { LiveTVPlaybackPreparation() },
            reference: { _ in nil }, authorizes: { _, _ in true }, recordWatched: { _ in }
        )
        XCTAssertTrue(coordinator.begin())
        addTeardownBlock { await coordinator.close() }
        var measuredInsets: EdgeInsets?
        try await withWindow { window, host in
            for size in [
                CGSize(width: 320, height: 568), CGSize(width: 390, height: 844),
                CGSize(width: 440, height: 956), CGSize(width: 844, height: 390),
                CGSize(width: 507, height: 768), CGSize(width: 768, height: 1024),
                CGSize(width: 1366, height: 1024)
            ] {
                window.frame.size = size
                host.additionalSafeAreaInsets = size.width > size.height
                    ? UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)
                    : UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
                for textSize in [DynamicTypeSize.large, .accessibility2] {
                    coordinator.beginEditingLayout()
                    host.rootView = AnyView(
                        MultiviewTouchFixture(coordinator: coordinator, measured: { measuredInsets = $0 })
                            .environment(\.dynamicTypeSize, textSize)
                            .environment(\.themePalette, .dark)
                            .environment(\.locale, Locale(identifier: "en_US"))
                    )
                    try await settle(window)
                    let image = snapshot(window, name: "multiview-\(Int(size.width))-\(Int(size.height))-\(textSize)")
                    let observations = try text(image)
                    let safe = window.bounds.inset(by: host.view.safeAreaInsets)
                    for label in textSize.isAccessibilitySize ? ["Watch", "Add"] : ["Watch", "Add", "Layout", "More"] {
                        let frame = try textFrame(label, observations: observations, size: size)
                        XCTAssertTrue(safe.insetBy(dx: -1, dy: -1).contains(frame), "\(label) must clear every system inset: \(frame), \(safe)")
                    }
                    let watch = try textFrame("Watch", observations: observations, size: size)
                    let add = try textFrame("Add", observations: observations, size: size)
                    XCTAssertLessThan(watch.maxY + 44, add.minY, "Header and toolbar must leave room for the pictures.")
                    let insets = try XCTUnwrap(measuredInsets)
                    let picture = LiveTVMultiviewGeometry.frame(
                        for: coordinator.primaryPaneID, panes: coordinator.panes.map(\.id), primary: coordinator.primaryPaneID,
                        layout: coordinator.layout, corner: coordinator.corner, insetSize: coordinator.insetSize,
                        expanded: nil, size: size, isEditing: true, editingInsets: insets)
                    XCTAssertGreaterThanOrEqual(picture.minY, watch.maxY + 8)
                    XCTAssertLessThanOrEqual(picture.maxY, add.minY - 8,
                                             "Editing pictures must not sit underneath the touch dock.")
                    if textSize.isAccessibilitySize,
                       let toolbar = scrollViews(window).first(where: { $0.contentSize.width > $0.bounds.width + 1 }) {
                        toolbar.setContentOffset(CGPoint(x: toolbar.contentSize.width - toolbar.bounds.width, y: 0), animated: false)
                        try await settle(window)
                        let revealed = try text(snapshot(window, name: "multiview-large-text-trailing-\(Int(size.width))"))
                        for label in ["Layout", "More"] {
                            let frame = try textFrame(label, observations: revealed, size: size)
                            XCTAssertTrue(safe.contains(frame))
                        }
                    }
                }
            }
            await coordinator.add(LiveTVPrototypeChannel(
                id: "touch-2", number: 2, name: "Channel 2", category: "Sports",
                symbol: "tv", accent: 1, source: .iptv, tagline: "",
                streamURL: URL(string: "https://example.invalid/touch-2.m3u8")!
            ))?.value
            window.frame.size = CGSize(width: 390, height: 844)
            host.additionalSafeAreaInsets = UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)
            host.rootView = AnyView(MultiviewTouchFixture(coordinator: coordinator).environment(\.themePalette, .dark))
            try await settle(window)
            var observations = try text(snapshot(window, name: "multiview-two-channel-editing"))
            _ = try textFrame("Audio", observations: observations, size: window.bounds.size)
            _ = try textFrame("Add", observations: observations, size: window.bounds.size)
            coordinator.finishEditingLayout()
            try await settle(window)
            observations = try text(snapshot(window, name: "multiview-two-channel-watching"))
            _ = try textFrame("Edit layout", observations: observations, size: window.bounds.size)
            _ = try textFrame("Audio", observations: observations, size: window.bounds.size)
            coordinator.beginEditingLayout()
            window.frame.size = CGSize(width: 320, height: 568)
            for number in 3...4 {
                await coordinator.add(LiveTVPrototypeChannel(
                    id: "touch-\(number)", number: number, name: "Channel \(number)", category: "Sports",
                    symbol: "tv", accent: number, source: .iptv, tagline: "",
                    streamURL: URL(string: "https://example.invalid/touch-\(number).m3u8")!
                ))?.value
                try await settle(window)
                observations = try text(snapshot(window, name: "multiview-\(number)-channels-small-phone"))
                for label in number == 3 ? ["Add", "Layout", "Audio", "More"] : ["Layout", "Audio", "More"] {
                    let frame = try textFrame(label, observations: observations, size: window.bounds.size)
                    XCTAssertTrue(window.bounds.inset(by: host.view.safeAreaInsets).contains(frame))
                }
            }
            XCTAssertEqual(coordinator.panes.first?.preparation.current?.id, primary.current?.id)
        }
    }

    private func withWindow(_ exercise: (UIWindow, UIHostingController<AnyView>) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await exercise(window, host)
    }

    private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
    }

    private func scrollViews(_ view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    private func snapshot(_ window: UIWindow, name: String? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        if let name {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return image
    }

    private struct RecognizedLabel {
        let candidate: VNRecognizedText
        let region: CGRect
    }

    private func text(_ image: UIImage) throws -> [RecognizedLabel] {
        // Wide iPad snapshots downsample small dock captions during full-image OCR.
        // Also recognize the native-resolution dock crop, retaining screen coordinates.
        let regions = [
            CGRect(origin: .zero, size: image.size),
            CGRect(x: max(0, (image.size.width - 640) / 2), y: max(0, image.size.height - 260),
                   width: min(640, image.size.width), height: min(260, image.size.height))
        ]
        return try regions.flatMap { region in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: region.applying(
                CGAffineTransform(scaleX: image.scale, y: image.scale))))
            try VNImageRequestHandler(cgImage: crop).perform([request])
            let normalized = CGRect(
                x: region.minX / image.size.width, y: 1 - region.maxY / image.size.height,
                width: region.width / image.size.width, height: region.height / image.size.height)
            return (request.results ?? []).flatMap { observation in
                observation.topCandidates(5).map { RecognizedLabel(candidate: $0, region: normalized) }
            }
        }
    }

    private func textFrame(_ label: String, observations: [RecognizedLabel], size: CGSize) throws -> CGRect {
        let match = try XCTUnwrap(observations.compactMap { observation -> (RecognizedLabel, Range<String.Index>)? in
            let candidate = observation.candidate
            guard let range = candidate.string.range(
                    of: "\\b\(NSRegularExpression.escapedPattern(for: label))\\b", options: .regularExpression)
            else { return nil }
            return (observation, range)
        }.first, "Missing untruncated action: \(label). Found \(observations.map { $0.candidate.string })")
        let local = try XCTUnwrap(match.0.candidate.boundingBox(for: match.1)).boundingBox
        let region = match.0.region
        let box = CGRect(x: region.minX + local.minX * region.width, y: region.minY + local.minY * region.height,
                         width: local.width * region.width, height: local.height * region.height)
        return CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                      width: box.width * size.width, height: box.height * size.height)
    }

    private func posterRuns(_ image: UIImage, y: CGFloat) throws -> [Range<Int>] {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var runs: [Range<Int>] = []
        var start: Int?
        for x in 0..<Int(image.size.width) {
            let offset = (Int(y * image.scale) * cg.width + Int(CGFloat(x) * image.scale)) * 4
            let artwork = bytes[offset] > 150 && bytes[offset + 1] < 70 && bytes[offset + 2] > 70
            if artwork && start == nil { start = x }
            if !artwork, let begin = start { runs.append(begin..<x); start = nil }
        }
        if let start { runs.append(start..<Int(image.size.width)) }
        return runs.filter { $0.count > 3 }
    }

    private func posterArtwork() async throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/mobile-poster-\(UUID()).png"))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 450)).image { context in
            UIColor(red: 0.8, green: 0.12, blue: 0.48, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 450))
        }
        let data = try XCTUnwrap(image.pngData())
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        for variant in ArtworkImageVariant.allCases {
            let requestURL = variant.requestURL(for: url)
            let response = try XCTUnwrap(HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]))
            cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: URLRequest(url: requestURL))
            let decoded = await ArtworkImageCache.shared.image(for: url, variant: variant)
            _ = try XCTUnwrap(decoded)
        }
        return url
    }
}

private struct MultiviewTouchFixture: View {
    let coordinator: LiveTVMultiviewCoordinator
    var measured: (EdgeInsets) -> Void = { _ in }
    @State private var editingInsets: EdgeInsets?

    var body: some View {
        GeometryReader { geometry in
            let bounds = PrototypePreviewLayout(size: geometry.size, safeAreaInsets: geometry.safeAreaInsets).bounds
            LiveTVMultiviewOverlay(
                coordinator: coordinator, safeAreaInsets: geometry.safeAreaInsets,
                editingInsets: editingInsets,
                onEditingInsetsChange: { editingInsets = $0; measured($0) },
                exit: {}, returnToGuide: {}, addChannel: {}, replaceChannel: { _ in },
                toggleFavorite: {}
            )
            .frame(width: bounds.width, height: bounds.height)
            .position(x: bounds.midX, y: bounds.midY)
        }
        .background(ThemePalette.dark.backgroundBase.ignoresSafeArea())
    }
}
#endif
