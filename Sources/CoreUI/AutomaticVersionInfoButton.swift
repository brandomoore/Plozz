#if canImport(SwiftUI)
import SwiftUI

public struct AutomaticVersionInfoButton: View {
    @State private var showsInformation = false

    public init() {}

    public var body: some View {
        Button {
            showsInformation = true
        } label: {
            Label("How automatic selection works", systemImage: "info.circle")
                .labelStyle(.iconOnly)
                .font(.body)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        #if os(tvOS)
        .buttonStyle(.bordered)
        #else
        .buttonStyle(.borderless)
        #endif
        .help("How automatic selection works")
        .accessibilityIdentifier("automatic-version-information")
        .alert("How automatic selection works", isPresented: $showsInformation) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("Automatically picks a version by weighing resolution, HDR and bitrate, while considering compatibility with your device. For example, a lower-bitrate HDR video might be selected over a higher-bitrate SDR video.\n\nIf you enable Remember series version choices, your previous choice takes priority when a similar version is available for that show.")
        }
    }
}
#endif
