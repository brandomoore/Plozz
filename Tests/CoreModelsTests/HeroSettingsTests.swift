import XCTest
import Observation
@testable import CoreModels

/// Locks down `HeroSettings` value semantics (clamping, de-dup, lenient decode)
/// and `HeroSettingsStore` persistence (round-trip + per-profile scoping).
final class HeroSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "HeroSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testKidsPolicyAppliesWithoutPINAndPreservesSavedDiscoveryPreferences() throws {
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let store = HeroSettingsStore(defaults: defaults)
        var saved = HeroSettings.default
        saved.setEnabled(.featured, enabled: true)
        saved.showsDiscoverRow = true
        saved.showsDiscoverySources = true
        saved.discoverySources = [.anilist, .tmdb]
        store.save(saved)
        let model = HeroSettingsModel(store: store)
        model.setDiscoveryPolicy { !profiles.activeProfile.isKids }
        XCTAssertEqual(model.effectiveSettings, saved)

        var profile = profiles.activeProfile
        profile.isKids = true
        profiles.update(profile)
        XCTAssertFalse(model.allowsDiscovery)
        XCTAssertFalse(model.effectiveSettings.isEnabled(.featured))
        XCTAssertTrue(model.effectiveSettings.discoverySources.isEmpty)
        XCTAssertFalse(model.effectiveSettings.showsDiscoverRow)
        XCTAssertFalse(model.effectiveSettings.showsDiscoverySources)
        XCTAssertTrue(model.effectiveSettings.isEnabled(.continueWatching))
        XCTAssertEqual(store.load(), saved)

        model.settings.maxItems = 10
        model.settings.sources = [.featured, .watchlist]
        model.settings.showsDiscoverRow = true
        XCTAssertEqual(model.effectiveSettings.sources, [.watchlist])
        XCTAssertFalse(model.effectiveSettings.showsDiscoverRow)
        XCTAssertEqual(store.load().discoverySources, saved.discoverySources)

        profile.isKids = false
        profiles.update(profile)
        XCTAssertTrue(model.allowsDiscovery)
        XCTAssertEqual(model.effectiveSettings, store.load())
        XCTAssertEqual(model.effectiveSettings.maxItems, 10)
        XCTAssertTrue(model.effectiveSettings.showsDiscoverRow)
        XCTAssertTrue(model.effectiveSettings.showsDiscoverySources)
    }

    func testRuntimeDiscoveryPolicyIsNotDecodedFromSyncedPreferences() throws {
        let input = Data(#"{"sources":["featured"],"allowsDiscovery":false,"showsDiscoverRow":true}"#.utf8)
        let decoded = try JSONDecoder().decode(HeroSettings.self, from: input)
        XCTAssertTrue(decoded.allowsDiscovery)
        let encoded = try JSONEncoder().encode(decoded.applyingDiscoveryPolicy(allowed: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["allowsDiscovery"])
    }

    @MainActor
    func testProfileUpdatesInvalidateEffectiveSettingsObservationWithoutRebuildingTheModel() async {
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let model = HeroSettingsModel(store: InMemoryHeroSettingsStore())
        model.setDiscoveryPolicy { !profiles.activeProfile.isKids }
        let changed = expectation(description: "Profile policy invalidates visible Home and settings")
        withObservationTracking {
            _ = model.effectiveSettings
        } onChange: {
            changed.fulfill()
        }
        var profile = profiles.activeProfile
        profile.isKids = true
        profiles.update(profile)
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertFalse(model.effectiveSettings.allowsDiscovery)
    }

    func testDefaultIsActiveWithoutOptInCollection() {
        let d = HeroSettings.default
        XCTAssertTrue(d.isActive)
        XCTAssertEqual(d.sources, HeroSourceKind.allCases.filter { $0 != .collection && $0 != .featured })
        XCTAssertTrue(d.discoveryFollowsSeerr)
        XCTAssertTrue(d.collections.isEmpty)
        XCTAssertTrue(d.hideWatched)
        XCTAssertFalse(d.showsRatings)
        XCTAssertFalse(d.showsDiscoverySources)
        XCTAssertFalse(d.watchlistDiscoveryEnabled)
        XCTAssertEqual(d.maxItems, 8)
    }

    @MainActor
    func testFreshDiscoveryFollowsSeerrWithoutPersistingConnectionState() {
        let store = HeroSettingsStore(defaults: defaults)
        let model = HeroSettingsModel(store: store)
        var configured = false
        model.setSeerrConnection { configured }
        XCTAssertFalse(model.effectiveSettings.isEnabled(.featured))
        configured = true
        XCTAssertTrue(model.effectiveSettings.isEnabled(.featured))
        XCTAssertEqual(model.effectiveSettings.sources.first, .featured)
        XCTAssertEqual(store.load(), .default)

        model.settings.maxItems = 12
        model.settings.setEnabled(.randomFromLibrary, enabled: false)
        let reloaded = HeroSettingsModel(store: store)
        reloaded.setSeerrConnection { configured }
        XCTAssertTrue(reloaded.settings.discoveryFollowsSeerr)
        XCTAssertTrue(reloaded.effectiveSettings.isEnabled(.featured))
        configured = false
        XCTAssertFalse(reloaded.effectiveSettings.isEnabled(.featured))
        XCTAssertFalse(reloaded.effectiveSettings.isEnabled(.randomFromLibrary))
        XCTAssertEqual(reloaded.effectiveSettings.maxItems, 12)
    }

    @MainActor
    func testExplicitDiscoveryChoiceOverridesSeerrAndTransfersPerProfile() {
        for enabled in [false, true] {
            let namespace = "source-\(enabled)"
            let store = HeroSettingsStore(defaults: defaults, namespace: namespace)
            let model = HeroSettingsModel(store: store)
            model.setSeerrConnection { !enabled }
            model.settings.setEnabled(.featured, enabled: enabled)
            XCTAssertFalse(model.settings.discoveryFollowsSeerr)
            let snapshot = ProfileSettingsTransfer.capture(namespace: namespace, defaults: defaults)
            ProfileSettingsTransfer.apply(snapshot, namespace: "destination", defaults: defaults)
            let transferred = HeroSettingsModel(
                store: HeroSettingsStore(defaults: defaults, namespace: "destination")
            )
            for configured in [true, false] {
                transferred.setSeerrConnection { configured }
                XCTAssertEqual(transferred.effectiveSettings.isEnabled(.featured), enabled)
            }
        }
        XCTAssertTrue(HeroSettingsStore(defaults: defaults).load().discoveryFollowsSeerr)
    }

    @MainActor
    func testAutomaticDiscoveryTransferUsesReceivingConnection() {
        let model = HeroSettingsModel(store: HeroSettingsStore(defaults: defaults, namespace: "sender"))
        model.setSeerrConnection { true }
        model.settings.maxItems = 11
        XCTAssertTrue(model.effectiveSettings.isEnabled(.featured))
        let snapshot = ProfileSettingsTransfer.capture(namespace: "sender", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "receiver", defaults: defaults)
        let receiver = HeroSettingsModel(
            store: HeroSettingsStore(defaults: defaults, namespace: "receiver")
        )
        XCTAssertTrue(receiver.settings.discoveryFollowsSeerr)
        XCTAssertFalse(receiver.effectiveSettings.isEnabled(.featured))
        receiver.setSeerrConnection { true }
        XCTAssertTrue(receiver.effectiveSettings.isEnabled(.featured))
        XCTAssertEqual(receiver.settings.maxItems, 11)
    }

    func testLegacySourceSelectionsDoNotStartFollowingSeerr() throws {
        for sources in [#"["featured","watchlist"]"#, #"["watchlist"]"#, "[]"] {
            let settings = try JSONDecoder().decode(
                HeroSettings.self,
                from: Data(#"{"sources":\#(sources),"offeredSourcesVersion":1}"#.utf8)
            )
            XCTAssertFalse(settings.discoveryFollowsSeerr)
            for configured in [true, false] {
                XCTAssertEqual(settings.applyingSeerrDefault(isConfigured: configured), settings)
            }
        }
    }

    @MainActor
    func testKidsPolicyOverridesAutomaticDiscoveryWithoutChangingPreference() {
        let model = HeroSettingsModel(store: InMemoryHeroSettingsStore())
        model.setSeerrConnection { true }
        model.setDiscoveryPolicy { false }
        XCTAssertFalse(model.effectiveSettings.isEnabled(.featured))
        XCTAssertTrue(model.settings.discoveryFollowsSeerr)
        model.setDiscoveryPolicy { true }
        XCTAssertTrue(model.effectiveSettings.isEnabled(.featured))
        XCTAssertEqual(model.settings, .default)
    }

    @MainActor
    func testSeerrConnectionInvalidatesEffectiveSettingsObservation() async {
        let connection = DiscoveryConnection()
        let model = HeroSettingsModel(store: InMemoryHeroSettingsStore())
        model.setSeerrConnection { connection.isConfigured }
        let changed = expectation(description: "Seerr connection invalidates Discovery")
        withObservationTracking {
            _ = model.effectiveSettings
        } onChange: {
            changed.fulfill()
        }
        connection.isConfigured = true
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertTrue(model.effectiveSettings.isEnabled(.featured))
    }

    @Observable
    final class DiscoveryConnection {
        var isConfigured = false
    }

    func testCollectionSelectionRoundTripsAndTransfersOnlyWithItsProfile() throws {
        var settings = HeroSettings.default
        settings.sources = [.collection]
        settings.collections = [
            .init(accountID: "a", libraryID: "movies", collectionID: "c", title: "Favorites"),
            .init(accountID: "b", libraryID: "shows", collectionID: "c", title: "Favorites", serverUserID: "viewer")
        ]
        XCTAssertEqual(try JSONDecoder().decode(HeroSettings.self, from: JSONEncoder().encode(settings)), settings)
        HeroSettingsStore(defaults: defaults, namespace: "one").save(settings)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "one", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "two", defaults: defaults)
        XCTAssertEqual(HeroSettingsStore(defaults: defaults, namespace: "two").load(), settings)
        XCTAssertTrue(HeroSettingsStore(defaults: defaults).load().collections.isEmpty)
        XCTAssertTrue(settings.requiresExternalWatchHistory)
    }

    func testOldSettingsDoNotAdoptCollectionWithoutSelection() throws {
        let settings = try JSONDecoder().decode(HeroSettings.self, from: Data(#"{"sources":["watchlist"]}"#.utf8))
        XCTAssertTrue(settings.collections.isEmpty)
        XCTAssertFalse(settings.sources.contains(.collection))
    }

    func testPersonalCollectionSelectionRoundTripsWithoutInventingALibrary() throws {
        var settings = HeroSettings.default
        settings.sources = [.collection]
        settings.collections = [.init(accountID: "a", collectionID: "personal", title: "Favorites", serverUserID: "viewer")]
        HeroSettingsStore(defaults: defaults, namespace: "one").save(settings)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "one", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "two", defaults: defaults)
        XCTAssertEqual(HeroSettingsStore(defaults: defaults, namespace: "two").load(), settings)
        XCTAssertNil(settings.collections.first?.libraryKey)
        let legacy = try JSONDecoder().decode(HeroCollectionSelection.self, from: Data(
            #"{"accountID":"a","libraryID":"movies","collectionID":"c","title":"Favorites"}"#.utf8
        ))
        XCTAssertEqual(legacy.libraryKey, "a:movies")
    }

    func testLegacyCollectionMigratesWithoutResurrectingAClearedSelection() throws {
        let legacy = #"{"sources":["collection"],"collection":{"accountID":"a","libraryID":"movies","collectionID":"c","title":"Favorites","serverUserID":"viewer"}}"#
        let migrated = try JSONDecoder().decode(HeroSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(migrated.collections, [
            .init(accountID: "a", libraryID: "movies", collectionID: "c", title: "Favorites", serverUserID: "viewer")
        ])
        let cleared = legacy.dropLast() + #","collections":[]}"#
        XCTAssertTrue(try JSONDecoder().decode(HeroSettings.self, from: Data(cleared.utf8)).collections.isEmpty)
        let encoded = try JSONEncoder().encode(migrated)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["collection"])
        XCTAssertNotNil(object["collections"])
    }

    func testSelectionIdentityIncludesScopeButNotItsDisplayName() {
        let first = HeroCollectionSelection(accountID: "a", libraryID: "movies", collectionID: "c", title: "Original", serverUserID: "viewer")
        let renamed = HeroCollectionSelection(accountID: "a", libraryID: "movies", collectionID: "c", title: "Renamed", serverUserID: "viewer")
        let others: [HeroCollectionSelection] = [
            .init(accountID: "b", libraryID: "movies", collectionID: "c", title: "Original", serverUserID: "viewer"),
            .init(accountID: "a", libraryID: "shows", collectionID: "c", title: "Original", serverUserID: "viewer"),
            .init(accountID: "a", libraryID: "movies", collectionID: "c", title: "Original", serverUserID: "child"),
            .init(accountID: "a", collectionID: "c", title: "Original", serverUserID: "viewer")
        ]
        XCTAssertEqual(first.id, renamed.id)
        XCTAssertEqual(HeroCollectionSelection.normalized([first, renamed] + others), [first] + others)
    }

    func testMaxItemsIsClamped() {
        let low = HeroSettings(isEnabled: true, sources: [.continueWatching], maxItems: 0, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: true, autoAdvanceSeconds: 10)
        XCTAssertEqual(low.maxItems, HeroSettings.maxItemsRange.lowerBound)
        let high = HeroSettings(isEnabled: true, sources: [.continueWatching], maxItems: 999, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: true, autoAdvanceSeconds: 10)
        XCTAssertEqual(high.maxItems, HeroSettings.maxItemsRange.upperBound)
    }

    func testAutoAdvanceSecondsIsClamped() {
        let s = HeroSettings(isEnabled: true, sources: [.watchlist], maxItems: 5, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: true, autoAdvanceSeconds: 1)
        XCTAssertEqual(s.autoAdvanceSeconds, HeroSettings.autoAdvanceRange.lowerBound)
    }

    func testDuplicateSourcesAreCollapsedPreservingOrder() {
        let s = HeroSettings(isEnabled: true, sources: [.watchlist, .continueWatching, .watchlist], maxItems: 5, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: false, autoAdvanceSeconds: 10)
        XCTAssertEqual(s.sources, [.watchlist, .continueWatching])
    }

    func testEmptySourcesIsNotActive() {
        let s = HeroSettings(isEnabled: true, sources: [], maxItems: 5, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: false, autoAdvanceSeconds: 10)
        XCTAssertFalse(s.isActive)
    }

    func testDisabledIsNotActive() {
        let s = HeroSettings(isEnabled: false, sources: [.featured], maxItems: 5, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: false, autoAdvanceSeconds: 10)
        XCTAssertFalse(s.isActive)
    }

    func testStoreRoundTrip() {
        let store = HeroSettingsStore(defaults: defaults, namespace: nil)
        let settings = HeroSettings(isEnabled: true, sources: [.featured, .randomFromLibrary], maxItems: 6, trailersEnabled: true, hideWatched: false, showsDiscoverySources: true, randomLibraryKeys: ["a:1", "a:2"], autoAdvance: false, autoAdvanceSeconds: 20)
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }

    func testStoreDefaultsWhenEmpty() {
        let store = HeroSettingsStore(defaults: defaults, namespace: nil)
        XCTAssertEqual(store.load(), .default)
    }

    func testNamespacesAreIsolated() {
        let primary = HeroSettingsStore(defaults: defaults, namespace: nil)
        let other = HeroSettingsStore(defaults: defaults, namespace: "profile-2")
        let a = HeroSettings(isEnabled: true, sources: [.watchlist], maxItems: 3, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: true, autoAdvanceSeconds: 10)
        let b = HeroSettings(isEnabled: false, sources: [.featured], maxItems: 9, trailersEnabled: true, randomLibraryKeys: ["x:1"], autoAdvance: false, autoAdvanceSeconds: 30)
        primary.save(a)
        other.save(b)
        XCTAssertEqual(primary.load(), a)
        XCTAssertEqual(other.load(), b)
    }

    func testLenientDecodeFillsMissingFieldsWithDefaults() throws {
        // A partial blob (as an older app version might have written) must decode
        // with the absent fields at their defaults, not fail the whole decode.
        let json = #"{"isEnabled":false,"maxItems":4}"#
        let decoded = try JSONDecoder().decode(HeroSettings.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isEnabled)
        XCTAssertEqual(decoded.maxItems, 4)
        XCTAssertEqual(decoded.sources, HeroSettings.default.sources)
        XCTAssertEqual(decoded.autoAdvanceSeconds, HeroSettings.default.autoAdvanceSeconds)
        XCTAssertTrue(decoded.hideWatched)
        XCTAssertFalse(decoded.showsRatings)
        XCTAssertFalse(decoded.showsDiscoverySources)
    }

    // MARK: Hero style

    func testHeroShowcaseIsProfileScopedAndKeepsRowsWhenHeroIsDisabled() {
        let primary = HeroSettingsStore(defaults: defaults)
        let secondary = HeroSettingsStore(defaults: defaults, namespace: "hero-showcase-test")
        var settings = HeroSettings.default
        settings.style = .heroShowcase
        secondary.save(settings)
        XCTAssertEqual(primary.load().style, .heroShowcase)
        XCTAssertEqual(secondary.load().style, .heroShowcase)
        XCTAssertTrue(secondary.load().hasFeaturedHero)
        XCTAssertTrue(secondary.load().followsFocus)
        settings.isEnabled = false
        secondary.save(settings)
        XCTAssertFalse(secondary.load().hasFeaturedHero)
        XCTAssertTrue(secondary.load().followsFocus)
        settings.isEnabled = true
        settings.sources = []
        XCTAssertFalse(settings.hasFeaturedHero)
    }

    func testExistingSettingsKeepTheCarousel() throws {
        let decoded = try JSONDecoder().decode(
            HeroSettings.self, from: Data(#"{"isEnabled":true,"maxItems":4}"#.utf8)
        )
        XCTAssertEqual(decoded.style, .carousel)
        XCTAssertFalse(decoded.followsFocus)
        XCTAssertFalse(decoded.showsCardCaptions, "The hero names the focused title, so cards start without one")
        XCTAssertFalse(decoded.showsDiscoverRow)
    }

    func testFreshProfilesDefaultToSpotlightAndShowcaseWithoutChangingSavedProfiles() {
        let existing = HeroSettingsStore(defaults: defaults)
        var classic = HeroSettings.default
        classic.style = .carousel
        existing.save(classic)
        let fresh = HeroSettingsStore(defaults: defaults, namespace: "new-profile")
        XCTAssertTrue(fresh.load().spotlightEnabled)
        XCTAssertTrue(fresh.load().immersiveRows)
        XCTAssertEqual(existing.load(), classic)
    }

    func testIndependentHomeControlsPreserveTheOtherChoiceAndCustomization() throws {
        for originalStyle in HeroStyle.allCases {
            for enabled in [false, true] {
                var original = HeroSettings.default
                original.style = originalStyle
                original.isEnabled = enabled
                original.maxItems = 13
                original.sources = [.watchlist]
                original.showsDiscoverRow = true
                for desired in [false, true] {
                    var spotlight = original
                    spotlight.spotlightEnabled = desired
                    XCTAssertEqual(spotlight.spotlightEnabled, desired)
                    XCTAssertEqual(spotlight.immersiveRows, original.immersiveRows)
                    var rows = original
                    rows.immersiveRows = desired
                    XCTAssertEqual(rows.immersiveRows, desired)
                    XCTAssertEqual(rows.spotlightEnabled, original.spotlightEnabled)
                    for changed in [spotlight, rows] {
                        XCTAssertEqual(changed.sources, original.sources)
                        XCTAssertEqual(changed.maxItems, original.maxItems)
                        XCTAssertTrue(changed.showsDiscoverRow)
                        let restored = try JSONDecoder().decode(HeroSettings.self, from: JSONEncoder().encode(changed))
                        XCTAssertEqual(restored, changed)
                    }
                }
            }
        }
    }

    func testLegacyShowcaseDoesNotGainSpotlightWhenChoosingClassicRows() throws {
        var settings = try JSONDecoder().decode(
            HeroSettings.self, from: Data(#"{"isEnabled":true,"style":"followsFocus"}"#.utf8)
        )
        XCTAssertFalse(settings.spotlightEnabled)
        settings.immersiveRows = false
        XCTAssertEqual(settings.style, .carousel)
        XCTAssertFalse(settings.isEnabled)
        settings.spotlightEnabled = true
        XCTAssertEqual(settings.style, .carousel)
        XCTAssertTrue(settings.hasFeaturedHero)
        settings.immersiveRows = true
        XCTAssertEqual(settings.style, .heroShowcase)
        settings.spotlightEnabled = false
        XCTAssertEqual(settings.style, .followsFocus)
        XCTAssertFalse(settings.hasFeaturedHero)
    }

    func testAnUnknownStyleFallsBackWithoutResettingOtherSettings() throws {
        let data = Data(#"{"maxItems":4,"style":"someday","backdropTransition":"spin"}"#.utf8)
        let decoded = try JSONDecoder().decode(HeroSettings.self, from: data)
        XCTAssertEqual(decoded.style, .carousel)
        XCTAssertEqual(decoded.maxItems, 4)
    }

    func testFollowingFocusRoundTripsAndNeedsOnlyTheSwitch() {
        var settings = HeroSettings.default
        settings.style = .followsFocus
        settings.showsCardCaptions = true
        settings.showsDiscoverRow = true
        settings.sources = []
        let store = HeroSettingsStore(defaults: defaults)
        store.save(settings)
        let loaded = store.load()
        XCTAssertEqual(loaded.style, .followsFocus)
        XCTAssertTrue(loaded.showsCardCaptions)
        XCTAssertTrue(loaded.showsDiscoverRow)
        XCTAssertTrue(loaded.followsFocus, "Its titles come from the rows, not the carousel's sources")

        settings.isEnabled = false
        XCTAssertTrue(settings.followsFocus, "Immersive is a layout, not the Spotlight's switch")
    }

    func testInMemoryStoreRoundTrips() {
        let store = InMemoryHeroSettingsStore()
        XCTAssertEqual(store.load(), .default)
        let s = HeroSettings(isEnabled: true, sources: [.continueWatching], maxItems: 2, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: true, autoAdvanceSeconds: 8)
        store.save(s)
        XCTAssertEqual(store.load(), s)
    }

    func testRetiredSlideTransitionDoesNotResetOrPersistAlongsideHomeChoices() throws {
        let data = Data(#"{"style":"followsFocus","backdropTransition":"slide","showsCardCaptions":true,"maxItems":4}"#.utf8)
        let decoded = try JSONDecoder().decode(HeroSettings.self, from: data)
        XCTAssertEqual(decoded.style, .followsFocus)
        XCTAssertTrue(decoded.showsCardCaptions)
        XCTAssertEqual(decoded.maxItems, 4)

        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["backdropTransition"])
    }
    // MARK: Adopting a newly-added source

    func testAnExistingProfilePicksUpASourceAddedLater() {
        // Settings store the exact list chosen, so a source added in a later version
        // would stay invisible to everyone who already has settings — the people
        // most likely to want it. A case never shown can't be one they declined.
        let legacy = #"{"isEnabled":true,"sources":["continueWatching","watchlist"],"maxItems":6}"#
        let decoded = try? JSONDecoder().decode(HeroSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded?.sources, [.continueWatching, .watchlist, .recentlyAdded])
    }

    func testASourceTheUserSwitchedOffStaysOff() {
        // The decisive case: once a blob records the generation it was offered,
        // "absent" means declined rather than unseen. Without that, turning Recently
        // Added off would switch itself back on at the next load.
        var settings = HeroSettings.default
        settings.sources = [.continueWatching, .watchlist]
        let data = try? JSONEncoder().encode(settings)
        let reloaded = data.flatMap { try? JSONDecoder().decode(HeroSettings.self, from: $0) }
        XCTAssertEqual(reloaded?.sources, [.continueWatching, .watchlist])
    }

    func testAnEmptySelectionIsNotRepopulated() {
        // No sources means "hero off by source"; adding one would switch it back on.
        let legacy = #"{"isEnabled":true,"sources":[],"maxItems":6}"#
        let decoded = try? JSONDecoder().decode(HeroSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded?.sources, [])
    }

    func testHomeRatingsOptInSurvivesPersistenceAndProfileTransfer() {
        var settings = HeroSettings.default
        settings.showsRatings = true
        let first = HeroSettingsStore(defaults: defaults, namespace: "first")
        let second = HeroSettingsStore(defaults: defaults, namespace: "second")
        first.save(settings)
        XCTAssertTrue(first.load().showsRatings)
        XCTAssertFalse(second.load().showsRatings)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "first", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "second", defaults: defaults)
        XCTAssertEqual(second.load(), settings)

        settings.showsRatings = false
        first.save(settings)
        XCTAssertFalse(first.load().showsRatings)
        XCTAssertTrue(second.load().showsRatings)
    }

    func testMissingOrMalformedRatingPreferenceDefaultsOffWithoutResettingOtherSettings() throws {
        for field in ["", #","showsRatings":null"#, #","showsRatings":"invalid""#] {
            let data = Data(#"{"maxItems":4,"hideWatched":false\#(field)}"#.utf8)
            let settings = try JSONDecoder().decode(HeroSettings.self, from: data)
            XCTAssertFalse(settings.showsRatings)
            XCTAssertEqual(settings.maxItems, 4)
            XCTAssertFalse(settings.hideWatched)
        }
    }

    func testDiscoveryCreditsDefaultOffAndRetiredSourceDoesNotResetOtherSettings() throws {
        for field in [
            "",
            #","showsDiscoverySources":null"#,
            #","showsDiscoverySources":"invalid""#,
            #","showsDiscoverySources":1"#
        ] {
            let data = Data(
                #"{"maxItems":4,"hideWatched":false,"discoverySources":["simkl","anilist"]\#(field)}"#.utf8
            )
            let settings = try JSONDecoder().decode(HeroSettings.self, from: data)
            XCTAssertFalse(settings.showsDiscoverySources)
            XCTAssertEqual(settings.maxItems, 4)
            XCTAssertFalse(settings.hideWatched)
            XCTAssertEqual(settings.discoverySources, [.anilist])
        }
    }

    func testDiscoveryCreditPreferenceRoundTripsAndTransfersPerProfile() {
        var settings = HeroSettings.default
        settings.showsDiscoverySources = true
        settings.discoverySources = [.tvdb, .anilist]
        let first = HeroSettingsStore(defaults: defaults, namespace: "first")
        let second = HeroSettingsStore(defaults: defaults, namespace: "second")
        first.save(settings)
        XCTAssertEqual(first.load(), settings)
        XCTAssertFalse(second.load().showsDiscoverySources)

        let snapshot = ProfileSettingsTransfer.capture(namespace: "first", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "second", defaults: defaults)
        XCTAssertEqual(second.load(), settings)

        settings.showsDiscoverySources = false
        first.save(settings)
        XCTAssertEqual(first.load(), settings)
        XCTAssertTrue(second.load().showsDiscoverySources)
        XCTAssertEqual(first.load().discoverySources, [.tvdb, .anilist])
        XCTAssertEqual(second.load().discoverySources, [.tvdb, .anilist])
    }

    func testDiscoveryCreditsHideOptionalSourcesByDefault() {
        var item = MediaItem(id: "title", title: "A title", kind: .movie)
        item.discoverySources = [.tmdb, .tvmaze, .anilist, .tvdb, .tmdb]
        XCTAssertEqual(HeroSettings.default.discoveryAttributionSources(for: item), [])
    }

    func testDiscoveryCreditsOptInNormalizesActualContributorsInOrder() {
        var settings = HeroSettings.default
        settings.showsDiscoverySources = true
        settings.discoverySources = [.tmdb]
        var item = MediaItem(id: "title", title: "A title", kind: .series)
        item.discoverySources = [.tvmaze, .tmdb, .tvmaze, .tvdb, .anilist, .tvdb]
        XCTAssertEqual(
            settings.discoveryAttributionSources(for: item),
            [.tvmaze, .tmdb, .tvdb, .anilist]
        )
    }

    func testOptedInDiscoveryCreditFollowsTheDisplayedItemNotCurrentFeedSelection() {
        var settings = HeroSettings.default
        settings.discoverySources = []
        settings.showsDiscoverySources = true
        let item = MediaItem(
            id: "cached-title", title: "A cached title", kind: .movie,
            discoverySources: [.tvdb, .tmdb]
        )
        XCTAssertEqual(settings.discoveryAttributionSources(for: item), [.tvdb, .tmdb])
    }

    func testDiscoveryCreditsDoNotInventContributorsForOrdinaryLibraryItems() {
        let item = MediaItem(id: "library-title", title: "A library title", kind: .movie)
        var settings = HeroSettings.default
        for showsSources in [false, true] {
            settings.showsDiscoverySources = showsSources
            XCTAssertEqual(settings.discoveryAttributionSources(for: item), [])
        }
    }

    func testDiscoveryCreditsAndLinksSurviveLibraryPresentationMergeAndItemRoundTrip() throws {
        var libraryItem = MediaItem(
            id: "library-title", title: "A library title", kind: .series,
            sourceAccountID: "library-account"
        )
        let discoveryItem = MediaItem(
            id: "discovery-title", title: "A discovered title", kind: .series,
            discoverySources: [.tvdb, .tvmaze],
            discoveryURLs: [
                "tvdb": try XCTUnwrap(URL(string: "https://thetvdb.com/series/example")),
                "tvmaze": try XCTUnwrap(URL(string: "https://www.tvmaze.com/shows/123/example"))
            ],
            locallyValidatedPlayableSource: false
        )
        libraryItem.fillingMissingPresentation(from: discoveryItem)
        let decoded = try JSONDecoder().decode(
            MediaItem.self, from: JSONEncoder().encode(libraryItem)
        )
        XCTAssertEqual(decoded.id, "library-title")
        XCTAssertEqual(decoded.sourceAccountID, "library-account")
        XCTAssertTrue(decoded.locallyValidatedPlayableSource)
        XCTAssertEqual(decoded.discoveryURLs, discoveryItem.discoveryURLs)

        var settings = HeroSettings.default
        XCTAssertEqual(settings.discoveryAttributionSources(for: decoded), [])
        settings.showsDiscoverySources = true
        XCTAssertEqual(settings.discoveryAttributionSources(for: decoded), [.tvdb, .tvmaze])
    }

    @MainActor
    func testDiscoveryCreditTogglePersistsThroughTheExistingHeroModel() {
        let store = InMemoryHeroSettingsStore()
        let model = HeroSettingsModel(store: store)
        let originalSources = model.settings.discoverySources
        XCTAssertFalse(model.settings.showsDiscoverySources)
        model.settings.showsDiscoverySources = true
        XCTAssertTrue(store.load().showsDiscoverySources)
        model.settings.showsDiscoverySources = false
        XCTAssertFalse(store.load().showsDiscoverySources)
        XCTAssertEqual(store.load().discoverySources, originalSources)
    }

    func testWatchlistDiscoveryDefaultsOffForLegacyOrMalformedSettings() throws {
        for field in ["", #","watchlistDiscoveryEnabled":null"#, #","watchlistDiscoveryEnabled":"invalid""#] {
            let data = Data(#"{"maxItems":20,"hideWatched":false\#(field)}"#.utf8)
            let settings = try JSONDecoder().decode(HeroSettings.self, from: data)
            XCTAssertFalse(settings.watchlistDiscoveryEnabled)
            XCTAssertEqual(settings.maxItems, 20)
            XCTAssertFalse(settings.hideWatched)
        }
    }

    func testWatchlistDiscoveryIsPersistedAndTransferredPerProfile() {
        var settings = HeroSettings.default
        settings.watchlistDiscoveryEnabled = true
        settings.maxItems = 20
        let first = HeroSettingsStore(defaults: defaults, namespace: "first")
        let second = HeroSettingsStore(defaults: defaults, namespace: "second")
        first.save(settings)
        XCTAssertEqual(first.load(), settings)
        XCTAssertFalse(second.load().watchlistDiscoveryEnabled)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "first", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "second", defaults: defaults)
        XCTAssertEqual(second.load(), settings)
    }

    func testHomeRatingsVisibilityStillHonorsSpoilersForEachPlayableKind() {
        for kind in [MediaItemKind.movie, .series, .season, .episode, .video] {
            var item = MediaItem(id: "title", title: "A title", kind: kind)
            item.isPlayed = false
            var settings = HeroSettings.default
            XCTAssertFalse(settings.shouldShowRatings(for: item, spoilerSettings: .default))
            item.isPlayed = true
            XCTAssertFalse(settings.shouldShowRatings(for: item, spoilerSettings: .default))

            settings.showsRatings = true
            let spoilers = SpoilerSettings(hideRatingsUntilWatched: true)
            XCTAssertTrue(settings.shouldShowRatings(for: item, spoilerSettings: spoilers))
            item.isPlayed = false
            XCTAssertFalse(settings.shouldShowRatings(for: item, spoilerSettings: spoilers))
            XCTAssertTrue(settings.shouldShowRatings(for: item, spoilerSettings: .default))
        }
    }

    @MainActor
    func testRatingsToggleUpdatesTheExistingHeroModel() {
        let store = InMemoryHeroSettingsStore()
        let model = HeroSettingsModel(store: store)
        XCTAssertFalse(model.settings.showsRatings)
        model.settings.showsRatings = true
        XCTAssertTrue(store.load().showsRatings)
        model.settings.showsRatings = false
        XCTAssertFalse(store.load().showsRatings)
    }
}
