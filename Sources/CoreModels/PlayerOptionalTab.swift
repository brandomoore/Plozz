import Foundation

/// Optional player cards in display order. Info is always available.
public enum PlayerOptionalTab: CaseIterable, Hashable, Sendable {
    case chapters, cast, episodes, playlist, continueWatching

    public var visibilityKeyPath: WritableKeyPath<PlaybackSettings, Bool> {
        switch self {
        case .chapters: \.chaptersInPlayer
        case .cast: \.castInPlayer
        case .episodes: \.episodesInPlayer
        case .playlist: \.playlistInPlayer
        case .continueWatching: \.continueWatchingInPlayer
        }
    }

    public var title: LocalizedStringResource {
        switch self {
        case .chapters: "Chapters"
        case .cast:
            LocalizedStringResource(
                "player.category.cast",
                defaultValue: "Cast",
                comment: "Tab beneath the in-player scrub bar listing the cast of what is playing."
            )
        case .episodes: "Episodes"
        case .playlist: "Playlist"
        case .continueWatching:
            LocalizedStringResource(
                "player.category.continueWatching",
                defaultValue: "Continue Watching",
                comment: "Tab beneath the in-player scrub bar listing titles to switch to and resume."
            )
        }
    }

    /// Stable settings/search anchor for this section. Kept explicit so adding a
    /// case cannot silently change an existing deep link or saved search target.
    public var searchAnchor: String {
        switch self {
        case .chapters: "player-tab-chapters"
        case .cast: "player-tab-cast"
        case .episodes: "player-tab-episodes"
        case .playlist: "player-tab-playlist"
        case .continueWatching: "continue-watching-in-player"
        }
    }
}
