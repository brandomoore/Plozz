#if canImport(SwiftUI)
import SwiftUI

public enum ActionButtonProminence {
    case primary
    case secondary
}

public extension View {
    func plozzActionButton(role: ActionButtonProminence = .primary) -> some View {
        modifier(NativeActionButtonModifier(prominence: role))
    }

    /// Full-width mobile page actions share label metrics; toolbars keep native sizing.
    @ViewBuilder
    func plozzPageActionLabel() -> some View {
        #if os(iOS)
        self
            .font(.body)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 24)
        #else
        self
        #endif
    }
}

private struct NativeActionButtonModifier: ViewModifier {
    let prominence: ActionButtonProminence
    @Environment(\.themePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        switch prominence {
        case .primary:
            primary(content)
        case .secondary:
            if #available(iOS 26.0, tvOS 26.0, *) {
                content.buttonStyle(.glass)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func primary(_ content: Content) -> some View {
        #if os(iOS)
        // Native prominent buttons assume white ink even when the theme's tint is white.
        let button = content.tint(palette.accent)
            .foregroundStyle(isEnabled ? palette.onAccent : palette.secondaryText)
        #else
        let button = content
        #endif
        if #available(iOS 26.0, tvOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }
}
#endif
