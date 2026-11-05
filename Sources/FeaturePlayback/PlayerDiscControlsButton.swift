#if canImport(UIKit) && canImport(SwiftUI)
import CoreUI
import SwiftUI

public struct PlayerDiscControlsButton: View {
    private let model: PlayerViewModel
    private let onInteraction: () -> Void
    private let onPresentationChanged: (Bool) -> Void
    @State private var showsVideos = false

    public init(
        model: PlayerViewModel,
        onInteraction: @escaping () -> Void = {},
        onPresentationChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.model = model
        self.onInteraction = onInteraction
        self.onPresentationChanged = onPresentationChanged
    }

    public var body: some View {
        Group {
            #if os(tvOS)
            PlayerControlButton(title, systemImage: "opticaldisc", action: activate)
            #else
            Button(action: activate) {
                Image(systemName: "opticaldisc")
                    .font(.title3)
                    .imageScale(.large)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 44))
            .accessibilityLabel(Text(title))
            #endif
        }
        .accessibilityIdentifier("player-control-opticaldisc")
        .contextMenu {
            if model.isDiscMenuPlayback {
                Button("Disc videos") { showsVideos = true }
                Button("Play video") { model.playVideoWithoutMenus() }
                if let state = model.videoEngine.discMenu {
                    Button("Try another region") {
                        model.retryDiscMenu(region: state.region == 1 ? 2 : state.region == 2 ? 4 : 1)
                    }
                }
            } else if model.isSelectedDiscVideo {
                Button("Play video") { model.playVideoWithoutMenus() }
            }
        }
        .sheet(isPresented: $showsVideos, onDismiss: onInteraction) {
            DiscVideoPicker(model: model)
        }
        .onChange(of: showsVideos) { _, presented in onPresentationChanged(presented) }
        .onDisappear { onPresentationChanged(false) }
    }

    private var title: LocalizedStringResource {
        model.isDiscMenuPlayback ? "Disc menu" : "Disc videos"
    }

    private func activate() {
        onInteraction()
        if model.isDiscMenuPlayback, let state = model.videoEngine.discMenu {
            state.openMenu()
        } else {
            showsVideos = true
        }
    }
}
#endif
