import CoreModels
import XCTest

@MainActor
final class NavigationNameTests: XCTestCase {
    func testNamesPreserveIdentityAndArrangementAcrossPersistenceAndReset() throws {
        let suite = "NavigationNames.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationLibraryLayoutStore(defaults: defaults)
        let home = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        let navigation = NavigationStyleSettingsModel(
            store: NavigationStyleSettingsStore(defaults: defaults), layoutStore: store
        )
        let keys = [NavigationLibraryLayout.homeKey, "first:movies", "second:movies"]
        navigation.applyLibrarySections(.init(enabled: Array(keys.reversed()), disabled: []), available: keys)
        let order = navigation.libraryLayout.order
        navigation.renameDestination("first:movies", to: "  Movie night \n", homeVisibility: home)
        navigation.renameDestination("second:movies", to: "Other movies", homeVisibility: home)
        XCTAssertEqual(navigation.libraryLayout.order, order)
        XCTAssertEqual(store.load().customNames["first:movies"], "Movie night")
        XCTAssertEqual(store.load().customNames["second:movies"], "Other movies")
        XCTAssertEqual(
            NavigationRailPlan.key(for: .library("first:movies")), "first:movies"
        )
        navigation.resetLibraryLayout()
        XCTAssertTrue(navigation.libraryLayout.order.isEmpty)
        XCTAssertEqual(store.load().customNames["first:movies"], "Movie night")
        navigation.renameDestination("first:movies", to: " \n ", homeVisibility: home)
        XCTAssertNil(store.load().customNames["first:movies"])
        XCTAssertEqual(store.load().customNames["second:movies"], "Other movies")
    }

    func testWatchlistHasOneNameFromEitherEditorIncludingRestoration() throws {
        let suite = "SharedWatchlistName.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NavigationLibraryLayoutStore(defaults: defaults)
        let homeStore = HomeLibraryVisibilityStore(defaults: defaults)
        let home = HomeLibraryVisibilityModel(store: homeStore)
        let navigation = NavigationStyleSettingsModel(
            store: NavigationStyleSettingsStore(defaults: defaults), layoutStore: store
        )
        let key = NavigationLibraryLayout.watchlistKey
        home.setHomeRowName("Weekend", for: .global(.watchlist))
        XCTAssertEqual(navigation.libraryLayout.customName(for: key, homeVisibility: home.visibility), "Weekend")
        navigation.renameDestination(key, to: "  Saved for later  ", homeVisibility: home)
        XCTAssertEqual(homeStore.load().homeRowName(for: .global(.watchlist)), "Saved for later")
        XCTAssertNil(store.load().customNames[key], "Watchlist must not gain a competing navigation name.")
        XCTAssertEqual(store.load().customName(for: key, homeVisibility: homeStore.load()), "Saved for later")
        home.setHomeRowName("", for: .global(.watchlist))
        XCTAssertNil(navigation.libraryLayout.customName(for: key, homeVisibility: home.visibility))
        navigation.renameDestination(key, to: "Queue", homeVisibility: home)
        navigation.renameDestination(key, to: "\n ", homeVisibility: home)
        XCTAssertNil(homeStore.load().homeRowName(for: .global(.watchlist)))
    }

    func testNamesRemainIsolatedAcrossProfileReloads() throws {
        let suite = "NavigationNameProfiles.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var layout = NavigationLibraryLayout.default
        layout.setCustomName("Cinema", for: "server:films")
        NavigationLibraryLayoutStore(defaults: defaults).save(layout)
        let otherStore = NavigationLibraryLayoutStore(defaults: defaults, namespace: "other")
        XCTAssertTrue(otherStore.load().customNames.isEmpty)
        var otherLayout = otherStore.load()
        otherLayout.setCustomName("Films", for: "server:films")
        otherStore.save(otherLayout)
        XCTAssertEqual(NavigationLibraryLayoutStore(defaults: defaults).load().customNames, ["server:films": "Cinema"])
        XCTAssertEqual(otherStore.load().customNames, ["server:films": "Films"])
    }

    func testLegacyLayoutAndVerbatimNamesRoundTrip() throws {
        let legacy = Data(#"{"order":[],"hiddenKeys":[]}"#.utf8)
        var layout = try JSONDecoder().decode(NavigationLibraryLayout.self, from: legacy)
        XCTAssertTrue(layout.customNames.isEmpty)
        layout.setCustomName("Movies %@ & friends", for: NavigationLibraryLayout.homeKey)
        XCTAssertEqual(try JSONDecoder().decode(
            NavigationLibraryLayout.self, from: JSONEncoder().encode(layout)
        ), layout)
    }
}
