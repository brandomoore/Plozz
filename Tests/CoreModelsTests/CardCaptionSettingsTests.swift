import XCTest
@testable import CoreModels

final class CardCaptionSettingsTests: XCTestCase {
    func testRecommendedShowsBrowsingLabelsButNotShowcaseLabels() {
        XCTAssertEqual(CardStyle.allCases.first, .default)
        let settings = CardCaptionSettings.default
        XCTAssertEqual(settings.preference, .recommended)
        XCTAssertTrue(settings.overrides.isEmpty)
        for view in CardCaptionView.allCases {
            XCTAssertTrue(settings.showsLabels(in: view))
            XCTAssertEqual(settings.showsLabels(in: view, isShowcase: true), view == .episodes)
            XCTAssertEqual(settings.override(for: view), .automatic)
        }
    }

    func testLegacyChoicesAndRecommendedRoundTripWithoutLosingOverrides() throws {
        for choice in [false, true] {
            let data = try JSONSerialization.data(withJSONObject: [
                "showsLabels": choice, "overrides": ["home": !choice]
            ])
            let legacy = try JSONDecoder().decode(CardCaptionSettings.self, from: data)
            XCTAssertEqual(legacy.preference, choice ? .show : .hide)
            XCTAssertEqual(legacy.showsLabels(in: .home, isShowcase: true), !choice)
            XCTAssertEqual(legacy.showsLabels(in: .browse), choice)
        }
        var settings = CardCaptionSettings()
        settings.setOverride(.show, for: .home)
        settings.setOverride(.hide, for: .browse)
        XCTAssertTrue(settings.showsLabels(in: .home, isShowcase: true), "Explicit choices override Recommended.")
        XCTAssertFalse(settings.showsLabels(in: .browse))
        let restored = try JSONDecoder().decode(CardCaptionSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.preference, .recommended)
        settings.resetOverrides()
        XCTAssertFalse(settings.showsLabels(in: .home, isShowcase: true))
        XCTAssertTrue(settings.showsLabels(in: .home))
    }

    func testEveryCaptionScopeHonorsPresetsAndPersistentOverrides() throws {
        XCTAssertEqual(CardCaptionView.customizableCases, CardCaptionView.allCases)
        for view in CardCaptionView.allCases {
            for preference in CardCaptionPreference.allCases {
                for showcase in [false, true] {
                    for artworkTitle in [false, true] {
                        var settings = CardCaptionSettings(preference: preference)
                        let inherited = preference == .show || (preference == .recommended
                            && (view == .episodes || (!showcase && !artworkTitle)))
                        for override in CardCaptionOverride.allCases {
                            settings.setOverride(override, for: view)
                            let restored = try JSONDecoder().decode(
                                CardCaptionSettings.self, from: JSONEncoder().encode(settings)
                            )
                            XCTAssertEqual(
                                restored.showsLabels(in: view, isShowcase: showcase, hasArtworkTitle: artworkTitle),
                                override == .automatic ? inherited : override == .show,
                                "\(view) / \(preference) / \(override) / \(showcase) / \(artworkTitle)"
                            )
                        }
                        settings.resetOverrides()
                        XCTAssertEqual(
                            settings.showsLabels(in: view, isShowcase: showcase, hasArtworkTitle: artworkTitle),
                            inherited
                        )
                    }
                }
            }
        }
    }

    func testSharedChoiceUpdatesInheritedViewsButPreservesExceptions() {
        var settings = CardCaptionSettings()
        settings.setOverride(.show, for: .browse)
        settings.setOverride(.hide, for: .home)
        settings.showsLabels = true
        XCTAssertTrue(settings.showsLabels(in: .browse))
        XCTAssertTrue(settings.showsLabels(in: .recommended))
        XCTAssertFalse(settings.showsLabels(in: .home))
        settings.setOverride(.automatic, for: .home)
        XCTAssertTrue(settings.showsLabels(in: .home))
        XCTAssertEqual(settings.overrides.count, 1)
        settings.resetOverrides()
        XCTAssertTrue(settings.overrides.isEmpty)
        XCTAssertTrue(settings.showsLabels)
    }

    func testExistingHomeChoiceMigratesOnceAndResetDoesNotResurrectIt() throws {
        try withDefaults { defaults in
            for showsLabels in [false, true] {
                let namespace = String(showsLabels)
                var hero = HeroSettings.default
                hero.showsCardCaptions = showsLabels
                HeroSettingsStore(defaults: defaults, namespace: namespace).save(hero)
                let store = CardCaptionSettingsStore(defaults: defaults, namespace: namespace)
                XCTAssertEqual(store.load().overrides, [.home: showsLabels])
                var settings = store.load()
                settings.resetOverrides()
                store.save(settings)
                XCTAssertEqual(store.load(), .default)
                ProfileSettingsTransfer.removeOne(
                    baseKey: CardCaptionSettingsStore.storageKey, namespace: namespace, defaults: defaults
                )
                XCTAssertEqual(store.load(), .default)
            }
        }
    }

    func testFreshProfileDoesNotMigrateLaterUnrelatedHomeEdits() throws {
        try withDefaults { defaults in
            let store = CardCaptionSettingsStore(defaults: defaults)
            XCTAssertEqual(store.load(), .default)
            HeroSettingsStore(defaults: defaults).save(.default)
            XCTAssertEqual(store.load(), .default)
        }
    }

    @MainActor
    func testModelPersistsAndRebuildsEachProfileIndependently() throws {
        try withDefaults { defaults in
            @MainActor func model(_ namespace: String?) -> CardStyleSettingsModel {
                CardStyleSettingsModel(
                    store: CardStyleSettingsStore(defaults: defaults, namespace: namespace),
                    focusStore: CardFocusStyleSettingsStore(defaults: defaults, namespace: namespace),
                    captionStore: CardCaptionSettingsStore(defaults: defaults, namespace: namespace)
                )
            }
            let primary = model(nil)
            primary.captions.showsLabels = true
            primary.captions.setOverride(.hide, for: .home)
            let other = model("other")
            other.captions.setOverride(.show, for: .browse)
            XCTAssertEqual(model(nil).captions, primary.captions)
            XCTAssertEqual(model("other").captions, other.captions)
            XCTAssertEqual(model("fresh").captions.preference, .recommended)
            XCTAssertTrue(model("fresh").captions.showsLabels)
        }
    }

    func testSettingsTransferRoundTripsAndOverridesEncodeAsStableObject() throws {
        try withDefaults { defaults in
            let source = CardCaptionSettingsStore(defaults: defaults)
            let expected = CardCaptionSettings(showsLabels: true, overrides: [.home: false, .search: true])
            source.save(expected)
            let entries = ProfileSettingsTransfer.capture(namespace: nil, defaults: defaults)
            XCTAssertNotNil(entries[CardCaptionSettingsStore.storageKey])
            ProfileSettingsTransfer.apply(entries, namespace: "received", defaults: defaults)
            XCTAssertEqual(
                CardCaptionSettingsStore(defaults: defaults, namespace: "received").load(), expected
            )
            XCTAssertEqual(
                ProfileSettingsTransfer.capture(namespace: "received", defaults: defaults), entries
            )
            let data = try XCTUnwrap(defaults.data(forKey: CardCaptionSettingsStore.storageKey))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["overrides"] as? [String: Bool], ["home": false, "search": true])
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "CardCaptionSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
