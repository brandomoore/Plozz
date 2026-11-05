#if os(tvOS)
import AVKit
import CoreModels
import CoreNetworking
import CoreUI
import FeatureHomeCore
import SwiftUI

public struct HeroTrailerPlayerFactory {
    public var make: @MainActor (AVPlayer, UIView, String, @escaping () -> Void) -> UIViewController

    public init(make: @escaping @MainActor (AVPlayer, UIView, String, @escaping () -> Void) -> UIViewController) {
        self.make = make
    }
}

private struct HeroTrailerPlayerFactoryKey: EnvironmentKey {
    static let defaultValue: HeroTrailerPlayerFactory? = nil
}

extension EnvironmentValues {
    public var heroTrailerPlayerFactory: HeroTrailerPlayerFactory? {
        get { self[HeroTrailerPlayerFactoryKey.self] }
        set { self[HeroTrailerPlayerFactoryKey.self] = newValue }
    }
}

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
        title: String = "",
        navigationStyle: NavigationStyle? = nil,
        enabled: Bool = true,
        buttonRequest: Int = 0,
        onUnavailable: @escaping () -> Void = {},
        onPresent: @escaping () -> Void = {},
        onMove: @escaping () -> Void = {}
    ) -> some View {
        modifier(TrailerFullscreenModifier(
            controller: controller, itemID: itemID, role: role,
            title: title, navigationStyle: navigationStyle, enabled: enabled,
            buttonRequest: buttonRequest, onUnavailable: onUnavailable, onPresent: onPresent, onMove: onMove
        ))
    }
}

private struct TrailerFullscreenModifier: ViewModifier {
    let controller: HeroTrailerController
    let itemID: String
    let role: HeroTrailerSurfaceRole
    let title: String
    let navigationStyle: NavigationStyle?
    let enabled: Bool
    let buttonRequest: Int
    let onUnavailable: () -> Void
    let onPresent: () -> Void
    let onMove: () -> Void
    @Environment(\.heroTrailerPlayerFactory) private var factory
    @State private var request: TrailerFullscreenRequest?

    func body(content: Content) -> some View {
        content
            .onMoveCommand { direction in
                onMove()
                if direction == .up { _ = openTrailer() }
            }
            .background {
                // Nested Home hosts can swallow SwiftUI move commands. Observe
                // only the native focus region without consuming navigation.
                TVFocusActivityObserver(onActivity: {}, onUp: { _ = openTrailer() })
            }
            .background {
                TrailerFullscreenPresentation(controller: controller, request: $request, title: title)
            }
            .onChange(of: buttonRequest) { _, _ in
                if !openTrailer() { onUnavailable() }
            }
            .onChange(of: controller.isFullScreen) { _, isFullScreen in
                if !isFullScreen { request = nil }
            }
    }

    private func openTrailer() -> Bool {
        guard enabled, request == nil, factory != nil else { return false }
        request = TrailerFullscreenRequest(
            controller: controller, itemID: itemID, role: role,
            navigationStyle: navigationStyle
        )
        if request != nil { onPresent() }
        return request != nil
    }
}

struct TrailerFullscreenPresentation: UIViewControllerRepresentable {
    let controller: HeroTrailerController
    @Binding var request: TrailerFullscreenRequest?
    let title: String
    @Environment(\.heroTrailerPlayerFactory) private var factory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIViewController(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.view.isUserInteractionEnabled = false
        anchor.appeared = { [weak coordinator = context.coordinator, weak anchor] in
            if let anchor { coordinator?.reconcile(anchor: anchor) }
        }
        return anchor
    }

    func updateUIViewController(_ anchor: Anchor, context: Context) {
        context.coordinator.request = request
        context.coordinator.factory = factory
        context.coordinator.title = title
        context.coordinator.animated = !reduceMotion
        context.coordinator.clearRequest = { request = nil }
        context.coordinator.reconcile(anchor: anchor)
    }

    static func dismantleUIViewController(_ anchor: Anchor, coordinator: Coordinator) {
        coordinator.request = nil
        coordinator.animated = false
        coordinator.reconcile(anchor: anchor)
    }

    @MainActor
    final class Anchor: UIViewController {
        var appeared: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared?()
        }
    }

    @MainActor
    final class Coordinator {
        let controller: HeroTrailerController
        var request: TrailerFullscreenRequest?
        var factory: HeroTrailerPlayerFactory?
        var title = ""
        var animated = true
        var clearRequest: () -> Void = {}
        private var presented: (id: UUID, player: UIViewController)?
        private var dismissing = false

        init(controller: HeroTrailerController) {
            self.controller = controller
        }

        func reconcile(anchor: Anchor) {
            if let presented {
                guard request?.id != presented.id, !dismissing else { return }
                dismissing = true
                controller.prepareFullScreenReturn(id: presented.id)
                presented.player.dismiss(animated: animated) { [self] in
                    controller.endFullScreen(id: presented.id)
                    self.presented = nil
                    dismissing = false
                    reconcile(anchor: anchor)
                }
                return
            }
            guard let request, let factory, anchor.view.window != nil,
                  let surface = controller.fullScreenSurface(id: request.id) else { return }
            let player = factory.make(controller.player, surface, title) { [weak self] in
                self?.clearRequest()
            }
            // Keep the SwiftUI owner mounted so binding changes and profile
            // revocation can dismiss the borrowed player while it is visible.
            player.modalPresentationStyle = .overFullScreen
            player.modalTransitionStyle = .crossDissolve
            presented = (request.id, player)
            anchor.present(player, animated: animated)
        }
    }
}
#endif
