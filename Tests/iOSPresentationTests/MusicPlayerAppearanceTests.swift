#if os(iOS)
@testable import AppShelliOS
import CoreModels
import CoreUI
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
            XCTAssertEqual(appearance.anchorID, "music-style")
        }
        let television = SettingsSearchCatalog.entries(on: .television, releaseChannel: .production)
        XCTAssertTrue(television.contains(appearance))
        XCTAssertTrue(television.contains(details))
    }

    func testMatchThemeResolvesActivePaletteAndExplicitChoicesRemainIndependent() {
        for (palette, expected) in [(ThemePalette.light, MusicPlayerAppearance.light),
                                    (.dark, .dark), (.pureBlack, .pureBlack)] {
            XCTAssertEqual(MusicPlayerOverlay.resolvedAppearance(.matchTheme, palette: palette), expected)
            for appearance: MusicPlayerAppearance in [.light, .dark, .pureBlack] {
                XCTAssertEqual(MusicPlayerOverlay.resolvedAppearance(appearance, palette: palette), appearance)
            }
        }
    }

    func testNativePickerShowsLiveProfilePreferenceAndPersistsIndependently() async throws {
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
                let text = try visibleText(window)
                XCTAssertTrue(text.contains("Appearance"), text)
                XCTAssertTrue(text.localizedCaseInsensitiveContains(String(localized: appearance.displayName)), text)
                XCTAssertEqual(primaryStore.loadAppearance(), appearance)
                XCTAssertEqual(otherStore.loadAppearance(), .dark)
                XCTAssertEqual(other.appearance, .dark)
            }
            host.rootView = page(other)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(try visibleText(window).contains("Dark"))
            XCTAssertEqual(MusicPlayerSettingsModel(store: primaryStore).appearance, .matchTheme)
            XCTAssertEqual(themeStore.load(), .light, "Changing player colors must not change the app theme")
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
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
#endif
