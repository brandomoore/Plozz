#if os(iOS)
import SwiftUI
import UIKit

/// Keeps horizontal back navigation from also stretching the detail's scroll view.
struct PlozziOSInteractivePopObserver: UIViewRepresentable {
    @Binding var isActive: Bool

    func makeUIView(context: Context) -> ObserverView {
        ObserverView()
    }

    func updateUIView(_ view: ObserverView, context: Context) {
        view.onChange = { active in
            guard isActive != active else { return }
            isActive = active
        }
        view.attach()
    }

    static func dismantleUIView(_ view: ObserverView, coordinator: ()) {
        view.detach()
        view.onChange = nil
    }

    final class ObserverView: UIView {
        var onChange: ((Bool) -> Void)?
        private weak var navigation: UINavigationController?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attach()
        }

        func attach() {
            guard window != nil,
                  let enclosing = enclosingNavigationController(),
                  navigation !== enclosing else { return }
            detach()
            navigation = enclosing
            for gesture in gestures {
                gesture.addTarget(self, action: #selector(handle(_:)))
            }
        }

        func detach() {
            for gesture in gestures {
                gesture.removeTarget(self, action: #selector(handle(_:)))
            }
            navigation = nil
            onChange?(false)
        }

        private var gestures: [UIGestureRecognizer] {
            guard let navigation else { return [] }
            var result = [navigation.interactivePopGestureRecognizer].compactMap { $0 }
            if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer {
                result.append(content)
            }
            return result
        }

        @objc private func handle(_ recognizer: UIGestureRecognizer) {
            onChange?(gestures.contains { $0.state == .began || $0.state == .changed })
        }

        private func enclosingNavigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController,
                   let navigation = controller as? UINavigationController ?? controller.navigationController {
                    return navigation
                }
                responder = current.next
            }
            return nil
        }
    }
}
#endif
