#if os(tvOS)
import Observation
import SwiftUI
import UIKit

@MainActor @Observable
public final class RetainedFullscreenWorkspaceState {
    public var isPresented = false {
        didSet {
            if oldValue != isPresented { presentationChanged?() }
        }
    }
    public fileprivate(set) var isTransferring = false
    public fileprivate(set) var isHostingFullscreen = false
    fileprivate var presentationChanged: (() -> Void)?
}

extension EnvironmentValues {
    @Entry public var retainedFullscreenWorkspace: RetainedFullscreenWorkspaceState?
}

/// Retains one SwiftUI tree while moving its workspace outside native app navigation.
public struct RetainedFullscreenWorkspace<Content: View>: UIViewControllerRepresentable {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public struct HostedContent: View {
        let content: Content
        let environment: EnvironmentValues
        let state: RetainedFullscreenWorkspaceState

        public var body: some View {
            // A whole environment snapshot also copies the presenting host's private focus context.
            content.environment(\.retainedFullscreenWorkspace, state)
                .environment(\.scenePhase, environment.scenePhase)
                .environment(\.isEnabled, environment.isEnabled)
                .environment(\.locale, environment.locale)
                .environment(\.calendar, environment.calendar)
                .environment(\.timeZone, environment.timeZone)
                .environment(\.layoutDirection, environment.layoutDirection)
                .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
                .environment(\.colorScheme, environment.colorScheme)
                .environment(\.themePalette, environment.themePalette)
                .environment(\.gradientBackgroundsEnabled, environment.gradientBackgroundsEnabled)
                .environment(\.plozzReduceTransparency, environment.plozzReduceTransparency)
                .environment(\.plozzReducePanelGlass, environment.plozzReducePanelGlass)
                .environment(\.plozzHDRDisplayActive, environment.plozzHDRDisplayActive)
                .environment(\.plozzNavigationContentInset, environment.plozzNavigationContentInset)
                .environment(\.plozzTopNavigationContentInsets, environment.plozzTopNavigationContentInsets)
        }
    }

    public func makeUIViewController(context: Context) -> Controller {
        let state = RetainedFullscreenWorkspaceState()
        return Controller(content: HostedContent(content: content, environment: context.environment, state: state))
    }

    public func updateUIViewController(_ controller: Controller, context: Context) {
        controller.host.rootView = HostedContent(
            content: content, environment: context.environment, state: controller.state)
    }

    public static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.tearDown()
    }

    public final class Controller: UIViewController {
        let host: UIHostingController<HostedContent>
        let state: RetainedFullscreenWorkspaceState
        private let workspace = UIViewController()
        private var transitioning = false
        private var tornDown = false

        init(content: HostedContent) {
            state = content.state
            host = UIHostingController(rootView: content)
            super.init(nibName: nil, bundle: nil)
            workspace.modalPresentationStyle = .overFullScreen
            workspace.isModalInPresentation = true
            state.presentationChanged = { [weak self] in
                DispatchQueue.main.async { self?.updatePresentation() }
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        public override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            host.view.backgroundColor = .clear
            moveHost(to: self)
        }

        public override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updatePresentation()
        }

        private func updatePresentation() {
            guard !tornDown, !transitioning, viewIfLoaded?.window != nil else { return }
            if state.isPresented, workspace.presentingViewController == nil {
                guard presentedViewController == nil else { return }
                transitioning = true
                state.isTransferring = true
                state.isHostingFullscreen = true
                workspace.view.backgroundColor = .clear
                // Keep the live tree windowed while UIKit establishes the modal hierarchy.
                present(workspace, animated: false) { [weak self] in
                    guard let self, !tornDown else { return }
                    moveHost(to: workspace)
                    state.isTransferring = false
                    transitioning = false
                    updatePresentation()
                }
            } else if !state.isPresented, workspace.presentingViewController != nil {
                transitioning = true
                state.isTransferring = true
                moveHost(to: self)
                workspace.dismiss(animated: false) { [weak self] in
                    guard let self, !tornDown else { return }
                    state.isTransferring = false
                    state.isHostingFullscreen = false
                    transitioning = false
                    updatePresentation()
                }
            }
        }

        private func moveHost(to parent: UIViewController) {
            guard host.parent !== parent else { return }
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            parent.addChild(host)
            host.view.frame = parent.view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            parent.view.addSubview(host.view)
            host.didMove(toParent: parent)
        }

        func tearDown() {
            tornDown = true
            state.presentationChanged = nil
            state.isTransferring = false
            state.isHostingFullscreen = false
            if workspace.presentingViewController != nil { workspace.dismiss(animated: false) }
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
    }
}
#endif
