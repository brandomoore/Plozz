#if os(tvOS)
import SwiftUI
import UIKit

/// The remote's dedicated Channel Up / Channel Down buttons.
///
/// tvOS delivers them as `.pageUp` / `.pageDown` presses — the Siri Remote has
/// none, but TV remotes driving the Apple TV over HDMI-CEC and IR remotes do.
/// SwiftUI has no command for them, so this watches the window the player is
/// in, the same way `TVFocusActivityObserver` does, without consuming or
/// redirecting any other press.
struct LiveChannelRemotePresses: UIViewRepresentable {
    let isEnabled: Bool
    let channelUp: () -> Void
    let channelDown: () -> Void

    func makeUIView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.isUserInteractionEnabled = false
        update(view)
        return view
    }

    func updateUIView(_ view: ObserverView, context: Context) { update(view) }

    static func dismantleUIView(_ view: ObserverView, coordinator: ()) { view.detach() }

    private func update(_ view: ObserverView) {
        view.isEnabled = isEnabled
        view.channelUp = channelUp
        view.channelDown = channelDown
    }

    final class ObserverView: UIView, UIGestureRecognizerDelegate {
        var isEnabled = false
        var channelUp: (() -> Void)?
        var channelDown: (() -> Void)?
        private var recognizers: [UITapGestureRecognizer] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            recognizers = [
                recognizer(.pageUp, action: #selector(pressedUp)),
                recognizer(.pageDown, action: #selector(pressedDown))
            ]
            recognizers.forEach(window.addGestureRecognizer)
        }

        func detach() {
            recognizers.forEach { $0.view?.removeGestureRecognizer($0) }
            recognizers = []
        }

        private func recognizer(_ type: UIPress.PressType, action: Selector) -> UITapGestureRecognizer {
            let recognizer = UITapGestureRecognizer(target: self, action: action)
            recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
            recognizer.allowedTouchTypes = []
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }

        @objc private func pressedUp() { if isEnabled { channelUp?() } }
        @objc private func pressedDown() { if isEnabled { channelDown?() } }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }
}
#endif
