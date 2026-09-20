#if canImport(SwiftUI)
import CoreModels
import FeatureHomeCore
import XCTest
@testable import FeatureHome

final class HeroRefreshTriggerTests: XCTestCase {
    func testFeaturedTrendsDoNotReloadWhenUnrelatedWatchlistIDsChange() {
        var settings = HeroSettings.default
        settings.sources = [.featured]
        settings.discoverySources = [.tmdb]
        let before = HeroRecomputeKey(
            content: .init(watchlist: [
                MediaItem(id: "saved", title: "Saved", kind: .movie, providerIDs: ["Tmdb": "1"])
            ]),
            settings: settings, randomLibraries: [], discoveryUsesWatchlist: true
        )
        let after = HeroRecomputeKey(
            content: .init(watchlist: [
                MediaItem(id: "saved", title: "Saved", kind: .movie, providerIDs: ["Tmdb": "2"])
            ]),
            settings: settings, randomLibraries: [], discoveryUsesWatchlist: true
        )
        XCTAssertFalse(settings.usesDiscoveryWatchlistSeeds)
        XCTAssertEqual(before, after)
        XCTAssertTrue(before.matchesIgnoringExternalRefresh(after))
        XCTAssertTrue(before.matchesConfiguration(after))
    }

    func testUnseededDiscoveryDoesNotDependOnWatchlist() {
        var settings = HeroSettings.default
        settings.sources = [.featured]
        settings.discoverySources = [.tvmaze]
        let before = HeroRecomputeKey(
            content: .init(), settings: settings, randomLibraries: [], discoveryUsesWatchlist: true
        )
        let after = HeroRecomputeKey(
            content: .init(watchlist: [MediaItem(id: "saved", title: "Saved", kind: .movie)]),
            settings: settings, randomLibraries: [], discoveryUsesWatchlist: true
        )
        XCTAssertEqual(before, after)
    }

    func testDiscoveryCreditPreferenceDoesNotRestartCurationOrRetireCachedTitles() {
        var settings = HeroSettings.default
        let originalConfiguration = HeroConfigurationKey(settings: settings)
        let before = HeroRecomputeKey(content: .init(), settings: settings, randomLibraries: [])
        settings.showsDiscoverySources = true
        let after = HeroRecomputeKey(content: .init(), settings: settings, randomLibraries: [])
        XCTAssertEqual(HeroConfigurationKey(settings: settings), originalConfiguration)
        XCTAssertEqual(before, after)
        XCTAssertFalse(HeroRecomputePolicy.shouldRun(key: after, completedKey: before))
    }

    @MainActor
    func testDisabledLibraryRetiresLoadedAndCachedPinsBeforeFreshCuration() {
        var settings = HeroSettings.default
        settings.sources = [.randomFromLibrary]
        settings.maxItems = 1
        let before = HeroRecomputeKey(
            content: .init(), settings: settings, randomLibraries: []
        )
        let after = HeroRecomputeKey(
            content: .init(), settings: settings, randomLibraries: [],
            disabledLibraryKeys: ["account:a"]
        )
        let old = MediaItem(id: "a", title: "A", kind: .movie)
        let runtime = HomeHeroRuntimeState()
        runtime.items = [old]
        runtime.completedKey = before
        runtime.cachedItems = [old]
        runtime.cachedKey = HeroConfigurationKey(settings: settings)
        runtime.pinnedItemIDs = ["a"]
        XCTAssertFalse(before.matchesConfiguration(after))
        let showing = HomeHeroDisplayResolver.resolve(
            runtime: runtime, key: after, settings: settings,
            continueWatching: [], watchlist: [], curator: HeroCurator()
        )
        XCTAssertTrue(showing.isEmpty)
        let fresh = MediaItem(id: "b", title: "B", kind: .movie)
        XCTAssertEqual(HeroLiveMerge.merge(
            showing: showing, fresh: [fresh], limit: 1,
            pinnedItemIDs: runtime.pinnedItemIDs, preservesPinnedItems: true
        ).items, [fresh])
    }

    func testFreshnessRevisionForcesFullCurationWithUnchangedHomeContent() {
        let settings = HeroSettings.default
        let content = HomeViewModel.Content()
        let before = HeroRecomputeKey(
            content: content, settings: settings, randomLibraries: [],
            freshnessRevision: 0
        )
        let after = HeroRecomputeKey(
            content: content, settings: settings, randomLibraries: [],
            freshnessRevision: 1
        )
        XCTAssertTrue(HeroRecomputePolicy.shouldRun(key: after, completedKey: before))
        XCTAssertFalse(before.matchesIgnoringExternalRefresh(after))
        XCTAssertTrue(before.matchesConfiguration(after))
    }

    func testWatchlistDiscoveryChangeDoesNotTakeWatchStateOnlyFastPath() {
        var settings = HeroSettings.default
        settings.sources = [.watchlist]
        let before = HeroRecomputeKey(
            content: .init(), settings: settings, randomLibraries: []
        )
        settings.watchlistDiscoveryEnabled = true
        let after = HeroRecomputeKey(
            content: .init(), settings: settings, randomLibraries: []
        )
        XCTAssertFalse(before.matchesIgnoringExternalRefresh(after))
        XCTAssertFalse(before.matchesConfiguration(after))
    }

    func testInactiveHeroIgnoresFreshnessRevision() {
        var settings = HeroSettings.default
        settings.isEnabled = false
        let before = HeroRecomputeKey(
            content: .init(), settings: settings, randomLibraries: [],
            freshnessRevision: 0
        )
        let after = HeroRecomputeKey(
            content: .init(), settings: settings, randomLibraries: [],
            freshnessRevision: 1
        )
        XCTAssertEqual(before, after)
    }
}
#endif
