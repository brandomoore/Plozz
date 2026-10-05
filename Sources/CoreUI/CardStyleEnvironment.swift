#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// The active profile's `CardStyle`, injected into the SwiftUI environment at the
/// app root (see `RootView`) alongside `\.plozzMetrics`. Media cards read this so
/// switching the "Card Style" setting (or switching to a profile with a different
/// style) restyles the whole media UI live, with no view rebuild — exactly like
/// the theme palette and density metrics.
private struct PlozzCardStyleKey: EnvironmentKey {
    static let defaultValue: CardStyle = .default
}

private struct PlozzGradientCardSurfaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var plozzGradientCardSurface: Bool {
        get { self[PlozzGradientCardSurfaceKey.self] }
        set { self[PlozzGradientCardSurfaceKey.self] = newValue }
    }

    var plozzRestingCardSurface: SurfaceStyle {
        plozzGradientCardSurface ? themePalette.gradientSurface : themePalette.raised
    }
}

public extension EnvironmentValues {
    /// The live, per-profile media card presentation (framed glass card vs
    /// borderless artwork-only). Set once at the app root; read by `PosterCardView`.
    var plozzCardStyle: CardStyle {
        get { self[PlozzCardStyleKey.self] }
        set { self[PlozzCardStyleKey.self] = newValue }
    }
}
#endif
