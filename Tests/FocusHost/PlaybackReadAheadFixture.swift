import AppShell
import CoreModels
import CoreUI
@testable import FeatureSettings
import SwiftUI

struct PlaybackReadAheadFixture: View {
    @State private var models: ProfileSettingsModel
    @AppStorage(PlaybackReadAheadStore.storageKey) private var selection = PlaybackReadAhead.default
    @AppStorage(LivePlaybackBufferStore.storageKey) private var liveSelection = LivePlaybackBuffer.default
    private let subtitleWorkspace = ProcessInfo.processInfo.arguments.contains("--subtitle-settings-workspace")
    private var inWorkspace: Bool {
        subtitleWorkspace || ProcessInfo.processInfo.arguments.contains("--playback-settings-workspace")
    }

    init() {
        if ProcessInfo.processInfo.arguments.contains("--reset-read-ahead") {
            PlaybackReadAheadStore().save(.default)
            LivePlaybackBufferStore().save(.default)
        }
        _models = State(initialValue: ProfileSettingsModel(namespace: "read-ahead-fixture"))
    }

    var body: some View {
        NavigationStack {
            PlaybackDetailView(
                playback: models.playbackModel,
                subtitleBehavior: models.subtitleBehaviorModel,
                subtitleStyle: models.subtitleStyleModel,
                subtitlePolicy: models.subtitlePolicyModel,
                audioPolicy: models.audioPolicyModel,
                canDownloadSubtitles: false,
                section: subtitleWorkspace ? .subtitles : .playback
            )
            .environment(\.settingsInWorkspace, inWorkspace)
            .frame(maxWidth: inWorkspace ? SettingsFormMetrics.pageWidth : .infinity)
        }
        .environment(models.uiDensityModel)
        .environment(models.transparencyModel)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading) {
                Text(verbatim: selection.rawValue)
                    .accessibilityIdentifier("read-ahead-saved")
                Text(verbatim: liveSelection.rawValue)
                    .accessibilityIdentifier("live-buffer-saved")
            }
        }
    }
}
