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

    /// Searchable settings entry for this section. New cases get a settings
    /// toggle and a search result without editing the settings view or catalog.
    public var settingsSearchEntry: SettingsSearchEntry {
        SettingsSearchEntry(
            searchAnchor, page: .playback, title: title, keywords: searchKeywords
        )
    }

    private var searchKeywords: LocalizedStringResource {
        switch self {
        case .chapters:
            "player tabs show hide chapters scenes navigation"
        case .cast:
            "player tabs show hide cast actors people"
        case .episodes:
            "player tabs show hide episodes season series navigation"
        case .playlist:
            "player tabs show hide playlist queue navigation"
        case .continueWatching:
            "player tabs show hide continue watching switch title resume another movie show"
        }
    }
}
