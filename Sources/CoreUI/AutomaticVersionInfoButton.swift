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
            Text("Plozz picks a version for you based on what can play, resolution, HDR and bitrate, so you don't have to choose each time. It won't always pick the first or biggest file. For example, HDR can take priority over a higher-resolution SDR version when HDR playback is available.\n\nIf Remember series version choices is on, Plozz checks for a match to your previous choice first. So if you picked a 1080p version for one episode, it'll try to pick a similar version for the next.")
        }
    }
}
#endif
