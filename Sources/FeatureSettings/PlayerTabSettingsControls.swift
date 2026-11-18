import CoreModels
import CoreUI
import SwiftUI

public struct PlayerTabSettingsControls: View {
    @Bindable private var model: PlaybackSettingsModel

    public init(model: PlaybackSettingsModel) {
        self.model = model
    }

    public var body: some View {
        #if os(tvOS)
        SettingsControlRows { controls }
        #else
        SettingsSectionGroup("Player tabs") { controls }
            .settingsSearchGroup([
                "player-tab-chapters", "player-tab-cast", "player-tab-episodes",
                "player-tab-playlist", "continue-watching-in-player"
            ])
        #endif
    }

    @ViewBuilder private var controls: some View {
        Toggle(isOn: $model.settings.chaptersInPlayer) {
            Text(PlayerOptionalTab.chapters.title)
        }
        .settingsSearchAnchor("player-tab-chapters")
        Toggle(isOn: $model.settings.castInPlayer) {
            Text(PlayerOptionalTab.cast.title)
        }
        .settingsSearchAnchor("player-tab-cast")
        Toggle(isOn: $model.settings.episodesInPlayer) {
            Text(PlayerOptionalTab.episodes.title)
        }
        .settingsSearchAnchor("player-tab-episodes")
        Toggle(isOn: $model.settings.playlistInPlayer) {
            Text(PlayerOptionalTab.playlist.title)
        }
        .settingsSearchAnchor("player-tab-playlist")
        Toggle(isOn: $model.settings.continueWatchingInPlayer) {
            Text(PlayerOptionalTab.continueWatching.title)
        }
        .settingsSearchAnchor("continue-watching-in-player")
    }
}
