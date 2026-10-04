#if canImport(SwiftUI)
import XCTest
import CoreModels
@testable import FeatureHome
@testable import FeatureHomeCore

/// Locks down `HomeRow.rows(for:isLibraryVisible:)`: the data-driven layout that
/// both the loaded Home view and (later) the skeleton/streaming view render from.
/// These assert the exact order + visibility rules the view previously applied
/// inline, so the refactor stays behaviour-preserving and the order/visibility
/// contract is protected before row customization is layered on.
final class HomeRowTests: XCTestCase {
    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, title: id, kind: .movie)
    }

    private func library(account: String, id: String, title: String = "Movies") -> AggregatedLibrary {
        AggregatedLibrary(
            accountID: account,
            accountName: account,
            serverName: "Server",
            providerKind: .plex,
            library: MediaLibrary(id: id, title: title, kind: .movie).taggingSource(account)
        )
    }

    private func content(
        continueWatching: [MediaItem] = [],
        latest: [MediaItem] = [],
        watchlist: [MediaItem] = [],
        libraries: [AggregatedLibrary] = []
    ) -> HomeViewModel.Content {
        HomeViewModel.Content(
            continueWatching: continueWatching,
            latest: latest,
            watchlist: watchlist,
            libraries: libraries
        )
    }

    func testEmptyContentProducesNoRows() {
        let rows = HomeRow.rows(for: content()) { _ in true }
        XCTAssertTrue(rows.isEmpty)
    }

    func testSnapshotBoundsRetainLocalizedLibraryHeadings() throws {
        let section = LibrarySection(
            id: "hub", title: "Recommended", localizedTitle: "Recommended",
            localizedTitleSuffix: " · Cinema", items: [item("one"), item("two")]
        )
        let source = HomeViewModel.Content(
            continueWatching: [], latest: [], watchlist: [], libraries: [],
            librarySections: [.init(library: library(account: "a", id: "movies"), sections: [section])]
        )
        let bounded = source.bounded(perRow: 1, watchlistLimit: 1)
        let retained = try XCTUnwrap(bounded.librarySections.first?.sections.first)
        XCTAssertEqual(retained.localizedTitle, section.localizedTitle)
        XCTAssertEqual(retained.localizedTitleSuffix, section.localizedTitleSuffix)
        XCTAssertEqual(retained.id, section.id)
        XCTAssertEqual(retained.items.map(\.id), ["one"])
    }

    func testPendingRowsKeepTheirSlotsWithoutExposingCachedCards() {
        let cached = content(continueWatching: [item("old-resume")], latest: [item("fresh-latest")])
        let pending = HomeRow.rows(
            for: cached, isLibraryVisible: { _ in true },
            loadingRows: [.continueWatching],
            skeletonLayout: [HomeRowLayout(kind: .continueWatching, count: 3)]
        )
        XCTAssertEqual(pending.map(\.kind), [.continueWatching, .recentlyAdded])
        XCTAssertEqual(pending[0].loadingPlaceholderCount, 3)
        XCTAssertTrue(pending[0].items.isEmpty)
        XCTAssertEqual(pending[1].items.map(\.id), ["fresh-latest"])
        XCTAssertFalse(pending[0].isEmptyOnHome)

        let ready = HomeRow.rows(
            for: content(continueWatching: [item("fresh-resume")], latest: [item("fresh-latest")]),
            isLibraryVisible: { _ in true }
        )
        XCTAssertEqual(pending.map(\.id), ready.map(\.id))
        XCTAssertEqual(ready[0].loadingPlaceholderCount, 0)
    }

    func testHeroOnlyConsumesCompletedFreshRowInputs() {
        let source = content(
            continueWatching: [item("live-resume")], latest: [item("cached-latest")],
            watchlist: [item("cached-watchlist")], libraries: [library(account: "a", id: "movies")]
        )
        let live = HomeHeroLaunchPolicy.content(
            source, awaitingLiveContinueWatching: false,
            loadingRows: [.recentlyAdded, .watchlist, .libraries]
        )
        XCTAssertEqual(live.continueWatching.map(\.id), ["live-resume"])
        XCTAssertTrue(live.latest.isEmpty)
        XCTAssertTrue(live.watchlist.isEmpty)
        XCTAssertTrue(live.libraries.isEmpty)
        XCTAssertFalse(source.latest.isEmpty, "Hero filtering must not mutate the row's own fallback snapshot.")
        XCTAssertTrue(HomeHeroLaunchPolicy.content(
            source, awaitingLiveContinueWatching: true
        ).continueWatching.isEmpty)
    }

    func testDisabledRowsNeverGainAPlaceholderOrFailureRow() {
        let rows = HomeRow.rows(
            for: content(latest: [item("latest")]), isLibraryVisible: { _ in true },
            isGlobalRowEnabled: { $0 == .recentlyAdded },
            loadingRows: [.continueWatching],
            failures: [.watchlist: .serverUnreachable]
        )
        XCTAssertEqual(rows.map(\.kind), [.recentlyAdded])
    }

    func testLibraryRowUsesOneIdentityFromLoadingThroughContentOrFailure() {
        let library = library(account: "a", id: "movies")
        let pending = HomeLibrarySectionGroup(library: library, sections: [], loadingRows: [.recentlyAdded])
        let ready = HomeLibrarySectionGroup(
            library: library,
            sections: [LibrarySection(id: "recentlyAdded", title: "Recent", style: .poster, items: [item("movie")])]
        )
        let failed = HomeLibrarySectionGroup(library: library, sections: [], failures: [.recentlyAdded: .serverUnreachable])
        XCTAssertEqual(pending.rows.map(\.id), ready.rows.map(\.id))
        XCTAssertEqual(pending.rows.map(\.id), failed.rows.map(\.id))
        XCTAssertTrue(pending.rows[0].isLoading)
        XCTAssertFalse(failed.rows[0].isLoading)
        XCTAssertEqual(failed.rows[0].failure, .serverUnreachable)
        XCTAssertFalse(failed.isEmpty)
        XCTAssertTrue(HomeLibrarySectionGroup(library: library, sections: []).rows.isEmpty)
    }

    func testRowsAppearInFixedOrder() {
        let c = content(
            continueWatching: [item("cw")],
            latest: [item("lt")],
            watchlist: [item("wl")],
            libraries: [library(account: "a", id: "1")]
        )
        let rows = HomeRow.rows(for: c) { _ in true }
        XCTAssertEqual(rows.map(\.kind), [.continueWatching, .watchlist, .recentlyAdded, .libraries])
    }

    func testEmptyMediaRowsAreOmitted() {
        // Continue Watching empty, Recently Added present: only the populated row
        // survives (mirroring MediaRowView hiding itself when empty).
        let c = content(latest: [item("lt")])
        let rows = HomeRow.rows(for: c) { _ in true }
        XCTAssertEqual(rows.map(\.kind), [.recentlyAdded])
        XCTAssertEqual(rows.first?.items.map(\.id), ["lt"])
    }

    func testContinueWatchingKeepsAllVisibleTitlesInOrder() {
        let items = (0..<125).map {
            taggedItem("cw\($0)", account: "a", library: "L1")
        }
        let c = content(continueWatching: items + [
            taggedItem("hidden", account: "a", library: "L2")
        ])
        let rows = HomeRow.rows(for: c) { $0 != "a:L2" }
        XCTAssertEqual(rows.first?.kind, .continueWatching)
        XCTAssertEqual(rows.first?.items.map(\.id), items.map(\.id))
    }

    func testHiddenLibrariesAreFilteredOut() {
        let visible = library(account: "a", id: "1")
        let hidden = library(account: "b", id: "2")
        let c = content(libraries: [visible, hidden])
        let rows = HomeRow.rows(for: c) { $0 == visible.key }
        XCTAssertEqual(rows.map(\.kind), [.libraries])
        XCTAssertEqual(rows.first?.libraries.map(\.key), [visible.key])
    }

    func testLibrariesRowOmittedWhenAllHidden() {
        let c = content(libraries: [library(account: "a", id: "1")])
        let rows = HomeRow.rows(for: c) { _ in false }
        XCTAssertTrue(rows.isEmpty)
    }

    func testContinueWatchingUsesLandscapeStyleOthersPoster() {
        let c = content(
            continueWatching: [item("cw")],
            latest: [item("lt")],
            watchlist: [item("wl")]
        )
        let rows = HomeRow.rows(for: c) { _ in true }
        let styles = Dictionary(uniqueKeysWithValues: rows.map { ($0.kind, $0.style) })
        XCTAssertEqual(styles[.continueWatching], .landscape)
        XCTAssertEqual(styles[.watchlist], .poster)
        XCTAssertEqual(styles[.recentlyAdded], .poster)
    }

    /// Titles are `LocalizedStringResource`, so compare the *rendered* English
    /// rather than the resource: comparing resources would assert the key, which
    /// is an implementation detail we deliberately allow to be semantic.
    func testTitlesMatchKinds() {
        XCTAssertEqual(String(localized: HomeRowKind.continueWatching.title), "Continue Watching")
        XCTAssertEqual(String(localized: HomeRowKind.watchlist.title), "Watchlist")
        XCTAssertEqual(String(localized: HomeRowKind.recentlyAdded.title), "Recently Added")
        XCTAssertEqual(String(localized: HomeRowKind.libraries.title), "Libraries")
    }

    // MARK: - Per-item library visibility (hide a library everywhere on Home)

    private func taggedItem(_ id: String, account: String, library: String) -> MediaItem {
        MediaItem(id: id, title: id, kind: .movie, sourceAccountID: account, libraryID: library)
    }

    func testMediaRowItemsFromHiddenLibraryAreDropped() {
        // Two Continue Watching items: one from a hidden library, one visible.
        let c = content(continueWatching: [
            taggedItem("hidden", account: "a", library: "L2"),
            taggedItem("shown", account: "a", library: "L1")
        ])
        let rows = HomeRow.rows(for: c) { $0 != "a:L2" }
        XCTAssertEqual(rows.map(\.kind), [.continueWatching])
        XCTAssertEqual(rows.first?.items.map(\.id), ["shown"],
                       "A hidden library's item must be suppressed from Continue Watching, not just the tiles")
    }

    func testUnattributedItemsStayVisibleFailOpen() {
        // An item without library provenance (item(_:) leaves libraryID nil) must
        // never be hidden, even by an all-hiding predicate.
        let c = content(latest: [item("noLibrary")])
        let rows = HomeRow.rows(for: c) { _ in false }
        XCTAssertEqual(rows.map(\.kind), [.recentlyAdded])
        XCTAssertEqual(rows.first?.items.map(\.id), ["noLibrary"])
    }

    func testMediaRowOmittedWhenEveryItemHidden() {
        // Recently Added holds only hidden-library items → the whole row disappears.
        let c = content(latest: [taggedItem("h1", account: "a", library: "L2")])
        let rows = HomeRow.rows(for: c) { $0 != "a:L2" }
        XCTAssertTrue(rows.isEmpty, "A media row with no surviving items must be omitted entirely")
    }

    func testMergedCardVisibleIfAnyContributingLibraryVisible() {
        var merged = taggedItem("m", account: "plex", library: "P1")
        merged.sources = [
            MediaSourceRef(accountID: "plex", itemID: "p", libraryID: "P1"),
            MediaSourceRef(accountID: "jelly", itemID: "j", libraryID: "J9")
        ]
        let c = content(latest: [merged])
        // Plex library hidden, Jellyfin visible → merged card still shows.
        let rows = HomeRow.rows(for: c) { $0 == "jelly:J9" }
        XCTAssertEqual(rows.first?.items.map(\.id), ["m"])
    }

    func testWatchlistIsExemptFromLibraryHiding() {
        // A watchlisted title from a hidden library must still appear: the
        // Watchlist row is a deliberate user save and is never library-filtered,
        // even when the item carries a hidden library's provenance.
        let c = content(watchlist: [taggedItem("saved", account: "a", library: "L2")])
        let rows = HomeRow.rows(for: c) { _ in false } // hide everything
        XCTAssertEqual(rows.map(\.kind), [.watchlist])
        XCTAssertEqual(rows.first?.items.map(\.id), ["saved"])
    }
}
#endif
