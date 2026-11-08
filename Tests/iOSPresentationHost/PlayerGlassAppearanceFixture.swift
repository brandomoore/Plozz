import CoreUI
@testable import FeaturePlayback
import SwiftUI
import UIKit

struct DiscTouchFixture: View {
    @State private var state = DiscMenuPlaybackState()
    @State private var pointers = 0
    @State private var keys = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            DiscMenuArtwork(state: state)
            DiscMenuTouchControls(state: state) {
                Button("Toggle menu visibility") { state.isMenuVisible.toggle() }
            }
            if state.showsLoadingIndicator { ProgressView().accessibilityIdentifier("disc-fixture-loading") }
            VStack {
                Text(verbatim: "Disc touch fixture: \(pointers) taps, \(keys) keys")
                    .accessibilityIdentifier("disc-touch-events")
                Spacer()
            }
            .foregroundStyle(.white)
            .allowsHitTesting(false)
        }
        .onAppear {
            state.isActive = true
            state.isOpening = false
            state.sendPointerClick = { _, _ in pointers += 1 }
            state.sendKey = { _ in keys += 1 }
        }
        .task {
            guard !ProcessInfo.processInfo.arguments.contains("--disc-touch-loading") else { return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            state.image = UIGraphicsImageRenderer(
                size: CGSize(width: 1280, height: 720), format: format
            ).image {
                UIColor.systemIndigo.setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
            }
            state.isMenuVisible = true
            state.isMenuRequestPending = false
            state.hasPresentedVideoFrame = true
        }
    }
}

struct PlayerGlassAppearanceFixture: View {
    @State private var light = false
    @State private var reduced = false
    @State private var whiteVideo = true
    @State private var leftPresses = 0
    @State private var rightPresses = 0

    var body: some View {
        VStack(spacing: 32) {
            HStack {
                Button(light ? "Dark" : "Light") { light.toggle() }.accessibilityIdentifier("appearance-theme")
                Button(reduced ? "Glass" : "Fallback") { reduced.toggle() }.accessibilityIdentifier("appearance-effects")
                Button(whiteVideo ? "Black video" : "White video") { whiteVideo.toggle() }
                    .accessibilityIdentifier("appearance-video")
            }
            .buttonStyle(.borderedProminent)
            HStack(spacing: 24) {
                Button {} label: { Image(systemName: "plus").font(.title) }
                    .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 80))
                    .accessibilityIdentifier("appearance-circle")
                Button("Info") {}
                    .playerTouchTab(selected: false)
                    .accessibilityIdentifier("appearance-tab")
                PlayerControlButton("Play", systemImage: "play.fill") {}
                    .accessibilityIdentifier("appearance-native-button")
                PlayerControlButton("Prominent", systemImage: "play.fill", prominent: true) {}
                    .accessibilityIdentifier("appearance-prominent")
            }
            PlayerGlassControlGroup {
                Button { leftPresses += 1 } label: { Image(systemName: "captions.bubble") }
                    .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 44))
                    .accessibilityIdentifier("appearance-group-left")
                    .accessibilityValue("\(leftPresses)")
                PlayerOptionsMenuButton(
                    makeMenu: { UIMenu(children: [UIAction(title: "Fixture option") { _ in rightPresses += 1 }]) },
                    onPresentationChange: { _ in }
                )
                    .frame(width: 44, height: 44)
                    .accessibilityValue("\(rightPresses)")
            }
            .accessibilityIdentifier("appearance-group")
            if #available(iOS 26.0, *) {
                HStack(spacing: 24) {
                    Image(systemName: "plus").font(.title).foregroundStyle(.white)
                        .frame(width: 80, height: 80)
                        .glassEffect(.clear.interactive(), in: Circle())
                        .accessibilityIdentifier("appearance-reference-circle")
                    Group {
                        if reduced {
                            Color.clear.frame(width: 100, height: 44)
                                .plozzFrostedBackground(Capsule())
                                .plozzFrostedBorder(Capsule())
                        } else {
                            Color.clear.frame(width: 100, height: 44)
                                .glassEffect(.clear, in: Capsule())
                        }
                    }
                    .accessibilityIdentifier("appearance-reference-group")
                }
            }
            PlayerScrubTrackSurface(height: 20)
                .frame(maxWidth: 500)
                .accessibilityElement()
                .accessibilityIdentifier("appearance-track")
            Text(verbatim: "Player panel")
                .font(.title)
                .foregroundStyle(reduced && light ? Color.black : .white)
                .frame(maxWidth: 500)
                .frame(height: 120)
                .modifier(PanelGlassBackground(mediaGlass: true))
                .accessibilityIdentifier("appearance-panel")
            if #available(iOS 26.0, *) {
                Text(verbatim: "Player panel")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 500)
                    .frame(height: 120)
                    .background {
                        UIKitGlassReference()
                    }
                    .accessibilityIdentifier("appearance-reference")
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(whiteVideo ? Color.white : .black)
        .environment(\.colorScheme, light ? .light : .dark)
        .environment(\.themePalette, light ? .light : .dark)
        .environment(\.plozzReduceTransparency, reduced)
        .preferredColorScheme(light ? .light : .dark)
    }
}

@available(iOS 26.0, *)
private struct UIKitGlassReference: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIGlassEffect(style: .clear))
        view.layer.cornerRadius = 32
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}
