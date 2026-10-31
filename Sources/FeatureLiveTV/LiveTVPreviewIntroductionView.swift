import CoreUI
import SwiftUI

struct LiveTVPreviewIntroductionPresentation: ViewModifier {
    let isPresented: Bool
    let choose: (Bool) -> Void
    let onDismiss: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        #if os(tvOS)
        // Only an explicit action records a choice, not a scene-driven dismissal.
        content.plozzSheet(isPresented: .constant(isPresented && isEnabled), onDismiss: onDismiss) {
            LiveTVPreviewIntroductionView(choose: choose)
                .interactiveDismissDisabled()
        }
        .navigationEntryFocus(isPresented ? .pending : nil)
        #else
        content
        #endif
    }
}

#if os(tvOS)
struct LiveTVPreviewIntroductionView: View {
    let choose: (Bool) -> Void

    var body: some View {
        FirstUseChoiceView(
            symbol: "play.tv",
            title: "Turn on live previews?",
            message: "As you browse, the highlighted channel starts playing behind the guide.",
            firstAction: "Turn on previews",
            secondAction: "Keep previews off",
            footer: "Change this any time in Settings > Live TV > Auto preview.",
            firstIdentifier: "live-tv-preview-enable",
            secondIdentifier: "live-tv-preview-disable",
            choose: choose
        )
        .onExitCommand { choose(false) }
    }
}
#endif
