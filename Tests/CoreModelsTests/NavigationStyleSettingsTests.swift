import XCTest
@testable import CoreModels

final class NavigationStyleSettingsStoreTests: XCTestCase {
    @MainActor
    func testOfflineStatusIsTransientAndDoesNotMislabelAuthenticationOrCancellation() {
        let model = NavigationStyleSettingsModel(
            store: NavigationStyleSettingsStore(defaults: makeDefaults()),
            layoutStore: NavigationLibraryLayoutStore(defaults: makeDefaults())
        )
        XCTAssertTrue(model.offlineAccountIDs.isEmpty)
        model.updateContentLibraries(
            [], accountIDs: ["a", "b", "c"], unreachableAccountIDs: ["a", "b", "c"],
            failures: ["a": .serverUnreachable, "b": .unauthorized, "c": .cancelled])
        XCTAssertEqual(model.offlineAccountIDs, ["a"])
        model.updateContentLibraries([], accountIDs: ["a"], unreachableAccountIDs: [])
        XCTAssertTrue(model.offlineAccountIDs.isEmpty)
    }
    private func makeDefaults() -> UserDefaults {
        let suite = "NavigationStyleSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testUnsetProfileUsesPinnedSidebar() {
        let store = NavigationStyleSettingsStore(defaults: makeDefaults())

        XCTAssertEqual(store.load(), .rail)
    }

    func testPinnedSidebarIsFirstInEveryNavigationPicker() {
        XCTAssertEqual(NavigationStyle.allCases, [.rail, .sidebar, .tabBar])
    }

    func testExplicitSelectionSurvivesDefaultChange() {
        let defaults = makeDefaults()
        let store = NavigationStyleSettingsStore(defaults: defaults)
        for style in NavigationStyle.allCases {
            store.save(style)
            XCTAssertEqual(NavigationStyleSettingsStore(defaults: defaults).load(), style)
        }
    }

    func testProfileNamespacesRemainIndependent() {
        let defaults = makeDefaults()
        let primary = NavigationStyleSettingsStore(defaults: defaults)
        let child = NavigationStyleSettingsStore(defaults: defaults, namespace: "child")

        primary.save(.tabBar)

        XCTAssertEqual(primary.load(), .tabBar)
        XCTAssertEqual(child.load(), .rail)
        child.save(.sidebar)
        XCTAssertEqual(NavigationStyleSettingsStore(defaults: defaults, namespace: "child").load(), .sidebar)
        XCTAssertEqual(primary.load(), .tabBar)
    }

    func testAccidentalExitDefaultsOffAndPersistsFalseAcrossRestarts() {
        let defaults = makeDefaults()
        let store = NavigationStyleSettingsStore(defaults: defaults)

        XCTAssertFalse(store.loadPreventsAccidentalExit())

        store.savePreventsAccidentalExit(true)
        XCTAssertTrue(
            NavigationStyleSettingsStore(defaults: defaults).loadPreventsAccidentalExit()
        )

        store.savePreventsAccidentalExit(false)
        XCTAssertFalse(
            NavigationStyleSettingsStore(defaults: defaults).loadPreventsAccidentalExit()
        )
    }

    func testAccidentalExitPreferenceIsIsolatedPerProfile() {
        let defaults = makeDefaults()
        let primary = NavigationStyleSettingsStore(defaults: defaults)
        let child = NavigationStyleSettingsStore(defaults: defaults, namespace: "child")

        child.savePreventsAccidentalExit(true)

        XCTAssertFalse(primary.loadPreventsAccidentalExit())
        XCTAssertTrue(child.loadPreventsAccidentalExit())
    }

    @MainActor
    func testModelUsesInjectedPersistenceForAccidentalExitPreference() {
        let store = NavigationStyleSettingsStore(defaults: makeDefaults())
        store.savePreventsAccidentalExit(true)
        let model = NavigationStyleSettingsModel(
            store: store,
            layoutStore: NavigationLibraryLayoutStore(defaults: makeDefaults())
        )
        XCTAssertTrue(model.preventsAccidentalExit)

        model.preventsAccidentalExit = false

        XCTAssertFalse(store.loadPreventsAccidentalExit())
    }

    func testLayoutStoreUsesInjectedPlatformDefaultWhenUnset() {
        let defaults = makeDefaults()
        let fallback = NavigationLibraryLayout(
            hiddenKeys: [NavigationLibraryLayout.watchlistKey]
        )
        let store = NavigationLibraryLayoutStore(
            defaults: defaults,
            defaultLayout: fallback
        )

        XCTAssertEqual(store.load(), fallback)

        var optedIn = fallback
        optedIn.setVisible(true, for: NavigationLibraryLayout.watchlistKey)
        store.save(optedIn)

        XCTAssertTrue(
            NavigationLibraryLayoutStore(
                defaults: defaults,
                defaultLayout: fallback
            ).load().isVisible(NavigationLibraryLayout.watchlistKey)
        )
    }

    func testDefaultPolicyKeepsSettingsReachableWithoutErasingMobilePreference() {
        let defaults = makeDefaults()
        let key = "com.plozz.navigationLibraryLayout"
        defaults.set(
            Data(
                """
                {"order":[],"hiddenKeys":["\(NavigationLibraryLayout.settingsKey)"]}
                """.utf8
            ),
            forKey: key
        )

        let store = NavigationLibraryLayoutStore(defaults: defaults)
        var layout = store.load()
        XCTAssertTrue(layout.isVisible(NavigationLibraryLayout.settingsKey))
        XCTAssertTrue(layout.hiddenKeys.contains(NavigationLibraryLayout.settingsKey))

        layout.hiddenKeys.insert(NavigationLibraryLayout.settingsKey)
        store.save(layout)
        XCTAssertTrue(store.load().hiddenKeys.contains(NavigationLibraryLayout.settingsKey))
        let available = [NavigationLibraryLayout.homeKey, NavigationLibraryLayout.settingsKey]
        XCTAssertEqual(layout.sections(available: available).enabled, available)
        XCTAssertEqual(layout.sections(available: available, requiredEnabled: []).disabled,
                       [NavigationLibraryLayout.settingsKey])

        layout.setVisible(false, for: NavigationLibraryLayout.settingsKey)
        XCTAssertTrue(layout.isVisible(NavigationLibraryLayout.settingsKey))
    }

    func testMobileSettingsHidingSurvivesPersistenceAndTVReordering() {
        let available = NavigationDestinationDefaults.iOS
        var layout = NavigationLibraryLayout()
        layout.apply(.init(
            enabled: available.filter { $0 != NavigationLibraryLayout.settingsKey },
            disabled: [NavigationLibraryLayout.settingsKey]
        ), available: available, requiredEnabled: [])
        let store = NavigationLibraryLayoutStore(defaults: makeDefaults())
        store.save(layout)
        var restored = store.load()
        XCTAssertFalse(restored.sections(available: available, requiredEnabled: [])
            .enabled.contains(NavigationLibraryLayout.settingsKey))
        let tv = restored.sections(available: available)
        XCTAssertTrue(tv.enabled.contains(NavigationLibraryLayout.settingsKey))
        restored.apply(tv, available: available)
        XCTAssertTrue(restored.hiddenKeys.contains(NavigationLibraryLayout.settingsKey))
    }

    func testEmptyMobileNavigationRetainsAReachableDestination() {
        let available = NavigationDestinationDefaults.iOS
        var layout = NavigationLibraryLayout(hiddenKeys: Set(available))
        XCTAssertEqual(layout.sections(available: available, requiredEnabled: []).enabled,
                       [NavigationLibraryLayout.settingsKey])
        layout.apply(.init(enabled: [], disabled: available), available: available, requiredEnabled: [])
        XCTAssertEqual(layout.sections(available: available, requiredEnabled: []).enabled,
                       [NavigationLibraryLayout.settingsKey])
    }

    func testMoreLabelsFollowTheEnabledOrderOnlyWhenThereAreMoreThanFiveTabs() {
        let available = NavigationDestinationDefaults.iOS
        XCTAssertTrue(NavigationDestinationDefaults.iPhoneOverflowKeys(
            visible: Array(available.prefix(5))
        ).isEmpty)
        XCTAssertEqual(NavigationDestinationDefaults.iPhoneOverflowKeys(visible: available),
                       Set(available.suffix(2)))
        let reordered = Array(available.reversed())
        XCTAssertEqual(NavigationDestinationDefaults.iPhoneOverflowKeys(visible: reordered),
                       Set(reordered.suffix(2)))
    }

    func testMobileDefaultsNeverOverflowEvenWithWatchlistAndKeepTVSettingsVisible() {
        let available = NavigationDestinationDefaults.iOS
        let automatic = NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys
        for hasWatchlist in [false, true] {
            let hidden = hasWatchlist ? automatic : automatic.union([NavigationLibraryLayout.watchlistKey])
            let sections = NavigationLibraryLayout.default
                .resolvingAutomaticVisibility(hidden: hidden)
                .sections(available: available, requiredEnabled: [])
            XCTAssertEqual(sections.enabled, available.filter {
                $0 != NavigationLibraryLayout.settingsKey
                    && (hasWatchlist || $0 != NavigationLibraryLayout.watchlistKey)
            })
            XCTAssertLessThanOrEqual(sections.enabled.count, 5)
            XCTAssertTrue(NavigationDestinationDefaults.iPhoneOverflowKeys(visible: sections.enabled).isEmpty)
        }
        XCTAssertTrue(NavigationLibraryLayout.default
            .sections(available: NavigationDestinationDefaults.compact(hasMusic: true))
            .enabled.contains(NavigationLibraryLayout.settingsKey))
    }

    func testMobileSettingsShowPersistsWithoutSavingAutomaticHidingOrChangingOtherProfiles() throws {
        let defaults = makeDefaults()
        let primary = NavigationLibraryLayoutStore(defaults: defaults)
        let child = NavigationLibraryLayoutStore(defaults: defaults, namespace: "child")
        let available = NavigationDestinationDefaults.iOS
        let automatic = NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys
        func sections(_ layout: NavigationLibraryLayout) -> OrderedVisibilityList.Sections<String> {
            layout.resolvingAutomaticVisibility(hidden: automatic)
                .sections(available: available, requiredEnabled: [])
        }
        var layout = primary.load()
        var unchanged = sections(layout)
        unchanged = .init(enabled: Array(unchanged.enabled.reversed()), disabled: unchanged.disabled)
        layout.apply(unchanged, available: available, requiredEnabled: [], automaticallyHiddenKeys: automatic)
        XCTAssertTrue(layout.hiddenKeys.isEmpty)
        XCTAssertTrue(layout.shownKeys.isEmpty)
        primary.save(layout)
        XCTAssertEqual(sections(primary.load()).disabled, [NavigationLibraryLayout.settingsKey])

        layout.apply(.init(enabled: available, disabled: []), available: available,
                     requiredEnabled: [], automaticallyHiddenKeys: automatic)
        primary.save(layout)
        XCTAssertTrue(primary.load().shownKeys.contains(NavigationLibraryLayout.settingsKey))
        XCTAssertEqual(sections(primary.load()).enabled, available)
        XCTAssertEqual(sections(child.load()).disabled, [NavigationLibraryLayout.settingsKey])

        layout.apply(.init(enabled: available.filter { $0 != NavigationLibraryLayout.settingsKey },
                           disabled: [NavigationLibraryLayout.settingsKey]),
                     available: available, requiredEnabled: [], automaticallyHiddenKeys: automatic)
        primary.save(layout)
        XCTAssertTrue(primary.load().hiddenKeys.contains(NavigationLibraryLayout.settingsKey))
        primary.save(.default)
        XCTAssertEqual(sections(primary.load()).disabled, [NavigationLibraryLayout.settingsKey])
        XCTAssertTrue(primary.load().hiddenKeys.isEmpty)

        let legacy = try JSONDecoder().decode(NavigationLibraryLayout.self, from: JSONEncoder().encode([
            "order": available, "hiddenKeys": []
        ]))
        XCTAssertEqual(sections(legacy).enabled, available, "Keep explicitly arranged legacy navigation.")
    }

    @MainActor
    func testWatchlistVisibilityPersistsPerProfile() {
        let defaults = makeDefaults()
        func model(namespace: String?) -> NavigationStyleSettingsModel {
            NavigationStyleSettingsModel(
                store: NavigationStyleSettingsStore(
                    defaults: defaults,
                    namespace: namespace
                ),
                layoutStore: NavigationLibraryLayoutStore(
                    defaults: defaults,
                    namespace: namespace
                )
            )
        }

        let primary = model(namespace: nil)
        let child = model(namespace: "child")
        XCTAssertTrue(primary.showsWatchlist)
        XCTAssertTrue(child.showsWatchlist)

        primary.showsWatchlist = false

        XCTAssertFalse(model(namespace: nil).showsWatchlist)
        XCTAssertTrue(model(namespace: "child").showsWatchlist)
    }

    @MainActor
    func testResetNavigationRestoresEveryShortcutIncludingFormerSeparateToggles() {
        let defaults = makeDefaults()
        let model = NavigationStyleSettingsModel(
            store: NavigationStyleSettingsStore(defaults: defaults),
            layoutStore: NavigationLibraryLayoutStore(defaults: defaults)
        )
        let available = NavigationRailPlan.customizableKeys(visibleLibraries: [])
        model.applyLibrarySections(
            .init(
                enabled: [NavigationLibraryLayout.settingsKey],
                disabled: available.filter { $0 != NavigationLibraryLayout.settingsKey }
            ),
            available: available
        )
        XCTAssertFalse(model.showsWatchlist)
        XCTAssertFalse(model.showsMusic)
        model.resetLibraryLayout()
        XCTAssertEqual(model.librarySections(available: available).enabled, available)
        XCTAssertTrue(model.showsWatchlist)
        XCTAssertTrue(model.showsMusic)
        XCTAssertEqual(NavigationLibraryLayoutStore(defaults: defaults).load(), .default)
    }

    @MainActor
    func testHorizontalLibraryChoicesPersistWithoutSavingAutomaticHiding() {
        let defaults = makeDefaults()
        func model(_ namespace: String) -> NavigationStyleSettingsModel {
            NavigationStyleSettingsModel(
                store: NavigationStyleSettingsStore(defaults: defaults, namespace: namespace),
                layoutStore: NavigationLibraryLayoutStore(defaults: defaults, namespace: namespace)
            )
        }
        let available = [
            NavigationLibraryLayout.homeKey, "account:movies", "account:shows",
            NavigationLibraryLayout.allLibrariesKey, NavigationLibraryLayout.settingsKey
        ]
        let automatic: Set<String> = ["account:movies", "account:shows", NavigationLibraryLayout.allLibrariesKey]
        let first = model("first")
        first.style = .tabBar
        var sections = first.librarySections(available: available, automaticallyHiddenKeys: automatic)
        XCTAssertEqual(sections.enabled, [NavigationLibraryLayout.homeKey, NavigationLibraryLayout.settingsKey])
        XCTAssertEqual(Set(sections.disabled), automatic)
        first.applyLibrarySections(sections, available: available, automaticallyHiddenKeys: automatic)
        XCTAssertTrue(first.libraryLayout.hiddenKeys.isEmpty, "Opening or reordering must not save automatic Hide choices.")
        XCTAssertTrue(first.libraryLayout.shownKeys.isEmpty)

        sections = .init(
            enabled: [NavigationLibraryLayout.homeKey, "account:movies", NavigationLibraryLayout.settingsKey],
            disabled: ["account:shows", NavigationLibraryLayout.allLibrariesKey]
        )
        first.applyLibrarySections(sections, available: available, automaticallyHiddenKeys: automatic)
        let restored = model("first")
        XCTAssertEqual(restored.libraryLayout.shownKeys, ["account:movies"])
        XCTAssertEqual(restored.librarySections(available: available, automaticallyHiddenKeys: automatic), sections)
        XCTAssertFalse(model("second").libraryLayout.shownKeys.contains("account:movies"))
        restored.style = .sidebar
        XCTAssertEqual(restored.librarySections(available: available).disabled, [])
        restored.style = .tabBar
        XCTAssertEqual(restored.librarySections(available: available, automaticallyHiddenKeys: automatic), sections)
        restored.resetLibraryLayout()
        XCTAssertEqual(
            Set(restored.librarySections(available: available, automaticallyHiddenKeys: automatic).disabled),
            automatic
        )
    }

    @MainActor
    func testFullNavigationLayoutRemainsIndependentAcrossProfiles() {
        let defaults = makeDefaults()
        func model(namespace: String?) -> NavigationStyleSettingsModel {
            NavigationStyleSettingsModel(
                store: NavigationStyleSettingsStore(defaults: defaults, namespace: namespace),
                layoutStore: NavigationLibraryLayoutStore(defaults: defaults, namespace: namespace)
            )
        }
        let available = [
            NavigationLibraryLayout.homeKey,
            NavigationLibraryLayout.searchKey,
            NavigationLibraryLayout.settingsKey,
        ]
        let primary = model(namespace: nil)
        primary.applyLibrarySections(
            .init(
                enabled: [
                    NavigationLibraryLayout.settingsKey,
                    NavigationLibraryLayout.searchKey,
                ],
                disabled: [NavigationLibraryLayout.homeKey]
            ),
            available: available
        )

        XCTAssertEqual(
            model(namespace: nil).librarySections(available: available).enabled,
            [NavigationLibraryLayout.settingsKey, NavigationLibraryLayout.searchKey]
        )
        XCTAssertEqual(
            model(namespace: "child").librarySections(available: available).enabled,
            available
        )
    }
}
