#if os(iOS)
import SwiftUI
import UIKit

struct PlozziOSHeroKeyboardControls: UIViewControllerRepresentable {
    let isEnabled: Bool
    let onPage: (Bool) -> Void

    func makeUIViewController(context: Context) -> KeyboardViewController {
        KeyboardViewController()
    }

    func updateUIViewController(_ controller: KeyboardViewController, context: Context) {
        controller.isEnabled = isEnabled
        controller.onPage = onPage
        controller.updateResponder()
    }

    static func dismantleUIViewController(_ controller: KeyboardViewController, coordinator: ()) {
        controller.isEnabled = false
        controller.resignFirstResponder()
        controller.onPage = nil
    }

    final class KeyboardViewController: UIViewController {
        var isEnabled = false
        var onPage: ((Bool) -> Void)?

        override var canBecomeFirstResponder: Bool { canHandleCommands }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(editingEnded(_:)), name: name, object: nil
                )
            }
            for input in [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow] {
                let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(page(_:)))
                command.wantsPriorityOverSystemBehavior = true
                addKeyCommand(command)
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updateResponder()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            resignFirstResponder()
        }

        func updateResponder() {
            if canHandleCommands {
                if !isFirstResponder { becomeFirstResponder() }
            } else if isFirstResponder {
                resignFirstResponder()
            }
        }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(page(_:)), let command = sender as? UIKeyCommand {
                return canHandleCommands && command.modifierFlags.isEmpty
                    && (command.input == UIKeyCommand.inputLeftArrow || command.input == UIKeyCommand.inputRightArrow)
            }
            return super.canPerformAction(action, withSender: sender)
        }

        @objc private func page(_ command: UIKeyCommand) {
            guard canPerformAction(#selector(page(_:)), withSender: command) else { return }
            onPage?(command.input == UIKeyCommand.inputRightArrow)
        }

        @objc private func editingEnded(_ notification: Notification) {
            guard let window = viewIfLoaded?.window,
                  (notification.object as? UIView)?.window === window else { return }
            // Let a replacement text field acquire focus before reclaiming idle Home input.
            DispatchQueue.main.async { [weak self] in self?.updateResponder() }
        }

        private var canHandleCommands: Bool {
            guard isEnabled, let window = viewIfLoaded?.window, window.isKeyWindow else { return false }
            var ancestor: UIViewController? = self
            while let controller = ancestor {
                if controller.presentedViewController != nil { return false }
                ancestor = controller.parent
            }
            return isFirstResponder || !hasEditingResponder(in: window)
        }

        private func hasEditingResponder(in view: UIView) -> Bool {
            if view.isFirstResponder, view is UITextInput { return true }
            return view.subviews.contains { hasEditingResponder(in: $0) }
        }
    }
}
#endif
