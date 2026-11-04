#if os(iOS)
import CoreModels
import SwiftUI
import UIKit

/// Keeps Home still beneath a native push without replacing navigation or its gestures.
struct PlozziOSStationaryNavigationSource: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard animated, let navigation = navigationController,
                  let coordinator = transitionCoordinator,
                  let source = coordinator.viewController(forKey: .from),
                  let destination = coordinator.viewController(forKey: .to),
                  navigation.viewControllers.contains(where: { $0 === source }),
                  navigation.viewControllers.last === destination,
                  owns(source) else { return }

            guard let sourceView = coordinator.view(forKey: .from),
                  let snapshot = sourceView.snapshotView(afterScreenUpdates: false) else {
                HandoffDiagnostics.emit("home NAVIGATION_SNAPSHOT_UNAVAILABLE")
                return
            }
            snapshot.frame = sourceView.convert(sourceView.bounds, to: coordinator.containerView)
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            snapshot.accessibilityIdentifier = "home-navigation-source-snapshot"

            coordinator.animate { context in
                guard let destinationView = context.view(forKey: .to),
                      let destinationRoot = Self.transitionRoot(
                        of: destinationView, in: context.containerView
                      ) else {
                    HandoffDiagnostics.emit("home NAVIGATION_DESTINATION_UNAVAILABLE")
                    return
                }
                // A sibling of the moving pages, not a child of the outgoing page:
                // its pixels must not inherit UIKit's outgoing parallax transform.
                context.containerView.insertSubview(snapshot, belowSubview: destinationRoot)
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
        }

        private func owns(_ controller: UIViewController) -> Bool {
            var ancestor: UIViewController? = self
            while let current = ancestor {
                if current === controller { return true }
                ancestor = current.parent
            }
            return false
        }

        private static func transitionRoot(of view: UIView, in container: UIView) -> UIView? {
            var candidate: UIView? = view
            while let current = candidate, current !== container {
                if current.superview === container { return current }
                candidate = current.superview
            }
            return nil
        }
    }
}
#endif
