import XCTest
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

    func testDefaultIsActiveWithAllSources() {
        let d = HeroSettings.default
        XCTAssertTrue(d.isActive)
        XCTAssertEqual(d.sources, HeroSourceKind.allCases)
        XCTAssertTrue(d.hideWatched)
        XCTAssertFalse(d.showsRatings)
        XCTAssertFalse(d.showsDiscoverySources)
        XCTAssertFalse(d.watchlistDiscoveryEnabled)
        XCTAssertEqual(d.maxItems, 8)
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

    func testInMemoryStoreRoundTrips() {
        let store = InMemoryHeroSettingsStore()
        XCTAssertEqual(store.load(), .default)
        let s = HeroSettings(isEnabled: true, sources: [.continueWatching], maxItems: 2, trailersEnabled: false, randomLibraryKeys: [], autoAdvance: true, autoAdvanceSeconds: 8)
        store.save(s)
        XCTAssertEqual(store.load(), s)
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

    func testDiscoveryCreditsDefaultOffForLegacyOrMalformedSettingsWithoutChangingFeedOptIns() throws {
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
            XCTAssertEqual(settings.discoverySources, [.simkl, .anilist])
        }
    }

    func testDiscoveryCreditPreferenceRoundTripsAndTransfersPerProfile() {
        var settings = HeroSettings.default
        settings.showsDiscoverySources = true
        settings.discoverySources = [.simkl, .anilist]
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
        XCTAssertEqual(first.load().discoverySources, [.simkl, .anilist])
        XCTAssertEqual(second.load().discoverySources, [.simkl, .anilist])
    }

    func testDiscoveryCreditsHideOptionalSourcesByDefault() {
        var item = MediaItem(id: "title", title: "A title", kind: .movie)
        item.discoverySources = [.tmdb, .tvmaze, .anilist, .tvdb, .tmdb]
        XCTAssertEqual(HeroSettings.default.discoveryAttributionSources(for: item), [])

        item.discoverySources = [.tmdb, .simkl, .tvmaze, .simkl]
        XCTAssertEqual(HeroSettings.default.discoveryAttributionSources(for: item), [.simkl])
    }

    func testDiscoveryCreditsOptInNormalizesActualContributorsInOrder() {
        var settings = HeroSettings.default
        settings.showsDiscoverySources = true
        settings.discoverySources = [.tmdb]
        var item = MediaItem(id: "title", title: "A title", kind: .series)
        item.discoverySources = [.tvmaze, .tmdb, .tvmaze, .simkl, .anilist, .simkl, .tvdb]
        XCTAssertEqual(
            settings.discoveryAttributionSources(for: item),
            [.tvmaze, .tmdb, .simkl, .anilist, .tvdb]
        )
    }

    func testMandatoryDiscoveryCreditFollowsTheDisplayedItemNotCurrentFeedSelection() {
        var settings = HeroSettings.default
        settings.discoverySources = []
        let item = MediaItem(
            id: "cached-title", title: "A cached title", kind: .movie,
            discoverySources: [.simkl, .tmdb]
        )
        XCTAssertEqual(settings.discoveryAttributionSources(for: item), [.simkl])
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
            discoverySources: [.simkl, .tvmaze],
            discoveryURLs: [
                "simkl": try XCTUnwrap(URL(string: "https://simkl.com/tv/123/example")),
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
        XCTAssertEqual(settings.discoveryAttributionSources(for: decoded), [.simkl])
        settings.showsDiscoverySources = true
        XCTAssertEqual(settings.discoveryAttributionSources(for: decoded), [.simkl, .tvmaze])
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
