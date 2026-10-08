import XCTest
@testable import CoreModels

final class CardCaptionSettingsTests: XCTestCase {
    func testCustomStateAndPresetReplacementSurviveProfileStorageAndTransfer() throws {
        try withDefaults { defaults in
            let source = CardCaptionSettingsStore(defaults: defaults)
            var settings = CardCaptionSettings.default
            settings.toggleCustomization(in: .home)
            settings.toggleCustomization(in: .home)
            source.save(settings)
            XCTAssertNil(source.load().selectedPreset)
            let entries = ProfileSettingsTransfer.capture(namespace: nil, defaults: defaults)
            ProfileSettingsTransfer.apply(entries, namespace: "other", defaults: defaults)
            let other = CardCaptionSettingsStore(defaults: defaults, namespace: "other")
            XCTAssertEqual(other.load(), settings)
            settings.applyPreset(.recommended)
            other.save(settings)
            XCTAssertEqual(other.load(), .default)
            XCTAssertFalse(other.load().showsLabels(in: .home, isShowcase: true))
            XCTAssertTrue(source.load().showsLabels(in: .home, isShowcase: true))
            XCTAssertNil(source.load().selectedPreset)
        }
    }

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

    func testExistingHomeDefaultIsOnAndLegacyOptInSurvivesUntilReset() throws {
        try withDefaults { defaults in
            for showsLabels in [false, true] {
                let namespace = String(showsLabels)
                var hero = HeroSettings.default
                hero.showsCardCaptions = showsLabels
                HeroSettingsStore(defaults: defaults, namespace: namespace).save(hero)
                let store = CardCaptionSettingsStore(defaults: defaults, namespace: namespace)
                XCTAssertEqual(store.load().overrides, showsLabels ? [.home: true] : [:])
                XCTAssertTrue(store.load().showsLabels(in: .home))
                XCTAssertEqual(store.load().showsLabels(in: .home, isShowcase: true), showsLabels)
                XCTAssertEqual(store.load().showsLabels(in: .home, hasArtworkTitle: true), showsLabels)
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

    func testSyncedResetBeforeFirstLoadDoesNotResurrectLegacyHomeLabels() throws {
        try withDefaults { defaults in
            var legacy = HeroSettings.default
            legacy.showsCardCaptions = false
            let source = CardCaptionSettingsStore(defaults: defaults, namespace: "source")
            source.save(.init(showsLabels: false, overrides: [.browse: true]))
            let snapshot = ProfileSettingsTransfer.capture(namespace: "source", defaults: defaults)
            let blob = try XCTUnwrap(snapshot[CardCaptionSettingsStore.storageKey])
            for namespace in ["inactive", "never-received"] {
                HeroSettingsStore(defaults: defaults, namespace: namespace).save(legacy)
                if namespace == "inactive" {
                    ProfileSettingsTransfer.applyOne(
                        baseKey: CardCaptionSettingsStore.storageKey, blob: blob,
                        namespace: namespace, defaults: defaults
                    )
                }
                ProfileSettingsTransfer.removeOne(
                    baseKey: CardCaptionSettingsStore.storageKey, namespace: namespace, defaults: defaults
                )
                let store = CardCaptionSettingsStore(defaults: defaults, namespace: namespace)
                XCTAssertEqual(store.load(), .default)
                XCTAssertEqual(store.load(), .default)
                XCTAssertFalse(ProfileSettingsTransfer.capture(namespace: namespace, defaults: defaults).keys
                    .contains { $0.hasSuffix(".migrated") })
            }
            HeroSettingsStore(defaults: defaults, namespace: "fresh").save(legacy)
            XCTAssertEqual(CardCaptionSettingsStore(defaults: defaults, namespace: "fresh").load(), .default)
            XCTAssertEqual(source.load().overrides, [.browse: true])
        }
    }

    func testAmbiguousHomeOnlyLegacyMigrationAdoptsAppDefaultInBothFormats() throws {
        let payloads: [[String: Any]] = [
            ["preference": "recommended", "showsLabels": true, "overrides": ["home": false]],
            ["showsLabels": false, "overrides": ["home": false]]
        ]
        try withDefaults { defaults in
            for (index, payload) in payloads.enumerated() {
                let namespace = index == 0 ? nil : "inactive"
                let key = SettingsKey.scoped(CardCaptionSettingsStore.storageKey, namespace: namespace)
                let data = try JSONSerialization.data(withJSONObject: payload)
                defaults.set(data, forKey: key)
                defaults.set(true, forKey: key + ".migrated")
                let store = CardCaptionSettingsStore(defaults: defaults, namespace: namespace)
                let migrated = store.load()
                XCTAssertEqual(migrated, .default)
                XCTAssertEqual(migrated.selectedPreset, .recommended)
                for view in CardCaptionView.allCases {
                    XCTAssertTrue(migrated.showsLabels(in: view))
                }
                XCTAssertFalse(migrated.showsLabels(in: .home, isShowcase: true))
                XCTAssertFalse(migrated.showsLabels(in: .home, hasArtworkTitle: true))

                var customized = migrated
                customized.setOverride(.hide, for: .home)
                store.save(customized)
                XCTAssertEqual(store.load(), customized, "A new deliberate Home-off choice must survive.")
                let savedData = try XCTUnwrap(defaults.data(forKey: key))
                let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
                XCTAssertEqual(saved["homeDefaultVersion"] as? Int, 1)
                XCTAssertNil(store.load().selectedPreset)
            }
        }
    }

    func testHomeDefaultCorrectionPreservesExplicitPresetsAndOtherCustomizations() throws {
        let cases: [([String: Any], CardCaptionSettings)] = [
            (["preference": "hide", "overrides": ["home": false]],
             .init(preference: .hide, overrides: [.home: false])),
            (["preference": "show", "overrides": ["home": false]],
             .init(preference: .show, overrides: [.home: false])),
            (["preference": "recommended", "overrides": ["home": true]],
             .init(overrides: [.home: true])),
            (["preference": "recommended", "overrides": ["home": false, "browse": true]],
             .init(overrides: [.home: false, .browse: true])),
            (["showsLabels": false, "overrides": [:]],
             .init(preference: .hide)),
            (["showsLabels": false, "overrides": ["home": false, "search": false]],
             .init(preference: .hide, overrides: [.home: false, .search: false])),
            (["showsLabels": true, "overrides": ["home": false]],
             .init(preference: .show, overrides: [.home: false])),
            (["preference": "recommended", "overrides": ["home": false], "homeDefaultVersion": 1],
             .init(overrides: [.home: false])),
            (["preference": "recommended", "overrides": ["home": false], "homeDefaultVersion": 2],
             .init(overrides: [.home: false]))
        ]
        for (payload, expected) in cases {
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertEqual(try JSONDecoder().decode(CardCaptionSettings.self, from: data), expected)
        }
    }

    func testHomeDefaultCorrectionAndSubsequentOptOutFollowProfileTransfers() throws {
        try withDefaults { defaults in
            let data = try JSONSerialization.data(withJSONObject: [
                "preference": "recommended", "showsLabels": true, "overrides": ["home": false]
            ])
            defaults.set(data, forKey: CardCaptionSettingsStore.storageKey)
            let oldSnapshot = ProfileSettingsTransfer.capture(namespace: nil, defaults: defaults)
            let oldBlob = try XCTUnwrap(oldSnapshot[CardCaptionSettingsStore.storageKey])
            ProfileSettingsTransfer.apply(oldSnapshot, namespace: "bulk", defaults: defaults)
            ProfileSettingsTransfer.applyOne(
                baseKey: CardCaptionSettingsStore.storageKey, blob: oldBlob,
                namespace: "individual", defaults: defaults
            )
            for namespace in ["bulk", "individual"] {
                XCTAssertEqual(
                    CardCaptionSettingsStore(defaults: defaults, namespace: namespace).load(), .default
                )
            }

            let source = CardCaptionSettingsStore(defaults: defaults)
            var updated = source.load()
            updated.setOverride(.hide, for: .home)
            source.save(updated)
            let newSnapshot = ProfileSettingsTransfer.capture(namespace: nil, defaults: defaults)
            let newBlob = try XCTUnwrap(newSnapshot[CardCaptionSettingsStore.storageKey])
            ProfileSettingsTransfer.apply(newSnapshot, namespace: "bulk", defaults: defaults)
            ProfileSettingsTransfer.applyOne(
                baseKey: CardCaptionSettingsStore.storageKey, blob: newBlob,
                namespace: "individual", defaults: defaults
            )
            for namespace in ["bulk", "individual"] {
                let store = CardCaptionSettingsStore(defaults: defaults, namespace: namespace)
                XCTAssertEqual(store.load(), updated)
                XCTAssertFalse(store.load().showsLabels(in: .home))
                ProfileSettingsTransfer.removeOne(
                    baseKey: CardCaptionSettingsStore.storageKey, namespace: namespace, defaults: defaults
                )
                XCTAssertEqual(store.load(), .default)
            }
            XCTAssertEqual(source.load(), updated, "Resetting another profile must not change this one.")
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
