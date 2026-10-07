import CoreModels
import CoreUI
import AppShell
@testable import FeatureSettings
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class ArtworkSettingsHostedTests: XCTestCase {
    func testAppearanceSeparatesArtworkAndGatesHouseholdProviderNavigation() async throws {
        let namespace = "ArtworkAppearanceHosted.\(UUID())"
        let models = ProfileSettingsModel(namespace: namespace)
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(namespace) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        models.cardStyleModel.artwork = .default
        let navigation = SettingsNavigationModel()
        navigation.appearanceRowID = "artwork"
        let libraries = ProfileLibrariesScope(
            accounts: [], activeProfile: .init(id: namespace, name: "Viewer"),
            discoveredLibraries: .empty, refreshingLibraryAccountIDs: [],
            unreachableLibraryAccountIDs: [], reloadLibraries: {},
            homeVisibility: models.homeLibraryVisibilityModel,
            isAccountIncludedInActiveProfile: { _ in false },
            onSetAccountIncluded: { _, _ in }, onAddAccount: {},
            plexHomeUsersFetcher: { _ in [] }, onSelectPlexHomeUser: { _, _ in }
        )
        for canManage in [true, false] {
            let content = NavigationStack {
                AppearanceDetailView(
                    librariesScope: libraries, settingsNavigation: navigation,
                    canManageProviders: canManage,
                    theme: models.themeModel, nightShift: models.nightShiftModel,
                    spoilers: models.spoilerModel
                )
            }
            .environment(models.musicPlayerModel)
            .environment(models.uiDensityModel)
            .environment(models.cardStyleModel)
            .environment(models.watchStatusIndicatorModel)
            .environment(models.navigationStyleModel)
            .environment(models.transparencyModel)
            .environment(models.appLanguageModel)
            try await withScreen(content: content) { window in
                let text = try await self.capture(window, name: "artwork-appearance-providers-\(canManage)")
                XCTAssertTrue(text.contains("Choose the posters, backgrounds, and logos you see"), text)
                XCTAssertTrue(text.contains("Recommended"), text)
                XCTAssertTrue(text.contains("Prefer my library"), text)
                XCTAssertTrue(text.contains("Prefer online artwork"), text)
                XCTAssertTrue(text.contains("Movies and shows prefer images from metadata providers"), text)
                XCTAssertTrue(text.contains("Music prefers artwork from your library"), text)
                XCTAssertTrue(text.contains("Customize by view"), text)
                XCTAssertTrue(text.contains("Using defaults"), text)
                XCTAssertTrue(text.contains("About artwork sources"), text)
                XCTAssertFalse(text.contains("Remove view customizations"), text)
                XCTAssertEqual(text.contains("Metadata Providers"), canManage, text)
                XCTAssertEqual(text.contains("TMDB"), canManage, text)
                XCTAssertEqual(text.contains("TheTVDB"), canManage, text)
                XCTAssertFalse(text.contains("Online services"), text)
                if canManage {
                    models.cardStyleModel.artwork.setOverride(.library, for: .browse)
                    let customized = try await self.capture(window, name: "artwork-appearance-customized")
                    XCTAssertTrue(customized.contains("1 customized"), customized)
                    XCTAssertTrue(customized.contains("Remove view customizations"), customized)
                    models.cardStyleModel.artwork.resetOverrides()
                }
            }
        }
    }

    func testBrowseShowsInheritedSourceAndKeepsAnExplicitChoiceWhenPresetChanges() async throws {
        let suite = "ArtworkSettingsHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        try await withScreen(cards: cards, area: .browse) { window in
            let inherited = try await self.capture(window, name: "artwork-browse-use-preset")
            XCTAssertTrue(inherited.contains("Use default: online preferred"), inherited)
            XCTAssertTrue(inherited.contains("Libraries, collections, and playlists"), inherited)
            XCTAssertFalse(inherited.contains("without text"), inherited)
            XCTAssertFalse(inherited.contains("Continue Watching"), inherited)
            XCTAssertLessThan(inherited.split(whereSeparator: \.isWhitespace).count, 25, inherited)

            cards.artwork.setOverride(.library, for: .browse)
            let overridden = try await self.capture(window, name: "artwork-browse-library-first")
            XCTAssertTrue(overridden.contains("Use default: online preferred"), overridden)
            XCTAssertEqual(cards.artwork.override(for: .browse), .library)
            cards.artwork.preference = .library
            let changed = try await self.capture(window, name: "artwork-browse-changed-preset")
            XCTAssertTrue(changed.contains("Use default: library preferred"), changed)
            XCTAssertEqual(cards.artwork.override(for: .browse), .library)
            XCTAssertEqual(ArtworkSettingsStore(defaults: defaults).load(), cards.artwork)
        }
    }

    func testContinueWatchingExplainsTextlessArtworkOnlyInItsOwnPane() async throws {
        let suite = "ArtworkContinueWatchingHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        try await withScreen(cards: cards, area: .continueWatching) { window in
            let text = try await self.capture(window, name: "artwork-continue-watching")
            XCTAssertTrue(text.contains("without text"), text)
            XCTAssertTrue(text.contains("chosen images"), text)
        }
    }

    func testArtworkSourceHelpExplainsBothSourcesAndPreservedCustomizations() async throws {
        for topic in ArtworkSourceHelpTopic.allCases {
            try await withScreen(
                content: ArtworkSourcesHelpView(selection: .constant(topic.rawValue))
            ) { window in
                let text = try await self.capture(window, name: "artwork-source-help-\(topic.rawValue)")
                switch topic {
                case .library:
                    XCTAssertTrue(text.contains("Plex, Jellyfin, or Emby"), text)
                    XCTAssertTrue(text.contains("network shares"), text)
                case .online:
                    XCTAssertTrue(text.contains("through metadata providers"), text)
                    XCTAssertTrue(text.contains("In Metadata Providers"), text)
                    XCTAssertTrue(text.contains("same images"), text)
                    XCTAssertTrue(text.contains("Custom uses your saved order"), text)
                case .preferences:
                    XCTAssertTrue(text.contains("this profile"), text)
                    XCTAssertTrue(text.contains("fall back"), text)
                    XCTAssertTrue(text.contains("keeps view customizations"), text)
                }
            }
        }
    }

    private func makeCards(defaults: UserDefaults) -> CardStyleSettingsModel {
        CardStyleSettingsModel(
            store: CardStyleSettingsStore(defaults: defaults),
            focusStore: CardFocusStyleSettingsStore(defaults: defaults),
            captionStore: CardCaptionSettingsStore(defaults: defaults),
            artworkStore: ArtworkSettingsStore(defaults: defaults)
        )
    }

    private func withScreen(
        cards: CardStyleSettingsModel,
        area: ArtworkArea,
        inspect: (UIWindow) async throws -> Void
    ) async throws {
        try await withScreen(
            content: ArtworkCustomizationView(cards: cards, selection: .constant(area.rawValue)),
            inspect: inspect
        )
    }

    private func withScreen(
        content: some View,
        inspect: (UIWindow) async throws -> Void
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView:
            content
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "en_US"))
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        let focusDeadline = ContinuousClock.now + .seconds(3)
        while system.focusedItem == nil, ContinuousClock.now < focusDeadline {
            window.layoutIfNeeded()
            system.requestFocusUpdate(to: host)
            system.updateFocusIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(system.focusedItem)
        try await Task.sleep(for: .milliseconds(350))
        try await inspect(window)
    }

    private func capture(_ window: UIWindow, name: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.regionOfInterest = CGRect(x: 0.40, y: 0, width: 0.60, height: 1)
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}
