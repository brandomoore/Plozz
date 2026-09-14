#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The active profile's `CardFocusStyle`, injected into the SwiftUI environment
/// at the app root (see `RootView`) alongside `\.plozzCardStyle`. Every focusable
/// media card reads this so the selected effect follows the active profile.
private struct PlozzCardFocusStyleKey: EnvironmentKey {
    static let defaultValue: CardFocusStyle = .default
}

public extension EnvironmentValues {
    /// The live, per-profile System, custom Highlight or custom Outline effect.
    /// Set once at the app root; read by
    /// `plozzCardFocusLift`, `plozzCardFocusTransition` and `plozzFocusHalo`.
    var plozzCardFocusStyle: CardFocusStyle {
        get { self[PlozzCardFocusStyleKey.self] }
        set { self[PlozzCardFocusStyleKey.self] = newValue }
    }
}

public extension View {
    /// Scope both the control's focus owner and its visuals to the circular treatment,
    /// without changing the saved media-card preference.
    func plozzCircularFocusStyle() -> some View {
        modifier(CircularFocusStyleScope())
    }
}

enum CircularControlFocusStyle {
    static func resolve(_ selected: CardFocusStyle) -> CardFocusStyle {
        selected.usesSystemEffect ? .outlined : selected
    }
}

private struct CircularFocusStyleScope: ViewModifier {
    @Environment(\.plozzCardFocusStyle) private var selected

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.environment(\.plozzCardFocusStyle, CircularControlFocusStyle.resolve(selected))
        #else
        content
        #endif
    }
}
#endif
