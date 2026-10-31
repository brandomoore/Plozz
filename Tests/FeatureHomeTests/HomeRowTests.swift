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
    func testWatchlistHomePreviewCapsAtTwentyWithoutTruncatingTheFullList() throws {
        for count in [0, 1, 19, 20, 21, 100] {
            let saved = (0..<count).map { item("saved-\($0)") }
            let snapshot = content(watchlist: saved)
            let rows = HomeRow.rows(for: snapshot, isLibraryVisible: { _ in false })
            if count == 0 {
                XCTAssertFalse(rows.contains { $0.kind == .watchlist })
                continue
            }
            let row = try XCTUnwrap(rows.first { $0.kind == .watchlist })
            XCTAssertEqual(row.items, Array(saved.prefix(20)))
            XCTAssertEqual(row.hasMore, count > 20)
            let presentation = HomePresentationRow.resolve(rows: rows, content: snapshot, visibility: .default)
            XCTAssertEqual(presentation.first { $0.id == .global(.watchlist) }?.canBrowse, count > 20)
            XCTAssertEqual(snapshot.watchlist, saved, "The existing Watchlist tab must retain every saved title")
        }
    }

    func testWatchlistPreviewReevaluatesOverflowAfterRemovalAndIgnoresDuplicates() throws {
        var snapshot = content(watchlist: (0..<22).map { item("saved-\($0)") })
        func row() throws -> HomeRow {
            try XCTUnwrap(HomeRow.rows(for: snapshot, isLibraryVisible: { _ in true }).first { $0.kind == .watchlist })
        }
        snapshot.watchlist.removeFirst()
        XCTAssertEqual(try row().items.last?.id, "saved-20")
        XCTAssertTrue(try row().hasMore)
        snapshot.watchlist.removeFirst()
        XCTAssertEqual(try row().items.last?.id, "saved-21")
        XCTAssertFalse(try row().hasMore)
        snapshot.watchlist.append(snapshot.watchlist[0])
        XCTAssertFalse(try row().hasMore, "A duplicate is not an extra title")
        XCTAssertEqual(try row().items.count, 20)
    }

    func testLoadingWatchlistDoesNotOfferItsCachedOverflowShortcut() throws {
        let snapshot = content(watchlist: (0..<21).map { item("saved-\($0)") })
        let rows = HomeRow.rows(for: snapshot, isLibraryVisible: { _ in true }, loadingRows: [.watchlist])
        let presentation = HomePresentationRow.resolve(rows: rows, content: snapshot, visibility: .default)
        let watchlist = try XCTUnwrap(presentation.first { $0.id == .global(.watchlist) })
        XCTAssertFalse(watchlist.canBrowse)
    }

    func testContinueWatchingSelectionUsesPreferenceWithoutChangingOtherRows() {
        for kind in HomeRowKind.allCases {
            let row = HomeRow(kind: kind)
            XCTAssertEqual(
                row.playsOnSelect(continueWatchingAction: .default), kind == .continueWatching
            )
            XCTAssertEqual(
                row.playsOnSelect(continueWatchingAction: .play), kind == .continueWatching
            )
            XCTAssertFalse(row.playsOnSelect(continueWatchingAction: .openDetails))
        }
    }

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

    func testLibraryTilesFollowNavigationOrderWithoutChangingHomeVisibility() {
        let first = library(account: "plex", id: "movies")
        let second = library(account: "jellyfin", id: "movies")
        let homeHidden = library(account: "plex", id: "hidden")
        let newLibrary = library(account: "jellyfin", id: "new")
        let layout = NavigationLibraryLayout(
            order: [NavigationLibraryLayout.homeKey, second.key, "offline:movies",
                    homeHidden.key, first.key, second.key],
            hiddenKeys: [second.key]
        )
        let source = content(
            latest: [item("latest")], libraries: [first, homeHidden, newLibrary, second]
        )
        let rows = HomeRow.rows(
            for: source, libraryOrder: layout.order,
            isLibraryVisible: { _ in true }, isLibraryTileVisible: { $0.key != homeHidden.key }
        )
        XCTAssertEqual(rows.first(where: { $0.kind == .libraries })?.libraries.map(\.key),
                       [second.key, first.key, newLibrary.key])
        XCTAssertEqual(rows.first(where: { $0.kind == .recentlyAdded })?.items.map(\.id), ["latest"])
        XCTAssertTrue(layout.hiddenKeys.contains(second.key), "Navigation hiding is independent of Home.")
        let reordered = HomeRow.rows(
            for: source, libraryOrder: [newLibrary.key, first.key, second.key],
            isLibraryVisible: { $0 != homeHidden.key }
        )
        XCTAssertEqual(reordered.first(where: { $0.kind == .libraries })?.libraries.map(\.key),
                       [newLibrary.key, first.key, second.key])
        XCTAssertEqual(source.libraries.map(\.key), [first.key, homeHidden.key, newLibrary.key, second.key])
    }

    func testLibraryTilesUseNavigationDiscoveryOrderBeforeHomeOnlyDiscoveries() {
        let first = library(account: "a", id: "1")
        let second = library(account: "a", id: "2")
        let latest = library(account: "a", id: "3")
        let rows = HomeRow.rows(
            for: content(libraries: [latest, second, first]),
            libraryOrder: [first.key, second.key], isLibraryVisible: { _ in true }
        )
        XCTAssertEqual(rows.first?.libraries.map(\.key), [first.key, second.key, latest.key])
    }

    func testEmptyCollectionTileAppearsOnlyAfterContentOrManualEnable() {
        var directory = library(account: "a", id: "collections", title: "Collections")
        directory.library.kind = .collection
        directory.library.hasCollections = false
        var visibility = HomeLibraryVisibility.default
        func rows() -> [HomeRow] {
            HomeRow.rows(
                for: content(libraries: [directory]), isLibraryVisible: visibility.isEnabled,
                isLibraryTileVisible: visibility.isVisibleOnHome
            )
        }
        XCTAssertTrue(rows().isEmpty)
        directory.library.hasCollections = true
        XCTAssertEqual(rows().first?.libraries.map(\.key), [directory.key])
        directory.library.hasCollections = false
        XCTAssertTrue(rows().isEmpty)
        visibility.setEnabled(true, for: directory.key)
        XCTAssertEqual(rows().first?.libraries.map(\.key), [directory.key])
        visibility.setEnabled(false, for: directory.key)
        directory.library.hasCollections = true
        XCTAssertTrue(rows().isEmpty)
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

    func testContinueWatchingKeepsAllTitlesRegardlessOfCatalogVisibility() {
        let items = (0..<125).map {
            taggedItem("cw\($0)", account: "a", library: "L1")
        }
        let c = content(continueWatching: items + [
            taggedItem("hidden", account: "a", library: "L2")
        ])
        let rows = HomeRow.rows(for: c) { $0 != "a:L2" }
        XCTAssertEqual(rows.first?.kind, .continueWatching)
        XCTAssertEqual(rows.first?.items.map(\.id), items.map(\.id) + ["hidden"])
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

    func testGlobalHistoryIsExemptFromLibraryHiding() {
        let c = content(continueWatching: [
            taggedItem("hidden", account: "a", library: "L2"),
            taggedItem("shown", account: "a", library: "L1")
        ])
        let rows = HomeRow.rows(for: c) { $0 != "a:L2" }
        XCTAssertEqual(rows.map(\.kind), [.continueWatching])
        XCTAssertEqual(rows.first?.items.map(\.id), ["hidden", "shown"])
        XCTAssertEqual(
            HomeRow.rows(for: c) { _ in false }.first?.items.map(\.id),
            ["hidden", "shown"]
        )
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
