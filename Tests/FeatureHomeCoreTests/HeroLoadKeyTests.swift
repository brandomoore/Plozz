import CoreModels
import Foundation
import XCTest
@testable import FeatureHomeCore

final class HeroLoadKeyTests: XCTestCase {
    private let scope = NSObject()
    private let connection = UUID()

    private var featured: HeroSettings {
        var settings = HeroSettings.default
        settings.sources = [.featured]
        return settings
    }

    private func curation(
        _ settings: HeroSettings, revision: Int,
        content: HomeViewModel.Content = .init(),
        membershipRevision: Int = 0,
        scopeID: ObjectIdentifier? = nil,
        isPreparingHome: Bool = false,
        loadingRows: Set<HomeRowKind> = []
    ) -> HeroCurationLoadKey {
        HeroCurationLoadKey(
            content: content, settings: settings, visibility: .default,
            freshnessRevision: 0, identityIndexRevision: revision,
            watchlistMembershipRevision: membershipRevision,
            scopeID: scopeID ?? ObjectIdentifier(scope), seerRevision: connection,
            isPreparingHome: isPreparingHome, loadingRows: loadingRows
        )
    }

    func testPendingEmptySourcesCannotCompleteHeroAndReadyEmptySourcesRestartCuration() {
        let dependencies: [(HeroSourceKind, HomeRowKind)] = [
            (.continueWatching, .continueWatching), (.recentlyAdded, .recentlyAdded),
            (.watchlist, .watchlist), (.randomFromLibrary, .libraries)
        ]
        for (source, row) in dependencies {
            var settings = HeroSettings.default
            settings.sources = [source]
            let preparing = curation(settings, revision: 0, isPreparingHome: true)
            let pending = curation(settings, revision: 0, loadingRows: [row])
            let ready = curation(settings, revision: 0)
            XCTAssertTrue(preparing.isAwaitingSources)
            XCTAssertTrue(pending.isAwaitingSources)
            XCTAssertFalse(ready.isAwaitingSources)
            XCTAssertNotEqual(pending, ready, "Even a successful empty source must restart the task.")
            XCTAssertEqual(
                ready,
                curation(settings, revision: 0, loadingRows: Set(HomeRowKind.allCases).subtracting([row])),
                "Unrelated Home rows must not delay or restart this hero."
            )
        }
    }

    func testAsyncHeroSourcesWaitForPreparationButNotUnrelatedRows() {
        for source: HeroSourceKind in [.featured, .collection] {
            var settings = HeroSettings.default
            settings.sources = [source]
            let preparing = curation(settings, revision: 0, isPreparingHome: true)
            let pendingRows = curation(settings, revision: 0, loadingRows: Set(HomeRowKind.allCases))
            XCTAssertTrue(preparing.isAwaitingSources)
            XCTAssertEqual(pendingRows.isAwaitingSources, settings.usesDiscoveryWatchlistSeeds)
            XCTAssertFalse(curation(settings, revision: 0).isAwaitingSources)
        }
        var settings = featured
        settings.isEnabled = false
        XCTAssertFalse(curation(settings, revision: 0, loadingRows: Set(HomeRowKind.allCases)).isAwaitingSources)
    }

    func testFeaturedOnlyReloadsWhenItsIndexWarmsWithoutHomeRowChanges() {
        let cold = curation(featured, revision: 0)
        let unrelated = HomeViewModel.Content(
            watchlist: [MediaItem(id: "saved", title: "Saved", kind: .movie)]
        )
        XCTAssertEqual(cold, curation(featured, revision: 0, content: unrelated))
        XCTAssertNotEqual(cold, curation(featured, revision: 1))
        XCTAssertEqual(curation(featured, revision: 1), curation(featured, revision: 1))
        var unfiltered = featured
        unfiltered.hideWatched = false
        XCTAssertNotEqual(curation(unfiltered, revision: 0), curation(unfiltered, revision: 1))
    }

    func testIndexUpdatesDoNotRestartDisabledOrNonDiscoveryHeroes() {
        var settings = featured
        settings.sources = [.watchlist]
        XCTAssertEqual(curation(settings, revision: 1), curation(settings, revision: 2))
        settings = featured
        settings.isEnabled = false
        XCTAssertEqual(curation(settings, revision: 1), curation(settings, revision: 2))
        settings = featured
        settings.discoverySources = []
        XCTAssertEqual(curation(settings, revision: 1), curation(settings, revision: 2))
    }

    func testNewProfileScopeReloadsEvenWhenIndexRevisionAndSettingsMatch() {
        let otherScope = NSObject()
        XCTAssertNotEqual(
            curation(featured, revision: 1),
            curation(featured, revision: 1, scopeID: ObjectIdentifier(otherScope))
        )
    }

    func testWatchlistIntentRollbackReloadsWithoutRowIDChanges() {
        var settings = featured
        settings.sources = [.watchlist]
        XCTAssertNotEqual(
            curation(settings, revision: 0, membershipRevision: 1),
            curation(settings, revision: 0, membershipRevision: 2)
        )
        XCTAssertEqual(
            curation(featured, revision: 0, membershipRevision: 1),
            curation(featured, revision: 0, membershipRevision: 2)
        )
    }

    func testPresentationPreferencesCannotRestartDiscoveryVerification() {
        var restyled = featured
        restyled.showsDiscoverySources = true
        restyled.showsRatings = true
        restyled.autoAdvance.toggle()
        XCTAssertEqual(curation(featured, revision: 1), curation(restyled, revision: 1))
    }

    func testCollectionSelectionAndHistoryRevisionRestartCuration() {
        var settings = featured
        settings.sources = [.collection]
        settings.collections = [.init(accountID: "a", libraryID: "l", collectionID: "c", title: "Collection")]
        let initial = curation(settings, revision: 0)
        XCTAssertNotEqual(initial, curation(settings, revision: 1))
        settings.collections.append(.init(accountID: "a", libraryID: "l", collectionID: "other", title: "Collection"))
        XCTAssertNotEqual(initial, curation(settings, revision: 0))
        settings.hideWatched = false
        XCTAssertEqual(curation(settings, revision: 0), curation(settings, revision: 1))
    }

    private func status(
        _ items: [MediaItem], context: String = "profile-a/connection-a",
        configured: Bool = true, settings: HeroSettings? = nil
    ) -> HeroStatusRefreshKey {
        HeroStatusRefreshKey(
            requestableItems: items, settings: settings ?? featured,
            isConfigured: configured, contextID: context, scopeID: ObjectIdentifier(scope)
        )
    }

    private func item(_ id: String = "42") -> MediaItem {
        MediaItem(
            id: id, title: "Movie", kind: .movie, providerIDs: ["Tmdb": id],
            availability: .unknown, locallyValidatedPlayableSource: false
        )
    }

    func testPublishingHeroStartsStatusTaskButReceivingStatusDoesNotRestartIt() {
        let empty = status([])
        let published = status([item()])
        XCTAssertFalse(empty.isActive)
        XCTAssertTrue(published.isActive)
        XCTAssertNotEqual(empty, published)
        var downloading = item()
        downloading.availability = .processing
        downloading.downloadProgress = 0.35
        XCTAssertEqual(published, status([downloading]))
        XCTAssertNotEqual(published, status([item("43")]))
    }

    func testStatusTaskRestartsForChangedRequestIdentityAndProfileOrConnection() {
        let original = status([item()])
        var changed = item()
        changed.providerIDs = ["Tmdb": "99"]
        XCTAssertNotEqual(original, status([changed]))
        changed = item()
        changed.kind = .series
        XCTAssertNotEqual(original, status([changed]))
        XCTAssertNotEqual(original, status([item()], context: "profile-b/connection-a"))
        XCTAssertNotEqual(original, status([item()], context: "profile-a/connection-b"))
    }

    func testStatusTaskIsInactiveWithoutConfiguredFeaturedAndIgnoresCosmeticChanges() {
        XCTAssertFalse(status([item()], configured: false).isActive)
        XCTAssertFalse(HeroStatusRefreshKey(
            requestableItems: [item()], settings: nil, isConfigured: true,
            contextID: "profile", scopeID: ObjectIdentifier(scope)
        ).isActive)
        var settings = featured
        settings.isEnabled = false
        XCTAssertFalse(status([item()], settings: settings).isActive)
        settings = featured
        settings.sources = [.watchlist]
        XCTAssertFalse(status([item()], settings: settings).isActive)
        settings = featured
        settings.showsDiscoverySources = true
        XCTAssertEqual(status([item()]), status([item()], settings: settings))
    }

    func testPinnedPlaybackResolutionRestartsWhenOwnershipChangesWithoutChangingDisplayID() {
        var external = item()
        external.kind = .series
        external.discoverySources = [.tmdb]
        let cold = resolution(external)
        var owned = external
        owned.locallyValidatedPlayableSource = true
        owned.sources = [.init(accountID: "a", itemID: "physical-series", kind: .series)]
        owned.availability = nil
        let verified = resolution(owned)
        XCTAssertEqual(owned.id, external.id)
        XCTAssertNotEqual(cold, verified)

        let episode = MediaItem(id: "physical-episode", title: "Episode", kind: .episode)
        let cached = HeroResolutionCacheEntry(key: verified, item: episode)
        XCTAssertEqual(cached.value(for: verified)?.id, episode.id)
        XCTAssertNil(cached.value(for: cold), "Revoked ownership must not expose a cached playable episode.")
        owned.sources = [.init(accountID: "b", itemID: "different-series", kind: .series)]
        XCTAssertNil(cached.value(for: resolution(owned)), "Replacing routing must resolve a new episode.")
    }

    func testPlaybackResolutionKeyTracksVersionsIndexAndProfileNotStatusOrArtwork() {
        let original = item()
        let key = resolution(original)
        var presentation = original
        presentation.title = "Updated title"
        presentation.availability = .processing
        presentation.downloadProgress = 0.5
        presentation.posterURL = URL(string: "https://images.example.test/new.jpg")
        XCTAssertEqual(key, resolution(presentation))
        presentation.selectedVersionID = "version-b"
        XCTAssertNotEqual(key, resolution(presentation))
        XCTAssertNotEqual(key, resolution(original, revision: 1))
        let otherScope = NSObject()
        XCTAssertNotEqual(key, HeroPlaybackResolutionKey(
            item: original, scopeID: ObjectIdentifier(otherScope), identityIndexRevision: 0
        ))
    }

    private func resolution(_ item: MediaItem, revision: Int = 0) -> HeroPlaybackResolutionKey {
        HeroPlaybackResolutionKey(
            item: item, scopeID: ObjectIdentifier(scope), identityIndexRevision: revision
        )
    }
}
