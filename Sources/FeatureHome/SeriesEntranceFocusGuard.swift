import SwiftUI

#if os(tvOS)
import CoreModels
import CoreUI
import Observation
import UIKit
#endif

/// Keep the whole page in one focus tree beneath the entrance veto.
struct SeriesEntranceFocusGuard<Content: View>: View {
    let isEnabled: Bool
    let content: Content

    init(isEnabled: Bool, @ViewBuilder content: () -> Content) {
        self.isEnabled = isEnabled
        self.content = content()
    }

    var body: some View {
        #if os(tvOS)
        SeriesEntrancePageHost(content: content, blocksDown: isEnabled)
            .ignoresSafeArea(.container, edges: .top)
        #else
        content
        #endif
    }
}

#if os(tvOS)
@MainActor @Observable
private final class SeriesPageHostedModel<Content: View> {
    var content: Content
    var environment: EnvironmentValues

    init(content: Content, environment: EnvironmentValues) {
        self.content = content
        self.environment = environment
    }
}

private struct SeriesPageHostedContent<Content: View>: View {
    let model: SeriesPageHostedModel<Content>

    var body: some View {
        model.content.environment(\.self, model.environment)
    }
}

private struct SeriesEntrancePageHost<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let blocksDown: Bool

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(model: SeriesPageHostedModel(
            content: content, environment: context.environment
        ))
        controller.blocksDown = blocksDown
        controller.entrance = context.environment.detailEntranceSession
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.blocksDown = blocksDown
        controller.entrance = context.environment.detailEntranceSession
        controller.model.content = content
        controller.model.environment = context.environment
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiViewController: Controller, context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? UIScreen.main.bounds.width,
            height: proposal.height ?? UIScreen.main.bounds.height
        )
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.blocksDown = false
        controller.entrance = nil
    }

    final class Controller: UIHostingController<AnyView> {
        let model: SeriesPageHostedModel<Content>
        var blocksDown = false
        weak var entrance: TVDetailEntranceSession?

        init(model: SeriesPageHostedModel<Content>) {
            self.model = model
            super.init(rootView: AnyView(SeriesPageHostedContent(model: model)))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            if blocksDown, entrance?.blocksNavigation == true, entrance?.isClosing != true,
               context.focusHeading.contains(.down),
               context.previouslyFocusedItem != nil {
                #if DEBUG
                if ProcessInfo.processInfo.environment["PLOZZ_SERIES_FOCUS_TRACE"] == "1" {
                    HandoffDiagnostics.emit("SERIES_FOCUS event=blockedDownByPageAncestor")
                }
                #endif
                return false
            }
            return super.shouldUpdateFocus(in: context)
        }
    }
}
#endif
