import Foundation

/// Extra, screen-supplied context that lets the context menu offer list-aware
/// actions. Most screens supply nothing (`.none`); a series/season episode list
/// supplies the ordering so "mark watched up to here" knows what "up to here"
/// means.
public struct MediaItemActionContext: Sendable, Equatable {
    /// The items in the same list as the target, in display order — a season's
    /// episodes, sorted by episode number. Empty where the surrounding screen
    /// doesn't know an ordering (e.g. a Home rail of unrelated items).
    public var orderedSiblings: [MediaItem]

    /// Container ids (earlier seasons) that "mark watched up to here" should mark
    /// fully watched in addition to the preceding `orderedSiblings`. Lets the
    /// action span seasons: marking up to S2E3 also clears all of season 1.
    public var precedingContainerIDs: [String]

    /// Whether the target is shown on a Continue Watching row. Every card there
    /// can be removed from it — including a Next Up suggestion that has no
    /// saved position, which is otherwise indistinguishable from any other
    /// unstarted episode.
    public var isContinueWatchingRow: Bool

    /// Whether the target is shown on a Next Up row.
    public var isNextUpRow: Bool

    /// Whether the target is a show on a Coming Soon row or in the Upcoming
    /// agenda. Nothing there is playable yet, so Drop Show is the one action.
    public var isUpcomingRow: Bool

    /// Whether the target is the show a series details page is about AND that
    /// show sits on Continue Watching, Next Up or Upcoming. Those rows are the
    /// only places a show is dropped from, so its page offers Drop Show only then.
    public var isDroppableShowPage: Bool

    public init(
        orderedSiblings: [MediaItem] = [],
        precedingContainerIDs: [String] = [],
        isContinueWatchingRow: Bool = false,
        isNextUpRow: Bool = false,
        isUpcomingRow: Bool = false,
        isDroppableShowPage: Bool = false
    ) {
        self.orderedSiblings = orderedSiblings
        self.precedingContainerIDs = precedingContainerIDs
        self.isContinueWatchingRow = isContinueWatchingRow
        self.isNextUpRow = isNextUpRow
        self.isUpcomingRow = isUpcomingRow
        self.isDroppableShowPage = isDroppableShowPage
    }

    /// Whether the target is on a row that suggests what to watch next, the
    /// places a show can be dropped from, along with Coming Soon and the page of
    /// a show that is on one of those rows.
    public var offersShowDrop: Bool {
        isContinueWatchingRow || isNextUpRow || isUpcomingRow || isDroppableShowPage
    }

    /// No surrounding-list context — the default for standalone cards.
    public static let none = MediaItemActionContext()

    /// Cards on a Continue Watching row.
    public static let continueWatching = MediaItemActionContext(isContinueWatchingRow: true)

    /// Cards on a Next Up row.
    public static let nextUp = MediaItemActionContext(isNextUpRow: true)

    /// Cards on the Coming Soon row and in the Upcoming agenda.
    public static let upcoming = MediaItemActionContext(isUpcomingRow: true)

    /// A series details page's hero. Drop Show is offered only when the show is
    /// on Continue Watching, Next Up or Upcoming.
    public static func showDetail(onDroppableRow: Bool) -> MediaItemActionContext {
        MediaItemActionContext(isDroppableShowPage: onDroppableRow)
    }
}

/// Pure, UI-independent rules for which `MediaItemAction`s an item offers and
/// which siblings a bulk action touches. Kept free of SwiftUI and providers so
/// it is fully unit-testable on Linux/CI.
public enum MediaItemActionCatalog {
    /// Season containers do not reliably report aggregate watch state. Offer
    /// both explicit operations, but only when the provider supports watch edits.
    public static func seasonWatchActions(
        for item: MediaItem,
        availableActions: [MediaItemAction]
    ) -> [MediaItemAction] {
        guard item.kind == .season,
              availableActions.contains(.markWatched) || availableActions.contains(.markUnwatched)
        else { return [] }
        return [.markWatched, .markUnwatched]
    }

    /// The ordered actions to show for `item`.
    ///
    /// - Parameters:
    ///   - item: the focused item the menu is for.
    ///   - supportsWatchState: whether the item's provider can mutate watched
    ///     state (i.e. conforms to `WatchStateProviding`). When `false` no
    ///     watched-state actions are offered.
    ///   - supportsWatchlist: whether the item's provider conforms to
    ///     `WatchlistProviding`. When `true` an add/remove-watchlist action is
    ///     offered for watchlist-eligible items (the item's `isFavorite` flag
    ///     decides add vs remove).
    ///   - supportsMetadataRefresh: whether the item's provider conforms to
    ///     `MetadataRefreshing`. When `true` a "Refresh Metadata" action is
    ///     offered for refreshable items.
    ///   - context: any surrounding-list context (see `MediaItemActionContext`).
    ///   - downloadState: the item's current offline-download state, or `nil` on
    ///     a surface with no download capability (tvOS today). `.some(nil)` means
    ///     downloads ARE available and this item has none yet.
    ///   - isShowDropped: whether the show this item belongs to is dropped, or
    ///     `nil` where dropping is unavailable. Drop Show is offered only on
    ///     Continue Watching and Next Up rows (see `context`); Undrop Show
    ///     wherever the show is dropped. Either replaces Remove from Continue
    ///     Watching on an episode.
    public static func actions(
        for item: MediaItem,
        supportsWatchState: Bool,
        supportsWatchlist: Bool = false,
        isWatchlisted: Bool? = nil,
        supportsMetadataRefresh: Bool = false,
        downloadState: MediaItemDownloadState?? = nil,
        isShowDropped: Bool? = nil,
        context: MediaItemActionContext = .none
    ) -> [MediaItemAction] {
        var actions: [MediaItemAction] = []

        // Watched-state actions: only when the provider can mutate them and the
        // item is a kind that carries a watched state.
        if supportsWatchState, isWatchStateEligible(item) {
            if hasResumePoint(item) {
                actions.append(contentsOf: [.markWatched, .markUnwatched])
            } else {
                actions.append(item.isPlayed ? .markUnwatched : .markWatched)
            }

            // "Up to here" only makes sense for an episode whose position in its
            // list is known and where something up to that point is still
            // unwatched.
            if item.kind == .episode, hasUnwatchedUpToHere(item, in: context) {
                actions.append(.markWatchedUpToHere)
            }
        }

        // Watchlist action: a single toggle whose direction follows the item's
        // current favourite/watchlist state. Offered for the same content kinds
        // that carry a watched state (movies, episodes, series, …) — not folders.
        if let watchlistAction = watchlistAction(
            for: item, supportsWatchlist: supportsWatchlist, isWatchlisted: isWatchlisted
        ) {
            actions.append(watchlistAction)
        }

        // Navigation actions: independent of watched-state capability.
        if canGoToSeason(item, in: context) {
            actions.append(.goToSeason)
        }

        if canGoToMovie(item, in: context) {
            actions.append(.goToMovie)
        }

        if canGoToEpisode(item, in: context) {
            actions.append(.goToEpisode)
        }
        if item.kind != .folder, let containerID = item.fileBrowserContainerID,
           !containerID.isEmpty {
            actions.append(.browseFiles)
        }

        // Refresh Metadata: a server-side maintenance task, offered last for any
        // refreshable content item when the provider supports it.
        if supportsMetadataRefresh, isWatchStateEligible(item) {
            actions.append(.refreshMetadata)
        }

        // Download actions: only on a surface that has the capability, and only
        // for a kind that is individually downloadable (a series/folder has no
        // single file to fetch).
        if let downloadState, isDownloadEligible(item) {
            switch downloadState {
            case nil:
                actions.append(.startDownload)
            case .inFlight:
                actions.append(.pauseDownload)
            case .interrupted:
                actions.append(.resumeDownload)
            case .downloaded:
                actions.append(.removeDownload)
            }
        }

        // Last, and set apart by the menu: this is the only action here that
        // changes what the viewer sees on Home rather than acting on the title in
        // front of them, and it is not one to hit by accident while reaching for
        // "Mark as Watched".
        //
        // Offered wherever a title has somewhere to resume from, rather than only
        // on the Continue Watching row. The row is the reason to want it, but what
        // is being undone is the resume point itself, and meeting the same title in
        // a library or on its own page is no reason to withhold it.
        //
        // On the row itself it is offered for every card, progress or not: a Next
        // Up suggestion is just as unwanted there as an abandoned film, and the
        // row is the one place where "remove" unambiguously means "from here".
        //
        // On Continue Watching and Next Up an episode drops its show instead:
        // removing the one episode only has the next take its place, so what the
        // viewer is turning down is the show. Elsewhere a show isn't something
        // being suggested, so there is nothing to drop it from. A dropped show
        // never reaches those rows, so it can be taken back wherever it appears.
        let showDrop = showDropAction(for: item, isShowDropped: isShowDropped, context: context)
        if !(showDrop != nil && item.kind == .episode), supportsWatchState, isWatchStateEligible(item),
           hasResumePoint(item) || (context.isContinueWatchingRow && isPlayableTitle(item)) {
            actions.append(.removeFromContinueWatching)
        }
        if let showDrop {
            actions.append(showDrop)
        }

        return actions
    }

    /// The bookmark control and full menu share eligibility and membership rules.
    public static func watchlistAction(
        for item: MediaItem, supportsWatchlist: Bool, isWatchlisted: Bool? = nil
    ) -> MediaItemAction? {
        guard isWatchlistEligible(item) else { return nil }
        if let isWatchlisted {
            return isWatchlisted ? .removeFromWatchlist : .addToWatchlist
        }
        guard supportsWatchlist else { return nil }
        return item.isFavorite ? .removeFromWatchlist : .addToWatchlist
    }

    /// Downloadable kinds: a single playable file. A series or folder resolves to
    /// many files, so it has no one download to start, pause or remove.
    private static func isDownloadEligible(_ item: MediaItem) -> Bool {
        !item.opensExternalSource && (item.kind == .movie || item.kind == .episode)
    }

    /// Whether "Episode Info" applies: any episode, wherever it is shown.
    ///
    /// Unlike the other navigation actions this is offered *inside* its own list
    /// too. The series page shows one episode at a time — whatever Play would run
    /// — and episode cards stay deliberately sparse, so the rail is exactly where
    /// someone needs to inspect a different episode's file before playing it.
    private static func canGoToEpisode(_ item: MediaItem, in context: MediaItemActionContext) -> Bool {
        item.kind == .episode
    }

    /// Whether "Go to Season" applies: an episode that knows its season id and is
    /// shown *outside* its season's own list (so it isn't redundant). We treat an
    /// empty `orderedSiblings` as "not already on the season page" — Continue
    /// Watching, Recently Added, Search and Top Shelf deep links all qualify.
    private static func canGoToSeason(_ item: MediaItem, in context: MediaItemActionContext) -> Bool {
        item.kind == .episode && item.seasonID != nil && context.orderedSiblings.isEmpty
    }

    /// Whether "Go to Movie" applies: a movie shown *outside* its own detail page
    /// (Continue Watching, Recently Added, Search), where tapping may play it
    /// immediately. As with `canGoToSeason`, an empty `orderedSiblings` marks
    /// "not already inside a list that the action would be redundant for".
    private static func canGoToMovie(_ item: MediaItem, in context: MediaItemActionContext) -> Bool {
        item.kind == .movie && context.orderedSiblings.isEmpty
    }

    /// The siblings "mark watched up to here" should mark watched: every sibling
    /// up to and including `item` in display order that isn't already watched.
    /// Empty when `item` isn't found in `siblings`.
    public static func siblingsToMarkUpToHere(_ item: MediaItem, in siblings: [MediaItem]) -> [MediaItem] {
        guard let index = siblings.firstIndex(where: { $0.id == item.id }) else { return [] }
        return siblings[...index].filter { !$0.isPlayed }
    }

    /// Whether `item` is a kind that can carry a watched state at all. Folders,
    /// collections and unknowns can't.
    /// Whether the title has a saved position to clear.
    ///
    /// Containers are excluded: a season's "progress" is a count of watched
    /// episodes rather than a position, so there is nothing here to remove — the
    /// episode itself is where the action belongs.
    private static func hasResumePoint(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .movie, .episode, .video:
            return (item.resumePosition ?? 0) > 0
        case .season, .series, .folder, .collection, .playlist, .unknown:
            return false
        }
    }

    private static func showDropAction(
        for item: MediaItem, isShowDropped: Bool?, context: MediaItemActionContext
    ) -> MediaItemAction? {
        guard let isShowDropped, isShowDropEligible(item) else { return nil }
        if isShowDropped { return .undropShow }
        return context.offersShowDrop ? .dropShow : nil
    }

    /// Whether `item` is part of a show it can drop: a series, or a season or
    /// episode that knows its series.
    private static func isShowDropEligible(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .series: return true
        case .season, .episode: return !(item.seriesID ?? "").isEmpty
        case .movie, .video, .folder, .collection, .playlist, .unknown: return false
        }
    }

    /// The kinds the Continue Watching row can hold: a single playable title.
    private static func isPlayableTitle(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .movie, .episode, .video: return true
        case .season, .series, .folder, .collection, .playlist, .unknown: return false
        }
    }

    private static func isWatchStateEligible(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .movie, .episode, .video, .season, .series: return true
        case .folder, .collection, .playlist, .unknown: return false
        }
    }

    /// Whether `item` is a kind a user would reasonably save to a watchlist. We
    /// scope this to whole titles — movies and series — rather than individual
    /// episodes/seasons, matching how Plex's account watchlist and a typical
    /// "save for later" mental model work.
    private static func isWatchlistEligible(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .movie, .series: return true
        case .video, .episode, .season, .folder, .collection, .playlist, .unknown:
            return false
        }
    }

    private static func hasUnwatchedUpToHere(_ item: MediaItem, in context: MediaItemActionContext) -> Bool {
        if !context.precedingContainerIDs.isEmpty { return true }
        // Only meaningful when something *strictly before* the target is still
        // unwatched. If the only unwatched item up to here is the target itself,
        // "up to here" is redundant with plain "mark watched", so we hide it.
        guard let index = context.orderedSiblings.firstIndex(where: { $0.id == item.id }) else {
            return false
        }
        return context.orderedSiblings[..<index].contains { !$0.isPlayed }
    }
}
