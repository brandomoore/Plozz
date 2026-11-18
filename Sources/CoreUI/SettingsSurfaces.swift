#if canImport(SwiftUI)
import SwiftUI

public struct SettingsPageBackground: View {
    private var paintsDialogBackground = false
    @Environment(\.themePalette) private var palette
    @Environment(\.gradientBackgroundsEnabled) private var gradientEnabled
    @Environment(\.plozzDialogBackgroundOwned) private var dialogBackgroundOwned
    #if os(tvOS) || os(iOS)
    @Environment(\.settingsGradientCardSurface) private var cardSurface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif
    #if os(tvOS)
    @Environment(\.settingsInWorkspace) private var inWorkspace
    #endif

    public init() {}

    init(paintsDialogBackground: Bool) {
        self.paintsDialogBackground = paintsDialogBackground
    }

    public var body: some View {
        if inheritsBackground && !paintsDialogBackground {
            Color.clear
        } else if gradientEnabled {
            AmbientGradientBackground(palette: palette)
                #if os(tvOS) || os(iOS)
                .background {
                    if let cardSurface {
                        NativeGradientViewport(
                            surface: cardSurface,
                            style: .init(
                                colors: AmbientGradientBackground.meshColors(tint: nil, palette: palette),
                                palette: palette,
                                informationSurfaceOpacity: 0
                            ),
                            reduceMotion: reduceMotion
                        )
                        .ignoresSafeArea()
                    }
                }
                #endif
        } else {
            (inheritsBackground ? palette.overlay.fill : palette.settingsBackground).ignoresSafeArea()
        }
    }

    private var inheritsBackground: Bool {
        #if os(tvOS)
        dialogBackgroundOwned || inWorkspace
        #else
        dialogBackgroundOwned
        #endif
    }
}

#if os(tvOS)
private struct SettingsWorkspaceKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SettingsPageBackButtonKey: EnvironmentKey {
    static let defaultValue: AnyView? = nil
}

public extension EnvironmentValues {
    var settingsInWorkspace: Bool {
        get { self[SettingsWorkspaceKey.self] }
        set { self[SettingsWorkspaceKey.self] = newValue }
    }

    /// The navigation owner supplies its focus-aware Back control; the page hosts it inside its scroll content.
    var settingsPageBackButton: AnyView? {
        get { self[SettingsPageBackButtonKey.self] }
        set { self[SettingsPageBackButtonKey.self] = newValue }
    }
}

#endif

#if os(tvOS) || os(iOS)
private struct SettingsGradientCardSurfaceKey: EnvironmentKey {
    static let defaultValue: NativeGradientCardSurface? = nil
}

extension EnvironmentValues {
    var settingsGradientCardSurface: NativeGradientCardSurface? {
        get { self[SettingsGradientCardSurfaceKey.self] }
        set { self[SettingsGradientCardSurfaceKey.self] = newValue }
    }
}
#endif

public struct SettingsPageBackButton: View {
    #if os(tvOS)
    @Environment(\.settingsPageBackButton) private var backButton
    #endif

    public init() {}

    public var body: some View {
        #if os(tvOS)
        if let backButton {
            backButton
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
        }
        #else
        EmptyView()
        #endif
    }
}

private struct SettingsPageBackgroundModifier: ViewModifier {
    var paintsDialogBackground = false
    #if os(tvOS) || os(iOS)
    @State private var cardSurface = NativeGradientCardSurface()
    #endif
    #if os(iOS)
    @Environment(\.settingsGradientCardSurface) private var inheritedSurface
    @Environment(\.plozzDialogBackgroundOwned) private var dialogBackgroundOwned
    #endif

    func body(content: Content) -> some View {
        content
            .background { SettingsPageBackground(paintsDialogBackground: paintsDialogBackground) }
            #if os(tvOS)
            .environment(\.settingsGradientCardSurface, cardSurface)
            #elseif os(iOS)
            .environment(
                \.settingsGradientCardSurface,
                dialogBackgroundOwned && !paintsDialogBackground ? inheritedSurface : cardSurface
            )
            #endif
    }
}

public struct PlozzDialogBackdrop: View {
    @Environment(\.themePalette) private var palette
    private let minimumOpacity: Double

    /// Preserve a dialog's existing stronger backdrop when adopting the shared theme.
    public init(minimumOpacity: Double = 0) {
        self.minimumOpacity = minimumOpacity
    }

    public var body: some View {
        Color.black.opacity(max(palette.dialogBackdropOpacity, minimumOpacity))
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// A hairline separator that uses the palette's shared ``ThemePalette/separator``
/// token instead of SwiftUI's default `Divider()` (whose OS separator colour is
/// brighter than the app's surface hairlines, so it clashes with card edges —
/// especially in OLED). Use this for dividers *inside* elevated surfaces.
///
/// Thickness is a fixed **1pt**, matching the `lineWidth: 1` used on the surface
/// borders. A true `1/displayScale` hairline would antialias to a sub-point line
/// that reads noticeably *dimmer* than the 1pt card edge even at the same colour,
/// so the two are pinned to the same weight to look like one family.
public struct PlozzDivider: View {
    @Environment(\.themePalette) private var palette

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(height: 1)
    }
}

/// Renders a surface at a given elevation rung using the palette's shared
/// ``SurfaceStyle`` table — a fill, an optional hairline border (OLED), and an
/// optional drop shadow (light / dark overlays). Shared by app-owned settings
/// groups, detail cards and dialogs so both platforms resolve the same theme.
private struct PlozzSurfaceModifier<SurfaceShape: InsettableShape>: ViewModifier {
    @Environment(\.themePalette) private var palette
    #if os(iOS)
    @Environment(\.settingsGradientCardSurface) private var cardSurface
    #endif
    let level: SurfaceLevel
    let shape: SurfaceShape
    var surfaceOverride: SurfaceStyle? = nil
    var opaqueGradient = false

    func body(content: Content) -> some View {
        let style = surfaceOverride ?? palette.surface(level)
        content
            .background {
                Group {
                    if level == .overlay {
                        PlozzDialogBackground().clipShape(shape)
                    } else {
                        #if os(iOS)
                        if opaqueGradient {
                            NativeGradientCardFill(surface: cardSurface, fill: style.fill)
                                .background(palette.raised.fill)
                                .clipShape(shape)
                        } else {
                            shape.fill(style.fill)
                        }
                        #else
                        shape.fill(style.fill)
                        #endif
                    }
                }
                    .overlay {
                        if let border = style.border {
                            shape.strokeBorder(border, lineWidth: style.borderWidth)
                        }
                    }
                    .modifier(OptionalSurfaceShadow(shadow: style.shadow))
            }
    }
}

/// Applies the surface's drop shadow only when one is defined, so borderless
/// dark/OLED raised surfaces don't pay for an invisible shadow layer. Shared so
/// both the `plozzSurface` modifier and the focusable-card path render shadows
/// identically.
struct OptionalSurfaceShadow: ViewModifier {
    let shadow: SurfaceShadow?

    func body(content: Content) -> some View {
        if let shadow {
            content.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
        } else {
            content
        }
    }
}

private struct SettingsGroupSurface<SurfaceShape: InsettableShape>: ViewModifier {
    let shape: SurfaceShape
    @Environment(\.themePalette) private var palette
    @Environment(\.gradientBackgroundsEnabled) private var gradientEnabled
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        #if os(iOS)
        content.modifier(PlozzSurfaceModifier(
            level: .raised, shape: shape,
            surfaceOverride: gradientEnabled ? palette.gradientSurface : nil,
            opaqueGradient: gradientEnabled && reduceTransparency
        ))
        #else
        let translucent = gradientEnabled && !reduceTransparency
        content.modifier(PlozzSurfaceModifier(
            level: .raised, shape: shape,
            surfaceOverride: translucent ? palette.gradientSurface : nil
        ))
        #endif
    }
}

public extension View {
    /// Shares the Settings backdrop with native cards' page-aligned surface.
    func settingsPageBackground(paintsDialogBackground: Bool = false) -> some View {
        modifier(SettingsPageBackgroundModifier(paintsDialogBackground: paintsDialogBackground))
    }

    /// Paints an elevated surface behind this view at the given rung, using the
    /// palette's shared elevation table.
    func plozzSurface(_ level: SurfaceLevel, cornerRadius: CGFloat) -> some View {
        modifier(PlozzSurfaceModifier(
            level: level, shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ))
    }

    func settingsGroupSurface(cornerRadius: CGFloat) -> some View {
        modifier(SettingsGroupSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }

    func settingsGroupSurface<SurfaceShape: InsettableShape>(in shape: SurfaceShape) -> some View {
        modifier(SettingsGroupSurface(shape: shape))
    }

    func settingsGroupSurface(cornerRadii: RectangleCornerRadii) -> some View {
        modifier(SettingsGroupSurface(shape: UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)))
    }
}
#endif
