import SwiftUI

#if os(tvOS)
import CoreModels
import UIKit
#endif

/// A real ancestor of the hero's focus items can veto escape before it occurs.
struct SeriesEntranceFocusGuard<Content: View>: View {
    let isEnabled: Bool
    let content: Content

    init(isEnabled: Bool, @ViewBuilder content: () -> Content) {
        self.isEnabled = isEnabled
        self.content = content()
    }

    var body: some View {
        #if os(tvOS)
        SeriesEntranceHeroHost(content: content, blocksDown: isEnabled)
        #else
        content
        #endif
    }
}

#if os(tvOS)
private struct SeriesEntranceHeroHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let blocksDown: Bool

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(rootView: AnyView(
            content.environment(\.self, context.environment)
        ))
        controller.blocksDown = blocksDown
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.blocksDown = blocksDown
        controller.rootView = AnyView(content.environment(\.self, context.environment))
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiViewController: Controller, context: Context
    ) -> CGSize? {
        uiViewController.sizeThatFits(in: CGSize(
            width: proposal.width ?? UIScreen.main.bounds.width,
            height: proposal.height ?? CGFloat.greatestFiniteMagnitude
        ))
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.blocksDown = false
    }

    final class Controller: UIHostingController<AnyView> {
        var blocksDown = false

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            if blocksDown, context.focusHeading.contains(.down),
               context.previouslyFocusedItem != nil {
                #if DEBUG
                if ProcessInfo.processInfo.environment["PLOZZ_SERIES_FOCUS_TRACE"] == "1" {
                    HandoffDiagnostics.emit("SERIES_FOCUS event=blockedDownByHeroAncestor")
                }
                #endif
                return false
            }
            return super.shouldUpdateFocus(in: context)
        }
    }
}
#endif
