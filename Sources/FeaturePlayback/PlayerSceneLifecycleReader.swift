#if os(iOS)
import SwiftUI
import UIKit

/// Full-screen UIKit hosts can retain a stale SwiftUI scenePhase environment.
struct PlayerSceneLifecycleReader: UIViewRepresentable {
    var onPhase: @MainActor (ScenePhase) -> Void

    func makeUIView(context: Context) -> SceneView {
        SceneView(onPhase: onPhase)
    }

    func updateUIView(_ view: SceneView, context: Context) {
        view.onPhase = onPhase
    }

    static func dismantleUIView(_ view: SceneView, coordinator: ()) {
        view.detach()
        view.onPhase = nil
    }

    final class SceneView: UIView {
        var onPhase: (@MainActor (ScenePhase) -> Void)?
        private weak var observedScene: UIWindowScene?

        init(onPhase: @escaping @MainActor (ScenePhase) -> Void) {
            self.onPhase = onPhase
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard observedScene !== window?.windowScene else { return }
            detach()
            guard let scene = window?.windowScene else { return }
            observedScene = scene
            for name in [
                UIScene.willDeactivateNotification,
                UIScene.didEnterBackgroundNotification,
                UIScene.didActivateNotification
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(sceneChanged(_:)), name: name, object: scene
                )
            }
            if scene.activationState == .background {
                onPhase?(.background)
            } else if scene.activationState != .foregroundActive {
                onPhase?(.inactive)
            }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            observedScene = nil
        }

        @objc private func sceneChanged(_ notification: Notification) {
            guard let scene = notification.object as? UIWindowScene,
                  scene === observedScene, scene === window?.windowScene else { return }
            switch notification.name {
            case UIScene.willDeactivateNotification:
                onPhase?(.inactive)
            case UIScene.didEnterBackgroundNotification:
                onPhase?(.background)
            case UIScene.didActivateNotification:
                onPhase?(.active)
            default:
                break
            }
        }
    }
}
#endif
