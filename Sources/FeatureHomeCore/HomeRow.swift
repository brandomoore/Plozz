import Foundation
import CoreModels

/// Identifies a Home row independently of its content. This is the stable unit
/// the UI renders against and — crucially — the unit a future "customize my
/// rows" feature will reorder/toggle. Keeping identity separate from payload is
/// what lets the loaded view and a (later) skeleton view render from the *same*
/// ordered list, guaranteeing they stay 1:1.
public enum HomeRowKind: String, Hashable, Sendable, CaseIterable {
    case continueWatching
    case watchlist
    case recentlyAdded
    case libraries

    /// The row's display heading.
    public var title: LocalizedStringResource {
        switch self {
        case .continueWatching:
            return LocalizedStringResource(
                "homeRowKind.continueWatching",
                defaultValue: "Continue Watching",
                comment: "Home screen row of partly-watched items the user can resume."
            )
        case .watchlist:
            return LocalizedStringResource(
                "homeRowKind.watchlist",
                defaultValue: "Watchlist",
                comment: "Home screen row of items the user saved to watch later."
            )
        case .recentlyAdded:
            return LocalizedStringResource(
                "homeRowKind.recentlyAdded",
                defaultValue: "Recently Added",
                comment: "Home screen row of the newest items on the server."
            )
        case .libraries:
            return LocalizedStringResource(
                "homeRowKind.libraries",
                defaultValue: "Libraries",
                comment: "Home screen row listing the user's media libraries."
            )
        }
    }

    /// Fallback skeleton structure used only on the very first launch (before any
    /// real layout has been persisted). A sensible "most users have these" guess;
    /// once a real load completes, the persisted layout replaces it. The `count: 0`
    /// on each row means "unknown" — the skeleton fills the screen for the current
    /// density until a real load records how many cards each row actually had.
    public static let defaultSkeletonLayout: [HomeRowLayout] = [
        HomeRowLayout(kind: .continueWatching),
        HomeRowLayout(kind: .recentlyAdded),
        HomeRowLayout(kind: .libraries),
    ]
}

/// One persisted Home row descriptor: its `kind` (identity + order + title +
/// style) paired with the number of cards it rendered on the last successful
/// load. The loading skeleton uses `count` to show a *matching* number of
/// placeholders — clamped to what actually fits at the current display density —
/// instead of a fixed guess. That keeps a full row (e.g. Recently Added) filling
/// the screen while a genuinely sparse row (e.g. 3 Continue Watching items) shows
/// just three, so nothing balloons then collapses when real content swaps in.
public struct HomeRowLayout: Hashable, Sendable {
    public let kind: HomeRowKind
    /// Cards the row rendered last load. `0` means "unknown" (first-ever launch or
    /// an older persisted value); the skeleton then fills the screen for the
    /// current density rather than guessing a fixed number.
    public let count: Int

    public init(kind: HomeRowKind, count: Int = 0) {
        self.kind = kind
        self.count = max(count, 0)
    }
}

/// The poster aspect a media row renders with. Mirrors `PosterCardView.Style`
/// but stays SwiftUI-free so the layout model itself is pure and testable on any
/// platform; the view maps it back to the concrete card style.
public enum HomeRowStyle: Sendable, Equatable {
    case poster
    case landscape
}

/// One resolved Home row: its kind (identity + title + style) paired with the
/// content to render. `items` is populated for media rows; `libraries` for the
/// Libraries row. Exactly one of the two is non-empty for any built row.
public struct HomeRow: Identifiable, Equatable, Sendable {
    public let kind: HomeRowKind
    public var items: [MediaItem]
    public var libraries: [AggregatedLibrary]
    public var loadingPlaceholderCount: Int
    public var failure: AppError?
    public var hasMore = false

    /// True when this row would draw nothing on Home. A row survives the
    /// visibility filter as an empty shell, so "are there any rows" is not the
    /// same question as "will anything appear" — and only the latter tells Home
    /// whether it is about to render a screen with nothing to focus.
    public var isEmptyOnHome: Bool {
        items.isEmpty && libraries.isEmpty && loadingPlaceholderCount == 0 && failure == nil
    }

    public var id: HomeRowKind { kind }
    public var title: LocalizedStringResource { kind.title }

    /// Continue Watching shows wide landscape stills (resume artwork); every other
    /// media row shows portrait posters.
    public var style: HomeRowStyle { kind == .continueWatching ? .landscape : .poster }

    public func playsOnSelect(continueWatchingAction: ContinueWatchingAction) -> Bool {
        kind == .continueWatching && continueWatchingAction == .play
    }

    /// The number of cards this row renders — its media `items` for a media row,
    /// or its `libraries` tiles for the Libraries row (exactly one is populated).
    /// Recorded per row so the next launch's skeleton shows a matching count.
    public var cardCount: Int { max(items.count, libraries.count) }

    init(
        kind: HomeRowKind,
        items: [MediaItem] = [],
        libraries: [AggregatedLibrary] = [],
        loadingPlaceholderCount: Int = 0,
        failure: AppError? = nil
    ) {
        self.kind = kind
        self.items = items
        self.libraries = libraries
        self.loadingPlaceholderCount = loadingPlaceholderCount
        self.failure = failure
    }
}

struct HomeRowPreview: Sendable {
    var items: [MediaItem]
    let hasMore: Bool

    init(_ candidates: [MediaItem], limit: Int, retainsCandidates: Bool = false) {
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.stablePresentationID).inserted }
        items = retainsCandidates ? unique : Array(unique.prefix(limit))
        hasMore = unique.count > limit
    }
}

public extension HomeRow {
    static let watchlistPreviewLimit = 20

    /// Resolves the ordered, visible Home rows from loaded content.
    ///
    /// This makes explicit (and testable) the visibility rules the view used to
    /// apply inline: a media row appears only when it actually has items (matching
    /// `MediaRowView`'s own "hide when empty" behaviour), and the Libraries row
    /// carries only the libraries the visibility model permits and appears only
    /// when at least one survives. The order is fixed for now — Continue Watching,
    /// Watchlist, Recently Added, Libraries — and becomes user-customizable later
    /// by reordering this array.
    ///
    /// `isLibraryVisible` is passed the library's `AggregatedLibrary.key` so the
    /// caller can consult the shared, reactive visibility model; recomputing this
    /// on each render keeps visibility toggles taking effect without a reload.
    ///
    /// Library visibility filters discovery, not account-wide viewing history.
    /// Recently Added keeps unattributed items and merged cards with any visible
    /// contributing library. Watchlist retains its explicit-save policy below.
    static func rows(
        for content: HomeViewModel.Content,
        libraryOrder: [String] = [],
        isLibraryVisible: (String) -> Bool,
        isLibraryTileVisible: (AggregatedLibrary) -> Bool = { HomeLibraryVisibility.default.isVisibleOnHome($0) },
        isGlobalRowEnabled: (HomeGlobalRow) -> Bool = { _ in true },
        includesEmptyWatchlist: Bool = false,
        loadingRows: Set<HomeRowKind> = [],
        failures: [HomeRowKind: AppError] = [:],
        skeletonLayout: [HomeRowLayout] = []
    ) -> [HomeRow] {
        var rows: [HomeRow] = []
        func makeRow(
            _ kind: HomeRowKind, items: [MediaItem] = [], libraries: [AggregatedLibrary] = []
        ) -> HomeRow {
            let isLoading = loadingRows.contains(kind) && (kind != .libraries || libraries.isEmpty)
            let previousCount = skeletonLayout.first { $0.kind == kind }?.count ?? 0
            return HomeRow(
                kind: kind, items: isLoading ? [] : items, libraries: libraries,
                loadingPlaceholderCount: isLoading ? min(12, previousCount > 0 ? previousCount : 8) : 0,
                failure: failures[kind]
            )
        }
        func isPending(_ kind: HomeRowKind) -> Bool {
            loadingRows.contains(kind) || failures[kind] != nil
        }

        if isGlobalRowEnabled(.continueWatching) {
            let continueWatching = content.continueWatching
            if !continueWatching.isEmpty || isPending(.continueWatching) {
                rows.append(makeRow(.continueWatching, items: continueWatching))
            }
        }
        // Watchlist is deliberately NOT library-filtered: it's an explicit user
        // save ("find this later"), and the Plex watchlist is an account-level
        // Discover list that isn't tied to any local library at all. So hiding a
        // library never removes a title the user chose to watchlist. We keep this
        // explicit (rather than relying on watchlist items happening to lack a
        // libraryID) so the guarantee survives even if provenance is added later.
        if isGlobalRowEnabled(.watchlist),
           !content.watchlist.isEmpty || includesEmptyWatchlist || isPending(.watchlist) {
            let preview = HomeRowPreview(content.watchlist, limit: watchlistPreviewLimit)
            var row = makeRow(.watchlist, items: preview.items)
            row.hasMore = preview.hasMore
            rows.append(row)
        }
        if isGlobalRowEnabled(.recentlyAdded) {
            let latest = content.latest.filter { $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible) }
            let hasCandidates = content.recentlyAddedCandidates?.contains {
                $0.isVisibleOnHome(isLibraryVisible: isLibraryVisible)
            } == true
            if !latest.isEmpty || hasCandidates || isPending(.recentlyAdded) {
                rows.append(makeRow(.recentlyAdded, items: latest))
            }
        }

        let visibleLibraries = content.libraries.filter { isLibraryVisible($0.key) && isLibraryTileVisible($0) }
        if !visibleLibraries.isEmpty || isPending(.libraries) {
            let byKey = Dictionary(visibleLibraries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let keys = OrderedVisibilityList.resolving(
                available: visibleLibraries.map(\.key), order: libraryOrder, hidden: []
            ).enabled
            rows.append(makeRow(.libraries, libraries: keys.compactMap { byKey[$0] }))
        }

        return rows
    }
}
