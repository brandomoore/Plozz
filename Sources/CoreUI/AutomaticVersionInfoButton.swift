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
            Text("With Remember series version choices on, Plozz tries to pick something similar to what you've chosen before for that show. Pick 1080p for one episode, for example, and it'll look for a similar version next time.\n\nOtherwise, it weighs up what can play, resolution, HDR and bitrate. HDR can win over a higher-resolution SDR version when HDR playback is available, so it won't always pick the first or biggest file.")
        }
    }
}
#endif
