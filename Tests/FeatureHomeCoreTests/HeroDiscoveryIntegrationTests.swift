import CoreModels
import Foundation
import XCTest
@testable import FeatureHomeCore

final class HeroDiscoveryIntegrationTests: XCTestCase {
    func testMixedCacheCannotReclassifyRemovedWatchlistItemAsFeatured() async {
        var settings = HeroSettings.default
        settings.sources = [.watchlist, .featured]
        settings.discoverySources = [.tmdb]
        settings.autoAdvance = false
        let removed = MediaItem(
            id: "watchlist-only", title: "Removed", kind: .movie,
            backdropURL: URL(string: "https://images.example.test/removed.jpg"),
            providerIDs: ["Tmdb": "42"], availability: .unknown,
            locallyValidatedPlayableSource: false
        )
        let featured = MediaItem(
            id: "featured", title: "Featured", kind: .movie,
            backdropURL: URL(string: "https://images.example.test/featured.jpg"),
            providerIDs: ["Tmdb": "43"], discoverySources: [.tmdb],
            availability: .unknown, locallyValidatedPlayableSource: false
        )
        let fallback = HeroDiscoveryStatus.attributedFeaturedCandidates(
            [removed, featured], sources: settings.discoverySources
        )
        XCTAssertEqual(fallback.map(\.id), [featured.id])
        let initial = HeroSourceEligibility(settings: settings, removedFromWatchlist: [removed])
        let result = await HeroCurator().curateResult(
            settings: settings, continueWatching: [], watchlist: [removed],
            sourceEligibility: initial,
            featuredProvider: { _ in fallback },
            artworkValidator: { _ in true }
        )
        XCTAssertEqual(result.items.map(\.id), [featured.id])
        let final = HeroSourceEligibility(
            settings: settings, removedFromWatchlist: [removed],
            supportingCandidates: result.candidatePool
        )
        let merged = HeroLiveMerge.merge(
            showing: [removed], fresh: result.items, limit: 2,
            pinnedItemIDs: [removed.id], preservesPinnedItems: true,
            sourceEligibility: final
        )
        XCTAssertEqual(merged.items.map(\.id), [featured.id])
        XCTAssertEqual(merged.retired, [removed.id])
    }

    func testPinnedTargetIsRevokedWhenOnlyAnotherAccountStillVerifies() {
        let first = MediaSourceRef(accountID: "a", itemID: "a-item", kind: .movie)
        let second = MediaSourceRef(accountID: "b", itemID: "b-item", kind: .movie)
        let old = MediaItem(
            id: first.itemID, title: "Title", kind: .movie,
            providerIDs: ["Tmdb": "42"], discoverySources: [.tmdb],
            sourceAccountID: first.accountID, sources: [first, second]
        )
        let fresh = MediaItem(
            id: second.itemID, title: "Title", kind: .movie,
            providerIDs: ["Tmdb": "42"], discoverySources: [.tmdb],
            sourceAccountID: second.accountID, sources: [second]
        )
        let merged = HeroLiveMerge.merge(
            showing: [old], fresh: [fresh], limit: 1,
            pinnedItemIDs: [old.id], preservesPinnedItems: true
        )
        XCTAssertEqual(merged.items.first?.id, old.id)
        XCTAssertFalse(merged.items.first?.locallyValidatedPlayableSource ?? true)
        XCTAssertFalse(merged.items.first?.hasPlayableLibraryTarget(additionalSources: [first]) ?? true)
        XCTAssertTrue(merged.items.first?.sources.isEmpty ?? false)
    }

    func testPinnedVerifiedTargetReplacesAllOldRoutingEvidence() {
        let retained = MediaSourceRef(accountID: "a", itemID: "a-item", kind: .movie)
        let rejected = MediaSourceRef(accountID: "removed", itemID: "old", kind: .movie)
        let newPrimary = MediaSourceRef(accountID: "b", itemID: "b-item", kind: .movie)
        let old = MediaItem(
            id: retained.itemID, title: "Title", kind: .movie,
            providerIDs: ["Tmdb": "42"], discoverySources: [.tmdb],
            sourceAccountID: retained.accountID, sources: [retained, rejected]
        )
        let fresh = MediaItem(
            id: newPrimary.itemID, title: "Title", kind: .movie,
            providerIDs: ["Tmdb": "42"], discoverySources: [.tmdb],
            sourceAccountID: newPrimary.accountID, sources: [newPrimary, retained]
        )
        let merged = HeroLiveMerge.merge(
            showing: [old], fresh: [fresh], limit: 1,
            pinnedItemIDs: [old.id], preservesPinnedItems: true
        )
        XCTAssertEqual(merged.items.first?.id, old.id)
        XCTAssertTrue(merged.items.first?.locallyValidatedPlayableSource ?? false)
        XCTAssertEqual(Set(merged.items.first?.sources.map(\.id) ?? []), Set([retained.id, newPrimary.id]))
    }

    func testFallbackCannotReuseADisabledFeedOrPreviousLibraryScope() {
        var settings = HeroSettings.default
        settings.sources = [.featured]
        settings.discoverySources = [.tmdb]
        let previous = HeroConfigurationKey(settings: settings)
        let cached = [MediaItem(id: "tmdb", title: "Movie", kind: .movie)]
        XCTAssertEqual(HeroDiscoveryStatus.cachedCandidates(
            cached, configuration: previous, disabledLibraryKeys: [],
            matching: previous, currentDisabledKeys: []
        ), cached)
        settings.discoverySources = [.anilist]
        XCTAssertNil(HeroDiscoveryStatus.cachedCandidates(
            cached, configuration: previous, disabledLibraryKeys: [],
            matching: .init(settings: settings), currentDisabledKeys: []
        ))
        XCTAssertNil(HeroDiscoveryStatus.cachedCandidates(
            cached, configuration: previous, disabledLibraryKeys: [],
            matching: previous, currentDisabledKeys: ["account:hidden"]
        ))
    }

    func testPinnedTitleLosesRejectedOwnershipWithoutChangingItsVisibleIdentity() {
        let old = MediaItem(
            id: "library-item", title: "Title", kind: .movie,
            providerIDs: ["Tmdb": "42"], discoverySources: [.tmdb],
            sourceAccountID: "account",
            sources: [.init(accountID: "account", itemID: "library-item", kind: .movie)]
        )
        let fresh = MediaItem(
            id: "tmdb:movie:42", title: "Title", kind: .movie,
            providerIDs: ["Tmdb": "42"], discoverySources: [.tmdb],
            availability: .unknown, locallyValidatedPlayableSource: false
        )
        let merged = HeroLiveMerge.merge(
            showing: [old], fresh: [fresh], limit: 1,
            pinnedItemIDs: [old.id], preservesPinnedItems: true
        )
        XCTAssertEqual(merged.items.first?.id, old.id)
        XCTAssertFalse(merged.items.first?.locallyValidatedPlayableSource ?? true)
        XCTAssertNil(merged.items.first?.sourceAccountID)
        XCTAssertTrue(merged.items.first?.sources.isEmpty ?? false)
    }

    func testFeedChoicesInvalidateOnlyFeaturedConfigurations() throws {
        var settings = HeroSettings.default
        settings.sources = [.featured]
        let original = HeroConfigurationKey(settings: settings)
        settings.discoverySources = [.anilist]
        XCTAssertNotEqual(HeroConfigurationKey(settings: settings), original)

        settings.sources = [.randomFromLibrary]
        let libraryOnly = HeroConfigurationKey(settings: settings)
        settings.discoverySources = []
        XCTAssertEqual(HeroConfigurationKey(settings: settings), libraryOnly)

        let legacy = Data(#"{"sources":["featured"],"maxItems":8,"hideWatched":true}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(HeroConfigurationKey.self, from: legacy).discoverySources,
            HeroDiscoverySource.defaultSelection
        )
    }

    func testProviderOutageWithoutSeerrDoesNotAuthoritativelyClearHero() {
        var settings = HeroSettings.default
        settings.sources = [.featured]
        XCTAssertFalse(HeroEmptyCuration.isAuthoritative(
            settings: settings, continueWatching: [], watchlist: [], recentlyAdded: [],
            randomLibraries: [], seerConnected: false, featuredDiscoveryEnabled: true
        ))
        XCTAssertTrue(HeroEmptyCuration.isAuthoritative(
            settings: settings, continueWatching: [], watchlist: [], recentlyAdded: [],
            randomLibraries: [], seerConnected: true, featuredDiscoveryEnabled: false
        ))
    }

    func testSeerrStatusCannotOverwriteDiscoveryIdentityArtworkOrOwnership() {
        let original = MediaItem(
            id: "discovery", title: "Original", kind: .movie,
            posterURL: URL(string: "https://images.example.test/poster.jpg"),
            providerIDs: ["Tmdb": "42"], discoverySources: [.simkl],
            availability: .unknown, locallyValidatedPlayableSource: false
        )
        let status = MediaItem(
            id: original.id, title: "Other title", kind: .series,
            providerIDs: ["Tmdb": "999"], availability: .processing,
            locallyValidatedPlayableSource: true, downloadProgress: 0.4,
            sourceAccountID: "not-owned"
        )
        let result = HeroDiscoveryStatus.merging([status], into: [original])[0]
        XCTAssertEqual(result.title, original.title)
        XCTAssertEqual(result.kind, .movie)
        XCTAssertEqual(result.providerIDs, original.providerIDs)
        XCTAssertEqual(result.posterURL, original.posterURL)
        XCTAssertEqual(result.discoverySources, [.simkl])
        XCTAssertEqual(result.availability, .processing)
        XCTAssertEqual(result.downloadProgress, 0.4)
        XCTAssertFalse(result.locallyValidatedPlayableSource)
        XCTAssertNil(result.sourceAccountID)
    }
}
