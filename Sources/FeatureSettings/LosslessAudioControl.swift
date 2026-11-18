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
        SettingsDescribedControl {
            Toggle(isOn: $isEnabled) {
                Text("Prefer lossless audio")
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("lossless-surround-toggle")
        } description: {
            Text("Turn off for surround sound over regular HDMI ARC, which requires compressed audio.")
        }
    }
}
#endif
