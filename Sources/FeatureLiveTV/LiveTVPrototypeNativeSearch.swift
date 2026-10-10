#if os(tvOS)
import CoreModels
import CoreNetworking
import CoreUI
import SwiftUI
import UIKit

/// Preserve native tab navigation while browsing in one retained fullscreen host.
public struct LiveTVNavigationContainer<Content: View>: View {
    private let isActive: Bool
    private let content: Content

    public init(isActive: Bool = true, @ViewBuilder content: () -> Content) {
        self.isActive = isActive
        self.content = content()
    }

    public var body: some View {
        // Native TabView can replace an unstacked destination during presentation.
        NavigationStack {
            NativeLiveTVPresentation(isActive: isActive, content: AnyView(NavigationStack {
                content.ignoresSafeArea(.container, edges: .top)
                    .toolbar(.hidden, for: .navigationBar)
            }))
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct NativeLiveTVPresentation: UIViewControllerRepresentable {
    let isActive: Bool
    let content: AnyView
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?
    @Environment(GlassPerformanceModel.self) private var glassPerformance: GlassPerformanceModel?

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.invalidate()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        let environment = context.environment
        // The new hosting root must establish its own focus and dismissal context.
        controller.content = AnyView(content
            .environment(profiles)
            .environment(glassPerformance)
            .environment(\.themePalette, environment.themePalette)
            .environment(\.plozzReduceTransparency, environment.plozzReduceTransparency)
            .environment(\.plozzReducePanelGlass, environment.plozzReducePanelGlass)
            .environment(\.gradientBackgroundsEnabled, environment.gradientBackgroundsEnabled)
            .environment(\.plozzMetrics, environment.plozzMetrics)
            .environment(\.plozzArtworkSettings, environment.plozzArtworkSettings)
            .environment(\.plozzArtworkProviders, environment.plozzArtworkProviders)
            .environment(\.plozzCardFocusStyle, environment.plozzCardFocusStyle)
            .environment(\.channelLogoPreservesSourceCorners, environment.channelLogoPreservesSourceCorners)
            .environment(\.plozzHDRDisplayActive, environment.plozzHDRDisplayActive)
            .environment(\.managedProviderSetupRouter, environment.managedProviderSetupRouter)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.locale, environment.locale)
            .environment(\.calendar, environment.calendar)
            .environment(\.timeZone, environment.timeZone)
            .environment(\.scenePhase, environment.scenePhase)
            .environment(\.isEnabled, environment.isEnabled))
        controller.updateContent()
        controller.setActive(isActive)
    }

    final class Controller: UIViewController {
        var content = AnyView(EmptyView())
        private var host: Host?
        private var immersive = false
        private var transitioning = false
        private var hasEntered = false
        private var isActive = true
        private var invalidated = false
        private let lifecycle = LiveTVPresentationLifecycle()

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if !hasEntered {
                hasEntered = true
                enter()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if host?.parent === self { host?.view.frame = view.bounds }
        }

        func updateContent() {
            let root = AnyView(content.environment(lifecycle)
                .onExitCommand { [weak self] in self?.leave() })
            if let host {
                host.rootView = root
            } else {
                let host = Host(rootView: root)
                host.returnedToContent = { [weak self] in
                    guard let self, hasEntered, !immersive, !transitioning else { return }
                    enter()
                }
                self.host = host
            }
        }

        func setActive(_ active: Bool) {
            isActive = active
            if !active { leave() }
        }

        func invalidate() {
            invalidated = true
            lifecycle.isRelocating = false
            host?.returnedToContent = nil
            if host?.presentingViewController != nil { host?.dismiss(animated: false) }
            if let host, host.parent === self {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
            }
            host = nil
        }

        private func attach() {
            guard let host, host.parent == nil else { return }
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }

        private func enter() {
            guard let host, isActive, !invalidated, !transitioning, !immersive, view.window != nil else { return }
            transitioning = true
            lifecycle.isRelocating = true
            if host.parent != nil {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
            }
            host.modalPresentationStyle = .overFullScreen
            present(host, animated: false) { [weak self] in
                guard let self, !invalidated else { return }
                immersive = true
                transitioning = false
                lifecycle.isRelocating = false
                if isActive {
                    let focus = UIFocusSystem.focusSystem(for: host)
                    focus?.requestFocusUpdate(to: host)
                    focus?.updateFocusIfNeeded()
                } else { leave() }
            }
            if host.presentingViewController == nil {
                PlozzLog.app.error("Live TV fullscreen presentation was not accepted")
                attach()
                transitioning = false
                lifecycle.isRelocating = false
            }
        }

        private func leave() {
            guard let host, immersive, !transitioning else { return }
            // Search and player presentations consume their own Back press.
            if isActive, containsPresentation(host) { return }
            transitioning = true
            lifecycle.isRelocating = isActive
            host.view.isUserInteractionEnabled = false
            host.dismiss(animated: false) { [weak self] in
                guard let self, !invalidated else { return }
                immersive = false
                attach()
                host.view.isUserInteractionEnabled = true
                transitioning = false
                lifecycle.isRelocating = false
            }
        }

        private func containsPresentation(_ controller: UIViewController) -> Bool {
            controller.presentedViewController != nil || controller.children.contains(where: containsPresentation)
        }
    }

    final class Host: UIHostingController<AnyView> {
        var returnedToContent: (() -> Void)?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            guard context.previouslyFocusedItem != nil,
                  contains(context.nextFocusedItem), !contains(context.previouslyFocusedItem) else { return }
            // Moving a newly focused environment during the focus update is illegal.
            coordinator.addCoordinatedAnimations(nil) { [weak self] in
                guard let self, contains(UIFocusSystem.focusSystem(for: self)?.focusedItem) else { return }
                returnedToContent?()
            }
        }

        private func contains(_ item: (any UIFocusItem)?) -> Bool {
            var environment: (any UIFocusEnvironment)? = item
            while let current = environment {
                if current === self || current === view { return true }
                environment = current.parentFocusEnvironment
            }
            return false
        }
    }
}

/// tvOS's inline keyboard and the existing guide share one search surface.
/// A TextField here would open another full-screen text-entry presentation.
struct PrototypeNativeSearch<Results: View>: UIViewControllerRepresentable {
    @Binding var query: String
    let restoresGuideFocus: Bool
    let isPresented: Bool
    let close: () -> Void
    let editing: () -> Void
    @ViewBuilder let results: (_ close: @escaping () -> Void) -> Results
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var searchPlaceholder: String {
        String(localized: "Search channels", locale: locale) // l10n:content — UIKit String boundary, recomputed from the live SwiftUI locale
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let host = UIHostingController(rootView: PrototypeSearchResults(content: results(context.coordinator.closeAction)))
        host.view.backgroundColor = .clear
        let search = PrototypeSearchController(searchResultsController: host)
        search.close = context.coordinator.closeAction
        search.reduceMotion = reduceMotion
        search.modalPresentationStyle = .custom
        search.searchBar.placeholder = searchPlaceholder
        search.searchBar.text = query
        search.searchBar.autocorrectionType = .no
        search.searchBar.autocapitalizationType = .none
        search.searchResultsUpdater = context.coordinator
        search.searchBar.delegate = context.coordinator
        search.searchBar.accessibilityIdentifier = "live-tv-search-field"
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        search.view.backgroundColor = .clear
        search.restoresGuideFocus = restoresGuideFocus
        let container = UISearchContainerViewController(searchController: search)
        container.definesPresentationContext = true
        container.view.backgroundColor = .clear
        let base = UIViewController()
        base.view.backgroundColor = .clear
        let navigation = UINavigationController()
        navigation.setNavigationBarHidden(true, animated: false)
        navigation.view.backgroundColor = .clear
        navigation.setViewControllers(isPresented ? [base, container] : [base], animated: false)
        navigation.delegate = context.coordinator
        context.coordinator.host = host
        context.coordinator.search = search
        context.coordinator.container = container
        context.coordinator.navigation = navigation
        context.coordinator.base = base
        return navigation
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host?.rootView = PrototypeSearchResults(content: results(context.coordinator.closeAction))
        guard let search = context.coordinator.search else {
            assertionFailure("Missing Live TV Search controller")
            return
        }
        if search.searchBar.text != query { search.searchBar.text = query }
        if search.searchBar.placeholder != searchPlaceholder {
            search.searchBar.placeholder = searchPlaceholder
        }
        search.view.isUserInteractionEnabled = context.environment.isEnabled
        search.reduceMotion = reduceMotion
        if search.restoresGuideFocus != restoresGuideFocus {
            search.restoresGuideFocus = restoresGuideFocus
            search.setNeedsFocusUpdate()
        }
        context.coordinator.synchronizePresentation()
    }

    static func dismantleUIViewController(_ controller: UINavigationController, coordinator: Coordinator) {
        coordinator.isDismantled = true
        controller.delegate = nil
        coordinator.search?.searchResultsUpdater = nil
        coordinator.search?.searchBar.delegate = nil
        coordinator.search?.close = nil
        if let base = coordinator.base {
            controller.setViewControllers([base], animated: false)
        }
        coordinator.host = nil
        coordinator.search = nil
        coordinator.container = nil
        coordinator.navigation = nil
        coordinator.base = nil
    }

    final class Coordinator: NSObject, UISearchResultsUpdating, UISearchBarDelegate, UINavigationControllerDelegate {
        var parent: PrototypeNativeSearch
        var host: UIHostingController<PrototypeSearchResults<Results>>?
        weak var search: PrototypeSearchController?
        var container: UISearchContainerViewController?
        weak var navigation: UINavigationController?
        weak var base: UIViewController?
        private(set) var isClosing = false
        private var changingPresentation = false
        private var closeNotified = false
        var isDismantled = false

        init(_ parent: PrototypeNativeSearch) { self.parent = parent }

        var closeAction: () -> Void {
            { [weak self] in self?.requestClose() }
        }

        func requestClose() {
            guard parent.isPresented, !isClosing, !isDismantled, let search else { return }
            isClosing = true
            search.fadeOut { [weak self] in
                guard let self, !self.isDismantled, let navigation = self.navigation, let base = self.base else { return }
                // UISearchContainer owns the search presentation. Pop its owner;
                // isActive only changes editing and dismiss() can leave it open.
                navigation.setViewControllers([base], animated: false)
                self.notifyClosed()
            }
        }

        private func notifyClosed() {
            guard !isDismantled, !closeNotified else { return }
            closeNotified = true
            parent.close()
        }

        func synchronizePresentation() {
            guard let search, let container, let navigation, let base,
                  !isClosing, !changingPresentation, !isDismantled else { return }
            let visible = navigation.topViewController === container
            guard visible != parent.isPresented else { return }
            changingPresentation = true
            search.searchBar.text = parent.query
            navigation.setViewControllers(parent.isPresented ? [base, container] : [base], animated: false)
            changingPresentation = false
        }

        func navigationController(
            _ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool
        ) {
            guard viewController === base, navigationController.topViewController === base,
                  parent.isPresented, !isClosing, !changingPresentation else { return }
            notifyClosed()
        }

        func updateSearchResults(for searchController: UISearchController) {
            guard parent.isPresented, !isClosing, !changingPresentation, !isDismantled else { return }
            let text = searchController.searchBar.text ?? ""
            if parent.query != text { parent.query = text }
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            Task { @MainActor [weak self] in
                guard let self, self.parent.isPresented, !self.isClosing, !self.isDismantled,
                      !self.parent.restoresGuideFocus else { return }
                self.parent.editing()
            }
        }
    }
}

final class PrototypeSearchController: UISearchController {
    var restoresGuideFocus = false
    var reduceMotion = false
    var close: (() -> Void)?
    var fadeDuration: TimeInterval { reduceMotion ? 0 : 0.18 }
    private(set) lazy var backPress = UITapGestureRecognizer(target: self, action: #selector(closeFromRemote))

    override func viewDidLoad() {
        super.viewDidLoad()
        backPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        // Attach to Search itself, never the window: sheets, playback and native
        // context menus outside this subtree keep their own Back handling.
        view.addGestureRecognizer(backPress)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.alpha = reduceMotion ? 1 : 0
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Fade the actual presented view, not the SwiftUI representable behind it.
        UIView.animate(withDuration: fadeDuration, delay: fadeDuration, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.view.alpha = 1
        }
    }

    func fadeOut(completion: @escaping () -> Void) {
        UIView.animate(withDuration: fadeDuration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.view.alpha = 0
        } completion: { _ in completion() }
    }

    @objc func closeFromRemote() {
        guard viewIfLoaded?.window != nil, !isBeingDismissed else { return }
        close?()
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        if restoresGuideFocus, let searchResultsController { return [searchResultsController] }
        return super.preferredFocusEnvironments
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if restoresGuideFocus, let next = context.nextFocusedView,
           let results = searchResultsController?.view, !next.isDescendant(of: results) {
            return false
        }
        return super.shouldUpdateFocus(in: context)
    }
}
#endif
