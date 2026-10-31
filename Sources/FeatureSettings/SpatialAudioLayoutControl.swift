import CoreModels
import CoreUI
import SwiftUI

struct SpatialAudioLayoutControl: View {
    @AppStorage private var layout: SpatialAudioLayout

    init(defaults: UserDefaults = .standard) {
        _layout = AppStorage(
            wrappedValue: .default, SpatialAudioLayoutStore.storageKey, store: defaults
        )
    }

    var body: some View {
        SettingsControlRows {
            SettingsMenuRow(title: "Rendering layout", value: Text(verbatim: layout.rawValue)) {
                Picker("Rendering layout", selection: $layout) {
                    ForEach(SpatialAudioLayout.allCases, id: \.self) { option in
                        optionTitle(option).tag(option)
                    }
                }
            }
            .accessibilityIdentifier("spatial-audio-layout")
            Text("Used when Spatial audio is on. Applies to this device.")
                .settingsHelperText()
            Text("DTS:X heights require 7.1.4 or 9.1.6.")
                .settingsHelperText()
        }
    }

    private func optionTitle(_ option: SpatialAudioLayout) -> Text {
        if option == .default { return Text("\(option.rawValue) (Default)") }
        return Text(verbatim: option.rawValue)
    }
}
