#if canImport(UIKit) && canImport(SwiftUI)
import CoreUI
import SwiftUI

public struct PlayerDiscControlsButton: View {
    private let model: PlayerViewModel
    private let onInteraction: () -> Void
    private let onPresentationChanged: (Bool) -> Void

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
                Button("Disc videos") { model.showsDiscVideos = true }
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
        .onChange(of: model.showsDiscVideos) { old, presented in
            onPresentationChanged(presented)
            if old && !presented { onInteraction() }
        }
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
            model.showsDiscVideos = true
        }
    }
}
#endif
