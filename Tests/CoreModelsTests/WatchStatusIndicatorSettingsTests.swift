import XCTest
@testable import CoreModels

final class WatchStatusIndicatorSettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "WatchStatusIndicatorSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDefaultIsUnwatchedWhenEmpty() {
        let store = WatchStatusIndicatorSettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.load(), .unwatched)
        XCTAssertEqual(WatchStatusIndicator.default, .unwatched)
        XCTAssertTrue(store.loadShowsUnwatchedEpisodeCount())
    }

    func testRoundTripForEveryIndicator() {
        let defaults = makeDefaults()
        let store = WatchStatusIndicatorSettingsStore(defaults: defaults)
        for indicator in WatchStatusIndicator.allCases {
            store.save(indicator)
            XCTAssertEqual(store.load(), indicator)
        }
    }

    @MainActor
    func testHiddenPersistsAndTransfersWithoutChangingCountsColorOrOtherProfiles() {
        let defaults = makeDefaults()
        let store = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "viewer")
        let model = WatchStatusIndicatorSettingsModel(store: store)
        model.episodeCountStyle = .floating
        model.color = .purple
        model.indicator = .hidden
        let restored = WatchStatusIndicatorSettingsModel(store: store)
        XCTAssertEqual(restored.indicator, .hidden)
        XCTAssertTrue(restored.showsUnwatchedEpisodeCount)
        XCTAssertEqual(restored.episodeCountStyle, .floating)
        XCTAssertEqual(restored.color, .purple)
        XCTAssertEqual(WatchStatusIndicatorSettingsStore(defaults: defaults).load(), .default)
        let destination = makeDefaults()
        ProfileSettingsTransfer.apply(
            ProfileSettingsTransfer.capture(namespace: "viewer", defaults: defaults),
            namespace: "copy", defaults: destination
        )
        let copy = WatchStatusIndicatorSettingsModel(
            store: WatchStatusIndicatorSettingsStore(defaults: destination, namespace: "copy")
        )
        XCTAssertEqual(copy.indicator, .hidden)
        XCTAssertTrue(copy.showsUnwatchedEpisodeCount)
        XCTAssertEqual(copy.episodeCountStyle, .floating)
        XCTAssertEqual(copy.color, .purple)
    }

    @MainActor
    func testProgressBarsDefaultOnAndPersistIndependentlyPerProfile() {
        let defaults = makeDefaults()
        let store = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "viewer")
        let model = WatchStatusIndicatorSettingsModel(store: store)
        XCTAssertTrue(model.showsProgressBars)
        model.showsProgressBars = false
        XCTAssertFalse(WatchStatusIndicatorSettingsModel(store: store).showsProgressBars)
        XCTAssertTrue(model.showsUnwatchedEpisodeCount)
        XCTAssertEqual(model.indicator, .default)
        XCTAssertTrue(WatchStatusIndicatorSettingsStore(defaults: defaults).loadShowsProgressBars())
        XCTAssertTrue(WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "other").loadShowsProgressBars())
        let destination = makeDefaults()
        ProfileSettingsTransfer.apply(
            ProfileSettingsTransfer.capture(namespace: "viewer", defaults: defaults),
            namespace: "copy", defaults: destination
        )
        XCTAssertFalse(WatchStatusIndicatorSettingsStore(defaults: destination, namespace: "copy").loadShowsProgressBars())
        XCTAssertTrue(WatchStatusIndicatorSettingsStore(defaults: destination).loadShowsProgressBars())
        model.showsProgressBars = true
        XCTAssertTrue(store.loadShowsProgressBars())
    }

    func testLegacyAndInvalidProgressBarPreferenceUseDefault() {
        let defaults = makeDefaults()
        let store = WatchStatusIndicatorSettingsStore(defaults: defaults)
        store.save(.hidden)
        XCTAssertTrue(store.loadShowsProgressBars())
        defaults.set("invalid", forKey: WatchStatusIndicatorSettingsStore.progressBarsStorageKey)
        XCTAssertTrue(store.loadShowsProgressBars())
        store.saveShowsProgressBars(false)
        XCTAssertEqual(defaults.object(forKey: WatchStatusIndicatorSettingsStore.progressBarsStorageKey) as? Bool, false)
    }

    func testCorruptValueFallsBackToDefault() {
        let defaults = makeDefaults()
        defaults.set("not-a-real-indicator", forKey: "com.plozz.watchStatusIndicator")
        XCTAssertEqual(WatchStatusIndicatorSettingsStore(defaults: defaults).load(), .default)
    }

    /// The primary profile (`namespace == nil`) keeps the legacy un-suffixed key.
    func testPrimaryProfileUsesLegacyKey() {
        let defaults = makeDefaults()
        defaults.set(WatchStatusIndicator.unwatched.rawValue, forKey: "com.plozz.watchStatusIndicator")
        let store = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: nil)
        XCTAssertEqual(store.load(), .unwatched)
    }

    /// A non-primary profile writes to `"<key>.<namespace>"` and is isolated from
    /// both the primary profile and other namespaces.
    func testNamespaceIsolatesProfiles() {
        let defaults = makeDefaults()
        let primary = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: nil)
        let alice = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "alice")
        let bob = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "bob")

        primary.save(.watched)
        alice.save(.unwatched)
        bob.save(.watched)

        XCTAssertEqual(primary.load(), .watched)
        XCTAssertEqual(alice.load(), .unwatched)
        XCTAssertEqual(bob.load(), .watched)

        // The namespaced profile uses the suffixed key, leaving the legacy key alone.
        XCTAssertEqual(defaults.string(forKey: "com.plozz.watchStatusIndicator.alice"), WatchStatusIndicator.unwatched.rawValue)
        XCTAssertEqual(defaults.string(forKey: "com.plozz.watchStatusIndicator"), WatchStatusIndicator.watched.rawValue)
    }

    @MainActor
    func testModelPersistsOnChange() {
        let defaults = makeDefaults()
        let model = WatchStatusIndicatorSettingsModel(store: WatchStatusIndicatorSettingsStore(defaults: defaults))
        model.indicator = .unwatched
        XCTAssertEqual(WatchStatusIndicatorSettingsStore(defaults: defaults).load(), .unwatched)
        model.showsUnwatchedEpisodeCount = false
        XCTAssertFalse(WatchStatusIndicatorSettingsStore(defaults: defaults).loadShowsUnwatchedEpisodeCount())
        XCTAssertEqual(model.indicator, .unwatched, "Count is independent of the indicator style")
    }

    func testEpisodeCountPreferenceIsProfileScopedAndTransferable() {
        let defaults = makeDefaults()
        let alice = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "alice")
        alice.saveShowsUnwatchedEpisodeCount(false)
        XCTAssertFalse(alice.loadShowsUnwatchedEpisodeCount())
        XCTAssertTrue(WatchStatusIndicatorSettingsStore(defaults: defaults).loadShowsUnwatchedEpisodeCount())
        XCTAssertTrue(WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "bob").loadShowsUnwatchedEpisodeCount())
        let snapshot = ProfileSettingsTransfer.capture(namespace: "alice", defaults: defaults)
        let destination = makeDefaults()
        ProfileSettingsTransfer.apply(snapshot, namespace: "alice", defaults: destination)
        XCTAssertFalse(WatchStatusIndicatorSettingsStore(defaults: destination, namespace: "alice").loadShowsUnwatchedEpisodeCount())
        XCTAssertTrue(WatchStatusIndicatorSettingsStore(defaults: destination).loadShowsUnwatchedEpisodeCount())
    }

    @MainActor
    func testEpisodeCountStyleMigratesOnceThenStaysIndependent() {
        for indicator in WatchStatusIndicator.allCases {
            let defaults = makeDefaults()
            let store = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "legacy")
            store.save(indicator)
            let expected: EpisodeCountBadgeStyle = indicator == .watched ? .floating : .attached
            let model = WatchStatusIndicatorSettingsModel(store: store)
            XCTAssertEqual(model.episodeCountStyle, expected)
            model.indicator = indicator == .watched ? .unwatched : .watched
            model.showsUnwatchedEpisodeCount = false
            XCTAssertEqual(WatchStatusIndicatorSettingsModel(store: store).episodeCountStyle, expected)
            for style in EpisodeCountBadgeStyle.allCases {
                model.episodeCountStyle = style
                XCTAssertEqual(store.loadEpisodeCountStyle(), style)
                XCTAssertFalse(model.showsUnwatchedEpisodeCount)
            }
        }
    }

    func testEpisodeCountStyleTransfersWithoutLeakingBetweenProfiles() {
        let defaults = makeDefaults()
        let alice = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "alice")
        alice.save(.unwatched)
        alice.saveEpisodeCountStyle(.floating)
        XCTAssertEqual(WatchStatusIndicatorSettingsStore(defaults: defaults).loadEpisodeCountStyle(), .attached)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "alice", defaults: defaults)
        let destination = makeDefaults()
        ProfileSettingsTransfer.apply(snapshot, namespace: "copy", defaults: destination)
        let copy = WatchStatusIndicatorSettingsStore(defaults: destination, namespace: "copy")
        XCTAssertEqual(copy.loadEpisodeCountStyle(), .floating)
        XCTAssertEqual(copy.load(), .unwatched)
        XCTAssertEqual(WatchStatusIndicatorSettingsStore(defaults: destination, namespace: "bob").loadEpisodeCountStyle(), .attached)
    }

    func testUnknownCountStyleUsesDefaultWithoutChangingStoredValue() {
        let defaults = makeDefaults()
        defaults.set("future-style", forKey: WatchStatusIndicatorSettingsStore.episodeCountStyleStorageKey)
        let store = WatchStatusIndicatorSettingsStore(defaults: defaults)
        store.save(.watched)
        XCTAssertEqual(store.loadEpisodeCountStyle(), .default)
        XCTAssertEqual(defaults.string(forKey: WatchStatusIndicatorSettingsStore.episodeCountStyleStorageKey), "future-style")
    }

    @MainActor
    func testEveryColorPersistsWithoutChangingOtherIndicatorPreferences() {
        let defaults = makeDefaults()
        let store = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "colors")
        let model = WatchStatusIndicatorSettingsModel(store: store)
        model.indicator = .watched
        model.showsUnwatchedEpisodeCount = false
        XCTAssertEqual(WatchIndicatorColor.allCases.count, 8)
        for color in WatchIndicatorColor.allCases {
            model.color = color
            XCTAssertEqual(WatchStatusIndicatorSettingsModel(store: store).color, color)
            XCTAssertEqual(store.load(), .watched)
            XCTAssertFalse(store.loadShowsUnwatchedEpisodeCount())
        }
    }

    func testUnknownColorFallsBackToWhiteWithinItsProfile() {
        let defaults = makeDefaults()
        defaults.set("future-color", forKey: "com.plozz.watchIndicatorColor.alice")
        let alice = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "alice")
        let bob = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "bob")
        bob.saveColor(.purple)
        XCTAssertEqual(alice.loadColor(), .white)
        XCTAssertEqual(bob.loadColor(), .purple)
    }

    @MainActor
    func testColorIsProfileScopedAndTransferable() {
        let defaults = makeDefaults()
        let alice = WatchStatusIndicatorSettingsStore(defaults: defaults, namespace: "alice")
        XCTAssertEqual(alice.loadColor(), .white)
        alice.saveColor(.blue)
        XCTAssertEqual(WatchStatusIndicatorSettingsModel(store: alice).color, .blue)
        XCTAssertEqual(WatchStatusIndicatorSettingsStore(defaults: defaults).loadColor(), .white)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "alice", defaults: defaults)
        let destination = makeDefaults()
        ProfileSettingsTransfer.apply(snapshot, namespace: "alice", defaults: destination)
        XCTAssertEqual(WatchStatusIndicatorSettingsStore(defaults: destination, namespace: "alice").loadColor(), .blue)
    }
}
