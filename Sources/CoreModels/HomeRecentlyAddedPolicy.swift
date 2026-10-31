import Foundation

/// Recently Added uses completion, not the hero's "ever watched" policy.
public enum HomeRecentlyAddedPolicy {
    public static let rowLimit = 20
    public static let candidateLimit = 100

    public static func requestLimit(_ limit: Int, hideWatched: Bool) -> Int {
        guard hideWatched, limit > 0 else { return limit }
        return max(limit, candidateLimit)
    }

    public static func isWatched(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .series, .season:
            // A second selected copy may have episodes missing from the primary.
            if item.sources.contains(where: { ($0.unwatchedEpisodeCount ?? 0) > 0 }) {
                return false
            }
            if let count = item.unwatchedEpisodeCount {
                return count == 0 && (item.isPlayed || item.hasBeenPlayed)
            }
            return item.isPlayed
        case .movie, .episode, .video:
            if item.sources.contains(where: { $0.isPlayed && ($0.resumePosition ?? 0) > 0 }) {
                // Some providers retain completion during a rewatch. The merger
                // clears the card's resume, but preserves the original source state.
                let sources = item.sources.map { source in
                    var copy = source
                    if (copy.resumePosition ?? 0) > 0 { copy.isPlayed = false }
                    return copy
                }
                return MediaItemMerger.unifiedWatchState(from: sources).isPlayed
            }
            return item.isPlayed && (item.resumePosition ?? 0) <= 0
        default:
            return false
        }
    }

    public static func items(
        _ items: [MediaItem], hideWatched: Bool, limit: Int = rowLimit
    ) -> [MediaItem] {
        Array(items.lazy.filter { !hideWatched || !isWatched($0) }.prefix(max(0, limit)))
    }
}
