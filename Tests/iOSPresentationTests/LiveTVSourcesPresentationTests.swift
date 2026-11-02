#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
@testable import FeatureLiveTV
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class LiveTVSourcesPresentationTests: XCTestCase {
    func testSourceOverflowUsesMeasuredRowsAndDirectionalSharedFade() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let heights: [CGFloat] = [58, 82, 74, 96, 108, 62]
        for width in [CGFloat(390), 834] {
            for count in [1, 4, 5, 6] {
                let viewport = SourceViewport()
                window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
                host.rootView = AnyView(
                    VStack(spacing: 0) {
                        LiveTVBoundedSourceRows {
                            ForEach(0..<count, id: \.self) { index in
                                Color.red.frame(height: heights[index])
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            viewport.frame = $0
                        }
                        .id("\(width)-\(count)")
                        Spacer(minLength: 0)
                    }
                    .background(.black)
                )
                try await settle(window)
                let scrolls = sourceScrollViews(in: window)
                if count <= 4 {
                    XCTAssertTrue(scrolls.isEmpty, "Four or fewer sources must use their natural height.")
                    XCTAssertEqual(
                        viewport.frame.height,
                        heights.prefix(count).reduce(0, +) + CGFloat(count - 1) * SettingsRowMetrics.formRowSpacing,
                        accuracy: 1
                    )
                    continue
                }
                let scroll = try XCTUnwrap(scrolls.first, "Missing source scroll view at width \(width), count \(count).")
                XCTAssertEqual(scrolls.count, 1)
                let expected = 8 + heights.prefix(4).reduce(0, +)
                    + heights[4] / 2 + 4 * SettingsRowMetrics.formRowSpacing
                XCTAssertEqual(viewport.frame.height, expected, accuracy: 1,
                               "Show four complete, potentially wrapping rows and half of the fifth.")
                let frame = viewport.frame
                let bottom = CGPoint(x: frame.midX, y: frame.maxY - 15)
                let before = snapshot(window)
                XCTAssertLessThan(try pixel(before, at: bottom)[0], 180,
                                  "The partially visible fifth row must fade, not end abruptly.")
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height),
                                        animated: false)
                try await settle(window)
                XCTAssertGreaterThan(try pixel(snapshot(window), at: bottom)[0], 230,
                                     "The last source must stop fading when no content remains below.")
                let attachment = XCTAttachment(image: before)
                attachment.name = "source-overflow-\(Int(width))-\(count)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func sourceScrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { sourceScrollViews(in: $0) }
    }

    private final class SourceViewport {
        var frame: CGRect = .zero
    }

    func testIPTVSetupUsesTheSharedSettingsBackground() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width in [CGFloat(390), 834] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
            for (theme, palette) in [("dark", ThemePalette.dark), ("black", .pureBlack), ("light", .light)] {
                for gradient in [false, true] {
                    window.overrideUserInterfaceStyle = palette.isLight ? .light : .dark
                    var images: [UIImage] = []
                    for showsSetup in [true, false] {
                        host.rootView = AnyView(
                            NavigationStack {
                                if showsSetup {
                                    IPTVSignInView(
                                        deviceID: "setup-presentation-fixture",
                                        onAuthenticated: { _ in }, onCancel: {}
                                    )
                                } else {
                                    ScrollView { Color.clear.frame(height: 100) }
                                        .background { SettingsPageBackground() }
                                        .navigationTitle("IPTV")
                                        .navigationBarTitleDisplayMode(.inline)
                                        .toolbarBackground(.hidden, for: .navigationBar)
                                }
                            }
                            .environment(\.themePalette, palette)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark)
                            .environment(\.gradientBackgroundsEnabled, gradient)
                            .environment(\.locale, Locale(identifier: "en_US"))
                        )
                        try await settle(window)
                        images.append(snapshot(window))
                    }
                    let attachment = XCTAttachment(image: images[0])
                    attachment.name = "iptv-setup-\(Int(width))-\(theme)-gradient-\(gradient)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    for y in [CGFloat(150), 500, 900] {
                        for x in [CGFloat(8), width - 8] {
                            let point = CGPoint(x: x, y: y)
                            for (actual, reference) in zip(try pixel(images[0], at: point), try pixel(images[1], at: point)) {
                                XCTAssertLessThanOrEqual(abs(actual - reference), 2,
                                    "IPTV setup must reveal the shared settings background at \(point).")
                            }
                        }
                    }
                }
            }
        }
    }

    func testOnboardingDoesNotCoverTheFullPageBackgroundWithAnInsetPanel() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width in [CGFloat(390), 834] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
            for (theme, palette) in [("dark", ThemePalette.dark), ("black", .pureBlack), ("light", .light)] {
                for gradient in [false, true] {
                    window.overrideUserInterfaceStyle = palette.isLight ? .light : .dark
                    var images: [UIImage] = []
                    for showsWelcome in [true, false] {
                        host.rootView = AnyView(
                            SetupBackgroundFixture(showsWelcome: showsWelcome)
                                .environment(\.themePalette, palette)
                                .environment(\.colorScheme, palette.isLight ? .light : .dark)
                                .environment(\.gradientBackgroundsEnabled, gradient)
                                .environment(\.locale, Locale(identifier: "en_US"))
                        )
                        try await settle(window)
                        images.append(snapshot(window))
                    }
                    let attachment = XCTAttachment(image: images[0])
                    attachment.name = "onboarding-surface-\(Int(width))-\(theme)-gradient-\(gradient)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    for x in [CGFloat(8), 18, 32, width / 2, width - 32, width - 18, width - 8] {
                        let point = CGPoint(x: x, y: 930)
                        for (actual, reference) in zip(try pixel(images[0], at: point), try pixel(images[1], at: point)) {
                            XCTAssertLessThanOrEqual(abs(actual - reference), 2,
                                                    "The onboarding canvas must match the page at \(point).")
                        }
                    }
                }
            }
        }
    }

    func testSetupChoicesFitTabletWidthsInBothDirections() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width in [CGFloat(390), 768, 834] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
                window.rootViewController = UIHostingController(rootView:
                    LiveTVSetupWelcome(addPlaylist: {}, useServer: {}, createChannel: {})
                        .background { AppBackground(palette: .light) }
                        .environment(\.themePalette, .light)
                        .environment(\.colorScheme, .light)
                        .environment(\.dynamicTypeSize, .large)
                        .environment(\.layoutDirection, direction)
                        .environment(\.locale, Locale(identifier: "en_US"))
                )
                window.makeKeyAndVisible()
                try await waitForHostedLayout(window)
                let image = snapshot(window)
                let attachment = XCTAttachment(image: image)
                attachment.name = "tablet-onboarding-\(Int(width))-\(direction)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.customWords = ["IPTV", "Plozz"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                for choice in ["IPTV provider", "Media server", "Plozz channels"] {
                    XCTAssertTrue(text.contains(choice), "\(choice) must be visible without scrolling: \(text)")
                }
                XCTAssertTrue(text.contains("Experimental"), "Setup must disclose Live TV's status: \(text)")
            }
        }
    }

    func testEmbeddedSourcesRevealTheSettingsBackgroundWithoutExtraRowInsets() async throws {
        let suite = "LiveTVSourcesPresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width in [CGFloat(390), 768] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
            for (theme, palette) in [("dark", ThemePalette.dark), ("black", .pureBlack), ("light", .light)] {
                for gradient in [false, true] {
                    window.overrideUserInterfaceStyle = palette.isLight ? .light : .dark
                    host.rootView = AnyView(
                        NavigationStack {
                            SettingsPageList {
                                LiveTVSourcesView(
                                    store: SourcesFixtureStore(), presentation: .settingsPane,
                                    connectServer: {}, createChannel: {}, scanChannels: {}
                                )
                            }
                            .navigationTitle(Text(SettingsCopy.tvSources))
                            .navigationBarTitleDisplayMode(.inline)
                        }
                        .environment(profiles)
                        .environment(\.themePalette, palette)
                        .environment(\.colorScheme, palette.isLight ? .light : .dark)
                        .environment(\.gradientBackgroundsEnabled, gradient)
                        .environment(\.locale, Locale(identifier: "en_US"))
                    )
                    try await settle(window)
                    let actual = snapshot(window)
                    let attachment = XCTAttachment(image: actual)
                    attachment.name = "sources-\(Int(width))-\(theme)-gradient-\(gradient)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: XCTUnwrap(actual.cgImage)).perform([request])
                    let header = try XCTUnwrap(request.results?.first {
                        $0.topCandidates(1).first?.string == "ADD A SOURCE"
                    })
                    let headerFrame = CGRect(
                        x: header.boundingBox.minX * width,
                        y: (1 - header.boundingBox.maxY) * window.bounds.height,
                        width: header.boundingBox.width * width,
                        height: header.boundingBox.height * window.bounds.height
                    )
                    let y = headerFrame.midY
                    host.rootView = AnyView(
                        NavigationStack {
                            Color.clear.settingsPageSurface()
                                .navigationTitle(Text(SettingsCopy.tvSources))
                                .navigationBarTitleDisplayMode(.inline)
                        }
                        .environment(\.themePalette, palette)
                        .environment(\.colorScheme, palette.isLight ? .light : .dark)
                        .environment(\.gradientBackgroundsEnabled, gradient)
                    )
                    try await settle(window)
                    let reference = snapshot(window)
                    XCTAssertEqual(try leadingInkEdge(actual, background: reference, header: headerFrame),
                                   24, accuracy: 2, "The pane must not gain a second native List row inset.")
                    for x in [width * 0.7, width - 32] {
                        let point = CGPoint(x: x, y: y)
                        for (observed, expected) in zip(try pixel(actual, at: point), try pixel(reference, at: point)) {
                            XCTAssertLessThanOrEqual(abs(observed - expected), 2,
                                                     "The Sources list cell must not cover the shared settings background.")
                        }
                    }
                }
            }
        }
    }

    private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
    }

    private func snapshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func leadingInkEdge(_ image: UIImage, background: UIImage, header: CGRect) throws -> CGFloat {
        let top = max(0, Int(floor(header.minY)) - 2)
        let bottom = min(Int(image.size.height), Int(ceil(header.maxY)) + 2)
        let right = min(Int(image.size.width), Int(ceil(header.maxX)) + 2)
        var leading: Int?
        // Vision's line box can extend beyond the glyphs; ignore faint panel shadows.
        scan: for x in 0..<right {
            for y in top..<bottom {
                let point = CGPoint(x: x, y: y)
                let observed = try pixel(image, at: point)
                let expected = try pixel(background, at: point)
                if zip(observed, expected).contains(where: { abs($0.0 - $0.1) > 40 }) {
                    leading = x
                    break scan
                }
            }
        }
        return CGFloat(try XCTUnwrap(leading, "The source header must have visible text."))
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Int.init)
    }
}

private struct SetupBackgroundFixture: View {
    let showsWelcome: Bool
    @Environment(\.themePalette) private var palette

    var body: some View {
        GeometryReader { geometry in
            let layout = PrototypePreviewLayout(size: geometry.size, safeAreaInsets: geometry.safeAreaInsets)
            ZStack(alignment: .topLeading) {
                AppBackground(palette: palette)
                PrototypePreviewScrim(layout: layout, reduceTransparency: false)
                    .frame(width: layout.bounds.width, height: layout.bounds.height)
                    .position(x: layout.bounds.midX, y: layout.bounds.midY)
                if showsWelcome {
                    PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: geometry.size.width) {
                        LiveTVSetupWelcome(addPlaylist: {}, useServer: {}, createChannel: {})
                    }
                }
            }
        }
    }
}

private struct SourcesFixtureStore: LiveTVSourcesStoring {
    func load() throws -> LiveTVSourcesConfiguration { .empty }
    func save(_ configuration: LiveTVSourcesConfiguration) throws { throw LiveTVSourcesStoreError.saveFailed }
}
#endif
