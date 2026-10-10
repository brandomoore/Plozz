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
}
