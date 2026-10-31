#if os(tvOS)
import Observation
import SwiftUI
import UIKit

@MainActor
final class TVProfileForegroundState {
    private var players: Set<UUID> = []
    private var hasBeenActive = false
    private var previousPhase: ScenePhase?
    private var playbackWhenResigning: Bool?
    private var backgroundedAt: ContinuousClock.Instant?
    private var requestedLock = false

    func setPlayback(_ active: Bool, id: UUID) {
        if active { players.insert(id) } else { players.remove(id) }
    }

    func shouldLock(
        after phase: ScenePhase,
        leavingForExternalPlayer: Bool = false,
        delay: TimeInterval? = 0,
        now: ContinuousClock.Instant = .now
    ) -> Bool {
        defer { previousPhase = phase }
        switch phase {
        case .active:
            let shouldLock = returnDelayExpired(delay, now: now)
            hasBeenActive = true
            playbackWhenResigning = nil
            backgroundedAt = nil
            requestedLock = false
            return shouldLock
        case .inactive:
            if previousPhase == .active {
                playbackWhenResigning = !players.isEmpty || leavingForExternalPlayer
            } else if previousPhase == .background {
                return returnDelayExpired(delay, now: now)
            }
        case .background:
            guard hasBeenActive, previousPhase != .background else { return false }
            guard !(playbackWhenResigning ?? (!players.isEmpty || leavingForExternalPlayer)) else { return false }
            if backgroundedAt == nil { backgroundedAt = now }
            return delay == 0 && returnDelayExpired(delay, now: now)
        @unknown default:
            break
        }
        return false
    }

    private func returnDelayExpired(_ delay: TimeInterval?, now: ContinuousClock.Instant) -> Bool {
        guard !requestedLock, let delay, let backgroundedAt,
              now - backgroundedAt >= .seconds(delay) else { return false }
        requestedLock = true
        return true
    }
}

private struct TVProfileForegroundStateKey: EnvironmentKey {
    static let defaultValue: TVProfileForegroundState? = nil
}

extension EnvironmentValues {
    var tvProfileForegroundState: TVProfileForegroundState? {
        get { self[TVProfileForegroundStateKey.self] }
        set { self[TVProfileForegroundStateKey.self] = newValue }
    }
}

/// Lifetime follows the mounted player host, not onDisappear (also fired by a cover).
struct TVProfilePlaybackPresence: UIViewRepresentable {
    let isActive: Bool
    @Environment(\.tvProfileForegroundState) private var state

    @MainActor
    final class Coordinator {
        let id = UUID()
        weak var state: TVProfileForegroundState?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.state !== state {
            coordinator.state?.setPlayback(false, id: coordinator.id)
            coordinator.state = state
        }
        state?.setPlayback(isActive, id: coordinator.id)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.state?.setPlayback(false, id: coordinator.id)
    }
}

/// A scene-owned window covers already-presented sheets without dismantling their navigation.
@MainActor
final class TVProfileForegroundWindow<Content: View> {
    private(set) var window: UIWindow?
    private weak var coveredWindow: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private var previousInteractionEnabled = true
    private var previousAccessibilityHidden = false

    func show(over source: UIWindow, content: Content) {
        guard let scene = source.windowScene else { return }
        if let host = window?.rootViewController as? UIHostingController<Content> {
            host.rootView = content
            return
        }
        coveredWindow = source
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        previousInteractionEnabled = source.isUserInteractionEnabled
        previousAccessibilityHidden = source.accessibilityElementsHidden
        source.isUserInteractionEnabled = false
        source.accessibilityElementsHidden = true
        let shield = UIWindow(windowScene: scene)
        shield.windowLevel = source.windowLevel + 1
        shield.backgroundColor = .black
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .black
        shield.rootViewController = host
        window = shield
        shield.makeKeyAndVisible()
    }

    func hide() {
        guard let window else { return }
        let restoreKeyWindow = window.isKeyWindow
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
        coveredWindow?.isUserInteractionEnabled = previousInteractionEnabled
        coveredWindow?.accessibilityElementsHidden = previousAccessibilityHidden
        if restoreKeyWindow, let previousKeyWindow, !previousKeyWindow.isHidden {
            previousKeyWindow.makeKey()
            previousKeyWindow.rootViewController?.setNeedsFocusUpdate()
            previousKeyWindow.rootViewController?.updateFocusIfNeeded()
        }
        coveredWindow = nil
        previousKeyWindow = nil
    }
}

struct TVProfileForegroundShield<Content: View>: UIViewRepresentable {
    let flow: ProfileFlowModel
    @ViewBuilder let content: (@escaping () -> Void) -> Content

    final class Anchor: UIView {
        var update: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            update?(window)
        }
    }

    @MainActor
    final class Coordinator {
        let presentation = TVProfileForegroundWindow<Content>()
        weak var sourceWindow: UIWindow?
        private var flow: ProfileFlowModel?
        private var content: ((@escaping () -> Void) -> Content)?
        private var observationGeneration = 0

        func sync(flow: ProfileFlowModel, content: @escaping (@escaping () -> Void) -> Content) {
            self.content = content
            if self.flow !== flow {
                self.flow = flow
                armObservation()
            }
            updatePresentation()
        }

        func attach(to source: UIWindow?) {
            // Full-screen covers detach the root anchor without ending its lifetime.
            if let source { sourceWindow = source }
            updatePresentation()
        }

        private func armObservation() {
            observationGeneration &+= 1
            let generation = observationGeneration
            // A covered SwiftUI root can stop updating, including on later departures.
            withObservationTracking {
                _ = flow?.isForegroundLocked
            } onChange: { [weak self] in
                Task { @MainActor in
                    guard let self, self.observationGeneration == generation else { return }
                    self.armObservation()
                    self.updatePresentation()
                }
            }
        }

        private func updatePresentation() {
            guard let flow else { return }
            if flow.isForegroundLocked {
                guard let sourceWindow, let content else { return }
                presentation.show(over: sourceWindow, content: content { [weak self] in
                    self?.updatePresentation()
                })
            } else {
                presentation.hide()
            }
        }

        func invalidate() {
            observationGeneration &+= 1
            flow = nil
            content = nil
            presentation.hide()
            sourceWindow = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIView(_ uiView: Anchor, context: Context) {
        let coordinator = context.coordinator
        coordinator.sync(flow: flow, content: content)
        uiView.update = { [weak coordinator] source in coordinator?.attach(to: source) }
        uiView.update?(uiView.window)
    }

    static func dismantleUIView(_ uiView: Anchor, coordinator: Coordinator) {
        uiView.update = nil
        coordinator.invalidate()
    }
}
#endif
