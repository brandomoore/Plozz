#if os(iOS)
import SwiftUI
import UIKit

/// Reports the enclosing navigation controller's interactive back-swipe.
///
/// The detail page's hero grows with a vertical overscroll (pull-to-stretch,
/// mirroring Home). During an edge back-swipe the system's pan can deliver a
/// small vertical component to the page's scroll view as well, so the hero
/// starts stretching and rebounding while the finger is still moving the page
/// horizontally. Freezing the pull for the duration of the pop gesture keeps the
/// hero fixed; a normal vertical overscroll still stretches it.
struct PlozziOSInteractivePopObserver: UIViewRepresentable {
    @Binding var isActive: Bool

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = { active in
            guard isActive != active else { return }
            isActive = active
        }
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onChange = { active in
            guard isActive != active else { return }
            isActive = active
        }
    }

    final class ObserverView: UIView {
        var onChange: ((Bool) -> Void)?
        private weak var gesture: UIGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                detach()
                return
            }
            attach()
        }

        private func attach() {
            guard gesture == nil, let navigation = enclosingNavigationController(),
                  let recognizer = navigation.interactivePopGestureRecognizer else { return }
            gesture = recognizer
            recognizer.addTarget(self, action: #selector(handle(_:)))
        }

        private func detach() {
            gesture?.removeTarget(self, action: nil)
            gesture = nil
        }

        @objc private func handle(_ recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                onChange?(true)
            case .ended, .cancelled, .failed:
                onChange?(false)
            default:
                break
            }
        }

        private func enclosingNavigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController {
                    return controller.navigationController
                }
                responder = current.next
            }
            return nil
        }

    }
}
#endif
