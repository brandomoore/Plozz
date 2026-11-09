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
            Text("Remembered choices come first. With series remembering on, choosing 1080p for one episode favors a similar version for later episodes.\n\nOtherwise, Plozz considers supported formats, resolution, HDR and bitrate. For example, an HDR version can beat a higher-resolution SDR version when HDR playback is available.\n\nThe first or largest file doesn't always win. These are metadata estimates, not a guarantee of picture quality.")
        }
    }
}
#endif
