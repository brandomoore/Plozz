#if os(iOS)
import SwiftUI
import UIKit

/// Pops the enclosing navigation stack to its root when the shell asks for it, and
/// notices a re-tap of the already-selected Search tab.
///
/// Search results push their detail page through a view-based `NavigationLink`
/// (`MediaArtworkZoomLink`), so there is no `NavigationPath` to clear: a pushed page
/// can only be dismissed by the `UINavigationController` that hosts it. Pressing the
/// Search tab while a result is open is a request for "search", so this walks up to
/// that controller and pops it.
///
/// A **re-tap** of the tab that is already selected never reaches SwiftUI's
/// `TabView` selection binding, so the shell cannot see it. The standard tab bar's
/// buttons are still real controls, though, and the tab bar controller is in this
/// view's ancestry: a non-cancelling tap recogniser on that bar reports a tap on the
/// *selected* item back to the shell. Installed only in the Search stack, so other
/// tabs keep their pushed pages when the bar is tapped.
///
/// Deliberately a no-op unless the request counter changes or the selected tab is
/// tapped, so a normal push is never disturbed, and it only pops the stack it is
/// installed in — the other tabs' stacks are untouched.
struct PlozziOSNavigationPopProxy: UIViewControllerRepresentable {
    let request: Int
    /// Whether this proxy lives in the Search stack. Only Search installs the tab
    /// re-selection observer.
    var isSearch: Bool = false
    /// Called when the viewer taps the selected Search tab again. The shell turns
    /// that into a fresh search request (focus, clear query, return to root).
    var onReselect: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.request = request
        controller.isSearch = isSearch
        controller.onReselect = onReselect
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.request = request
        controller.isSearch = isSearch
        controller.onReselect = onReselect
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var request: Int = 0 {
            didSet {
                guard request != oldValue, request > 0 else { return }
                // Deferred: the update pass can run while the navigation controller is
                // mid-transition, and popping there is what drops frames.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await Task.yield()
                    self.enclosingNavigationController()?.popToRootViewController(animated: false)
                }
            }
        }

        var isSearch: Bool = false
        var onReselect: (() -> Void)?
        private var tabBarTap: UITapGestureRecognizer?
        private weak var observedTabBar: UITabBar?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installTabReSelectionIfNeeded()
        }

        private func enclosingNavigationController() -> UINavigationController? {
            var candidate: UIViewController? = self
            while let current = candidate {
                if let navigation = current.navigationController { return navigation }
                candidate = current.parent ?? current.presentingViewController
            }
            return nil
        }

        private func enclosingTabBarController() -> UITabBarController? {
            var candidate: UIViewController? = self
            while let current = candidate {
                if let tabs = current as? UITabBarController { return tabs }
                if let tabs = current.tabBarController { return tabs }
                candidate = current.parent ?? current.presentingViewController
            }
            return nil
        }

        private func installTabReSelectionIfNeeded() {
            guard isSearch, tabBarTap == nil,
                  let tabs = enclosingTabBarController() else { return }
            let recognizer = UITapGestureRecognizer(
                target: self, action: #selector(tabBarTapped(_:))
            )
            // The tab bar must still perform its own selection; this only observes.
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            tabs.tabBar.addGestureRecognizer(recognizer)
            tabBarTap = recognizer
            observedTabBar = tabs.tabBar
        }

        @objc private func tabBarTapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let bar = observedTabBar else { return }
            let point = recognizer.location(in: bar)
            // `UITabBarButton` is a `UIControl`; checking `isSelected` keeps this to
            // the already-selected tab, so switching tabs never clears a query.
            guard let button = bar.subviews
                .compactMap({ $0 as? UIControl })
                .first(where: { $0.frame.contains(point) }),
                button.isSelected else { return }
            onReselect?()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        deinit {
            // The recogniser lives on the tab bar, which outlives this controller
            // only until the shell rebuilds. Detach on the main actor rather than
            // in `viewDidDisappear`: pushing a result covers the Search root, and
            // removing the observer there would disable the very re-tap it exists
            // to notice.
            let bar = observedTabBar
            let recognizer = tabBarTap
            Task { @MainActor in
                if let bar, let recognizer { bar.removeGestureRecognizer(recognizer) }
            }
        }

        override func loadView() {
            // Zero-size so it can sit in a background without affecting layout.
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
    }
}
#endif
