#if os(iOS)
@testable import AppShelliOS
import CoreModels
import CoreUI
import FeatureSettings
@testable import FeatureMusic
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class MusicPlayerAppearanceTests: XCTestCase {
    func testSearchOffersAppearanceOnlyOnMobileBetaAndKeepsTrackDetailsOnTV() throws {
        let appearance = try XCTUnwrap(SettingsSearchCatalog.entry(id: "music-style"))
        let details = try XCTUnwrap(SettingsSearchCatalog.entry(id: "music-track-details"))
        for platform: SettingsSearchEntry.Platform in [.phone, .tablet] {
            for channel: AppReleaseChannel in [.debug, .testflight, .production] {
                let entries = SettingsSearchCatalog.entries(on: platform, releaseChannel: channel)
                XCTAssertEqual(entries.contains(appearance), channel.isBeta)
                XCTAssertFalse(entries.contains(details))
            }
            let index = SettingsSearchIndex(
                entries: SettingsSearchCatalog.entries(on: platform, releaseChannel: .testflight),
                locale: Locale(identifier: "en_US")
            )
            for query in ["music player", "music color", "music pure black"] {
                XCTAssertTrue(index.results(for: query).contains(appearance), query)
            }
            XCTAssertEqual(appearance.destinationPage(on: platform), .musicPlayer)
            XCTAssertEqual(
                appearance.destinationPath(on: platform).map { $0.resolved(locale: Locale(identifier: "en_US")) },
                ["Appearance", "Music player"]
            )
            XCTAssertEqual(appearance.anchorID, "music-style")
        }
        let television = SettingsSearchCatalog.entries(on: .television, releaseChannel: .production)
        XCTAssertTrue(television.contains(appearance))
        XCTAssertTrue(television.contains(details))
        XCTAssertEqual(
            appearance.destinationPath(on: .television).map { $0.resolved(locale: Locale(identifier: "en_US")) },
            ["Screens & Navigation", "Music player"]
        )
        for id in ["theme", "gradient-backgrounds", "liquid-glass"] {
            let entry = try XCTUnwrap(SettingsSearchCatalog.entry(id: id))
            XCTAssertEqual(entry.destinationPage(on: .phone), .theme)
            XCTAssertEqual(
                entry.destinationPath(on: .phone).map { $0.resolved(locale: Locale(identifier: "en_US")) },
                ["Appearance"]
            )
        }
    }

    func testMatchThemeResolvesActivePaletteAndExplicitChoicesRemainIndependent() {
        for (palette, expected) in [(ThemePalette.light, MusicPlayerAppearance.light),
                                    (.dark, .dark), (.pureBlack, .pureBlack)] {
            for gradients in [false, true] {
                XCTAssertEqual(
                    MusicPlayerOverlay.resolvedAppearance(.matchTheme, palette: palette, gradientEnabled: gradients),
                    gradients ? .artwork : expected
                )
                for appearance: MusicPlayerAppearance in [.light, .dark, .pureBlack, .artwork] {
                    XCTAssertEqual(
                        MusicPlayerOverlay.resolvedAppearance(appearance, palette: palette, gradientEnabled: gradients),
                        appearance
                    )
                }
            }
        }
    }

    func testDefaultAndLegacyColorfulPreference() throws {
        let suite = "MusicAppearanceDefaults-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MusicPlayerSettingsStore(defaults: defaults)
        XCTAssertEqual(store.loadAppearance(), .matchTheme)
        var label = MusicPlayerAppearance.matchTheme.displayName
        label.locale = Locale(identifier: "en_US")
        XCTAssertEqual(String(localized: label), "Match App Theme")
        XCTAssertEqual(AppTheme.default, .pureBlack)
        XCTAssertTrue(ThemeSettingsStore(defaults: defaults).loadGradientEnabled())
        XCTAssertEqual(store.loadAppearance().resolved(palette: .pureBlack, gradientEnabled: true), .artwork)
        defaults.set("dark", forKey: MusicPlayerAppearance.storageKey)
        XCTAssertEqual(store.loadAppearance(), .artwork, "Existing colorful players must stay colorful")
        store.saveAppearance(.dark)
        XCTAssertEqual(MusicPlayerSettingsStore(defaults: defaults).loadAppearance(), .dark)
    }

    func testEveryPreviewMatchesItsPlayerBackgroundAndMatchAppUpdates() throws {
        var previews: [Data] = []
        for appearance in MusicPlayerAppearance.pickerOrder {
            for palette in [ThemePalette.pureBlack, .dark, .light] {
                for gradient in [false, true] {
                    let resolved = appearance.resolved(palette: palette, gradientEnabled: gradient)
                    let preview = ImageRenderer(content:
                        MusicPlayerStylePreview(appearance: appearance)
                            .frame(width: 240, height: 150)
                            .environment(\.themePalette, palette)
                            .environment(\.gradientBackgroundsEnabled, gradient)
                    )
                    let player = ImageRenderer(content:
                        PlayerBackdrop(style: PlayerBackgroundStyle(appearance: resolved),
                                       grid: MusicPlayerStylePreview.previewGrid, animated: false)
                            .frame(width: 240, height: 150)
                    )
                    preview.scale = 1
                    player.scale = 1
                    let actual = try XCTUnwrap(preview.uiImage)
                    let expected = try XCTUnwrap(player.uiImage)
                    for point in [CGPoint(x: 25, y: 30), CGPoint(x: 215, y: 60)] {
                        XCTAssertEqual(try pixel(actual, at: point), try pixel(expected, at: point))
                    }
                    if palette == .pureBlack, !gradient {
                        previews.append(try XCTUnwrap(actual.pngData()))
                    }
                }
            }
        }
        XCTAssertEqual(Set(previews).count, 4, "Match App Theme equals Black with gradients off; explicit looks are distinct")
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(cg.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    func testPreviewCardsShowLiveProfilePreferenceAndPersistIndependently() async throws {
        let suite = "MusicAppearance-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let primaryStore = MusicPlayerSettingsStore(defaults: defaults)
        let otherStore = MusicPlayerSettingsStore(defaults: defaults, namespace: "other")
        let themeStore = ThemeSettingsStore(defaults: defaults)
        themeStore.save(.light)
        primaryStore.saveAppearance(.pureBlack)
        otherStore.saveAppearance(.dark)
        let primary = MusicPlayerSettingsModel(store: primaryStore)
        let other = MusicPlayerSettingsModel(store: otherStore)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        for width: CGFloat in [390, 834] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            let host = UIHostingController(rootView: page(primary))
            window.rootViewController = host
            window.makeKeyAndVisible()
            for appearance in MusicPlayerAppearance.pickerOrder {
                primary.appearance = appearance
                try await Task.sleep(for: .milliseconds(350))
                var text = try visibleText(window)
                let scroll = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                if !containsLabel(appearance, in: text) {
                    scroll.setContentOffset(CGPoint(
                        x: 0, y: max(-scroll.adjustedContentInset.top,
                                     scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    ), animated: false)
                    try await Task.sleep(for: .milliseconds(150))
                    text = try visibleText(window)
                }
                XCTAssertTrue(containsLabel(appearance, in: text), text)
                XCTAssertEqual(primaryStore.loadAppearance(), appearance)
                XCTAssertEqual(otherStore.loadAppearance(), .dark)
                XCTAssertEqual(other.appearance, .dark)
            }
            host.rootView = page(other)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(try visibleText(window).contains("Dark"))
            XCTAssertEqual(MusicPlayerSettingsModel(store: primaryStore).appearance, MusicPlayerAppearance.pickerOrder.last)
            XCTAssertEqual(themeStore.load(), .light, "Changing player colors must not change the app theme")
        }
    }

    func testMountedMatchAppPreviewUpdatesWithThemeAndGradients() async throws {
        let suite = "MusicPreview-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let theme = ThemeSettingsModel(store: ThemeSettingsStore(defaults: defaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 240, height: 150)
        window.rootViewController = UIHostingController(rootView: LiveMusicPreview(theme: theme))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func capture() -> Data? {
            UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }.pngData()
        }
        theme.theme = .pureBlack
        theme.gradientEnabled = false
        try await Task.sleep(for: .milliseconds(200))
        let black = try XCTUnwrap(capture())
        theme.gradientEnabled = true
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotEqual(black, capture())
        theme.gradientEnabled = false
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(black, capture())
        theme.theme = .light
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotEqual(black, capture())
    }

    func testWrappedTitleOnlyAddsHeightToItsOwnRow() throws {
        let renderer = ImageRenderer(content:
            CompactMusicStylePicker(selection: .constant(.matchTheme)) { _ in
                Color(red: 0, green: 1, blue: 0)
            }
            .frame(width: 328)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.locale, Locale(identifier: "en_US"))
        )
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        func previewStarts(at x: CGFloat) throws -> [Int] {
            var starts: [Int] = []
            var inPreview = false
            for y in 0..<Int(image.size.height) {
                let sample = try pixel(image, at: CGPoint(x: x, y: CGFloat(y)))
                let green = sample[0] < 20 && sample[1] > 230 && sample[2] < 20
                if green && !inPreview { starts.append(y) }
                inPreview = green
            }
            return starts
        }
        let left = try previewStarts(at: 40)
        let right = try previewStarts(at: 220)
        XCTAssertEqual(left.count, 3)
        XCTAssertEqual(right.count, 2)
        guard left.count == 3, right.count == 2 else { return }
        XCTAssertEqual(left[0], right[0])
        XCTAssertEqual(left[1], right[1])
        XCTAssertGreaterThan(left[1] - left[0], left[2] - left[1] + 10,
                             "Black and Dark must not reserve the first row's extra title line")
    }

    func testAllCardsRemainReachableAtAccessibilitySizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView:
            ScrollView {
                CompactMusicStylePicker(selection: .constant(.matchTheme)) {
                    MusicPlayerStylePreview(appearance: $0)
                }.padding(20)
            }
            .environment(\.dynamicTypeSize, .accessibility3)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(200))
        let scroll = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        var text = ""
        for _ in 0..<12 {
            text += try visibleText(window)
            let maximum = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, scroll.contentOffset.y + 350)), animated: false)
            try await Task.sleep(for: .milliseconds(100))
        }
        for appearance in MusicPlayerAppearance.pickerOrder {
            XCTAssertTrue(containsLabel(appearance, in: text), text)
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func containsLabel(_ appearance: MusicPlayerAppearance, in text: String) -> Bool {
        String(localized: appearance.displayName).split(separator: " ").allSatisfy {
            text.localizedCaseInsensitiveContains(String($0))
        }
    }

    private func page(_ model: MusicPlayerSettingsModel) -> some View {
        NavigationStack {
            PlozziOSMusicPlayerSettingsView(model: model)
        }
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    private func visibleText(_ window: UIWindow) throws -> String {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Music appearance settings"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["PLOZZ_APPEARANCE_EVIDENCE"] {
            try image.pngData()?.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("music-appearance-\(Int(window.bounds.width)).png"))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

private struct LiveMusicPreview: View {
    let theme: ThemeSettingsModel

    var body: some View {
        MusicPlayerStylePreview(appearance: .matchTheme)
            .environment(\.themePalette, ThemePalette.palette(for: theme.theme, systemColorScheme: .dark))
            .environment(\.gradientBackgroundsEnabled, theme.gradientEnabled)
    }
}
#endif
