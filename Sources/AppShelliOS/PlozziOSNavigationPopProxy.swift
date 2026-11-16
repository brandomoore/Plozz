#if os(iOS)
import SwiftUI
import UIKit

/// Search also pushes through view-based links, which have no NavigationPath to
/// clear. Install this only inside Search; native tab reselection is observed by
/// the shell's existing tab delegate on both phone and iPad.
struct PlozziOSNavigationPopProxy: UIViewControllerRepresentable {
    let request: Int

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.receive(request, initial: true)
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.receive(request)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.cancelPendingPop()
    }

    final class Controller: UIViewController {
        private var request = 0
        private var pendingPop: Task<Void, Never>?

        func receive(_ value: Int, initial: Bool = false) {
            guard value != request else { return }
            request = value
            guard !initial else { return }
            pendingPop?.cancel()
            pendingPop = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled, request == value else { return }
                var candidate: UIViewController? = self
                while let current = candidate {
                    if let navigation = current.navigationController {
                        navigation.popToRootViewController(animated: false)
                        return
                    }
                    candidate = current.parent
                }
            }
        }

        func cancelPendingPop() {
            pendingPop?.cancel()
            pendingPop = nil
        }

        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
    }
}
#endif
