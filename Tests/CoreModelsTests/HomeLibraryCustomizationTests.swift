import XCTest
@testable import CoreModels

final class HomeLibraryVisibilityTests: XCTestCase {
    func testEmptyCollectionsHideAutomaticallyWithoutDisablingTheirLibrary() throws {
        var library = MediaLibrary(id: "collections", title: "Collections", kind: .collection, hasCollections: false)
        var visibility = HomeLibraryVisibility.default
        XCTAssertTrue(visibility.isEnabled("first:collections"))
        XCTAssertFalse(visibility.isVisibleOnHome("first:collections", library: library))
        visibility.setEnabled(true, for: "first:collections")
        XCTAssertTrue(visibility.isVisibleOnHome("first:collections", library: library))
        XCTAssertFalse(visibility.isVisibleOnHome("second:collections", library: library))
        let restored = try JSONDecoder().decode(
            HomeLibraryVisibility.self, from: JSONEncoder().encode(visibility)
        )
        XCTAssertTrue(restored.isVisibleOnHome("first:collections", library: library))
        visibility.setEnabled(false, for: "first:collections")
        XCTAssertFalse(visibility.isVisibleOnHome("first:collections", library: library))
        XCTAssertFalse(visibility.explicitlyEnabledKeys.contains("first:collections"))
        library.hasCollections = true
        XCTAssertFalse(visibility.isVisibleOnHome("first:collections", library: library), "Explicit off wins over new content.")
        XCTAssertTrue(visibility.isVisibleOnHome("second:collections", library: library))
    }

    func testCollectionAvailabilityIsOptionalAndDoesNotHideUnknownOrOrdinaryLibraries() throws {
        let legacy = try JSONDecoder().decode(
            MediaLibrary.self, from: Data(#"{"id":"collections","title":"Collections","kind":"collection"}"#.utf8)
        )
        XCTAssertNil(legacy.hasCollections)
        let visibility = try JSONDecoder().decode(HomeLibraryVisibility.self, from: Data("{}".utf8))
        XCTAssertTrue(visibility.explicitlyEnabledKeys.isEmpty)
        XCTAssertTrue(visibility.isVisibleOnHome("acct:collections", library: legacy))
        var knownEmpty = legacy
        knownEmpty.hasCollections = false
        let restored = try JSONDecoder().decode(MediaLibrary.self, from: JSONEncoder().encode(knownEmpty))
        XCTAssertEqual(restored.hasCollections, false)
        XCTAssertFalse(visibility.isVisibleOnHome("acct:collections", library: restored))
        knownEmpty.kind = .movie
        XCTAssertTrue(visibility.isVisibleOnHome("acct:collections", library: knownEmpty))
    }

    func testDefaultShowsEverything() {
        let visibility = HomeLibraryVisibility.default
        XCTAssertTrue(visibility.isVisible("acct:anything"))
        XCTAssertTrue(visibility.disabledKeys.isEmpty)
    }

    func testDisablingAndEnablingAKey() {
        var visibility = HomeLibraryVisibility.default
        visibility.setEnabled(false, for: "acct:movies")

        XCTAssertFalse(visibility.isVisible("acct:movies"))
        XCTAssertTrue(visibility.isVisible("acct:shows"), "Other libraries stay on (opt-out)")

        visibility.setEnabled(true, for: "acct:movies")
        XCTAssertTrue(visibility.isVisible("acct:movies"))
        XCTAssertTrue(visibility.disabledKeys.isEmpty)
    }

    func testNewlyDiscoveredLibraryIsEnabledByDefault() {
        var visibility = HomeLibraryVisibility.default
        visibility.setEnabled(false, for: "acct:movies")
        // A library the user has never toggled is on automatically.
        XCTAssertTrue(visibility.isVisible("acct:newly-added"))
    }

    func testCodableRoundTripPreservesDisabledKeys() throws {
        var visibility = HomeLibraryVisibility.default
        visibility.setEnabled(false, for: "a:1")
        visibility.setEnabled(false, for: "b:2")

        let data = try JSONEncoder().encode(visibility)
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: data)

        XCTAssertEqual(decoded.disabledKeys, ["a:1", "b:2"])
        XCTAssertFalse(decoded.isVisible("a:1"))
        XCTAssertTrue(decoded.isVisible("a:3"))
    }

    // MARK: - Continue Watching artwork treatment

    func testContinueWatchingActionDefaultsToDetailsWithoutASavedChoice() throws {
        XCTAssertEqual(ContinueWatchingAction.default, .openDetails)
        XCTAssertEqual(HomeLibraryVisibility.default.continueWatchingAction, .openDetails)
        XCTAssertEqual(HomeLibraryVisibility().continueWatchingAction, .openDetails)
        let legacy = try JSONDecoder().decode(
            HomeLibraryVisibility.self,
            from: Data(#"{"continueWatchingShowsSeriesArtwork":false,"disabledKeys":["account:library"]}"#.utf8)
        )
        XCTAssertEqual(legacy.continueWatchingAction, .openDetails)
        XCTAssertFalse(legacy.continueWatchingShowsSeriesArtwork)
        XCTAssertEqual(legacy.disabledKeys, ["account:library"])
    }

    func testContinueWatchingActionPreservesSavedChoices() throws {
        for action in ContinueWatchingAction.allCases {
            let data = Data(#"{"continueWatchingAction":"\#(action.rawValue)"}"#.utf8)
            let restored = try JSONDecoder().decode(HomeLibraryVisibility.self, from: data)
            XCTAssertEqual(restored.continueWatchingAction, action)
        }
    }

    func testContinueWatchingActionRoundTripsIndependentlyOfPresentation() throws {
        for action in ContinueWatchingAction.allCases {
            for layout in ContinueWatchingCardLayout.allCases {
                for details in ContinueWatchingPlaybackDetails.allCases {
                    let original = HomeLibraryVisibility(
                        continueWatchingShowsSeriesArtwork: false,
                        continueWatchingLayout: layout, continueWatchingPlaybackDetails: details,
                        continueWatchingAction: action
                    )
                    let restored = try JSONDecoder().decode(
                        HomeLibraryVisibility.self, from: JSONEncoder().encode(original)
                    )
                    XCTAssertEqual(restored, original)
                }
            }
        }
    }

    func testContinueWatchingShowsSeriesArtworkDefaultsOn() {
        XCTAssertTrue(HomeLibraryVisibility.default.continueWatchingShowsSeriesArtwork)
        XCTAssertEqual(HomeLibraryVisibility.default.continueWatchingLayout, .landscape)
        XCTAssertEqual(HomeLibraryVisibility.default.continueWatchingPlaybackDetails, .detailed)
    }

    func testPortraitOverridesThumbnailsWithoutErasingTheLandscapeChoice() throws {
        var visibility = HomeLibraryVisibility(continueWatchingShowsSeriesArtwork: false)
        visibility.continueWatchingLayout = .portrait
        var decoded = try JSONDecoder().decode(
            HomeLibraryVisibility.self, from: JSONEncoder().encode(visibility)
        )
        XCTAssertEqual(decoded.continueWatchingLayout, .portrait)
        XCTAssertTrue(decoded.continueWatchingUsesSeriesArtwork)
        XCTAssertFalse(decoded.continueWatchingShowsSeriesArtwork)
        decoded.continueWatchingLayout = .landscape
        XCTAssertFalse(decoded.continueWatchingUsesSeriesArtwork)
    }

    func testLegacyThumbnailPreferenceRemainsLandscape() throws {
        let decoded = try JSONDecoder().decode(
            HomeLibraryVisibility.self,
            from: Data(#"{"continueWatchingShowsSeriesArtwork":false}"#.utf8)
        )
        XCTAssertEqual(decoded.continueWatchingLayout, .landscape)
        XCTAssertFalse(decoded.continueWatchingUsesSeriesArtwork)
        XCTAssertEqual(decoded.continueWatchingPlaybackDetails, .detailed)
    }

    func testPlaybackDetailsRoundTripWithoutChangingArtworkOrLayout() throws {
        for layout in ContinueWatchingCardLayout.allCases {
            for details in ContinueWatchingPlaybackDetails.allCases {
                let original = HomeLibraryVisibility(
                    continueWatchingShowsSeriesArtwork: false, continueWatchingLayout: layout,
                    continueWatchingPlaybackDetails: details
                )
                let decoded = try JSONDecoder().decode(
                    HomeLibraryVisibility.self, from: JSONEncoder().encode(original)
                )
                XCTAssertEqual(decoded, original)
                XCTAssertEqual(decoded.continueWatchingUsesSeriesArtwork, layout == .portrait)
            }
        }
    }

    func testPortraitOnlyStoredPlaybackPreferenceIsPreservedForAllLayouts() throws {
        let decoded = try JSONDecoder().decode(
            HomeLibraryVisibility.self,
            from: Data(#"{"continueWatchingPortraitDetails":"progressOnly","continueWatchingLayout":"landscape"}"#.utf8)
        )
        XCTAssertEqual(decoded.continueWatchingPlaybackDetails, .progressOnly)
        XCTAssertEqual(decoded.continueWatchingLayout, .landscape)
    }

    func testContinueWatchingArtworkChoiceSurvivesARoundTrip() throws {
        var visibility = HomeLibraryVisibility.default
        visibility.continueWatchingShowsSeriesArtwork = false

        let decoded = try JSONDecoder().decode(
            HomeLibraryVisibility.self,
            from: try JSONEncoder().encode(visibility)
        )
        XCTAssertFalse(
            decoded.continueWatchingShowsSeriesArtwork,
            "turning it off must persist — otherwise the setting silently reverts on relaunch"
        )
    }

    /// A blob written before this field existed has no key for it. Unlike the
    /// conservative "change nothing on upgrade" fields, this one defaults ON: the
    /// old behaviour is the reported problem, so an upgrading user gets the better
    /// row and can switch back.
    func testUpgradingInstallWithoutTheKeyDefaultsOn() throws {
        let legacy = """
        {"mergeLibrariesOnHome":true,"disabledKeys":[],"disabledGlobalHomeRows":[],
         "enabledLibraryHomeRows":[],"hasSeededLibraryRows":true}
        """
        let decoded = try JSONDecoder().decode(
            HomeLibraryVisibility.self,
            from: Data(legacy.utf8)
        )
        XCTAssertTrue(decoded.continueWatchingShowsSeriesArtwork)
        XCTAssertTrue(decoded.mergeLibrariesOnHome, "unrelated fields still decode")
    }

    // MARK: - Single on/off axis (the Home-only opt-out was retired)

    func testDefaultsMatchServerWithoutDisablingLibraries() {
        let v = HomeLibraryVisibility.default
        XCTAssertFalse(v.mergeLibrariesOnHome)
        XCTAssertEqual(v.rowCustomization?.defaults, .matchServer)
        XCTAssertTrue(v.disabledKeys.isEmpty)
        XCTAssertTrue(v.isEnabled("acct:anything"))
        XCTAssertTrue(v.isVisibleOnHome("acct:anything"))
    }

    func testVisibleOnHomeIsJustEnabled() {
        var v = HomeLibraryVisibility.default
        // There is no separate Home-only opt-out anymore: on Home == enabled.
        XCTAssertTrue(v.isVisibleOnHome("acct:movies"))
        v.setEnabled(false, for: "acct:movies")
        XCTAssertFalse(v.isEnabled("acct:movies"))
        XCTAssertFalse(v.isVisibleOnHome("acct:movies"))
        XCTAssertFalse(v.isVisible("acct:movies"), "isVisible aliases isVisibleOnHome")
    }

    func testDisablingHidesEverywhereAndReEnablingRestores() {
        var v = HomeLibraryVisibility.default
        v.setEnabled(false, for: "acct:movies")
        XCTAssertFalse(v.isEnabled("acct:movies"))
        XCTAssertFalse(v.isVisibleOnHome("acct:movies"))

        v.setEnabled(true, for: "acct:movies")
        XCTAssertTrue(v.isVisibleOnHome("acct:movies"))
    }

    func testCodableRoundTripPreservesAllFields() throws {
        var v = HomeLibraryVisibility.default
        v.mergeLibrariesOnHome = false
        v.setEnabled(false, for: "a:1")

        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: data)

        XCTAssertFalse(decoded.mergeLibrariesOnHome)
        XCTAssertEqual(decoded.disabledKeys, ["a:1"])
    }

    func testLegacyExcludedKeysBlobDecodesAsShown() throws {
        // A pre-retirement blob carried the old Home-only `excludedKeys` opt-out.
        // It must still decode (merge ON, nothing disabled), and the retired axis
        // is dropped — an excluded-but-enabled library now simply shows on Home.
        let legacy = #"{"excludedKeys":["acct:movies"]}"#
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: Data(legacy.utf8))

        XCTAssertTrue(decoded.mergeLibrariesOnHome)
        XCTAssertTrue(decoded.disabledKeys.isEmpty)
        XCTAssertTrue(decoded.isEnabled("acct:movies"))
        XCTAssertTrue(decoded.isVisibleOnHome("acct:movies"), "retired opt-out folds to shown")
        // New row-selection fields also default sensibly: every global row on, no
        // per-library rows opted in.
        XCTAssertTrue(decoded.isGlobalRowEnabled(.continueWatching))
        XCTAssertTrue(decoded.isGlobalRowEnabled(.recentlyAdded))
        XCTAssertFalse(decoded.isLibraryRowEnabled("acct:movies", kind: .recentlyAdded))
    }

    // MARK: - Global & per-library Home rows

    func testProviderDefaultsUsePerLibraryLatestAndSharedWatchRows() {
        var v = HomeLibraryVisibility.default
        for row in HomeGlobalRow.allCases {
            XCTAssertEqual(v.isGlobalRowEnabled(row), row != .recentlyAdded)
        }
        v.setGlobalRowEnabled(false, for: .watchlist)
        XCTAssertFalse(v.isGlobalRowEnabled(.watchlist))
        XCTAssertTrue(v.isGlobalRowEnabled(.continueWatching), "other rows unaffected")
        XCTAssertEqual(v.disabledGlobalHomeRows, ["watchlist"])
    }

    func testPerLibraryRowsDefaultOffAndOptIn() {
        var v = HomeLibraryVisibility.default
        XCTAssertFalse(v.isLibraryRowEnabled("acct:L1", kind: .recentlyAdded))
        v.setLibraryRowEnabled(true, libraryKey: "acct:L1", kind: .recentlyAdded)
        XCTAssertTrue(v.isLibraryRowEnabled("acct:L1", kind: .recentlyAdded))
        // Independent per kind and per library.
        XCTAssertFalse(v.isLibraryRowEnabled("acct:L1", kind: .hubs))
        XCTAssertFalse(v.isLibraryRowEnabled("acct:L2", kind: .recentlyAdded))
        v.setLibraryRowEnabled(false, libraryKey: "acct:L1", kind: .recentlyAdded)
        XCTAssertTrue(v.enabledLibraryHomeRows.isEmpty)
    }

    func testRowSelectionSurvivesCodableRoundTrip() throws {
        var v = HomeLibraryVisibility.default
        v.setGlobalRowEnabled(false, for: .recentlyAdded)
        v.setLibraryRowEnabled(true, libraryKey: "acct:L1", kind: .hubs)

        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: data)

        XCTAssertFalse(decoded.isGlobalRowEnabled(.recentlyAdded))
        XCTAssertTrue(decoded.isLibraryRowEnabled("acct:L1", kind: .hubs))
    }
}

final class HomeLibraryVisibilityStoreTests: XCTestCase {
    @MainActor
    func testContinueWatchingActionPersistsPerProfileAndSurvivesPresetChanges() throws {
        let suite = "test.continueWatchingAction.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let primary = HomeLibraryVisibilityStore(defaults: defaults)
        let other = HomeLibraryVisibilityStore(defaults: defaults, namespace: "other")
        let model = HomeLibraryVisibilityModel(store: primary)
        model.setContinueWatchingAction(.play)
        for preset: HomeRowCustomization.Defaults in [.matchServer, .combined, .custom] {
            model.useRowDefaults(preset)
            model.setGlobalRowEnabled(false, for: .continueWatching)
            model.setGlobalRowEnabled(true, for: .continueWatching)
            XCTAssertEqual(HomeLibraryVisibilityModel(store: primary).continueWatchingAction, .play)
            XCTAssertEqual(HomeLibraryVisibilityModel(store: other).continueWatchingAction, .openDetails)
        }
        let restored = HomeLibraryVisibilityModel(store: primary)
        restored.setContinueWatchingAction(.openDetails)
        XCTAssertEqual(primary.load().continueWatchingAction, .openDetails)
    }

    @MainActor
    func testContinueWatchingLayoutPersistsAndSwitchesWithItsProfile() {
        let suite = "test.portraitVisibility.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = HomeLibraryVisibilityStore(defaults: defaults)
        let second = HomeLibraryVisibilityStore(defaults: defaults, namespace: "second")
        let model = HomeLibraryVisibilityModel(store: first)
        model.setContinueWatchingShowsSeriesArtwork(false)
        model.setContinueWatchingLayout(.portrait)
        model.setContinueWatchingPlaybackDetails(.progressOnly)
        let restored = HomeLibraryVisibilityModel(store: first)
        XCTAssertEqual(restored.continueWatchingLayout, .portrait)
        XCTAssertTrue(restored.continueWatchingUsesSeriesArtwork)
        XCTAssertEqual(HomeLibraryVisibilityModel(store: second).continueWatchingLayout, .landscape)
        XCTAssertEqual(restored.continueWatchingPlaybackDetails, .progressOnly)
        XCTAssertEqual(HomeLibraryVisibilityModel(store: second).continueWatchingPlaybackDetails, .detailed)
        restored.setContinueWatchingLayout(.landscape)
        XCTAssertFalse(restored.continueWatchingUsesSeriesArtwork)
        XCTAssertEqual(first.load().continueWatchingLayout, .landscape)
        XCTAssertEqual(first.load().continueWatchingPlaybackDetails, .progressOnly)
        restored.setContinueWatchingLayout(.portrait)
        XCTAssertEqual(restored.continueWatchingPlaybackDetails, .progressOnly)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "test.homeVisibility.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testDefaultNamespaceUsesLegacyUnsuffixedKey() {
        let defaults = makeDefaults()
        let store = HomeLibraryVisibilityStore(defaults: defaults, namespace: nil)
        var v = HomeLibraryVisibility.default
        v.setEnabled(false, for: "acct:movies")
        store.save(v)

        // Persisted under the un-suffixed key so upgrading installs inherit it.
        XCTAssertNotNil(defaults.data(forKey: "com.plozz.homeLibraryVisibility"))
        XCTAssertEqual(store.load().disabledKeys, ["acct:movies"])
    }

    func testProfilesGetIsolatedVisibility() {
        let defaults = makeDefaults()
        let alice = HomeLibraryVisibilityStore(defaults: defaults, namespace: "profile-alice")
        let bob = HomeLibraryVisibilityStore(defaults: defaults, namespace: "profile-bob")

        var aliceV = alice.load()
        aliceV.setEnabled(false, for: "acct:movies")
        alice.save(aliceV)

        // Bob's scope is untouched by Alice's choice.
        XCTAssertEqual(alice.load().disabledKeys, ["acct:movies"])
        XCTAssertTrue(bob.load().disabledKeys.isEmpty)
        XCTAssertTrue(bob.load().isVisible("acct:movies"))
    }

    @MainActor
    func testManualCollectionEnablePersistsOnlyForItsProfile() {
        let suite = "test.collectionVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = HomeLibraryVisibilityStore(defaults: defaults, namespace: "first")
        let second = HomeLibraryVisibilityStore(defaults: defaults, namespace: "second")
        let library = MediaLibrary(id: "collections", title: "Collections", kind: .collection, hasCollections: false)
        let model = HomeLibraryVisibilityModel(store: first)
        XCTAssertFalse(model.isVisibleOnHome("acct:collections", library: library))
        model.setEnabled(true, for: "acct:collections")
        XCTAssertTrue(HomeLibraryVisibilityModel(store: first).isVisibleOnHome("acct:collections", library: library))
        XCTAssertFalse(HomeLibraryVisibilityModel(store: second).isVisibleOnHome("acct:collections", library: library))
    }
}

final class HomeLibraryVisibilityModelTests: XCTestCase {
    @MainActor
    private func makeModel() -> HomeLibraryVisibilityModel {
        let suite = "test.homeVisibilityModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
    }

    @MainActor
    func testSetMergePersistsAndReads() {
        let model = makeModel()
        XCTAssertFalse(model.mergeLibrariesOnHome)
        model.setMergeLibrariesOnHome(true)
        XCTAssertTrue(model.mergeLibrariesOnHome)
        model.setMergeLibrariesOnHome(false)
        XCTAssertFalse(model.mergeLibrariesOnHome)
        XCTAssertFalse(model.visibility.mergeLibrariesOnHome)
    }

    @MainActor
    func testSetEnabledControlsVisibility() {
        let model = makeModel()
        XCTAssertTrue(model.isVisibleOnHome("acct:movies"))
        model.setEnabled(false, for: "acct:movies")

        XCTAssertFalse(model.isEnabled("acct:movies"))
        XCTAssertFalse(model.isVisibleOnHome("acct:movies"))

        model.setEnabled(true, for: "acct:movies")
        XCTAssertTrue(model.isVisibleOnHome("acct:movies"))
    }
}

final class AggregatedLibraryTests: XCTestCase {
    private func make(accountID: String, libraryID: String) -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: accountID,
            accountName: "Alice",
            serverName: "Home",
            providerKind: .jellyfin,
            library: MediaLibrary(id: libraryID, title: "Movies", kind: .movie)
        )
    }

    func testKeyCombinesAccountAndLibrary() {
        XCTAssertEqual(make(accountID: "acct-1", libraryID: "L9").key, "acct-1:L9")
    }

    func testKeyIsStableAndIdentifierMatches() {
        let aggregated = make(accountID: "acct-1", libraryID: "L9")
        XCTAssertEqual(aggregated.id, aggregated.key)
    }

    func testSameLibraryIDOnDifferentAccountsHasDistinctKeys() {
        let a = make(accountID: "acct-1", libraryID: "L1")
        let b = make(accountID: "acct-2", libraryID: "L1")
        XCTAssertNotEqual(a.key, b.key)
    }
}

final class MediaItemSourceTaggingTests: XCTestCase {
    func testTaggingStampsSourceAccount() {
        let item = MediaItem(id: "m1", title: "Dune", kind: .movie)
        XCTAssertNil(item.sourceAccountID)
        XCTAssertEqual(item.taggingSource("acct-1").sourceAccountID, "acct-1")
    }

    func testLibraryTaggingStampsSourceAccount() {
        let library = MediaLibrary(id: "L1", title: "Movies", kind: .movie)
        XCTAssertNil(library.sourceAccountID)
        XCTAssertEqual(library.taggingSource("acct-1").sourceAccountID, "acct-1")
    }

    func testSourceAccountIDDecodesAsNilFromLegacyData() throws {
        // Legacy JSON without the field decodes with sourceAccountID == nil.
        let legacy = #"{"id":"m1","title":"Dune","kind":"movie","isPlayed":false,"ratings":[],"providerIDs":{}}"#
        let data = Data(legacy.utf8)
        let item = try JSONDecoder().decode(MediaItem.self, from: data)
        XCTAssertNil(item.sourceAccountID)
        XCTAssertEqual(item.id, "m1")
    }

    // MARK: - Seeding per-library rows when first unmerging

    func testSeedLibraryRowsFillsEverythingWhenFirstUnmerging() {
        var visibility = HomeLibraryVisibility.default
        XCTAssertFalse(visibility.hasSeededLibraryRows)
        let seeded = visibility.seedLibraryRowsIfNeeded([
            ("acct:movies", .recentlyAdded),
            ("acct:movies", .hubs),
            ("acct:shows", .recentlyAdded)
        ])

        XCTAssertTrue(seeded)
        XCTAssertTrue(visibility.hasSeededLibraryRows)
        XCTAssertTrue(visibility.isLibraryRowEnabled("acct:movies", kind: .recentlyAdded))
        XCTAssertTrue(visibility.isLibraryRowEnabled("acct:movies", kind: .hubs))
        XCTAssertTrue(visibility.isLibraryRowEnabled("acct:shows", kind: .recentlyAdded))
    }

    func testSeedLibraryRowsPreservesExistingCustomization() {
        var visibility = HomeLibraryVisibility.default
        let seeds: [(libraryKey: String, kind: LibraryHomeRowKind)] = [
            ("acct:movies", .recentlyAdded),
            ("acct:movies", .hubs),
            ("acct:shows", .recentlyAdded)
        ]
        // First unmerge seeds everything on.
        XCTAssertTrue(visibility.seedLibraryRowsIfNeeded(seeds))
        // User pares it back to a single row.
        visibility.setLibraryRowEnabled(false, libraryKey: "acct:movies", kind: .hubs)
        visibility.setLibraryRowEnabled(false, libraryKey: "acct:shows", kind: .recentlyAdded)

        // A later merge on→off re-toggle must NOT re-seed over that choice.
        XCTAssertFalse(visibility.seedLibraryRowsIfNeeded(seeds), "Must not re-seed after the one-time seed")
        XCTAssertTrue(visibility.isLibraryRowEnabled("acct:movies", kind: .recentlyAdded))
        XCTAssertFalse(visibility.isLibraryRowEnabled("acct:movies", kind: .hubs))
        XCTAssertFalse(visibility.isLibraryRowEnabled("acct:shows", kind: .recentlyAdded))
    }

    func testSeedLibraryRowsDoesNotReSeedAfterUserTurnsEveryRowOff() {
        // Regression: an all-off selection must survive a merge re-toggle. An
        // emptiness check couldn't tell "customized to nothing on Home" from
        // "never seeded"; the explicit flag can.
        var visibility = HomeLibraryVisibility.default
        let seeds: [(libraryKey: String, kind: LibraryHomeRowKind)] = [
            ("acct:movies", .recentlyAdded),
            ("acct:shows", .recentlyAdded)
        ]
        XCTAssertTrue(visibility.seedLibraryRowsIfNeeded(seeds))
        // User turns EVERY per-library row off — a valid "only Shared rows" Home.
        visibility.setLibraryRowEnabled(false, libraryKey: "acct:movies", kind: .recentlyAdded)
        visibility.setLibraryRowEnabled(false, libraryKey: "acct:shows", kind: .recentlyAdded)
        XCTAssertTrue(visibility.enabledLibraryHomeRows.isEmpty)

        // Re-toggling merge off again must NOT re-enable everything.
        XCTAssertFalse(visibility.seedLibraryRowsIfNeeded(seeds))
        XCTAssertTrue(visibility.enabledLibraryHomeRows.isEmpty, "All-off choice must be preserved")
    }

    func testSeedLibraryRowsNoOpWhenNothingToSeedAndStaysUnseeded() {
        var visibility = HomeLibraryVisibility.default
        // Discovery not ready yet (no seeds) — must no-op AND stay unseeded so a
        // later attempt (once libraries load) can still seed.
        XCTAssertFalse(visibility.seedLibraryRowsIfNeeded([]))
        XCTAssertFalse(visibility.hasSeededLibraryRows)
        XCTAssertTrue(visibility.enabledLibraryHomeRows.isEmpty)

        XCTAssertTrue(visibility.seedLibraryRowsIfNeeded([("acct:movies", .recentlyAdded)]))
        XCTAssertTrue(visibility.hasSeededLibraryRows)
    }

    func testSeededFlagMigratesFromExistingOptedInRows() throws {
        // A blob predating the flag that already has opted-in rows must decode as
        // already-seeded, so a post-upgrade re-toggle doesn't re-seed over it.
        let legacyJSON = """
        {"mergeLibrariesOnHome":false,"enabledLibraryHomeRows":["acct:movies:recentlyAdded"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HomeLibraryVisibility.self, from: legacyJSON)
        XCTAssertTrue(decoded.hasSeededLibraryRows, "Existing opted-in rows imply prior seeding")

        // A legacy blob with NO rows stays unseeded (can't tell first-run from
        // all-off for old data; safest is to allow one seed going forward).
        let emptyLegacy = """
        {"mergeLibrariesOnHome":true}
        """.data(using: .utf8)!
        let decodedEmpty = try JSONDecoder().decode(HomeLibraryVisibility.self, from: emptyLegacy)
        XCTAssertFalse(decodedEmpty.hasSeededLibraryRows)
    }
}
