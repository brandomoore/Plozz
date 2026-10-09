#if os(tvOS)
import CoreModels
import CoreUI
import FeatureHomeCore
import FeaturePlayback
import FeatureSettings
import SwiftUI
import UIKit

struct NavigationRailFocusHost<Content: View>: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    @Environment(\.isEnabled) private var isEnabled
    let isNavigationFocused: Bool
    let content: Content

    init(isNavigationFocused: Bool, @ViewBuilder content: () -> Content) {
        self.isNavigationFocused = isNavigationFocused
        self.content = content()
    }

    func makeUIViewController(context: Context) -> NavigationRailFocusHostController {
        let controller = NavigationRailFocusHostController()
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: NavigationRailFocusHostController, context: Context) {
        controller.isNavigationFocused = isNavigationFocused
        let source = environment
        controller.rootView = AnyView(content.transformEnvironment(\.self) { target in
            target.copyHostedPresentation(from: source)
            target.isEnabled = isEnabled
            target.plozzReducePanelGlass = source.plozzReducePanelGlass
            target.plozzHDRDisplayActive = source.plozzHDRDisplayActive
            target.themeMusicController = source.themeMusicController
            target.themeMusicSettings = source.themeMusicSettings
            target.themeMusicAuthenticatedHTTPResolver = source.themeMusicAuthenticatedHTTPResolver
            target.seasonRequestContextID = source.seasonRequestContextID
            target[NavigationChromeModel.self] = source[NavigationChromeModel.self]
            target[ProfilesModel.self] = source[ProfilesModel.self]
            target[HeroTrailerController.self] = source[HeroTrailerController.self]
            target[HeroBackgroundSettingsModel.self] = source[HeroBackgroundSettingsModel.self]
            target[HeroSettingsModel.self] = source[HeroSettingsModel.self]
            target[ShareScanStatusModel.self] = source[ShareScanStatusModel.self]
            target[MusicPlayerSettingsModel.self] = source[MusicPlayerSettingsModel.self]
            target[UIDensitySettingsModel.self] = source[UIDensitySettingsModel.self]
            target[CardStyleSettingsModel.self] = source[CardStyleSettingsModel.self]
            target[WatchStatusIndicatorSettingsModel.self] = source[WatchStatusIndicatorSettingsModel.self]
            target[NavigationStyleSettingsModel.self] = source[NavigationStyleSettingsModel.self]
            target[TransparencyPreferenceModel.self] = source[TransparencyPreferenceModel.self]
            target[AppLanguageSettingsModel.self] = source[AppLanguageSettingsModel.self]
            target[LiveTVSettingsSources.self] = source[LiveTVSettingsSources.self]
            target[SubtitleStyleSettingsDestination.self] = source[SubtitleStyleSettingsDestination.self]
            target[GlassPerformanceModel.self] = source[GlassPerformanceModel.self]
            target[DisplayVeilModel.self] = source[DisplayVeilModel.self]
        })
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiViewController: NavigationRailFocusHostController,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleUIViewController(
        _ controller: NavigationRailFocusHostController, coordinator: ()
    ) {
        controller.rootView = AnyView(EmptyView())
    }
}

final class NavigationRailFocusHostController: UIHostingController<AnyView> {
    var isNavigationFocused = false
    private weak var requestedFocus: (any UIFocusItem)?

    static func containing(_ view: UIView) -> NavigationRailFocusHostController? {
        var responder = view.next
        while let current = responder {
            if let owner = current as? NavigationRailFocusHostController { return owner }
            responder = current.next
        }
        return nil
    }

    init() {
        super.init(rootView: AnyView(EmptyView()))
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        requestedFocus.map { [$0] } ?? super.preferredFocusEnvironments
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        // Leave Right unresolved so the existing boundary observer requests the
        // captured source, rather than letting geometry choose a different control.
        allowsFocusUpdate(heading: context.focusHeading) && super.shouldUpdateFocus(in: context)
    }

    func allowsFocusUpdate(heading: UIFocusHeading) -> Bool {
        !(isNavigationFocused && heading.contains(.right))
    }

    @discardableResult
    func requestFocus(to item: any UIFocusItem, using system: any NavigationFocusUpdating) -> Bool {
        // UIKit only honors requests from an environment containing current focus.
        // This owner contains both the rail and the destination's nested hosts.
        requestedFocus = item
        defer { requestedFocus = nil }
        system.requestFocusUpdate(to: self)
        system.updateFocusIfNeeded()
        return system.focusedItem === item
    }
}

@MainActor
protocol NavigationFocusUpdating: AnyObject {
    var focusedItem: (any UIFocusItem)? { get }
    func requestFocusUpdate(to environment: any UIFocusEnvironment)
    func updateFocusIfNeeded()
}

extension UIFocusSystem: NavigationFocusUpdating {}
#endif
