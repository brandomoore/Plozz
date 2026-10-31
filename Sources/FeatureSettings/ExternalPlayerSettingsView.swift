import CoreModels
import CoreUI
import SwiftUI
import UIKit

public struct PlaybackAdvancedSettingsView: View {
    @Bindable var playback: PlaybackSettingsModel
    @Bindable var model: ExternalPlayerSettingsModel
    @State private var showsExternalPlayer = false

    public init(playback: PlaybackSettingsModel, model: ExternalPlayerSettingsModel = .shared) {
        self.playback = playback
        self.model = model
    }

    public var body: some View {
        #if os(tvOS)
        SettingsSplitLayout(title: "Advanced", rows: Self.rows(playback: playback, model: model))
        #else
        List {
            SettingsSectionGroup {
                Button { showsExternalPlayer = true } label: {
                    SettingsDisclosureLabel { Text("External player") }
                }
            }
            SettingsSectionGroup {
                DolbyVisionFELControl(isOn: $playback.settings.dolbyVisionFELEnabled)
            }
            if #available(iOS 26.0, *) {
                SettingsSectionGroup {
                    SpatialAudioLayoutControl()
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Advanced")
        .navigationDestination(isPresented: $showsExternalPlayer) {
            ExternalPlayerSettingsView(model: model)
        }
        #endif
    }

    static func rows(
        playback: PlaybackSettingsModel, model: ExternalPlayerSettingsModel = .shared
    ) -> [SettingsSplitRow] {
        var rows = ExternalPlayerSettingsRows.advanced(model: model) + [
            SettingsSplitRow(id: "dolby-vision-fel", title: "Video") {
                DolbyVisionFELControl(isOn: Binding(
                    get: { playback.settings.dolbyVisionFELEnabled },
                    set: { playback.settings.dolbyVisionFELEnabled = $0 }
                ))
            }
        ]
        #if os(tvOS)
        if #available(tvOS 26.0, *) {
            rows.append(SettingsSplitRow(id: "spatial-audio-layout", title: "Audio") {
                SpatialAudioLayoutControl()
            })
        }
        #endif
        return rows
    }
}

private struct DolbyVisionFELControl: View {
    @Binding var isOn: Bool

    private var helperText: LocalizedStringResource {
        #if os(tvOS) || os(iOS)
        if #available(tvOS 26.0, iOS 26.0, *) {
            return "May impact performance."
        }
        #endif
        return "May impact performance. Disables spatial audio."
    }

    var body: some View {
        SettingsControlRows {
            Toggle("Dolby Vision FEL (experimental)", isOn: $isOn)
                .accessibilityIdentifier("playback-dolby-vision-fel")
            Text(helperText)
                .settingsHelperText()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ExternalPlayerSettingsRows {
    static func advanced(model: ExternalPlayerSettingsModel = .shared) -> [SettingsSplitRow] {
        [
            .page(id: "external-player", title: "External player") {
                [
                    SettingsSplitRow(id: "default-player", title: "Default player") {
                        ExternalPlayerChoices(model: model)
                    },
                    SettingsSplitRow(id: "external-player-help", title: "About external playback") {
                        ExternalPlayerHelp()
                    }.page(),
                    SettingsSplitRow(id: "custom-player", title: "Custom player") {
                        CustomExternalPlayerControls(model: model)
                    }.page()
                ]
            }
        ]
    }
}

#if os(iOS)
private struct ExternalPlayerSettingsView: View {
    @Bindable var model: ExternalPlayerSettingsModel
    @State private var showsAbout = false
    @State private var showsCustomPlayer = false

    var body: some View {
        List {
            SettingsSectionGroup("Default player") {
                ExternalPlayerChoices(model: model)
            }
            SettingsSectionGroup {
                Button { showsAbout = true } label: {
                    SettingsDisclosureLabel { Text("About external playback") }
                }
            }
            SettingsSectionGroup {
                Button { showsCustomPlayer = true } label: {
                    SettingsDisclosureLabel { Text("Custom player") }
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("External player")
        .navigationDestination(isPresented: $showsAbout) {
            List {
                SettingsSectionGroup { ExternalPlayerHelp() }
            }
            .settingsPageSurface()
            .navigationTitle("About external playback")
        }
        .navigationDestination(isPresented: $showsCustomPlayer) {
            List {
                SettingsSectionGroup {
                    CustomExternalPlayerControls(model: model)
                }
            }
            .settingsPageSurface()
            .navigationTitle("Custom player")
        }
    }
}
#endif

private struct ExternalPlayerChoices: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: ExternalPlayerSettingsModel
    @State private var installed: Set<ExternalPlayer> = [.builtIn]

    private var choices: [ExternalPlayer] {
        var result = ExternalPlayer.supported
        if !model.settings.customURLTemplate.isEmpty { result.append(.custom) }
        if !result.contains(model.settings.player) { result.append(model.settings.player) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Applies to everyone on this device.")
                .settingsHelperText()
            #if os(tvOS)
            SettingsControlRows {
                ForEach(choices, id: \.self) { player in
                    SettingsCheckableRow(
                        title: title(player),
                        isChecked: model.settings.player == player
                    ) {
                        model.settings.player = player
                    }
                    .disabled(!isAvailable(player))
                    .accessibilityIdentifier("external-player-\(player.rawValue)")
                }
            }
            #else
            Picker("Default player", selection: $model.settings.player) {
                ForEach(choices, id: \.self) { player in
                    title(player).tag(player).disabled(!isAvailable(player))
                }
            }
            .accessibilityIdentifier("external-player-selection")
            #endif
            if model.settings.player == .vlc || model.settings.player == .custom {
                Text("This player doesn't return watch progress to Plozz.")
                    .settingsHelperText()
            }
            if let error = model.error { Text(error.message).settingsHelperText() }
        }
        .task { refreshInstalledPlayers() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshInstalledPlayers() }
        }
    }

    private func isAvailable(_ player: ExternalPlayer) -> Bool {
        player == .custom || installed.contains(player)
    }

    private func title(_ player: ExternalPlayer) -> Text {
        if player == .custom { return Text("Custom player") }
        if isAvailable(player) { return Text(verbatim: player.name) }
        return Text("\(player.name) (not installed)")
    }

    private func refreshInstalledPlayers() {
        installed = Set(ExternalPlayer.supported.filter {
            guard let scheme = $0.scheme, let url = URL(string: scheme + "://") else { return $0 == .builtIn }
            return UIApplication.shared.canOpenURL(url)
        })
    }
}

private struct ExternalPlayerHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Supported movies and episodes open in the selected app. Everything else plays in Plozz automatically.")
            Text("Playable links, including server access tokens when required, are shared with the selected app. Only choose an app you trust.")
            Text("Native Player and Infuse 8.4.7 or later can return progress when their player closes. Plozz's controls, skip markers, and autoplay aren't available in another app.")
            Text("This choice stays on this device. Watch progress still belongs to the active viewer.")
        }
        .settingsHelperText()
    }
}

private struct CustomExternalPlayerControls: View {
    @Bindable var model: ExternalPlayerSettingsModel
    @State private var template = ""
    @State private var error: ExternalPlayerError?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Use {url} for the encoded video link. Custom players don't receive resume positions or return progress.")
                .settingsHelperText()
            TextField("myplayer://play?url={url}", text: $template)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Player URL template")
                .accessibilityIdentifier("external-player-custom-template")
            Text("Don't include passwords or access tokens in this template.")
                .settingsHelperText()
            if let error { Text(error.message).foregroundStyle(.red) }
            if saved { Text("Custom player selected").settingsHelperText() }
            Button("Save and use custom player") {
                do {
                    try ExternalPlayerURL.validateCustomTemplate(template)
                    model.settings = .init(player: .custom, customURLTemplate: template)
                    error = nil
                    saved = true
                } catch let failure as ExternalPlayerError {
                    error = failure
                } catch {
                    self.error = .invalidTemplate
                }
            }
            .accessibilityIdentifier("external-player-custom-save")
        }
        .onAppear { template = model.settings.customURLTemplate }
        .onChange(of: template) { _, _ in saved = false }
    }
}
