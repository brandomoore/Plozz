import XCTest
@testable import CoreModels

/// The rail's arrangement rules. These are the ones a user notices immediately if
/// they're wrong — a library that vanishes when a server is added, an order that
/// resets, or a hidden library that comes back on relaunch.
final class NavigationRailPlanTests: XCTestCase {
    func testNewPlexLibrariesAppearAutomaticallyInEveryTVNavigationStyle() {
        let libraries = [
            AggregatedLibrary(
                accountID: "plex", accountName: "Viewer", serverName: "Plex",
                providerKind: .plex,
                library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
            ),
            library("shows", title: "Shows", account: "jellyfin", kind: .series)
        ]
        for style in [NavigationStyle.tabBar, .sidebar, .rail] {
            let layout = NavigationLibraryLayout.default
            let keys = NavigationRailPlan.customizableKeys(visibleLibraries: libraries, style: style)
            let destinations = NavigationRailPlan.destinations(
                visibleLibraries: libraries, layout: layout, availableKeys: keys
            )
            XCTAssertTrue(destinations.contains(.library("plex:movies")), "\(style)")
            XCTAssertTrue(destinations.contains(.library("jellyfin:shows")), "\(style)")
            XCTAssertTrue(layout.sections(available: keys).enabled.contains("plex:movies"), "\(style)")
        }
    }

    func testOfflineBadgesKeepDestinationsAndOnlyMarkAllLibrariesWhenAllAreOffline() {
        let libraries = [
            library("movies", title: "Movies", account: "a"),
            library("shows", title: "Shows", account: "a", kind: .series),
            library("movies", title: "Movies", account: "b")
        ]
        let baseline = NavigationRailPlan.entries(visibleLibraries: libraries, layout: .default)
        for offline: Set<String> in [[], ["a"], ["a", "b"]] {
            let entries = NavigationRailPlan.entries(
                visibleLibraries: libraries, layout: .default, offlineAccountIDs: offline)
            XCTAssertEqual(entries.map(\.id), baseline.map(\.id))
            XCTAssertEqual(entries.map(\.destination), baseline.map(\.destination))
            for entry in entries {
                XCTAssertEqual(entry.isOffline, entry.library.map { offline.contains($0.accountID) } ?? (offline.count == 2))
            }
        }
    }
    func testPreparedEntriesPreserveEachStylesOrderAndVisibility() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Shows", account: "a", kind: .series),
            library("3", title: "Music", account: "a", isMusic: true),
            library("1", title: "Other Movies", account: "b")
        ]
        let layouts: [NavigationLibraryLayout] = [
            .default,
            .init(order: ["b:1", "a:2", NavigationLibraryLayout.allLibrariesKey]),
            .init(order: [NavigationLibraryLayout.settingsKey, "a:2"],
                  hiddenKeys: [NavigationLibraryLayout.homeKey, "a:1"]),
            .init(hiddenKeys: [NavigationLibraryLayout.allLibrariesKey, "b:1"])
        ]
        for visible in [libraries, Array(libraries.prefix(1)), []] {
            for layout in layouts {
                let entries = NavigationRailPlan.entries(visibleLibraries: visible, layout: layout)
                for keys in [
                    NavigationDestinationDefaults.compact(hasMusic: true),
                    NavigationDestinationDefaults.sidebar(visibleLibraries: visible, hasMusic: true),
                    NavigationDestinationDefaults.rail(visibleLibraries: visible, hasMusic: false)
                ] {
                    XCTAssertEqual(
                        NavigationRailPlan.destinations(
                            libraryEntries: entries, layout: layout, availableKeys: keys
                        ),
                        NavigationRailPlan.destinations(
                            visibleLibraries: visible, layout: layout, availableKeys: keys
                        )
                    )
                }
            }
        }
    }

    func testEditorDefaultsMatchEachTVNavigationStyle() {
        XCTAssertEqual(
            NavigationRailPlan.customizableKeys(visibleLibraries: [], style: .rail),
            NavigationDestinationDefaults.rail(visibleLibraries: [], hasMusic: true)
        )
        XCTAssertEqual(
            NavigationRailPlan.customizableKeys(visibleLibraries: [], style: .tabBar),
            NavigationDestinationDefaults.sidebar(visibleLibraries: [], hasMusic: true)
        )
        XCTAssertTrue(
            NavigationRailPlan.customizableKeys(visibleLibraries: [], style: .tabBar)
                .contains(NavigationLibraryLayout.allLibrariesKey)
        )
    }

    func testTopBarIncludesEveryResolvedDestinationWithoutChangingSidebarLayout() {
        let libraries = (1...20).map { library("\($0)", title: "Library \($0)", account: "plex") }
        var layout = NavigationLibraryLayout(
            order: ["plex:20", NavigationLibraryLayout.homeKey],
            hiddenKeys: ["plex:1", NavigationLibraryLayout.musicKey]
        )
        let saved = layout
        func resolved() -> [NavigationRailDestination] {
            NavigationRailPlan.destinations(
                visibleLibraries: libraries, layout: layout,
                availableKeys: NavigationDestinationDefaults.sidebar(visibleLibraries: libraries, hasMusic: true)
            )
        }
        let sidebar = resolved()
        let horizontal = NavigationDestinationDefaults.topBar(destinations: sidebar)
        XCTAssertEqual(horizontal, sidebar)
        XCTAssertEqual(horizontal.first, .library("plex:20"))
        XCTAssertTrue(horizontal.contains(.settings))
        XCTAssertFalse(horizontal.contains(.music))
        XCTAssertFalse(horizontal.contains(.library("plex:1")))
        XCTAssertEqual(layout, saved)
        XCTAssertTrue(sidebar.contains(.settings))
        XCTAssertEqual(sidebar.filter { if case .library = $0 { return true }; return false }.count, 19)
        layout.setVisible(false, for: "plex:20")
        let next = NavigationDestinationDefaults.topBar(destinations: resolved())
        XCTAssertEqual(next.count, horizontal.count - 1, "Hiding an item removes only that destination.")
        XCTAssertEqual(next.first, .home)
        XCTAssertEqual(NavigationDestinationDefaults.topBar(destinations: [.settings]), [.settings])
    }

    func testHorizontalSettingsRespectsExplicitMoveAndHideWithoutChangingVerticalSafety() throws {
        let keys = [NavigationLibraryLayout.homeKey, "plex:1", NavigationLibraryLayout.settingsKey]
        var layout = NavigationLibraryLayout()
        XCTAssertTrue(layout.pinsSettingsInTopBar)
        layout.apply(.init(enabled: [NavigationLibraryLayout.homeKey, NavigationLibraryLayout.settingsKey, "plex:1"],
                           disabled: []), available: keys)
        XCTAssertTrue(layout.pinsSettingsInTopBar, "Moving another destination must not unpin Settings.")
        XCTAssertEqual(NavigationDestinationDefaults.topBar(destinations: [.home, .settings, .library("plex:1")],
                                                            layout: layout),
                       [.home, .library("plex:1"), .settings])
        layout.recordMove(of: NavigationLibraryLayout.settingsKey)
        XCTAssertFalse(layout.pinsSettingsInTopBar)
        XCTAssertEqual(NavigationDestinationDefaults.topBar(destinations: [.home, .settings, .library("plex:1")],
                                                            layout: layout),
                       [.home, .settings, .library("plex:1")])
        layout.apply(.init(enabled: [NavigationLibraryLayout.homeKey, "plex:1"],
                           disabled: [NavigationLibraryLayout.settingsKey]), available: keys, requiredEnabled: [])
        let restored = try JSONDecoder().decode(NavigationLibraryLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(restored, layout)
        XCTAssertFalse(restored.pinsSettingsInTopBar)
        XCTAssertEqual(NavigationDestinationDefaults.topBar(destinations: [.home, .settings, .library("plex:1")],
                                                            layout: restored),
                       [.home, .library("plex:1")])
        XCTAssertTrue(restored.sections(available: keys).enabled.contains(NavigationLibraryLayout.settingsKey))
        XCTAssertTrue(NavigationLibraryLayout.default.pinsSettingsInTopBar)
    }

    func testHorizontalLibrariesAppearByDefaultAndKeepTheirDistinctDestinationIdentities() {
        let libraries = [
            library("movies", title: "Movies", account: "a"),
            library("movies", title: "Movies", account: "b"),
            library("music", title: "Music", account: "a", isMusic: true)
        ]
        let keys = NavigationRailPlan.customizableKeys(visibleLibraries: libraries, style: .tabBar)
        var layout = NavigationLibraryLayout.default
        func destinations() -> [NavigationRailDestination] {
            NavigationRailPlan.destinations(
                visibleLibraries: libraries,
                layout: layout,
                availableKeys: keys
            )
        }
        XCTAssertTrue(destinations().contains(.library("a:movies")))
        XCTAssertTrue(destinations().contains(.library("b:movies")))
        XCTAssertTrue(destinations().contains(.allLibraries))
        XCTAssertFalse(destinations().contains(.library("a:music")))
        layout.order = ["b:movies", NavigationLibraryLayout.homeKey, "a:movies"]
        let resolved = destinations()
        XCTAssertEqual(Array(resolved.prefix(3)), [.library("b:movies"), .home, .library("a:movies")])
        XCTAssertTrue(resolved.contains(.allLibraries))
        XCTAssertEqual(Set(resolved).count, resolved.count)
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(.library("a:movies"), destinations: resolved),
            .library("a:movies")
        )
        for destination in resolved {
            XCTAssertEqual(NavigationRailDestination(storageValue: destination.storageValue), destination)
        }
        layout.setVisible(false, for: "a:movies")
        XCTAssertFalse(destinations().contains(.library("a:movies")))
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(.library("a:movies"), destinations: destinations()),
            .library("b:movies")
        )
    }

    func testUnavailableLibrariesCannotReappear() {
        let libraries = [library("movies", title: "Movies", account: "a")]
        let layout = NavigationLibraryLayout(shownKeys: ["removed:movies", "a:movies"])
        let destinations = NavigationRailPlan.destinations(
            visibleLibraries: libraries, layout: layout,
            availableKeys: NavigationRailPlan.customizableKeys(visibleLibraries: libraries, style: .tabBar)
        )
        XCTAssertTrue(destinations.contains(.library("a:movies")))
        XCTAssertFalse(destinations.contains(.library("removed:movies")))
        XCTAssertFalse(destinations.contains(.allLibraries))
    }

    func testIOSCanHideEveryContentDestinationIncludingDownloads() {
        let available = NavigationDestinationDefaults.iOS
        XCTAssertTrue(available.contains(NavigationLibraryLayout.downloadsKey))
        let layout = NavigationLibraryLayout(hiddenKeys: Set(available))
        XCTAssertEqual(layout.visibleKeys(available: available), [NavigationLibraryLayout.settingsKey])
    }

    func testIOSDownloadsAndSearchCanMoveAheadOfHome() {
        let available = NavigationDestinationDefaults.iOS
        let first = [NavigationLibraryLayout.downloadsKey, NavigationLibraryLayout.searchKey]
        let layout = NavigationLibraryLayout(order: first)
        XCTAssertEqual(Array(layout.visibleKeys(available: available).prefix(2)), first)
    }

    func testMobileNavigationIncludesEveryVideoLibraryAndPreservesBuiltinOrder() {
        let libraries = (0..<20).map { library("\($0)", title: "Library \($0)", account: "server") }
        let music = library("music", title: "Music", account: "server", isMusic: true)
        let keys = NavigationDestinationDefaults.iOS(visibleLibraries: libraries + [music])
        XCTAssertEqual(
            keys.filter { !Set(libraries.map(\.key) + [NavigationLibraryLayout.allLibrariesKey]).contains($0) },
            NavigationDestinationDefaults.iOS
        )
        XCTAssertTrue(keys.contains(NavigationLibraryLayout.allLibrariesKey))
        XCTAssertEqual(keys.filter { $0.hasPrefix("server:") }, libraries.map(\.key))
        XCTAssertEqual(Array(keys.prefix(3)), NavigationDestinationDefaults.iOSDefaultVisibleKeys)
        let layout = NavigationLibraryLayout(order: ["server:19", "server:0"], hiddenKeys: ["server:1"])
        let visible = layout.sections(available: keys, requiredEnabled: []).enabled
        XCTAssertFalse(visible.contains("server:1"))
        XCTAssertLessThan(visible.firstIndex(of: "server:19")!, visible.firstIndex(of: "server:0")!)
        XCTAssertTrue(NavigationDestinationDefaults.iPhoneOverflowKeys(visible: visible).contains("server:18"))
    }


    func testMobileAllLibrariesRequiresMultipleVideoLibrariesAndRemainsArrangeable() {
        let movies = library("movies", title: "Movies", account: "plex")
        let shows = library("shows", title: "Shows", account: "jellyfin", kind: .series)
        let music = library("music", title: "Music", account: "plex", isMusic: true)
        let key = NavigationLibraryLayout.allLibrariesKey
        XCTAssertFalse(NavigationDestinationDefaults.iOS(visibleLibraries: []).contains(key))
        XCTAssertFalse(NavigationDestinationDefaults.iOS(visibleLibraries: [movies, music]).contains(key))
        let available = NavigationDestinationDefaults.iOS(visibleLibraries: [movies, shows, music])
        let layout = NavigationLibraryLayout(order: [key, NavigationLibraryLayout.homeKey], hiddenKeys: [movies.key])
        XCTAssertEqual(layout.visibleKeys(available: available).first, key)
        let hidden = NavigationLibraryLayout(hiddenKeys: [key])
        XCTAssertFalse(hidden.visibleKeys(available: available).contains(key))
    }

    func testMobileLibrariesStayOptInAndMoreRequiresSixExplicitPages() throws {
        let libraries = (0..<20).map { library("\($0)", title: "Library \($0)", account: "server") }
        let available = NavigationDestinationDefaults.iOS(visibleLibraries: libraries)
        let automatic = NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: available)
        var layout = NavigationLibraryLayout.default
        func sections() -> OrderedVisibilityList.Sections<String> {
            layout.resolvingAutomaticVisibility(hidden: automatic).sections(available: available, requiredEnabled: [])
        }
        XCTAssertEqual(sections().enabled, NavigationDestinationDefaults.iOSDefaultVisibleKeys)
        XCTAssertTrue(sections().disabled.contains(NavigationLibraryLayout.allLibrariesKey))
        for additions in [
            [NavigationLibraryLayout.allLibrariesKey, "server:0"],
            [NavigationLibraryLayout.allLibrariesKey, "server:0", NavigationLibraryLayout.watchlistKey]
        ] {
            let enabled = NavigationDestinationDefaults.iOSDefaultVisibleKeys + additions
            layout.apply(.init(enabled: enabled, disabled: available.filter { !enabled.contains($0) }),
                         available: available, requiredEnabled: [], automaticallyHiddenKeys: automatic)
            layout = try JSONDecoder().decode(NavigationLibraryLayout.self, from: JSONEncoder().encode(layout))
            XCTAssertEqual(sections().enabled, enabled)
            XCTAssertEqual(NavigationDestinationDefaults.iPhoneOverflowKeys(visible: sections().enabled),
                           enabled.count == 5 ? [] : Set(enabled.dropFirst(4)))
        }
        let expanded = available + ["server:new"]
        XCTAssertTrue(layout.resolvingAutomaticVisibility(
            hidden: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: expanded)
        ).sections(available: expanded, requiredEnabled: []).disabled.contains("server:new"))
        layout = .default
        XCTAssertEqual(sections().enabled, NavigationDestinationDefaults.iOSDefaultVisibleKeys)
    }

    private func library(
        _ id: String,
        title: String,
        account: String,
        kind: MediaItemKind = .movie,
        isMusic: Bool = false
    ) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: account,
            accountName: account,
            serverName: "Server \(account)",
            providerKind: .jellyfin,
            library: MediaLibrary(
                id: id,
                title: title,
                kind: kind,
                isMusic: isMusic,
                sourceAccountID: account
            )
        )
    }

    // MARK: Available keys

    func testAvailableKeysLeadWithAllLibrariesAndExcludeMusic() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Songs", account: "a", isMusic: true),
            library("3", title: "Shows", account: "a", kind: .series)
        ]
        XCTAssertEqual(
            NavigationRailPlan.availableKeys(visibleLibraries: libraries),
            [NavigationLibraryLayout.allLibrariesKey, "a:1", "a:3"]
        )
    }

    func testCustomizableKeysIncludeEveryBuiltInAndExcludeMusicLibraries() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Songs", account: "a", isMusic: true),
        ]
        var expected = [
            NavigationLibraryLayout.homeKey,
            NavigationLibraryLayout.watchlistKey,
        ]
        expected.append(NavigationLibraryLayout.liveTVKey)
        expected += [
            NavigationLibraryLayout.searchKey,
            NavigationLibraryLayout.musicKey,
            NavigationLibraryLayout.allLibrariesKey,
            "a:1",
            NavigationLibraryLayout.settingsKey,
        ]

        XCTAssertEqual(
            NavigationRailPlan.customizableKeys(visibleLibraries: libraries),
            expected
        )
    }

    // MARK: Default arrangement

    func testDefaultLayoutShowsEverythingInDiscoveryOrder() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Shows", account: "a", kind: .series)
        ]
        let entries = NavigationRailPlan.entries(visibleLibraries: libraries, layout: .default)
        XCTAssertEqual(
            entries.map(\.key),
            [NavigationLibraryLayout.allLibrariesKey, "a:1", "a:2"]
        )
        XCTAssertTrue(entries[0].isAllLibraries)
        XCTAssertEqual(entries[1].library?.library.title, "Movies")
    }

    func testCombinedEntryIsOmittedWhenThereIsNothingToCombine() {
        // One library means "All Libraries" would just be a duplicate of it, and
        // zero means it would open an empty grid.
        let single = [library("1", title: "Movies", account: "a")]
        XCTAssertEqual(
            NavigationRailPlan.entries(visibleLibraries: single, layout: .default).map(\.key),
            ["a:1"]
        )
        XCTAssertTrue(NavigationRailPlan.entries(visibleLibraries: [], layout: .default).isEmpty)
    }

    // MARK: Reordering + hiding

    func testExplicitOrderIsHonouredAndNewLibrariesAppendRatherThanVanish() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Shows", account: "a", kind: .series),
            library("3", title: "Anime", account: "a", kind: .series)
        ]
        var layout = NavigationLibraryLayout(
            order: ["a:2", NavigationLibraryLayout.allLibrariesKey, "a:1"]
        )
        // "a:3" was discovered after the arrangement was saved.
        XCTAssertEqual(
            NavigationRailPlan.entries(visibleLibraries: libraries, layout: layout).map(\.key),
            ["a:2", NavigationLibraryLayout.allLibrariesKey, "a:1", "a:3"]
        )

        layout.setVisible(false, for: "a:1")
        XCTAssertEqual(
            NavigationRailPlan.entries(visibleLibraries: libraries, layout: layout).map(\.key),
            ["a:2", NavigationLibraryLayout.allLibrariesKey, "a:3"]
        )
    }

    func testLegacyLibraryOnlyOrderKeepsEachStylesBuiltInDefaults() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Shows", account: "a", kind: .series),
        ]
        let layout = NavigationLibraryLayout(
            order: ["a:2", NavigationLibraryLayout.allLibrariesKey, "a:1"]
        )
        let available = [
            NavigationLibraryLayout.searchKey,
            NavigationLibraryLayout.homeKey,
            NavigationLibraryLayout.watchlistKey,
            NavigationLibraryLayout.allLibrariesKey,
            "a:1",
            "a:2",
            NavigationLibraryLayout.settingsKey,
        ]

        XCTAssertEqual(
            NavigationRailPlan.destinations(
                visibleLibraries: libraries,
                layout: layout,
                availableKeys: available
            ),
            [.search, .home, .watchlist, .library("a:2"), .allLibraries, .library("a:1"), .settings]
        )
    }

    func testExplicitBuiltInOrderWinsAcrossSupportedDestinations() {
        let libraries = [
            library("1", title: "Movies", account: "a"),
            library("2", title: "Shows", account: "a", kind: .series),
        ]
        let layout = NavigationLibraryLayout(order: [
            NavigationLibraryLayout.settingsKey,
            "a:2",
            NavigationLibraryLayout.searchKey,
            NavigationLibraryLayout.homeKey,
            NavigationLibraryLayout.allLibrariesKey,
            "a:1",
            NavigationLibraryLayout.watchlistKey,
        ])
        let available = [
            NavigationLibraryLayout.homeKey,
            NavigationLibraryLayout.watchlistKey,
            NavigationLibraryLayout.searchKey,
            NavigationLibraryLayout.allLibrariesKey,
            "a:1",
            "a:2",
            NavigationLibraryLayout.settingsKey,
        ]

        XCTAssertEqual(
            NavigationRailPlan.destinations(
                visibleLibraries: libraries,
                layout: layout,
                availableKeys: available
            ),
            [.settings, .library("a:2"), .search, .home, .allLibraries, .library("a:1"), .watchlist]
        )
    }

    func testApplyingAnEditPreservesTheArrangementOfAnOfflineLibrary() {
        // A server that is briefly unreachable must not cost the viewer the
        // arrangement they set for its libraries.
        var layout = NavigationLibraryLayout(
            order: ["a:1", "b:1", "a:2"],
            hiddenKeys: ["b:1"]
        )
        let available = ["a:1", "a:2"]
        let edited = OrderedVisibilityList.Sections(enabled: ["a:2"], disabled: ["a:1"])
        layout.apply(edited, available: available)

        XCTAssertEqual(layout.order, ["a:2", "b:1", "a:1"])
        XCTAssertEqual(layout.hiddenKeys, ["b:1", "a:1"])
    }

    func testApplyingAnEditUnhidesALibraryMovedBackAboveTheDivider() {
        var layout = NavigationLibraryLayout(order: ["a:1", "a:2"], hiddenKeys: ["a:2"])
        let available = ["a:1", "a:2"]
        layout.apply(
            OrderedVisibilityList.Sections(enabled: ["a:1", "a:2"], disabled: []),
            available: available
        )
        XCTAssertTrue(layout.hiddenKeys.isEmpty)
        XCTAssertEqual(layout.visibleKeys(available: available), ["a:1", "a:2"])
    }

    func testEditingLibrariesPreservesOptionalDestinationVisibility() {
        var layout = NavigationLibraryLayout(
            hiddenKeys: [NavigationLibraryLayout.watchlistKey]
        )
        layout.apply(
            OrderedVisibilityList.Sections(enabled: ["a:1"], disabled: []),
            available: ["a:1"]
        )

        XCTAssertFalse(layout.isVisible(NavigationLibraryLayout.watchlistKey))
        XCTAssertTrue(layout.isVisible(NavigationLibraryLayout.musicKey))
    }

    // MARK: Selection pruning

    func testSelectionFallsBackToFirstVisibleDestinationInsteadOfHiddenHome() {
        let destinations: [NavigationRailDestination] = [
            .search,
            .library("a:1"),
            .settings,
        ]
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(
                .library("a:1"),
                destinations: destinations
            ),
            .library("a:1")
        )
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(
                .library("gone:9"),
                destinations: destinations
            ),
            .search
        )
    }

    func testAllHiddenDestinationsStillRenderAndFallBackToSettings() {
        var hidden: Set<String> = [
            NavigationLibraryLayout.homeKey,
            NavigationLibraryLayout.searchKey,
            NavigationLibraryLayout.watchlistKey,
            NavigationLibraryLayout.musicKey,
            NavigationLibraryLayout.allLibrariesKey,
            "a:1",
        ]
        hidden.insert(NavigationLibraryLayout.liveTVKey)
        let layout = NavigationLibraryLayout(hiddenKeys: hidden)
        let libraries = [library("1", title: "Movies", account: "a")]

        XCTAssertEqual(
            NavigationRailPlan.destinations(
                visibleLibraries: libraries,
                layout: layout,
                availableKeys: NavigationRailPlan.customizableKeys(
                    visibleLibraries: libraries
                )
            ),
            [.settings]
        )
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(.home, destinations: [.settings]),
            .settings
        )

        // Even a style bug that supplies no destinations cannot fall back Home.
        XCTAssertEqual(
            NavigationRailPlan.resolvedSelection(.home, destinations: []),
            .settings
        )
    }

    // MARK: Scene-storage round trip

    func testDestinationStorageValueRoundTrips() {
        var cases: [NavigationRailDestination] = [
            .home, .search, .watchlist, .music, .settings, .allLibraries,
            .library("acct:lib:with:colons")
        ]
        cases.append(.liveTV)
        for destination in cases {
            XCTAssertEqual(
                NavigationRailDestination(storageValue: destination.storageValue),
                destination
            )
        }
        XCTAssertNil(NavigationRailDestination(storageValue: "nonsense"))
    }
}
