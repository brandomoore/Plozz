#if os(tvOS)
import AVKit
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
import SwiftUI

struct TrailerFullscreenRequest: Identifiable {
    let id: UUID

    @MainActor
    init?(
        controller: HeroTrailerController,
        itemID: String,
        role: HeroTrailerSurfaceRole,
        navigationStyle: NavigationStyle?
    ) {
        guard role != .home || navigationStyle == .rail,
              let id = controller.beginFullScreen(itemID: itemID, from: role) else { return nil }
        self.id = id
    }
}

struct TrailerPlaybackCue: View {
    let isEligible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        VStack(spacing: 12) {
            Chevron()
                .frame(width: 44, height: 14)
                .accessibilityHidden(true)
            Text("Up for playback controls")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .shadow(color: .black, radius: 4)
        }
        .opacity(visible && isEligible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!visible || !isEligible)
        .accessibilityIdentifier("detail-trailer-playback-cue")
        .task(id: isEligible) {
            visible = false
            guard isEligible else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { visible = true }
                try await Task.sleep(for: .seconds(3))
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { visible = false }
            } catch is CancellationError {
                return
            } catch {
                PlozzLog.app.debug("Trailer controls cue delay failed: \(error.localizedDescription)")
            }
        }
    }

    private struct Chevron: UIViewRepresentable {
        func makeUIView(context: Context) -> HeroUpChevronView { HeroUpChevronView() }
        func updateUIView(_ view: HeroUpChevronView, context: Context) {}
    }
}

extension View {
    func trailerFullScreenOnMove(
        controller: HeroTrailerController,
        itemID: String,
        role: HeroTrailerSurfaceRole,
        navigationStyle: NavigationStyle? = nil,
        enabled: Bool = true,
        onMove: @escaping () -> Void = {}
    ) -> some View {
        modifier(TrailerFullscreenModifier(
            controller: controller, itemID: itemID, role: role,
            navigationStyle: navigationStyle, enabled: enabled, onMove: onMove
        ))
    }
}

private struct TrailerFullscreenModifier: ViewModifier {
    let controller: HeroTrailerController
    let itemID: String
    let role: HeroTrailerSurfaceRole
    let navigationStyle: NavigationStyle?
    let enabled: Bool
    let onMove: () -> Void
    @State private var request: TrailerFullscreenRequest?

    func body(content: Content) -> some View {
        content
            .onMoveCommand { direction in
                onMove()
                if direction == .up { openTrailer() }
            }
            .background {
                // Nested Home hosts can swallow SwiftUI move commands. Observe
                // only the native focus region without consuming navigation.
                TVFocusActivityObserver(onActivity: {}, onUp: openTrailer)
            }
            .fullScreenCover(item: $request) { request in
                TrailerFullscreenPlayer(controller: controller, sessionID: request.id)
                    .ignoresSafeArea()
            }
            .onChange(of: controller.isFullScreen) { _, isFullScreen in
                if !isFullScreen { request = nil }
            }
    }

    private func openTrailer() {
        guard enabled, request == nil else { return }
        request = TrailerFullscreenRequest(
            controller: controller, itemID: itemID, role: role,
            navigationStyle: navigationStyle
        )
    }
}

struct TrailerFullscreenPlayer: UIViewControllerRepresentable {
    let controller: HeroTrailerController
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, sessionID: sessionID, dismiss: { dismiss() })
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let viewController = AVPlayerViewController()
        viewController.player = controller.player
        viewController.delegate = context.coordinator
        viewController.showsPlaybackControls = true
        viewController.requiresLinearPlayback = false
        viewController.allowsPictureInPicturePlayback = false
        viewController.videoGravity = .resizeAspect
        viewController.view.accessibilityIdentifier = "trailer-fullscreen-player"
        context.coordinator.holdFrameUntilReady(in: viewController)
        return viewController
    }

    func updateUIViewController(_ viewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ viewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.readiness?.invalidate()
        viewController.player = nil
        coordinator.controller.endFullScreen(id: coordinator.sessionID)
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let controller: HeroTrailerController
        let sessionID: UUID
        let dismiss: () -> Void
        var readiness: NSKeyValueObservation?

        init(controller: HeroTrailerController, sessionID: UUID, dismiss: @escaping () -> Void) {
            self.controller = controller
            self.sessionID = sessionID
            self.dismiss = dismiss
        }

        nonisolated func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
            MainActor.assumeIsolated {
                controller.prepareFullScreenReturn(id: sessionID)
                dismiss()
                return false
            }
        }

        func holdFrameUntilReady(in player: AVPlayerViewController) {
            guard let overlay = player.contentOverlayView, let frame = controller.handoffImage else { return }
            let image = UIImageView(image: frame)
            image.contentMode = .scaleAspectFit
            image.backgroundColor = .black
            image.isUserInteractionEnabled = false
            image.frame = overlay.bounds
            image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.addSubview(image)
            readiness = player.observe(\.isReadyForDisplay, options: [.initial, .new]) { player, _ in
                guard player.isReadyForDisplay else { return }
                Task { @MainActor [weak image] in image?.removeFromSuperview() }
            }
        }
    }
}
#endif
