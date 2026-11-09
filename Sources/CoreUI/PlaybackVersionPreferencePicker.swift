#if canImport(SwiftUI)
import CoreModels
import SwiftUI

public struct PlaybackVersionPreferencePicker: View {
    @Bindable private var model: PlaybackSettingsModel

    public init(model: PlaybackSettingsModel) { self.model = model }

    public var body: some View {
        HStack {
            Picker("Version selection", selection: $model.settings.versionSelectionMode) {
                if model.settings.versionSelectionMode == nil {
                    Text("Choose on first play")
                        .tag(Optional<PlaybackVersionSelectionMode>.none)
                        .disabled(true)
                }
                ForEach(PlaybackVersionSelectionMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(Optional(mode))
                }
            }
            .accessibilityIdentifier("playback-version-selection")
            if model.settings.versionSelectionMode == .automatic {
                AutomaticVersionInfoButton()
            }
        }
        .accessibilityElement(children: .contain)
    }
}
#endif
