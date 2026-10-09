import CoreUI
import SwiftUI

struct LiveTVPreviewIntroductionPresentation: ViewModifier {
    let isPresented: Bool
    let choose: (Bool) -> Void
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
        // Only an explicit action records a choice, not a scene-driven dismissal.
        content.sheet(isPresented: .constant(isPresented), onDismiss: onDismiss) {
            LiveTVPreviewIntroductionView(choose: choose)
                .interactiveDismissDisabled()
                .presentationBackground(.clear)
        }
        #else
        content
        #endif
    }
}

#if os(tvOS)
struct LiveTVPreviewIntroductionView: View {
    let choose: (Bool) -> Void
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            LiveTVPreviewIntroductionHeading()
            LiveTVPreviewIntroductionActions(choose: choose)
            Text("Change this any time in Settings > Live TV > Auto preview.")
                .font(.callout)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(56)
        .frame(maxWidth: 1_100, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(palette.primaryText)
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        .onExitCommand { choose(false) }
    }
}

private struct LiveTVPreviewIntroductionHeading: View {
    @Environment(\.themePalette) private var palette
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "play.tv")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(palette.primaryText)
                .accessibilityHidden(true)
            Text("Turn on live previews?")
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Text("As you browse, the highlighted channel starts playing behind the guide.")
                .font(.body)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LiveTVPreviewIntroductionActions: View {
    let choose: (Bool) -> Void
    @FocusState private var focused: Bool?

    var body: some View {
        HStack(spacing: 28) {
            Button { choose(true) } label: {
                Text("Turn on previews")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .plozzActionButton(role: .secondary)
            .focused($focused, equals: true)
            .accessibilityIdentifier("live-tv-preview-enable")
            Button { choose(false) } label: {
                Text("Keep previews off")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .plozzActionButton(role: .secondary)
            .focused($focused, equals: false)
            .accessibilityIdentifier("live-tv-preview-disable")
        }
        .defaultFocus($focused, true, priority: .userInitiated)
    }
}
#endif
