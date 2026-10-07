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
    func testLabelPreviewsOfferRecommendedAndShareCustomizationControls() async throws {
        let suite = "LabelPreviewHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        let settings = Binding(get: { cards.captions }, set: { cards.captions = $0 })
        try await withScreen(content: NavigationStack {
            SettingsSplitLayout(
                title: "Cards",
                rows: [SettingsSplitRow(id: "labels", title: "Labels") {
                    CardLabelControls(settings: settings, style: .borderless)
                }],
                selection: .constant("labels")
            )
        }) { window in
            let initial = try await self.capture(window, name: "labels-recommended-preview")
            for text in [
                "Recommended", "Show labels everywhere", "Hide labels everywhere",
                "Plozz chooses where labels help.", "View customizations override this choice.",
                "Customize by view", "Using defaults"
            ] {
                XCTAssertTrue(initial.contains(text), initial)
            }
            XCTAssertFalse(initial.contains("Showcase"), initial)
            XCTAssertEqual(cards.captions.preference, .recommended)
            cards.captions.setOverride(.hide, for: .browse)
            let customized = try await self.capture(window, name: "labels-customized-preview")
            XCTAssertTrue(customized.contains("1 customized"), customized)
            XCTAssertTrue(customized.contains("Remove view customizations"), customized)
        }
    }

    func testLabelViewChoicesUseResolvedDefaultsAndPreserveOverrides() async throws {
        let suite = "LabelChoicesHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        let settings = Binding(get: { cards.captions }, set: { cards.captions = $0 })
        try await withScreen(content: CardCaptionCustomizationContent(
            settings: settings, selection: .constant("browse")
        )) { window in
            let initial = try await self.capture(window, name: "labels-browse-inherited")
            XCTAssertTrue(initial.contains("Use default: Labels"), initial)
            XCTAssertTrue(initial.contains("No labels"), initial)
            cards.captions.setOverride(.show, for: .browse)
            cards.captions.preference = .hide
            let changed = try await self.capture(window, name: "labels-browse-explicit")
            XCTAssertTrue(changed.contains("Use default: No labels"), changed)
            XCTAssertEqual(cards.captions.override(for: .browse), .show)
            XCTAssertTrue(cards.captions.showsLabels(in: .browse))
            XCTAssertEqual(CardCaptionSettingsStore(defaults: defaults).load(), cards.captions)
            cards.captions.resetOverrides()
            XCTAssertFalse(cards.captions.showsLabels(in: .browse))
        }
    }

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
                XCTAssertTrue(text.contains("Prefer artwork from metadata providers"), text)
                XCTAssertTrue(text.contains("Customize by view"), text)
                XCTAssertTrue(text.contains("Using defaults"), text)
                XCTAssertFalse(text.contains("About artwork sources"), text)
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
            XCTAssertTrue(inherited.contains("Use default: library preferred"), inherited)
            XCTAssertTrue(inherited.contains("Libraries, collections, and playlists"), inherited)
            XCTAssertFalse(inherited.contains("without text"), inherited)
            XCTAssertFalse(inherited.contains("Continue Watching"), inherited)
            XCTAssertLessThan(inherited.split(whereSeparator: \.isWhitespace).count, 30, inherited)

            cards.artwork.setOverride(.online, for: .browse)
            let overridden = try await self.capture(window, name: "artwork-browse-provider-first")
            XCTAssertTrue(overridden.contains("Use default: library preferred"), overridden)
            XCTAssertEqual(cards.artwork.override(for: .browse), .online)
            cards.artwork.preference = .online
            let changed = try await self.capture(window, name: "artwork-browse-changed-preset")
            XCTAssertTrue(changed.contains("Use default: metadata providers preferred"), changed)
            XCTAssertEqual(cards.artwork.override(for: .browse), .online)
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

    func testPresetExplanationsFollowNativeFocusWithoutChangingSelection() async throws {
        let suite = "ArtworkFocusHosted.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = makeCards(defaults: defaults)
        try await withScreen(content: NavigationStack {
            SettingsSplitLayout(
                title: "Appearance",
                rows: [SettingsSplitRow(id: "artwork", title: "Artwork") {
                    ArtworkSettingsControls(cards: cards)
                }],
                selection: .constant("artwork")
            )
        }) { window in
            let snippets = [
                "Plozz chooses artwork to suit each part",
                "Always use local artwork from your libraries",
                "Always use metadata-provider artwork"
            ]
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let host = try XCTUnwrap(window.rootViewController as? ArtworkFocusRequesting)
            for index in 0..<4 {
                window.layoutIfNeeded()
                let allItems = self.focusItems(in: window)
                let items = allItems.filter { $0.frame.width > 700 }
                    .sorted { $0.frame.minY < $1.frame.minY }
                XCTAssertEqual(items.count, 4, allItems.map { "\($0.frame)" }.joined(separator: ", "))
                let target = try XCTUnwrap(items.indices.contains(index) ? items[index] : nil)
                host.artworkFocusTarget = target
                system.requestFocusUpdate(to: try XCTUnwrap(window.rootViewController))
                system.updateFocusIfNeeded()
                host.artworkFocusTarget = nil
                let text = try await self.capture(window, name: "artwork-preset-focus-\(index)")
                XCTAssertTrue(system.focusedItem === target, "Inline help must retain native focus.")
                for (snippetIndex, snippet) in snippets.enumerated() {
                    XCTAssertEqual(text.contains(snippet), index == snippetIndex, text)
                }
                XCTAssertEqual(cards.artwork.preference, .recommended, "Focus must not select a preference.")
                XCTAssertFalse(text.contains("About artwork sources"), text)
            }
        }
    }

    private func focusItems(in window: UIWindow) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [window]
        var seen = Set<ObjectIdentifier>()
        var items: [ObjectIdentifier: any UIFocusItem] = [:]
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let frame = container.coordinateSpace.convert(window.bounds, from: window)
            for item in container.focusItems(in: frame) {
                if let child = item.focusItemContainer { containers.append(child) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) {
                    items[ObjectIdentifier(item)] = item
                }
            }
        }
        return Array(items.values)
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
        let host = ArtworkFocusHost(rootView:
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

@MainActor
private protocol ArtworkFocusRequesting: AnyObject {
    var artworkFocusTarget: (any UIFocusEnvironment)? { get set }
}

@MainActor
private final class ArtworkFocusHost<Content: View>: UIHostingController<Content>, ArtworkFocusRequesting {
    weak var artworkFocusTarget: (any UIFocusEnvironment)?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        artworkFocusTarget.map { [$0] } ?? super.preferredFocusEnvironments
    }
}
