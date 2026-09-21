import CoreModels
import Foundation
import MetadataKit
import FeatureHomeCore
import XCTest
@testable import AppRuntime

final class HeroDiscoveryRuntimeTests: XCTestCase {
    @MainActor
    func testColdFeaturedReverifiesAfterIndexPublicationAndUpgradesThePinnedSlide() async throws {
        let raw = external()
        let record = owned()
        let fixture = fixture(records: [record])
        let snapshot = IdentityIndexSnapshotStore()
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account], identitySources: snapshot.sourcesProvider(),
            discovery: { _, _ in [raw] }
        )
        var settings = HeroSettings.default
        settings.sources = [.featured]
        settings.autoAdvance = false
        let scope = NSObject()
        let connection = UUID()
        func loadKey() -> HeroCurationLoadKey {
            HeroCurationLoadKey(
                content: .init(), settings: settings, visibility: .default,
                freshnessRevision: 0, identityIndexRevision: snapshot.revision,
                scopeID: ObjectIdentifier(scope), seerRevision: connection
            )
        }

        let coldKey = loadKey()
        let cold = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: true)
        let showing = try XCTUnwrap(cold.first)
        XCTAssertFalse(showing.hasPlayableLibraryTarget())
        let index = IdentityIndex()
        await index.ingest([record], accountID: fixture.account.account.id)
        snapshot.update(await index.snapshot())
        XCTAssertNotEqual(loadKey(), coldKey, "Index publication must restart the actual curation task identity.")

        let fresh = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: true)
        let merged = HeroLiveMerge.merge(
            showing: cold, fresh: fresh, limit: 1,
            pinnedItemIDs: [showing.id], preservesPinnedItems: true
        )
        let visible = try XCTUnwrap(merged.items.first)
        XCTAssertEqual(visible.id, showing.id, "Learning ownership must not replace the visible slide.")
        XCTAssertTrue(visible.hasPlayableLibraryTarget())
        let target = PlaybackSourceSelection.bestPlayItem(
            visible, accounts: [fixture.account], identitySources: snapshot.sourcesProvider()
        )
        XCTAssertEqual(target.id, record.id, "Playback must use the verified physical ID, never the display alias.")
        XCTAssertEqual(target.sourceAccountID, fixture.account.account.id)
        XCTAssertEqual(visible.sources.map(\.itemID), [record.id])
    }

    func testRejectedDiscoveryCannotRegainOwnershipDuringRoutingOrMetadataEnrichment() async throws {
        let raw = external(kind: .series)
        let record = owned(kind: .series).taggingLibrary("hidden")
        let fixture = fixture(records: [record])
        let ref = MediaSourceRef(
            accountID: "active", itemID: record.id, libraryID: "hidden", kind: .series
        )
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account], identitySources: { _ in [ref] },
            discovery: { _, _ in [raw] }
        )
        let results = await runtime.candidates(
            .init(), sources: [.tmdb], hideWatched: true,
            visibility: .init(disabledKeys: ["active:hidden"])
        )
        let rejected = try XCTUnwrap(results.first)
        let selected = PlaybackSourceSelection.bestPlayItem(
            rejected, accounts: [fixture.account], identitySources: { _ in [ref] }
        )
        XCTAssertFalse(selected.locallyValidatedPlayableSource)
        XCTAssertEqual(selected.id, raw.id)
        XCTAssertTrue(TitleClassifier.isDiscoveryRouting(rejected, identitySources: [ref]))
        XCTAssertNil(rejected.retargetedToOwnedLibraryCopy(indexedSources: { _ in [ref] }))
        let enriched = await HeroMetadataEnricher(
            accounts: [fixture.account],
            targetSelector: { item in
                PlaybackSourceSelection.bestPlayItem(
                    item, accounts: [fixture.account], identitySources: { _ in [ref] }
                )
            }
        ).enrich([rejected])
        XCTAssertEqual(enriched.first?.id, raw.id)
        XCTAssertFalse(enriched.first?.locallyValidatedPlayableSource ?? true)
        let lookups = await fixture.provider.lookupIDs
        XCTAssertTrue(lookups.isEmpty)
    }

    func testVerifiedDiscoveryUsesOnlyVerifiedCopiesNotNewIndexHints() async throws {
        let raw = external()
        let fixture = fixture(records: [owned()])
        let allowed = MediaSourceRef(accountID: "active", itemID: "library-42", kind: .movie)
        let rejected = MediaSourceRef(accountID: "active", itemID: "not-verified", kind: .movie)
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account], identitySources: { _ in [allowed] },
            discovery: { _, _ in [raw] }
        )
        let results = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: true)
        let verified = try XCTUnwrap(results.first)
        let selected = PlaybackSourceSelection.bestPlayItem(
            verified, accounts: [fixture.account], identitySources: { _ in [rejected] }
        )
        XCTAssertTrue(selected.locallyValidatedPlayableSource)
        XCTAssertEqual(selected.id, "library-42")
        XCTAssertFalse(selected.sources.contains { $0.itemID == "not-verified" })
    }

    @MainActor
    func testCachedDiscoveryCannotRetainPlayFromDisabledLibrary() throws {
        var config = HeroSettings.default
        config.sources = [.featured]
        let fixture = fixture(records: [])
        var cached = owned().taggingSource("active").taggingLibrary("hidden")
        cached.discoverySources = [.tmdb]
        cached.sources = [.init(
            accountID: "active", itemID: cached.id, libraryID: "hidden", kind: .movie
        )]
        let store = InMemoryHomeContentStore()
        store.saveHeroCandidatePool(.init(buckets: [
            .init(source: .featured, items: [cached])
        ]), for: HeroConfigurationKey(settings: config))
        let model = HomeViewModel(
            accounts: [fixture.account], layoutStore: InMemoryHomeLayoutStore(), contentStore: store,
            currentVisibility: { .init(disabledKeys: ["active:hidden"]) }
        )
        let selected = try XCTUnwrap(model.cachedHeroItems(for: config)?.first)
        XCTAssertFalse(selected.locallyValidatedPlayableSource)
        XCTAssertNil(selected.sourceAccountID)
        XCTAssertTrue(selected.sources.isEmpty)
    }

    private func external(_ id: String = "42", kind: MediaItemKind = .movie) -> MediaItem {
        var item = MediaItem(
            id: "discovery:\(kind.rawValue):\(id)", title: "External \(id)", kind: kind,
            overview: "Public overview", productionYear: 2026,
            posterURL: URL(string: "https://public.example/\(id)-poster.jpg"),
            heroBackdropURL: URL(string: "https://public.example/\(id)-hero.jpg"),
            providerIDs: ["Tmdb": id],
            availability: .unknown,
            locallyValidatedPlayableSource: false
        )
        item.discoverySources = [.tmdb, .tvdb]
        return item
    }

    private func owned(_ id: String = "library-42", tmdbID: String = "42", kind: MediaItemKind = .movie) -> MediaItem {
        MediaItem(
            id: id, title: "Server \(tmdbID)", kind: kind,
            overview: "Server overview", productionYear: 2026,
            backdropURL: URL(string: "https://server.example/\(id)-custom.jpg"),
            providerIDs: ["Tmdb": tmdbID]
        )
    }

    private func fixture(
        _ accountID: String = "active",
        kind: ProviderKind = .jellyfin,
        records: [MediaItem],
        probe: HeroDiscoveryLookupProbe = HeroDiscoveryLookupProbe(),
        delay: Duration = .zero,
        ignoresCancellation: Bool = false
    ) -> (account: ResolvedAccount, provider: HeroDiscoveryTestProvider) {
        let server = MediaServer(
            id: "server-\(accountID)", name: "Fixture \(accountID)",
            baseURL: URL(string: "https://server.example")!, provider: kind
        )
        let session = UserSession(
            server: server, userID: "profile-\(accountID)", userName: "Viewer",
            deviceID: "fixture", accessToken: "TEST-ONLY"
        )
        let provider = HeroDiscoveryTestProvider(
            kind: kind, session: session,
            records: Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            probe: probe, delay: delay, ignoresCancellation: ignoresCancellation
        )
        return (ResolvedAccount(account: Account(id: accountID, from: session), provider: provider), provider)
    }

    func testNoAccountsKeepDiscoveryNavigableWithoutGlobalOwnershipOrWatchState() async throws {
        var stale = external()
        stale.availability = .available
        stale.sourceAccountID = "another-profile"
        stale.locallyValidatedPlayableSource = true
        stale.isPlayed = true
        stale.hasBeenPlayed = true
        stale.resumePosition = 500
        stale.sources = [.init(accountID: "another-profile", itemID: "old", isPlayed: true)]
        let runtime = HeroDiscoveryRuntime(
            accounts: [], identitySources: { _ in [] },
            discovery: { [stale] _, _ in [stale] }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: true)
        let result = try XCTUnwrap(items.first)
        XCTAssertEqual(result.id, stale.id)
        XCTAssertEqual(result.availability, .unknown)
        XCTAssertFalse(result.locallyValidatedPlayableSource)
        XCTAssertFalse(result.hasBeenPlayed)
        XCTAssertFalse(result.isPlayed)
        XCTAssertNil(result.resumePosition)
        XCTAssertNil(result.sourceAccountID)
        XCTAssertTrue(result.sources.isEmpty)
        XCTAssertEqual(result.discoverySources, [.tmdb, .tvdb])
        XCTAssertTrue(stale.isPlayed, "Binding must not mutate shared public candidates.")
    }

    func testOnlyActiveKindCompatibleReferencesAreLookedUpAndIndexWatchStateIsIgnored() async throws {
        let raw = external()
        let fixture = fixture(records: [owned()])
        let references: [MediaSourceRef] = [
            .init(accountID: "inactive", itemID: "hidden", kind: .movie, isPlayed: true),
            .init(accountID: "active", itemID: "wrong-kind", kind: .series),
            .init(accountID: "active", itemID: "library-42", kind: .movie, resumePosition: 999, isPlayed: true),
            .init(accountID: "active", itemID: "library-42", kind: .movie)
        ]
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account], identitySources: { _ in references },
            discovery: { _, _ in [raw] }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: true)
        let result = try XCTUnwrap(items.first)
        let lookups = await fixture.provider.lookupIDs
        XCTAssertEqual(lookups, ["library-42"])
        XCTAssertEqual(result.sourceAccountID, "active")
        XCTAssertEqual(result.sources.map(\.accountID), ["active"])
        XCTAssertFalse(result.hasBeenPlayed)
        XCTAssertNil(result.resumePosition)
    }

    func testDisabledIndexedLibraryIsNotQueriedOrClaimedAsOwned() async throws {
        let raw = external()
        let fixture = fixture(records: [owned()])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [
                .init(accountID: "active", itemID: "library-42", libraryID: "hidden", kind: .movie)
            ] },
            discovery: { _, _ in [raw] }
        )
        let result = await runtime.candidates(
            .init(), sources: [.tmdb], hideWatched: true,
            visibility: .init(disabledKeys: ["active:hidden"])
        )
        let lookups = await fixture.provider.lookupIDs
        XCTAssertTrue(lookups.isEmpty)
        XCTAssertEqual(result.first?.id, raw.id)
        XCTAssertFalse(try XCTUnwrap(result.first).locallyValidatedPlayableSource)
        XCTAssertEqual(result.first?.availability, .unknown)
    }

    func testLiveLibraryOverridesStaleVisibleIndexProvenance() async throws {
        let raw = external()
        let server = owned().taggingLibrary("hidden")
        let fixture = fixture(records: [server])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [
                .init(accountID: "active", itemID: "library-42", libraryID: "formerly-visible", kind: .movie)
            ] },
            discovery: { _, _ in [raw] }
        )
        let result = await runtime.candidates(
            .init(), sources: [.tmdb], hideWatched: false,
            visibility: .init(disabledKeys: ["active:hidden"])
        )
        XCTAssertFalse(try XCTUnwrap(result.first).locallyValidatedPlayableSource)
        XCTAssertTrue(result[0].sources.isEmpty)
    }

    func testUnknownDuplicateRefCannotBypassKnownDisabledLibrary() async throws {
        let raw = external()
        let fixture = fixture(records: [owned()])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [
                .init(accountID: "active", itemID: "library-42", kind: .movie),
                .init(accountID: "active", itemID: "library-42", libraryID: "hidden", kind: .movie)
            ] },
            discovery: { _, _ in [raw] }
        )
        let result = await runtime.candidates(
            .init(), sources: [.tmdb], hideWatched: false,
            visibility: .init(disabledKeys: ["active:hidden"])
        )
        XCTAssertFalse(try XCTUnwrap(result.first).locallyValidatedPlayableSource)
    }

    func testSparseLiveRecordUsesOnlyItsOwnLibraryRefForVisibility() async throws {
        let raw = external()
        var server = owned()
        server.sources = [
            .init(accountID: "other-profile", itemID: "other", libraryID: "visible", kind: .movie),
            .init(accountID: "active", itemID: "library-42", libraryID: "hidden", kind: .movie)
        ]
        let fixture = fixture(records: [server])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [
                .init(accountID: "active", itemID: "library-42", libraryID: "formerly-visible", kind: .movie)
            ] },
            discovery: { _, _ in [raw] }
        )
        let result = await runtime.candidates(
            .init(), sources: [.tmdb], hideWatched: false,
            visibility: .init(disabledKeys: ["active:hidden"])
        )
        XCTAssertFalse(try XCTUnwrap(result.first).locallyValidatedPlayableSource)
    }

    func testUnknownLibraryCannotEarnPlayWhenItsAccountHasDisabledLibraries() async throws {
        let raw = external()
        let fixture = fixture(records: [owned()])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [.init(accountID: "active", itemID: "library-42", kind: .movie)] },
            discovery: { _, _ in [raw] }
        )
        let restricted = await runtime.candidates(
            .init(), sources: [.tmdb], hideWatched: false,
            visibility: .init(disabledKeys: ["active:some-library"])
        )
        XCTAssertFalse(try XCTUnwrap(restricted.first).locallyValidatedPlayableSource)
        let otherAccountRestricted = await runtime.candidates(
            .init(), sources: [.tmdb], hideWatched: false,
            visibility: .init(disabledKeys: ["other-account:some-library"])
        )
        XCTAssertTrue(try XCTUnwrap(otherAccountRestricted.first).locallyValidatedPlayableSource)
    }

    func testDisabledCopyCannotContributePlayedStateWhenAnotherCopyIsEnabled() async throws {
        let raw = external()
        var hidden = owned("hidden-item").taggingLibrary("hidden")
        hidden.isPlayed = true
        hidden.hasBeenPlayed = true
        let visible = owned("visible-item").taggingLibrary("visible")
        let first = fixture("a", records: [hidden])
        let second = fixture("b", records: [visible])
        let runtime = HeroDiscoveryRuntime(
            accounts: [first.account, second.account],
            identitySources: { _ in [
                .init(accountID: "a", itemID: "hidden-item", kind: .movie),
                .init(accountID: "b", itemID: "visible-item", kind: .movie)
            ] },
            discovery: { _, _ in [raw] }
        )
        let items = await runtime.candidates(
            .init(), sources: [.tmdb], hideWatched: true,
            visibility: .init(disabledKeys: ["a:hidden"])
        )
        let result = try XCTUnwrap(items.first)
        XCTAssertEqual(result.sourceAccountID, "b")
        XCTAssertEqual(result.sources.map(\.id), ["b:visible-item"])
        XCTAssertFalse(result.hasBeenPlayed)
    }

    func testVisibilityIsReadPerCallRatherThanCapturedByRuntime() async throws {
        let raw = external()
        let fixture = fixture(records: [owned().taggingLibrary("library")])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [.init(accountID: "active", itemID: "library-42", kind: .movie)] },
            discovery: { _, _ in [raw] }
        )
        let before = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: false)
        let after = await runtime.candidates(
            .init(), sources: [.tmdb], hideWatched: false,
            visibility: .init(disabledKeys: ["active:library"])
        )
        XCTAssertTrue(try XCTUnwrap(before.first).locallyValidatedPlayableSource)
        XCTAssertFalse(try XCTUnwrap(after.first).locallyValidatedPlayableSource)
    }

    func testSparseOwnedCopyRetainsEligibleIndexedLibraryForLaterVisibilityChecks() async throws {
        let raw = external()
        let fixture = fixture(records: [owned()])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [
                .init(accountID: "active", itemID: "library-42", libraryID: "visible", kind: .movie)
            ] },
            discovery: { _, _ in [raw] }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: false)
        let result = try XCTUnwrap(items.first)
        XCTAssertEqual(result.libraryID, "visible")
        XCTAssertEqual(result.sources.first?.libraryID, "visible")
        XCTAssertTrue(result.locallyValidatedPlayableSource)
    }

    func testBothProvidersKeepServerMetadataAndArtworkAndDiscoveryAttribution() async throws {
        for kind in [ProviderKind.plex, .jellyfin] {
            var raw = external()
            raw.providerIDs["Imdb"] = "tt0042"
            raw.discoveryURLs = [
                HeroDiscoverySource.tmdb.rawValue: URL(string: "https://www.themoviedb.org/movie/42")!
            ]
            var server = owned()
            server.title = "My Curated Title"
            server.productionYear = 2001
            server.providerIDs = ["TMDB ID": "42", "Tvdb": "900"]
            let fixture = fixture(kind: kind, records: [server])
            let runtime = HeroDiscoveryRuntime(
                accounts: [fixture.account],
                identitySources: { _ in [.init(accountID: "active", itemID: "library-42", kind: .movie)] },
                discovery: { [raw] _, _ in [raw] }
            )
            let items = await runtime.candidates(.init(), sources: [.tmdb, .tvdb], hideWatched: false)
            let result = try XCTUnwrap(items.first)
            XCTAssertEqual(result.id, server.id)
            XCTAssertEqual(result.title, server.title)
            XCTAssertEqual(result.overview, server.overview)
            XCTAssertEqual(result.productionYear, server.productionYear)
            XCTAssertEqual(result.backdropURL, server.backdropURL)
            XCTAssertNil(result.heroBackdropURL, "Online hero art must not outrank a server's custom backdrop.")
            XCTAssertEqual(result.posterURL, raw.posterURL, "Missing server fields may use public metadata.")
            XCTAssertEqual(result.providerID(.tmdb), "42")
            XCTAssertEqual(result.providerID(.tvdb), "900")
            XCTAssertEqual(result.providerID(.imdb), "tt0042")
            XCTAssertEqual(result.discoverySources, [.tmdb, .tvdb])
            XCTAssertEqual(result.discoveryURLs, raw.discoveryURLs)
            XCTAssertTrue(result.locallyValidatedPlayableSource)
            XCTAssertNil(result.availability)
            XCTAssertEqual(result.sources.first?.providerKind, kind)
            XCTAssertEqual(result.sources.first?.itemID, server.id)
        }
    }

    func testNoServerBackdropAllowsExternalBackdropFallback() async throws {
        let raw = external()
        var server = owned()
        server.backdropURL = nil
        let fixture = fixture(records: [server])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [.init(accountID: "active", itemID: "library-42", kind: .movie)] },
            discovery: { _, _ in [raw] }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: false)
        XCTAssertEqual(items.first?.heroBackdropURL, raw.heroBackdropURL)
        XCTAssertTrue(try XCTUnwrap(items.first).locallyValidatedPlayableSource)
    }

    func testServerArtworkSelectionIsNotOverriddenByExternalHeroURL() async throws {
        let raw = external()
        var server = owned()
        server.backdropURL = nil
        server.artworkSelections = [.init(
            placement: .homeHero,
            references: [.remote(URL(string: "https://server.example/curated-hero.jpg")!)]
        )]
        let fixture = fixture(records: [server])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [.init(accountID: "active", itemID: "library-42", kind: .movie)] },
            discovery: { _, _ in [raw] }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: false)
        let result = try XCTUnwrap(items.first)
        XCTAssertNil(result.heroBackdropURL)
        XCTAssertEqual(result.artworkSelections, server.artworkSelections)
    }

    func testFailureLeavesExternalInsteadOfTrustingCachedResumeOrAvailability() async throws {
        let raw = external()
        let fixture = fixture(records: [])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [
                .init(accountID: "active", itemID: "missing", kind: .movie, resumePosition: 800, isPlayed: true)
            ] },
            discovery: { _, _ in [raw] }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: true)
        let result = try XCTUnwrap(items.first)
        XCTAssertFalse(result.locallyValidatedPlayableSource)
        XCTAssertFalse(result.hasBeenPlayed)
        XCTAssertNil(result.resumePosition)
        XCTAssertTrue(result.sources.isEmpty)
    }

    func testNumericExternalIDsAndUntypedRefsCannotCrossMovieAndSeriesKinds() async throws {
        let movie = external(kind: .movie)
        let series = external(kind: .series)
        let fixture = fixture(records: [owned("1", kind: .movie)])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [.init(accountID: "active", itemID: "1")] },
            discovery: { _, _ in [movie, series] }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: false)
        XCTAssertEqual(items.map(\.kind), [.movie, .series])
        XCTAssertTrue(items[0].locallyValidatedPlayableSource)
        XCTAssertFalse(items[1].locallyValidatedPlayableSource)
        XCTAssertEqual(items[1].id, series.id)
        let lookups = await fixture.provider.lookupIDs
        XCTAssertEqual(lookups, ["1"], "One physical lookup can be checked separately against each candidate's kind.")
    }

    func testAnyConflictingStrongNamespaceRejectsTheCopy() async throws {
        var raw = external()
        raw.providerIDs["Imdb"] = "tt0042"
        var server = owned()
        server.providerIDs["IMDb"] = "tt9999"
        server.isPlayed = true
        server.hasBeenPlayed = true
        let fixture = fixture(records: [server])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [.init(accountID: "active", itemID: "library-42", kind: .movie)] },
            discovery: { [raw] _, _ in [raw] }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: true)
        let result = try XCTUnwrap(items.first)
        XCTAssertEqual(result.providerID(.imdb), "tt0042")
        XCTAssertFalse(result.locallyValidatedPlayableSource)
        XCTAssertFalse(result.hasBeenPlayed)
    }

    func testTitleOnlyCandidatesNeverFanOutToLibrarySearchOrLookup() async {
        var raw = external()
        raw.providerIDs = [:]
        let fixture = fixture(records: [owned()])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [.init(accountID: "active", itemID: "library-42", kind: .movie)] },
            discovery: { [raw] _, _ in [raw] }
        )
        let items = await runtime.candidates(.init(), sources: [.tvmaze], hideWatched: false)
        let lookups = await fixture.provider.lookupIDs
        let searches = await fixture.provider.searchCount
        XCTAssertTrue(lookups.isEmpty)
        XCTAssertEqual(searches, 0)
        XCTAssertFalse(items[0].locallyValidatedPlayableSource)
    }

    func testSparseRecordWithoutMatchingStrongIdentityRemainsExternal() async {
        let raw = external()
        var server = owned()
        server.providerIDs = [:]
        let fixture = fixture(records: [server])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [.init(accountID: "active", itemID: "library-42", kind: .movie)] },
            discovery: { _, _ in [raw] }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: false)
        XCTAssertFalse(items[0].locallyValidatedPlayableSource)
        XCTAssertEqual(items[0].id, raw.id)
    }

    func testProviderReturningAnUnownedDiscoveryStubDoesNotProveOwnership() async {
        let raw = external()
        var server = owned()
        server.locallyValidatedPlayableSource = false
        server.availability = .available
        let fixture = fixture(records: [server])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [.init(accountID: "active", itemID: "library-42", kind: .movie)] },
            discovery: { _, _ in [raw] }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: false)
        XCTAssertFalse(items[0].locallyValidatedPlayableSource)
        XCTAssertEqual(items[0].availability, .unknown)
    }

    func testSuccessfulCopiesUnionWatchedHistoryAndCompletedPlaybackHasNoResume() async throws {
        let raw = external()
        var finished = owned("plex-item")
        finished.isPlayed = true
        finished.hasBeenPlayed = true
        finished.resumePosition = 123
        finished.lastPlayedAt = Date(timeIntervalSince1970: 20)
        var progressing = owned("jellyfin-item")
        progressing.resumePosition = 800
        progressing.lastPlayedAt = Date(timeIntervalSince1970: 10)
        let first = fixture("plex", kind: .plex, records: [finished])
        let second = fixture("jellyfin", records: [progressing])
        let runtime = HeroDiscoveryRuntime(
            accounts: [first.account, second.account],
            identitySources: { _ in [
                .init(accountID: "plex", itemID: "plex-item", kind: .movie),
                .init(accountID: "jellyfin", itemID: "jellyfin-item", kind: .movie)
            ] },
            discovery: { _, _ in [raw] }
        )
        let filtered = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: true)
        XCTAssertTrue(filtered.isEmpty)
        let visible = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: false)
        let result = try XCTUnwrap(visible.first)
        XCTAssertTrue(result.hasBeenPlayed)
        XCTAssertTrue(result.isPlayed)
        XCTAssertNil(result.resumePosition)
        XCTAssertEqual(Set(result.sources.map(\.id)), ["plex:plex-item", "jellyfin:jellyfin-item"])
        XCTAssertEqual(result.discoverySources, [.tmdb, .tvdb])
    }

    func testStaleForeignRefsCarriedByLiveRecordCannotMarkCurrentProfileWatched() async throws {
        let raw = external()
        var server = owned()
        server.sources = [
            .init(accountID: "another-profile", itemID: "other", kind: .movie, isPlayed: true),
            .init(accountID: "active", itemID: "library-42", kind: .movie, resumePosition: 900, isPlayed: true)
        ]
        let fixture = fixture(records: [server])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [.init(accountID: "active", itemID: "library-42", kind: .movie)] },
            discovery: { _, _ in [raw] }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: true)
        let result = try XCTUnwrap(items.first)
        XCTAssertFalse(result.hasBeenPlayed)
        XCTAssertNil(result.resumePosition)
        XCTAssertEqual(result.sources.map(\.accountID), ["active"])
    }

    func testUnavailableCopyDoesNotContributeCachedPlayedState() async throws {
        let raw = external()
        let available = fixture("available", records: [owned()])
        let unavailable = fixture("unavailable", records: [])
        let runtime = HeroDiscoveryRuntime(
            accounts: [available.account, unavailable.account],
            identitySources: { _ in [
                .init(accountID: "available", itemID: "library-42", kind: .movie),
                .init(accountID: "unavailable", itemID: "missing", kind: .movie, isPlayed: true)
            ] },
            discovery: { _, _ in [raw] }
        )
        let result = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: true)
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(try XCTUnwrap(result.first).hasBeenPlayed)
        XCTAssertEqual(result[0].sources.map(\.accountID), ["available"])
    }

    func testConflictingSecondaryCopyCannotContributePlayedStateOrAlias() async throws {
        let raw = external()
        var firstRecord = owned("first")
        firstRecord.providerIDs["Imdb"] = "tt0042"
        var secondRecord = owned("second")
        secondRecord.providerIDs["Imdb"] = "tt9999"
        secondRecord.hasBeenPlayed = true
        let first = fixture("a", records: [firstRecord])
        let second = fixture("b", records: [secondRecord])
        let runtime = HeroDiscoveryRuntime(
            accounts: [first.account, second.account],
            identitySources: { _ in [
                .init(accountID: "a", itemID: "first", kind: .movie),
                .init(accountID: "b", itemID: "second", kind: .movie)
            ] },
            discovery: { _, _ in [raw] }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: true)
        let result = try XCTUnwrap(items.first)
        XCTAssertEqual(result.sources.map(\.id), ["a:first"])
        XCTAssertFalse(result.hasBeenPlayed)
        XCTAssertEqual(result.providerID(.imdb), "tt0042")
    }

    func testHistoricalCompletionFiltersEvenWhenCurrentStateIsUnwatched() async {
        let raw = external()
        var server = owned()
        server.hasBeenPlayed = true
        server.isPlayed = false
        let fixture = fixture(records: [server])
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { _ in [.init(accountID: "active", itemID: "library-42", kind: .movie)] },
            discovery: { _, _ in [raw] }
        )
        let hidden = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: true)
        let visible = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: false)
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.hasBeenPlayed, true)
        XCTAssertEqual(visible.first?.isPlayed, false)
    }

    func testLookupsAreGloballyBoundedCoalescedAndResultOrderIsStable() async {
        let raw = (0..<16).map { external("\($0)") }
        let server = (0..<16).map { owned("owned-\($0)", tmdbID: "\($0)") }
        let probe = HeroDiscoveryLookupProbe()
        let first = fixture("a", records: server, probe: probe, delay: .milliseconds(10))
        let second = fixture("b", kind: .plex, records: server, probe: probe, delay: .milliseconds(10))
        let runtime = HeroDiscoveryRuntime(
            accounts: [first.account, second.account],
            identitySources: { item in
                guard let id = item.providerID(.tmdb) else { return [] }
                return [
                    .init(accountID: "a", itemID: "owned-\(id)", kind: .movie),
                    .init(accountID: "a", itemID: "owned-\(id)", kind: .movie),
                    .init(accountID: "b", itemID: "owned-\(id)", kind: .movie)
                ]
            },
            discovery: { _, _ in raw }
        )
        let items = await runtime.candidates(.init(), sources: [.tmdb], hideWatched: false)
        let peak = await probe.peak
        let total = await probe.total
        XCTAssertLessThanOrEqual(peak, 4)
        XCTAssertGreaterThan(peak, 1)
        XCTAssertEqual(total, 32)
        XCTAssertEqual(items.compactMap { $0.providerID(.tmdb) }, (0..<16).map(String.init))
        XCTAssertTrue(items.allSatisfy { $0.sources.count == 2 })
    }

    func testCancelledLookupPassCannotPublishOrStartRemainingJobs() async {
        let raw = (0..<16).map { external("\($0)") }
        let server = (0..<16).map { owned("owned-\($0)", tmdbID: "\($0)") }
        let probe = HeroDiscoveryLookupProbe()
        let fixture = fixture(records: server, probe: probe, delay: .seconds(30), ignoresCancellation: true)
        let runtime = HeroDiscoveryRuntime(
            accounts: [fixture.account],
            identitySources: { item in
                [.init(accountID: "active", itemID: "owned-\(item.providerID(.tmdb) ?? "")", kind: .movie)]
            },
            discovery: { _, _ in raw }
        )
        let task = Task { await runtime.candidates(.init(), sources: [.tmdb], hideWatched: false) }
        let started = await waitForLookups(4, probe: probe)
        XCTAssertTrue(started)
        task.cancel()
        let result = await task.value
        let total = await probe.total
        let active = await probe.active
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(total, 4)
        XCTAssertEqual(active, 0)
    }

    func testCancellationDuringPublicDiscoveryDropsItsLateResult() async {
        let raw = external()
        let probe = HeroDiscoveryLookupProbe()
        let runtime = HeroDiscoveryRuntime(
            accounts: [], identitySources: { _ in [] },
            discovery: { _, _ in
                await probe.begin()
                try? await Task.sleep(for: .seconds(30))
                await probe.end()
                return [raw]
            }
        )
        let task = Task { await runtime.candidates(.init(), sources: [.tmdb], hideWatched: false) }
        let started = await waitForLookups(1, probe: probe)
        XCTAssertTrue(started)
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.isEmpty)
    }

    func testDisabledRequestsSkipDiscoveryAndEnabledSourcesNeverExpandBeyondRequest() async {
        let probe = HeroDiscoveryRequestProbe()
        let runtime = HeroDiscoveryRuntime(
            accounts: [], identitySources: { _ in [] },
            discovery: { request, sources in
                await probe.record(request: request, sources: sources)
                return []
            }
        )
        _ = await runtime.candidates(.init(limit: 0), sources: [.tmdb], hideWatched: true)
        _ = await runtime.candidates(.init(), sources: [], hideWatched: true)
        let emptyCalls = await probe.sources
        XCTAssertTrue(emptyCalls.isEmpty)
        _ = await runtime.candidates(
            .init(), sources: [.tvdb, .tmdb, .anilist, .tvdb, .tvmaze, .tmdb], hideWatched: true
        )
        let calls = await probe.sources
        XCTAssertEqual(calls, [[.tvdb, .tmdb, .anilist, .tvmaze]])
    }

    func testInjectedFeedIsBoundedByRequestLimit() async {
        let raw = (0..<100).map { external("\($0)") }
        let runtime = HeroDiscoveryRuntime(
            accounts: [], identitySources: { _ in [] }, discovery: { _, _ in raw }
        )
        let items = await runtime.candidates(.init(limit: 500), sources: [.tmdb], hideWatched: false)
        XCTAssertEqual(items.count, 48)
    }

    @MainActor
    func testProductionConfigurationAndBYOKOverrideAreReadOffMainActor() async {
        let probe = HeroDiscoveryConfigurationProbe()
        let result = await HeroDiscoveryRuntime.productionCandidates(
            .init(), sources: [.tmdb],
            configurationLoader: {
                probe.recordConfigurationThread()
                return MetadataProviderConfig(tmdb: .disabled).withUserToken("TEST-ONLY-BYOK")
            },
            discover: { _, sources, config in
                probe.record(access: config.tmdb, sources: sources)
                return []
            }
        )
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(probe.configurationThreads, [false])
        XCTAssertEqual(probe.access, .userToken("TEST-ONLY-BYOK"))
        XCTAssertEqual(probe.sources, [.tmdb])
    }

    private func waitForLookups(_ count: Int, probe: HeroDiscoveryLookupProbe) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await probe.total >= count { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await probe.total >= count
    }
}

private actor HeroDiscoveryLookupProbe {
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var total = 0
    func begin() {
        active += 1
        total += 1
        peak = max(peak, active)
    }
    func end() { active -= 1 }
}

private actor HeroDiscoveryRequestProbe {
    private(set) var sources: [[HeroDiscoverySource]] = []
    func record(request: HeroDiscoveryRequest, sources: [HeroDiscoverySource]) {
        self.sources.append(sources)
    }
}

private final class HeroDiscoveryConfigurationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []
    private var storedAccess: TMDbAccess?
    private var storedSources: [HeroDiscoverySource] = []
    var configurationThreads: [Bool] { lock.withLock { threads } }
    var access: TMDbAccess? { lock.withLock { storedAccess } }
    var sources: [HeroDiscoverySource] { lock.withLock { storedSources } }
    func recordConfigurationThread() { lock.withLock { threads.append(Thread.isMainThread) } }
    func record(access: TMDbAccess, sources: [HeroDiscoverySource]) {
        lock.withLock {
            storedAccess = access
            storedSources = sources
        }
    }
}

private actor HeroDiscoveryTestProvider: MediaProvider {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    private let records: [String: MediaItem]
    private let probe: HeroDiscoveryLookupProbe
    private let delay: Duration
    private let ignoresCancellation: Bool
    private(set) var lookupIDs: [String] = []
    private(set) var searchCount = 0

    init(
        kind: ProviderKind,
        session: UserSession,
        records: [String: MediaItem],
        probe: HeroDiscoveryLookupProbe,
        delay: Duration,
        ignoresCancellation: Bool
    ) {
        self.kind = kind
        self.session = session
        self.records = records
        self.probe = probe
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
    }

    func item(id: String) async throws -> MediaItem {
        lookupIDs.append(id)
        await probe.begin()
        do {
            if ignoresCancellation {
                try? await Task.sleep(for: delay)
            } else {
                try await Task.sleep(for: delay)
            }
            guard let item = records[id] else { throw AppError.notFound }
            await probe.end()
            return item
        } catch {
            await probe.end()
            throw error
        }
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] {
        searchCount += 1
        return []
    }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
