import XCTest
@testable import CoreModels

final class CardCaptionSettingsTests: XCTestCase {
    func testFreshProfilesShareNoLabelsDefaultAndPostersAreFirst() {
        XCTAssertEqual(CardStyle.allCases.first, .default)
        let settings = CardCaptionSettings.default
        XCTAssertTrue(settings.overrides.isEmpty)
        for view in CardCaptionView.allCases {
            XCTAssertFalse(settings.showsLabels(in: view))
            XCTAssertEqual(settings.override(for: view), .automatic)
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
            XCTAssertFalse(model("fresh").captions.showsLabels)
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
