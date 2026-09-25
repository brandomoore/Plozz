#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import CoreUI
import SwiftUI

struct LiveChannelSubtitleSurface: View {
    let model: LiveChannelPlayerModel

    var body: some View {
        GeometryReader { geometry in
            SubtitleOverlayView(
                primary: model.subtitles.primary,
                style: model.subtitles.style,
                isHDR: model.subtitles.isHDR,
                videoRect: SubtitleOverlayGeometry.aspectFitRect(
                    in: CGRect(origin: .zero, size: geometry.size),
                    aspectRatio: model.engine.videoAspectRatio.map { CGFloat($0) }
                )
            )
        }
    }
}

public struct LiveChannelNetworkStatus: View {
    let block: LiveTVNetworkBlock

    public init(block: LiveTVNetworkBlock) { self.block = block }

    public var body: some View {
        VStack(spacing: 12) {
            Label(title, systemImage: "wifi.slash")
                .font(.headline)
            Text(block.playbackMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: 420)
        .modifier(PanelGlassBackground(cornerRadius: PlozzTheme.Metrics.playerPanelCornerRadius))
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringResource {
        switch block {
        case .checkingConnection: "Checking connection"
        case .offline: "You're offline"
        case .wifiRequired: "Waiting for Wi-Fi or Ethernet"
        case .lowDataMode: "Paused for Low Data Mode"
        }
    }

}
#endif
