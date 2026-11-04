import XCTest
@testable import CoreModels

@MainActor
final class DiscoverNavigationTests: XCTestCase {
    func testAutomaticVisibilityFollowsConfigurationWithoutPersistingIntent() throws {
        let suite = "DiscoverNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationLibraryLayoutStore(defaults: defaults)
        let model = NavigationStyleSettingsModel(
            store: NavigationStyleSettingsStore(defaults: defaults), layoutStore: store
        )
        let state = Policy()
        model.setDiscoveryPolicy(allowed: { !state.isKids }, isSeerrConfigured: { state.connected })
        let key = NavigationLibraryLayout.discoverKey
        XCTAssertFalse(model.resolvedLibraryLayout.isVisible(key))
        state.connected = true
        XCTAssertTrue(model.resolvedLibraryLayout.isVisible(key))
        XCTAssertTrue(model.resolvedLayout(
            additionallyHiddenKeys: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys
        ).isVisible(key))
        state.connected = false
        XCTAssertFalse(model.resolvedLibraryLayout.isVisible(key))
        XCTAssertEqual(store.load(), .default)
    }

    func testManualChoiceSurvivesConnectionChangesButNeverEnablesKidsAccess() throws {
        let suite = "DiscoverNavigationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = NavigationLibraryLayout.discoverKey
        let store = NavigationLibraryLayoutStore(defaults: defaults)
        store.save(.init(shownKeys: [key]))
        let model = NavigationStyleSettingsModel(
            store: NavigationStyleSettingsStore(defaults: defaults), layoutStore: store
        )
        let state = Policy()
        model.setDiscoveryPolicy(allowed: { !state.isKids }, isSeerrConfigured: { state.connected })
        XCTAssertTrue(model.resolvedLibraryLayout.isVisible(key))
        state.connected = true
        XCTAssertTrue(model.resolvedLibraryLayout.isVisible(key))
        state.isKids = true
        XCTAssertFalse(model.resolvedLibraryLayout.isVisible(key))
        XCTAssertFalse(model.availableNavigationKeys(NavigationDestinationDefaults.iOS).contains(key))
        let sections = model.librarySections(available: NavigationDestinationDefaults.iOS)
        XCTAssertFalse(sections.enabled.contains(key))
        XCTAssertFalse(sections.disabled.contains(key))
        XCTAssertTrue(store.load().shownKeys.contains(key), "Access policy must not rewrite saved adult intent.")
        state.isKids = false
        XCTAssertTrue(model.resolvedLibraryLayout.isVisible(key))
        let available = [NavigationLibraryLayout.homeKey, key, NavigationLibraryLayout.settingsKey]
        model.applyLibrarySections(.init(
            enabled: [NavigationLibraryLayout.homeKey, NavigationLibraryLayout.settingsKey], disabled: [key]
        ), available: available)
        XCTAssertFalse(model.resolvedLibraryLayout.isVisible(key))
        state.connected = false
        state.connected = true
        XCTAssertFalse(model.resolvedLibraryLayout.isVisible(key))
    }

    func testDestinationRoundTripAndRemovalFromRestoredChildSelection() {
        XCTAssertEqual(NavigationRailDestination(storageValue: "discover"), .discover)
        XCTAssertEqual(NavigationRailDestination.discover.storageValue, "discover")
        XCTAssertEqual(NavigationRailPlan.destination(for: NavigationLibraryLayout.discoverKey), .discover)
        XCTAssertEqual(NavigationRailPlan.key(for: .discover), NavigationLibraryLayout.discoverKey)
        XCTAssertEqual(NavigationRailPlan.resolvedSelection(.discover, destinations: [.home, .settings]), .home)
    }

    func testAvailableNowRequiresLibraryProofNotSeerrAvailability() {
        let remote = MediaItem(
            id: "seer:movie:1", title: "Remote", kind: .movie,
            availability: .available, locallyValidatedPlayableSource: false
        )
        var owned = remote
        owned.locallyValidatedPlayableSource = true
        XCTAssertFalse(DiscoverFilters(availableNow: true).includes(remote))
        XCTAssertTrue(DiscoverFilters(availableNow: true).includes(owned))
        owned.isPlayed = true
        XCTAssertFalse(DiscoverFilters(availableNow: true, hideWatched: true).includes(owned))
        XCTAssertTrue(DiscoverFilters(hideWatched: true).includes(remote))
    }

    private final class Policy {
        var isKids = false
        var connected = false
    }
}
