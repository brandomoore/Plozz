import CoreUI
import SwiftUI

public struct SpatialAudioControl: View {
    @Binding private var isOn: Bool

    public init(isOn: Binding<Bool>) {
        _isOn = isOn
    }

    public var body: some View {
        #if os(tvOS) || os(iOS)
        if #available(tvOS 26.0, iOS 26.0, *) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Spatial audio (height channel support)", isOn: $isOn)
                    .accessibilityIdentifier("spatial-audio-toggle")
                Text("Uses PCM for supported TrueHD Atmos and DTS:X tracks; lossy audio over AirPlay.")
                    .settingsHelperText()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        #endif
    }
}
