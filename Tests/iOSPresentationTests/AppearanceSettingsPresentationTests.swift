#if os(iOS)
@testable import AppShelliOS
import CoreModels
import CoreUI
import FeatureAuth
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class AppearanceSettingsPresentationTests: XCTestCase {
    func testThemeSwatchesMatchActualFlatAndGradientBackgrounds() throws {
        for (theme, palette) in [(AppTheme.light, ThemePalette.light), (.dark, .dark), (.pureBlack, .pureBlack)] {
            var samples: [[UInt8]] = []
            for enabled in [false, true] {
                let preview = ImageRenderer(content:
                    ThemeSwatch(theme: theme, cornerRadius: 0)
                        .frame(width: 200, height: 125)
                        .environment(\.gradientBackgroundsEnabled, enabled)
                )
                let actual = ImageRenderer(content:
                    AppBackground(palette: palette)
                        .frame(width: 200, height: 125)
                        .environment(\.gradientBackgroundsEnabled, enabled)
                )
                preview.scale = 1
                actual.scale = 1
                let image = try XCTUnwrap(preview.cgImage)
                let reference = try XCTUnwrap(actual.cgImage)
                var sample: [UInt8] = []
                for x in [30, 100, 170] {
                    let pixel = try self.pixel(image, x: x, y: 8)
                    let expected = try self.pixel(reference, x: x, y: 8)
                    for channel in 0..<3 {
                        XCTAssertEqual(Int(pixel[channel]), Int(expected[channel]), accuracy: 2)
                    }
                    sample += pixel
                }
                samples.append(sample)
            }
            XCTAssertNotEqual(samples[0], samples[1], "\(theme) preview must visibly reflect the toggle")
        }
        for enabled in [false, true] {
            let system = ImageRenderer(content:
                ThemeSwatch(theme: .system, cornerRadius: 0)
                    .frame(width: 200, height: 125)
                    .environment(\.gradientBackgroundsEnabled, enabled)
            )
            system.scale = 1
            let image = try XCTUnwrap(system.cgImage)
            XCTAssertGreaterThan(try pixel(image, x: 30, y: 8)[0], try pixel(image, x: 170, y: 8)[0])
        }
    }

    func testMountedThemePreviewsUpdateWhenGradientPreferenceChanges() async throws {
        try await mount(width: 390, palette: .dark) { window, theme in
            func capturePreviews() throws -> Data {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: 40, y: 180, width: 310, height: 270)))
                return try XCTUnwrap(UIImage(cgImage: crop).pngData())
            }
            theme.gradientEnabled = false
            try await Task.sleep(for: .milliseconds(150))
            let flat = try capturePreviews()
            theme.gradientEnabled = true
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertNotEqual(flat, try capturePreviews())
            theme.gradientEnabled = false
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(flat, try capturePreviews())
        }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (y * image.width + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }

    func testThemePreviewsLeadAppearanceAndMusicPrecedesOtherPages() async throws {
        for width: CGFloat in [320, 390, 834] {
            for palette in [ThemePalette.dark, .light] {
                try await mount(width: width, palette: palette) { window, _ in
                    let frames = try self.textFrames(window)
                    for title in ["System", "Light", "Dark", "Black", "Gradient Backgrounds", "Liquid Glass", "Music player"] {
                        XCTAssertNotNil(frames[title], "\(title) at width \(width)")
                    }
                    let light = try XCTUnwrap(frames["Light"])
                    let dark = try XCTUnwrap(frames["Dark"])
                    if width < 600 {
                        XCTAssertGreaterThan(light.minY, dark.maxY, "Phone previews use two rows")
                    } else {
                        // OCR ink bounds differ slightly for the descender in "Light".
                        XCTAssertEqual(dark.midY, light.midY, accuracy: 4, "Wide panes use a single preview row")
                    }
                    let music = try XCTUnwrap(frames["Music player"])
                    XCTAssertGreaterThan(music.minY, try XCTUnwrap(frames["Liquid Glass"]).maxY)
                    let scroll = try self.scrollView(window)
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                    scroll.setContentOffset(CGPoint(
                        x: 0, y: max(-scroll.adjustedContentInset.top,
                                     scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                    ), animated: false)
                    try await Task.sleep(for: .milliseconds(150))
                    let bottom = try self.textFrames(window)
                    let cards = try XCTUnwrap(bottom["Cards"])
                    let artwork = try XCTUnwrap(bottom["Artwork"])
                    let circadian = try XCTUnwrap(bottom["Circadian Mode"])
                    XCTAssertLessThan(cards.maxY, artwork.minY)
                    XCTAssertLessThan(artwork.maxY, circadian.minY)
                    if let music = bottom["Music player"] {
                        XCTAssertLessThan(music.maxY, cards.minY)
                    }
                }
            }
        }
    }

    func testAccessibilityTextKeepsThemeChoicesAndOtherPagesReachable() async throws {
        try await mount(width: 390, palette: .dark, textSize: .accessibility3) { window, _ in
            let scroll = try self.scrollView(window)
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            var found = Set<String>()
            for _ in 0..<18 {
                found.formUnion(try self.textFrames(window).keys)
                // Native List refines estimated row heights as later groups appear.
                let maximum = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                scroll.setContentOffset(CGPoint(x: 0, y: min(scroll.contentOffset.y + 400, maximum)), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                found.formUnion(try self.textFrames(window).keys)
                if found.contains("Artwork"), found.contains("Circadian Mode") { break }
            }
            for title in ["System", "Light", "Dark", "Black", "Music player", "Cards", "Artwork"] {
                XCTAssertTrue(found.contains(title), "\(title) must remain reachable at accessibility sizes")
            }
        }
    }

    func testThemeChangesPersistWithoutChangingMusicAppearance() async throws {
        try await mount(width: 390, palette: .dark) { window, theme in
            for option in AppTheme.pickerOrder {
                theme.theme = option
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertNotNil(try self.textFrames(window)[String(localized: option.displayName)])
            }
        }
    }

    private func mount(
        width: CGFloat, palette: ThemePalette, textSize: DynamicTypeSize = .large,
        inspect: (UIWindow, ThemeSettingsModel) async throws -> Void
    ) async throws {
        let suite = "AppearanceSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let themeStore = ThemeSettingsStore(defaults: defaults)
        let theme = ThemeSettingsModel(store: themeStore)
        // Direct XCTest bundle injection lacks the driver's unit-test marker.
        let injected = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        if injected { setenv("XCTestConfigurationFilePath", "", 1) }
        defer { if injected { unsetenv("XCTestConfigurationFilePath") } }
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        let musicBefore = app.music?.settings.appearance
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 1_000)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack {
                PlozziOSAppearanceSettingsView(
                    appModel: app, theme: theme, transparency: app.settings.transparency,
                    cardStyle: app.settings.cardStyle, density: app.settings.density,
                    watchIndicator: app.settings.watchIndicator
                )
            }
            .environment(\.themePalette, palette)
            .environment(\.colorScheme, palette == .light ? .light : .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, textSize)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(350))
        try await inspect(window, theme)
        XCTAssertEqual(themeStore.load(), theme.theme)
        XCTAssertEqual(app.music?.settings.appearance, musicBefore)
    }

    private func scrollView(_ window: UIWindow) throws -> UIScrollView {
        try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.max { $0.bounds.height < $1.bounds.height })
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func textFrames(_ window: UIWindow) throws -> [String: CGRect] {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        if let directory = ProcessInfo.processInfo.environment["PLOZZ_APPEARANCE_EVIDENCE"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("appearance-\(Int(window.bounds.width)).png")
            try XCTUnwrap(image.pngData()).write(to: url)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        var frames: [String: CGRect] = [:]
        for result in request.results ?? [] {
            guard let text = result.topCandidates(1).first?.string else { continue }
            frames[text] = CGRect(
                x: result.boundingBox.minX * window.bounds.width,
                y: (1 - result.boundingBox.maxY) * window.bounds.height,
                width: result.boundingBox.width * window.bounds.width,
                height: result.boundingBox.height * window.bounds.height
            )
        }
        return frames
    }
}
#endif
