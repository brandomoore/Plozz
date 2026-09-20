import CoreModels
import FeatureHomeCore
import Foundation
import XCTest
@testable import FeatureHome

@MainActor
final class HeroWatchlistDisplayEligibilityTests: XCTestCase {
    private func item(_ id: String) -> MediaItem {
        MediaItem(
            id: id, title: id, kind: .movie,
            backdropURL: URL(string: "https://example.com/\(id).jpg")
        )
    }

    private var settings: HeroSettings {
        var settings = HeroSettings.default
        settings.sources = [.watchlist]
        settings.autoAdvance = false
        return settings
    }

    func testLoadedHeroDropsRemovedPinnedTitleBeforeAsyncCurationCompletes() {
        let a = item("a")
        let b = item("b")
        let content = HomeViewModel.Content(watchlist: [a, b])
        let key = HeroRecomputeKey(content: content, settings: settings, randomLibraries: [])
        let runtime = HomeHeroRuntimeState()
        runtime.items = [a, b]
        runtime.completedKey = key
        runtime.pinnedItemIDs = ["a"]
        let resolved = HomeHeroDisplayResolver.resolve(
            runtime: runtime, key: key, settings: settings,
            continueWatching: [], watchlist: [a, b], curator: HeroCurator(),
            sourceEligibility: HeroSourceEligibility(settings: settings, removedFromWatchlist: [a])
        )
        XCTAssertEqual(resolved.map(\.id), ["b"])
        XCTAssertEqual(runtime.pinnedItemIDs, ["a"], "No blanket pin reset is necessary.")
    }

    func testCachedHeroCannotResurrectTitleRejectedByCurrentMembership() {
        let a = item("a")
        let b = item("b")
        let key = HeroRecomputeKey(content: .init(), settings: settings, randomLibraries: [])
        let runtime = HomeHeroRuntimeState()
        runtime.cachedItems = [a, b]
        runtime.cachedKey = HeroConfigurationKey(settings: settings)
        let eligibility = HeroSourceEligibility(settings: settings, removedFromWatchlist: [a])
        XCTAssertEqual(HomeHeroDisplayResolver.resolve(
            runtime: runtime, key: key, settings: settings,
            continueWatching: [], watchlist: [], curator: HeroCurator(),
            sourceEligibility: eligibility
        ).map(\.id), ["b"])
        XCTAssertEqual(HomeHeroDisplayResolver.resolve(
            runtime: runtime, key: key, settings: settings,
            continueWatching: [], watchlist: [], curator: HeroCurator()
        ).map(\.id), ["a", "b"], "Unknown/loading membership is not an exclusion.")
    }

    func testIntentAndRollbackRestartCurationEvenBeforeRowIdentityChanges() {
        let content = HomeViewModel.Content(watchlist: [item("a"), item("b")])
        let original = HeroRecomputeKey(
            content: content, settings: settings, randomLibraries: [], watchlistMembershipRevision: 0
        )
        let removal = HeroRecomputeKey(
            content: content, settings: settings, randomLibraries: [], watchlistMembershipRevision: 1
        )
        let rollback = HeroRecomputeKey(
            content: content, settings: settings, randomLibraries: [], watchlistMembershipRevision: 2
        )
        XCTAssertNotEqual(original, removal)
        XCTAssertNotEqual(removal, rollback)
        XCTAssertFalse(original.matchesIgnoringExternalRefresh(removal))
        XCTAssertTrue(original.matchesConfiguration(removal))
    }

    func testWatchlistNotificationsDoNotInvalidateHeroesWithoutWatchlistSource() {
        var config = settings
        config.sources = [.randomFromLibrary]
        let original = HeroRecomputeKey(
            content: .init(), settings: config, randomLibraries: [], watchlistMembershipRevision: 0
        )
        let changed = HeroRecomputeKey(
            content: .init(), settings: config, randomLibraries: [], watchlistMembershipRevision: 1
        )
        XCTAssertEqual(original, changed)
    }

    func testProfileScopeResetClearsPriorMembershipExclusions() {
        let a = item("a")
        let runtime = HomeHeroRuntimeState()
        runtime.sourceEligibility = HeroSourceEligibility(settings: settings, removedFromWatchlist: [a])
        XCTAssertFalse(runtime.sourceEligibility.allows(a))
        runtime.resetForSourceScopeChange()
        XCTAssertTrue(runtime.sourceEligibility.allows(a))
    }
}
