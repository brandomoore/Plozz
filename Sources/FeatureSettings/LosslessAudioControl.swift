#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct LosslessAudioControl: View {
    @AppStorage private var isEnabled: Bool

    public init(defaults: UserDefaults = .standard) {
        _isEnabled = AppStorage(
            wrappedValue: LosslessAudioSettingsStore.defaultEnabled,
            LosslessAudioSettingsStore.storageKey,
            store: defaults
        )
    }

    public var body: some View {
        SettingsControlRows {
            Toggle(isOn: $isEnabled) {
                Text("Prefer lossless audio")
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("lossless-surround-toggle")
            Text("Turn off for surround sound over regular HDMI ARC, which requires compressed audio.")
                .settingsHelperText()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
