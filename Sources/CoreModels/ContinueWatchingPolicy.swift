import Foundation

/// Continue Watching keeps eligible provider titles. Recency determines
/// order, not membership: an older next episode still belongs until the server
/// or viewer removes it. Brief plays and trailers retain their saved progress
/// without appearing in this row. Age restrictions are explicit caller overrides.
public struct ContinueWatchingPolicy: Sendable, Equatable, Codable {
    /// An explicit presentation limit; `.max` keeps every eligible title.
    /// Providers use bounded requests even when the total result is unlimited.
    public var rowLimit: Int

    /// An opt-in age restriction for unstarted suggestions. Home leaves this
    /// `nil`: time away from a series is not an instruction to hide its next episode.
    public var nextUpCutoff: TimeInterval?

    /// How old loaded Home content may be before returning to Home refreshes it.
    ///
    /// Home cannot see a title watched, finished or dismissed on another device,
    /// because nothing tells it to look. Without a bound it will keep showing the
    /// row it built at launch for as long as the app stays open.
    ///
    /// Short, because the refresh it gates is **silent**: the loaded rows stay on
    /// screen and swap in place. The instinct to make this long comes from when a
    /// reappearance triggered a *loud* reload that flashed the skeleton and threw
    /// focus back to the top — that was worth suppressing for a minute or more,
    /// and it is not what happens now. What is left to weigh is a fan-out across
    /// every signed-in account, so this only needs to be long enough that flicking
    /// between tabs does not re-run one repeatedly.
    ///
    /// It also has to be shorter than the thing it is racing: someone removing a
    /// title in the Plex app and coming back to see it gone. At ninety seconds
    /// that took several attempts and looked exactly like the bug it was meant to
    /// fix.
    public var refreshAfter: TimeInterval

    public init(
        rowLimit: Int = .max,
        nextUpCutoff: TimeInterval? = nil,
        refreshAfter: TimeInterval = 15
    ) {
        self.rowLimit = max(1, rowLimit)
        self.nextUpCutoff = nextUpCutoff
        self.refreshAfter = max(0, refreshAfter)
    }

    public static let `default` = ContinueWatchingPolicy()

    /// Eligible titles with no age bound or presentation limit.
    public static let unbounded = ContinueWatchingPolicy(rowLimit: .max, nextUpCutoff: nil)

    public static func minimumResumePosition(duration: TimeInterval?) -> TimeInterval {
        guard let duration, duration.isFinite, duration > 0 else { return 60 }
        return min(60, max(5, duration * 0.05))
    }

    /// Resume storage is independent of row eligibility. Zero-position episodes
    /// can be Next Up suggestions and must not be discarded as brief plays.
    public static func admits(_ item: MediaItem) -> Bool {
        guard !item.isTrailer, !item.isYouTubeTrailer else { return false }
        guard let position = item.resumePosition else { return true }
        guard position.isFinite, position >= 0 else { return false }
        if position == 0 { return item.kind == .episode }
        return position >= minimumResumePosition(duration: item.runtime)
    }

    /// Whether an eligible title passes an explicitly configured age restriction.
    ///
    /// **Fail-open by construction.** A title is dropped only when it is known to
    /// be a suggestion *and* known to be old. Anything in progress, and anything
    /// whose recency a backend did not report, is kept — a missing timestamp is an
    /// absence of evidence, and guessing from it would quietly delete a title the
    /// viewer is halfway through.
    public func keeps(_ item: MediaItem, now: Date = Date()) -> Bool {
        guard Self.admits(item) else { return false }
        guard let nextUpCutoff else { return true }
        // Started, therefore a promise to come back. Age is irrelevant.
        if (item.resumePosition ?? 0) > 0 { return true }
        // A suggestion. Providers stamp these with their series' last-played date
        // precisely so the row can order them; the same stamp bounds them here.
        guard let lastPlayedAt = item.lastPlayedAt else { return true }
        return now.timeIntervalSince(lastPlayedAt) <= nextUpCutoff
    }

    /// Applies progress eligibility and the optional age restriction, including
    /// when the row has no presentation limit.
    public func curated(_ items: [MediaItem], now: Date = Date()) -> [MediaItem] {
        return items.filter { keeps($0, now: now) }
    }
}
