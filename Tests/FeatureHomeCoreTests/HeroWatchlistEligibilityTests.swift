import CoreModels
import Foundation
import XCTest
@testable import FeatureHomeCore

final class HeroWatchlistEligibilityTests: XCTestCase {
    private func item(_ id: String, tmdb: String? = nil) -> MediaItem {
        MediaItem(
            id: id, title: id, kind: .movie,
            backdropURL: URL(string: "https://example.com/\(id).jpg"),
            providerIDs: tmdb.map { ["Tmdb": $0] } ?? [:]
        )
    }

    private func settings(_ sources: [HeroSourceKind] = [.watchlist]) -> HeroSettings {
        var value = HeroSettings.default
        value.sources = sources
        value.maxItems = 3
        value.autoAdvance = false
        return value
    }

    func testRemovingCurrentWatchlistTitleOverridesPinWithoutAutoAdvance() {
        let a = item("a")
        let b = item("b")
        let eligibility = HeroSourceEligibility(settings: settings(), removedFromWatchlist: [a])
        let result = HeroLiveMerge.merge(
            showing: [a, b], fresh: [b], limit: 2,
            pinnedItemIDs: ["a"], misses: ["a": 100],
            preservesPinnedItems: true, sourceEligibility: eligibility
        )
        XCTAssertEqual(result.items.map(\.id), ["b"])
        XCTAssertEqual(result.retired, ["a"])
        XCTAssertNil(result.misses["a"])
    }

    @MainActor
    func testFailedRemovalOutsideSampleIsRecheckedAfterSlideDisappears() {
        let late = item("position-60", tmdb: "60")
        let removed = HeroSourceEligibility.capture(
            settings: settings(), candidates: [late]
        ) { _ in false }
        XCTAssertFalse(removed.allows(late))

        let firstForty = (1...40).map { item("position-\($0)", tmdb: String($0)) }
        var queried: [String] = []
        let restored = HeroSourceEligibility.capture(
            settings: settings(), candidates: firstForty, previous: removed
        ) { candidate in
            queried.append(candidate.id)
            return true
        }
        XCTAssertTrue(queried.contains(late.id))
        XCTAssertTrue(restored.allows(late))
        XCTAssertEqual(restored.filtering([late]).map(\.id), [late.id])
    }

    func testNoncurrentRemovalPreservesCurrentTitleAndRemainingOrder() {
        let items = [item("a"), item("b"), item("c")]
        let eligibility = HeroSourceEligibility(settings: settings(), removedFromWatchlist: [items[1]])
        let result = HeroLiveMerge.merge(
            showing: items, fresh: [items[0], items[2]], limit: 3,
            pinnedItemIDs: ["a"], preservesPinnedItems: true, sourceEligibility: eligibility
        )
        XCTAssertEqual(result.items.map(\.id), ["a", "c"])
        XCTAssertEqual(result.retired, ["b"])
    }

    func testAuthoritativeRemovalAlsoAppliesWhenFreshResultIsTransientlyEmpty() {
        let a = item("a")
        let b = item("b")
        let result = HeroLiveMerge.merge(
            showing: [a, b], fresh: [], limit: 2, pinnedItemIDs: ["a"],
            freshIsAuthoritative: false, preservesPinnedItems: true,
            sourceEligibility: HeroSourceEligibility(settings: settings(), removedFromWatchlist: [a])
        )
        XCTAssertEqual(result.items.map(\.id), ["b"])
        XCTAssertEqual(result.retired, ["a"])
    }

    func testEquivalentProviderEditionIsRetiredByTitleIdentity() {
        var watchedEdition = item("edition-a", tmdb: "42")
        watchedEdition.sourceAccountID = "server-a"
        var otherEdition = item("edition-b", tmdb: "42")
        otherEdition.sourceAccountID = "server-b"
        let b = item("different")
        let eligibility = HeroSourceEligibility(settings: settings(), removedFromWatchlist: [watchedEdition])
        let result = HeroLiveMerge.merge(
            showing: [otherEdition, b], fresh: [b], limit: 2,
            pinnedItemIDs: [otherEdition.id], preservesPinnedItems: true, sourceEligibility: eligibility
        )
        XCTAssertEqual(result.items.map(\.id), ["different"])
        XCTAssertEqual(result.retired, [otherEdition.id])
    }

    func testSameNumericIDInDifferentMediaKindsDoesNotRetireAnotherWork() {
        let movie = item("movie", tmdb: "42")
        var series = item("series", tmdb: "42")
        series.kind = .series
        let eligibility = HeroSourceEligibility(settings: settings(), removedFromWatchlist: [movie])
        XCTAssertFalse(eligibility.allows(movie))
        XCTAssertTrue(eligibility.allows(series))
    }

    func testBackgroundNoveltyStillProtectsCurrentSlideIndefinitely() {
        let a = item("a")
        let b = item("b")
        var showing = [a, b]
        var misses: [String: Int] = [:]
        for _ in 0..<10 {
            let result = HeroLiveMerge.merge(
                showing: showing, fresh: [b], limit: 2,
                pinnedItemIDs: ["a"], misses: misses, preservesPinnedItems: true
            )
            showing = result.items
            misses = result.misses
            XCTAssertEqual(showing.first?.id, "a")
        }
    }

    func testRandomLibraryEligibilityDoesNotRequireWinningCurrentRandomDraw() {
        let a = item("a").taggingSource("account").taggingLibrary("movies")
        let eligibility = HeroSourceEligibility(
            settings: settings([.watchlist, .randomFromLibrary]), removedFromWatchlist: [a],
            randomLibraries: [.init(accountID: "account", libraryID: "movies", kind: .movie)]
        )
        let result = HeroLiveMerge.merge(
            showing: [a], fresh: [item("new-random")], limit: 2,
            pinnedItemIDs: ["a"], preservesPinnedItems: true, sourceEligibility: eligibility
        )
        XCTAssertEqual(result.items.first?.id, "a")
        XCTAssertTrue(result.retired.isEmpty)
    }

    func testUnselectedRandomLibraryCannotPreserveRemovedTitle() {
        let a = item("a").taggingSource("account").taggingLibrary("excluded")
        let eligibility = HeroSourceEligibility(
            settings: settings([.watchlist, .randomFromLibrary]), removedFromWatchlist: [a],
            randomLibraries: [.init(accountID: "account", libraryID: "selected", kind: .movie)]
        )
        XCTAssertFalse(eligibility.allows(a))
    }

    func testOtherEnabledRowCanStillSupplyRemovedWatchlistTitle() {
        let a = item("a")
        let recentlyAdded = HeroSourceEligibility(
            settings: settings([.watchlist, .recentlyAdded]),
            removedFromWatchlist: [a], recentlyAdded: [a]
        )
        XCTAssertTrue(recentlyAdded.allows(a))
        let disabledRow = HeroSourceEligibility(
            settings: settings(), removedFromWatchlist: [a], recentlyAdded: [a]
        )
        XCTAssertFalse(disabledRow.allows(a))
    }

    func testContinueWatchingEpisodeAndRemovedSeriesShareEligibility() {
        var series = item("show")
        series.kind = .series
        series.sourceAccountID = "account"
        var episode = item("episode")
        episode.kind = .episode
        episode.sourceAccountID = "account"
        episode.seriesID = "show"
        episode.parentTitle = series.title
        let eligibility = HeroSourceEligibility(
            settings: settings([.watchlist, .continueWatching]),
            removedFromWatchlist: [series], continueWatching: [episode]
        )
        XCTAssertTrue(eligibility.allows(episode))
        XCTAssertTrue(eligibility.allows(series))
    }

    func testFeaturedNeedsSourceEvidenceNotMerelyEnabledToggle() {
        var a = item("a")
        let noEvidence = HeroSourceEligibility(
            settings: settings([.watchlist, .featured]), removedFromWatchlist: [a]
        )
        XCTAssertFalse(noEvidence.allows(a))
        a.discoverySources = [.tmdb]
        XCTAssertTrue(noEvidence.allows(a))
        var requestableWatchlistTitle = item("a")
        requestableWatchlistTitle.availability = .unknown
        XCTAssertFalse(noEvidence.allows(requestableWatchlistTitle),
                       "Availability is also carried by Watchlist titles; it is not proof of a Featured source.")
        let supported = HeroSourceEligibility(
            settings: settings([.watchlist, .featured]), removedFromWatchlist: [item("a")],
            supportingCandidates: HeroFreshnessCandidatePool(buckets: [
                .init(source: .featured, items: [item("a")])
            ])
        )
        XCTAssertTrue(supported.allows(item("a")))
    }

    func testPoolDropsRemovedWatchlistProvenanceButKeepsFeaturedCopy() {
        let a = item("a")
        let b = item("b")
        let pool = HeroFreshnessCandidatePool(buckets: [
            .init(source: .watchlist, items: [a, b]),
            .init(source: .featured, items: [a])
        ])
        let eligibility = HeroSourceEligibility(
            settings: settings([.watchlist, .featured]), removedFromWatchlist: [a],
            supportingCandidates: pool
        )
        let filtered = eligibility.filtering(pool)
        XCTAssertEqual(filtered.buckets[0].items.map(\.id), ["b"])
        XCTAssertEqual(filtered.buckets[1].items.map(\.id), ["a"])
        XCTAssertTrue(eligibility.allows(a))
    }

    func testCuratorCannotReadmitRemovalFromStaleWatchlistInputOrPersistIt() async {
        let a = item("a")
        let b = item("b")
        let eligibility = HeroSourceEligibility(settings: settings(), removedFromWatchlist: [a])
        let result = await HeroCurator().curateResult(
            settings: settings(), continueWatching: [], watchlist: [a, b],
            sourceEligibility: eligibility
        )
        XCTAssertEqual(result.items.map(\.id), ["b"])
        XCTAssertEqual(result.durableItems.map(\.id), ["b"])
        XCTAssertEqual(result.candidatePool.buckets.first?.items.map(\.id), ["b"])
        XCTAssertEqual(HeroCurator().curateSync(
            settings: settings(), continueWatching: [], watchlist: [a, b],
            sourceEligibility: eligibility
        ).map(\.id), ["b"])
    }

    @MainActor
    func testLoadingAndFailedRefreshAbsenceIsNotAuthoritativeRemoval() {
        let a = item("a")
        let loading = HeroSourceEligibility.capture(
            settings: settings(), candidates: [a], watchlistMembership: { _ in nil }
        )
        let durableStillContainsTitle = HeroSourceEligibility.capture(
            settings: settings(), candidates: [a], watchlistMembership: { _ in true }
        )
        XCTAssertTrue(loading.allows(a))
        XCTAssertTrue(durableStillContainsTitle.allows(a))
    }

    @MainActor
    func testKnownRemovalSurvivesLoadingButRestoredAliasClearsWholeExclusion() {
        let a = item("a", tmdb: "42")
        let alias = item("other-edition", tmdb: "42")
        let removed = HeroSourceEligibility.capture(
            settings: settings(), candidates: [a], watchlistMembership: { _ in false }
        )
        let loading = HeroSourceEligibility.capture(
            settings: settings(), candidates: [alias], previous: removed,
            watchlistMembership: { _ in nil }
        )
        XCTAssertFalse(loading.allows(a))
        XCTAssertFalse(loading.allows(alias))
        let restored = HeroSourceEligibility.capture(
            settings: settings(), candidates: [alias], previous: loading,
            watchlistMembership: { _ in true }
        )
        XCTAssertTrue(restored.allows(a))
        XCTAssertTrue(restored.allows(alias))
    }

    @MainActor
    func testPendingRemovalWinsOverStalePositiveEditionInSameSnapshot() {
        let a = item("a", tmdb: "42")
        let alias = item("other-edition", tmdb: "42")
        let eligibility = HeroSourceEligibility.capture(
            settings: settings(), candidates: [a, alias],
            watchlistMembership: { $0.id == "other-edition" }
        )
        XCTAssertFalse(eligibility.allows(a))
        XCTAssertFalse(eligibility.allows(alias))
    }

    @MainActor
    func testConfirmedRemovalIsReversibleWhenFailedIntentOrReAddRestoresMembership() {
        let a = item("a")
        let b = item("b")
        let removed = HeroSourceEligibility.capture(
            settings: settings(), candidates: [a, b], watchlistMembership: { $0.id != "a" }
        )
        let restored = HeroSourceEligibility.capture(
            settings: settings(), candidates: [a, b], watchlistMembership: { _ in true }
        )
        XCTAssertEqual(removed.filtering([a, b]).map(\.id), ["b"])
        let result = HeroLiveMerge.merge(
            showing: [b], fresh: [a, b], limit: 2,
            pinnedItemIDs: ["b"], preservesPinnedItems: true, sourceEligibility: restored
        )
        XCTAssertEqual(Set(result.items.map(\.id)), ["a", "b"])
    }
}
