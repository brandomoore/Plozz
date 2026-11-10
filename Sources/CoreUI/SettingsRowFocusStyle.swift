#if canImport(SwiftUI)
import SwiftUI

/// Size variant for the unified list-row focus style. `.standard` is the
/// top-level row height; `.prominent` is the taller server-list row that
/// carries an "In use" badge and needs a larger corner radius / shadow;
/// `.contained` keeps its highlight inside a shared grouped container;
/// `.navigation` matches the full rounded outline of a standalone page link.
public enum SettingsRowSize {
    case standard
    case prominent
    case contained
    case navigation
}

/// How much weight a list-row *control* carries, and therefore how tall it is.
/// A single scale shared by every Settings row control (toggle rows, checkable
/// rows, selector rows) so "primary" and "secondary" mean the SAME physical
/// height everywhere instead of each control re-deriving its own.
///
/// - `primary`: master switches and single-select pickers (Theme, Display Size)
///   — the decision on the pane.
/// - `secondary`: sub-section checkmarks and selectors that sit under a master
///   toggle (Customize Home rows, the libraries + "Watching as" rows on Your
///   Servers & Libraries) — the toggle's children, a step shorter/lighter.
public enum SettingsRowProminence {
    case primary
    case secondary
}

/// Spacing for settings pages, distinct from the clearance around individual focusable rows.
public enum SettingsFormMetrics {
    public static let pageWidth: CGFloat = 960
    public static let sectionSpacing = PlozzTheme.Spacing.large + PlozzTheme.Spacing.xxSmall
    public static let controlSpacing = PlozzTheme.Spacing.large
    public static let relatedControlSpacing = PlozzTheme.Spacing.small
    public static let navigationRowSpacing = PlozzTheme.Spacing.xSmall
    public static let groupCornerRadius = PlozzTheme.Metrics.mediumCardCornerRadius
    public static let connectedGroupSpacing = PlozzTheme.Spacing.xSmall
    public static let connectedGroupInnerCornerRadius: CGFloat = 8
    public static let dividerFocusClearance = PlozzTheme.Spacing.xSmall
    public static let illustratedGroupSpacing = PlozzTheme.Spacing.medium
    public static var groupInset: CGFloat {
        #if os(tvOS)
        illustratedGroupSpacing
        #else
        PlozzTheme.Spacing.large
        #endif
    }
    public static let pageInset = sectionSpacing
    public static var headingInset: CGFloat {
        #if os(tvOS)
        groupInset + SettingsRowMetrics.horizontalPadding
        #else
        PlozzTheme.Spacing.medium
        #endif
    }
    public static let pageTopInset = PlozzTheme.Spacing.xSmall
    public static let pageBottomInset = PlozzTheme.Spacing.xxxLarge + PlozzTheme.Spacing.small
}

/// One source of truth for list-row control metrics, so every control at the
/// same ``SettingsRowProminence`` is the same height and its focus card nests
/// concentrically. Toggle rows and checkable rows both read these, which is what
/// keeps a switch row and a primary checkmark row exactly the same height (and a
/// secondary checkmark row the same height as a secondary selector row).
public enum SettingsRowMetrics {
    /// Control labels share the navigation-row size; headings use separate styles.
    public static let titleFont: Font = .body
    public static var optionFont: Font {
        #if os(tvOS)
        titleFont
        #else
        .headline
        #endif
    }
    public static var helperFont: Font {
        #if os(tvOS)
        descriptionFont
        #else
        .callout
        #endif
    }
    public static var descriptionFont: Font {
        #if os(tvOS)
        .caption
        #else
        .footnote
        #endif
    }
    public static let segmentedTrackInset: CGFloat = 4

    public static let formRowSpacing: CGFloat = 8
    public static let formSectionSpacing: CGFloat = 24
    public static var formGroupInset: CGFloat {
        #if os(tvOS)
        SettingsFormMetrics.groupInset
        #else
        10
        #endif
    }
    public static let navigationCornerRadius = SettingsFormMetrics.groupCornerRadius
    public static var formRowCornerRadius: CGFloat {
        #if os(tvOS)
        SettingsFormMetrics.groupCornerRadius - formGroupInset
        #else
        PlozzTheme.Metrics.Radius.card - formGroupInset
        #endif
    }

    /// Minimum content height before vertical padding.
    public static func minHeight(_ p: SettingsRowProminence) -> CGFloat {
        p == .primary ? 46 : 40
    }

    /// Vertical padding added above/below the content.
    public static func verticalPadding(_ p: SettingsRowProminence) -> CGFloat {
        p == .primary ? 14 : 11
    }

    /// Leading↔title spacing / general row inter-item spacing.
    public static func spacing(_ p: SettingsRowProminence) -> CGFloat {
        p == .primary ? 20 : 16
    }

    /// Horizontal content inset — same at both prominences so a secondary child
    /// list stays aligned under its primary master.
    public static let horizontalPadding: CGFloat = 12
    public static let iconColumnWidth: CGFloat = 30
    public static let iconTitleSpacing: CGFloat = 16
    public static var iconTitleInset: CGFloat {
        horizontalPadding + iconColumnWidth + iconTitleSpacing
    }

    /// The amount a row pulls its leading edge outward to cancel
    /// ``horizontalPadding`` and sit title-flush-left with a pane heading. Rows
    /// inside a *bordered* card pass `flushLeading: false` to skip this, so their
    /// focus card stays concentric with the card instead of hugging its border.
    public static var leadingPull: CGFloat { horizontalPadding }
}

/// Single shared, theme-aware focus style for every drill-in list row — the
/// Settings navigation rows AND any other control that should focus *exactly*
/// like them (e.g. the music rails' "See All"). Lives in CoreUI so every module
/// reuses the one implementation instead of re-deriving (or drifting from) it.
///
/// FOCUSED state is the native tvOS "inverted card":
/// - Dark mode focus: WHITE fill, BLACK foreground.
/// - Light mode focus: BLACK fill, WHITE foreground.
/// UNFOCUSED state inherits normal foreground colors. Navigation rows own their
/// resting settings surface; other row roles remain transparent.
///
/// The highlight card normally bleeds slightly outward via negative padding;
/// `.contained` keeps it within grouped-list row bounds. Content remains anchored
/// in place and never scales.
///
/// To keep ALL row content focus + theme adaptive (not just the background) the
/// style propagates the focused state via the environment. Helpers like
/// `.settingsRowSecondary()`, `.settingsRowIcon()`, and
/// `.settingsRowGreenIndicator()` let row content read that and flip their own
/// colors uniformly without re-implementing the logic per row.
public struct SettingsFocusButtonStyle: ButtonStyle {
    var size: SettingsRowSize

    public init(size: SettingsRowSize = .standard) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        SettingsFocusBody(configuration: configuration, size: size)
    }
}

/// Full-width form actions use the same content height and interior padding as
/// settings switches. Group spacing is outside the focus fill, not inside it.
public struct SettingsFormButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        SettingsFormButtonBody(configuration: configuration)
    }
}

private struct SettingsFormButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        SettingsFocusRow(isFocused: isFocused, isPressed: configuration.isPressed, size: .contained) {
            configuration.label
                .settingsFormRowLayout()
        }
    }
}

public extension View {
    /// Shared content bounds for form buttons, On/Off rows, and inline controls.
    @ViewBuilder
    func settingsFormRowLayout() -> some View {
        #if os(tvOS)
        self
            .environment(\.settingsFormTextInset, 0)
            .frame(
                maxWidth: .infinity,
                minHeight: SettingsRowMetrics.minHeight(.primary),
                alignment: .leading
            )
            .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
            .padding(.vertical, SettingsRowMetrics.verticalPadding(.primary))
        #else
        self
        #endif
    }

    /// Static text joins the control-label keyline only inside a grouped form.
    func settingsFormTextLayout() -> some View {
        modifier(SettingsFormTextLayout())
    }
}

private struct SettingsFormTextLayout: ViewModifier {
    @Environment(\.settingsFormTextInset) private var inset

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .environment(\.settingsFormTextInset, 0)
            .padding(.horizontal, inset)
        #else
        content
        #endif
    }
}

/// Compact, theme-aware chip used for Back/Edit controls in floating glass
/// panel headers. Player submenus and detail-page menus share this treatment.
public struct PlozzPanelHeaderButtonStyle: ButtonStyle {
    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = 14) {
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        PlozzPanelHeaderButtonBody(
            configuration: configuration,
            cornerRadius: cornerRadius
        )
    }
}

private struct PlozzPanelHeaderButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat

    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let foreground = colorScheme == .dark ? Color.white : Color.black
        let focusForeground = colorScheme == .dark ? Color.black : Color.white

        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isFocused ? focusForeground : foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                shape.fill(
                    isFocused
                    ? foreground
                    : foreground.opacity(colorScheme == .dark ? 0.12 : 0.08)
                )
            )
            .overlay(shape.stroke(foreground.opacity(isFocused ? 0 : 0.18), lineWidth: 1))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(nil, value: isFocused)
    }
}

private struct SettingsFocusBody: View {
    let configuration: ButtonStyle.Configuration
    let size: SettingsRowSize
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        SettingsFocusRow(isFocused: isFocused, isPressed: configuration.isPressed, size: size) {
            configuration.label
        }
    }
}

/// Shared row chrome for SwiftUI buttons and reusable native list cells.
public struct SettingsFocusRow<Content: View>: View {
    private let isFocused: Bool
    private let isPressed: Bool
    private let size: SettingsRowSize
    private let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsRowsHaveDividers) private var hasDividers
    @Environment(\.settingsFormTextInset) private var textInset

    public init(
        isFocused: Bool, isPressed: Bool = false, size: SettingsRowSize = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.isFocused = isFocused
        self.isPressed = isPressed
        self.size = size
        self.content = content()
    }

    private var effectiveSize: SettingsRowSize {
        #if os(tvOS)
        size == .standard && textInset > 0 ? .contained : size
        #else
        size
        #endif
    }

    private var corner: CGFloat {
        switch effectiveSize {
        case .standard: 16
        case .prominent: 18
        case .contained: SettingsRowMetrics.formRowCornerRadius
        case .navigation: SettingsRowMetrics.navigationCornerRadius
        }
    }

    private var focusInsetH: CGFloat {
        switch effectiveSize {
        case .standard: 16
        case .prominent: 10
        case .contained, .navigation: 0
        }
    }

    private var focusInsetV: CGFloat {
        if hasDividers { return 0 }
        return switch effectiveSize {
        case .standard: 4
        case .prominent: 6
        case .contained, .navigation: 0
        }
    }

    private var focusFill: Color {
        colorScheme == .dark ? Color.white : Color.black
    }
    private var focusForeground: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    public var body: some View {
        content
            .environment(\.settingsFormTextInset, 0)
            .font(SettingsRowMetrics.titleFont)
            // Inject the focused state + the "what color should focused
            // content be?" into the environment so descendants (subtitle,
            // chevron, icon, green chip…) can adapt without each row
            // reimplementing the logic.
            .environment(\.settingsRowIsFocused, isFocused)
            .environment(\.settingsRowFocusForeground, focusForeground)
            // The HIGHLIGHT grows on focus, NOT the content. The card
            // background extends slightly OUTWARD via a negative padding
            // so text/icons stay anchored in place — only the colored
            // surface and its shadow expand. (Old scaleEffect on the
            // whole label scaled the text too, which read as "weird"
            // because the label visibly grew.)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(isFocused ? focusFill : Color.clear)
                    .padding(.horizontal, isFocused ? -focusInsetH : 0)
                    .padding(.vertical, isFocused ? -focusInsetV : 0)
                    .shadow(
                        color: Color.black.opacity(isFocused ? 0.30 : 0),
                        radius: isFocused ? 14 : 0,
                        y: isFocused ? 6 : 0
                    )
            )
            .background {
                if effectiveSize == .navigation {
                    Color.clear.settingsGroupSurface(cornerRadius: corner)
                }
            }
            .contentShape(Rectangle())
            // Primary foreground inverts on focus so untouched titles flip.
            // Explicit `.foregroundStyle(...)` on individual leaves (chips,
            // checkmarks) still wins.
            .foregroundStyle(isFocused ? AnyShapeStyle(focusForeground) : AnyShapeStyle(.primary))
            .opacity(isPressed ? 0.88 : 1.0)
            // Focus is INSTANT — no fill/scale/shadow easing when focus moves
            // between rows. (Deliberately no `.animation(value: isFocused)`.)
    }
}

// MARK: - Focus-aware environment values

private struct SettingsRowIsFocusedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

private struct SettingsRowFocusForegroundKey: EnvironmentKey {
    static let defaultValue: Color = .white
}

private struct SettingsFormRowsFlushLeadingKey: EnvironmentKey {
    static let defaultValue = true
}

private struct SettingsRowsHaveDividersKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SettingsFormTextInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    /// Group-relative text and divider inset, consumed by already-padded row labels.
    var settingsFormTextInset: CGFloat {
        get { self[SettingsFormTextInsetKey.self] }
        set { self[SettingsFormTextInsetKey.self] = newValue }
    }

    /// Contained groups keep the shared row inset; ordinary forms align labels to their gutter.
    var settingsFormRowsFlushLeading: Bool {
        get { self[SettingsFormRowsFlushLeadingKey.self] }
        set { self[SettingsFormRowsFlushLeadingKey.self] = newValue }
    }

    var settingsRowsHaveDividers: Bool {
        get { self[SettingsRowsHaveDividersKey.self] }
        set { self[SettingsRowsHaveDividersKey.self] = newValue }
    }

    var settingsRowIsFocused: Bool {
        get { self[SettingsRowIsFocusedKey.self] }
        set { self[SettingsRowIsFocusedKey.self] = newValue }
    }
    var settingsRowFocusForeground: Color {
        get { self[SettingsRowFocusForegroundKey.self] }
        set { self[SettingsRowFocusForegroundKey.self] = newValue }
    }
}

// MARK: - Adaptive helpers used by row content

/// Secondary text (trailing value, subtitles, chevrons). On a focused
/// inverted card, inherits the focus foreground at a reduced opacity so it
/// still reads as "secondary" against the inverted fill instead of being
/// invisible (white-on-white) or low-contrast.
public struct SettingsRowSecondaryStyle: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content.plozzForeground(.secondary)
    }
}

/// Leading icon: rendered in the shared secondary text colour when the row is
/// idle (so icons read as calm supporting glyphs, not bright accent blobs, and
/// match the same tier on iOS), flipped to the focus foreground (black in dark
/// mode focus, white in light mode focus) when focused so it stays legible on
/// the inverted focus card.
public struct SettingsRowIconStyle: ViewModifier {
    @Environment(\.settingsRowIsFocused) private var focused
    @Environment(\.settingsRowFocusForeground) private var focusFg
    @Environment(\.themePalette) private var palette

    public init() {}

    public func body(content: Content) -> some View {
        content.foregroundStyle(
            focused
            ? AnyShapeStyle(focusFg)
            : AnyShapeStyle(palette.secondaryText)
        )
    }
}

/// "In use" / status green indicator with a contrast-correct variant on
/// focus: darker green on the white focus card (dark mode), lighter green on
/// the black focus card (light mode), so it stays legible against the
/// inverted fill instead of disappearing into it.
public struct SettingsRowGreenIndicatorStyle: ViewModifier {
    @Environment(\.settingsRowIsFocused) private var focused
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func body(content: Content) -> some View {
        let tint: Color = {
            guard focused else { return .green }
            return colorScheme == .dark
                ? Color(red: 0.10, green: 0.50, blue: 0.22)  // darker on white card
                : Color(red: 0.55, green: 0.95, blue: 0.65)  // lighter on black card
        }()
        return content.foregroundStyle(tint)
    }

}

/// Standard trailing mark for a selected settings choice.
///
/// The shape, size and focus-adaptive green belong together; exposing one view
/// prevents Plex, Jellyfin, Emby, Seerr and future pickers from drifting into
/// bare checks versus filled circles.
public struct SettingsSelectionIndicator: View {
    public init() {}

    public var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title3)
            .settingsRowGreenIndicator()
    }
}

/// The shared trailing checkmark for a checked settings row.
///
/// Lives in CoreUI so both shells draw the SAME mark. It used to be defined only
/// in the tvOS-side settings module, so when the iPhone/iPad Libraries screen
/// grew checkmarks they were filled circles against tvOS's bare glyph — the same
/// idea rendered as two different controls depending on the device.
///
/// Reserves its slot when unchecked (opacity, not absence) so a column doesn't
/// shift as rows are ticked.
public struct SettingsCheckmark: View {
    public let isChecked: Bool
    public var prominence: SettingsRowProminence

    public init(isChecked: Bool, prominence: SettingsRowProminence = .primary) {
        self.isChecked = isChecked
        self.prominence = prominence
    }

    private var glyphFont: Font {
        #if os(tvOS)
        SettingsRowMetrics.descriptionFont.weight(.semibold)
        #else
        prominence == .primary ? .headline.weight(.bold) : .callout.weight(.bold)
        #endif
    }

    public var body: some View {
        Image(systemName: "checkmark")
            .font(glyphFont)
            .opacity(isChecked ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// Label style for standard settings rows: the leading icon is rendered in the
/// shared ``ThemePalette/secondaryText`` tier while the title keeps its inherited
/// (primary) colour. Applied once at the group level so every plain
/// `Label(title, systemImage:)` in a settings section gets calm, standardized
/// icons on both platforms — no per-call-site styling. Rows that need a coloured
/// icon (e.g. a destructive red row) opt out by setting their own `.labelStyle`.
public struct SettingsIconLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var iconColumnWidth = SettingsRowMetrics.iconColumnWidth

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon
                .frame(width: iconColumnWidth)
                .settingsRowIcon()
        }
    }
}

public extension View {
    func settingsRowSecondary() -> some View { modifier(SettingsRowSecondaryStyle()) }
    func settingsRowIcon() -> some View { modifier(SettingsRowIconStyle()) }
    func settingsRowGreenIndicator() -> some View { modifier(SettingsRowGreenIndicatorStyle()) }
}

// MARK: - Settings typography scale (10-foot UI)

/// One shared type hierarchy for every Settings detail pane, so the levels never
/// collide (the "section header looks like a control label" problem):
///
///  1. ``settingsFeatureTitle()`` — the pane's feature name (e.g. "Hero").
///  2. ``settingsSectionHeader()`` — a group heading within the pane (e.g.
///     "Sources", "Items"). Compact uppercase text distinguishes a group from a row.
///  3. control labels — use ``SettingsRowMetrics/titleFont`` for toggles,
///     segments, reorder rows, and compact preview-card captions.
///  4. ``settingsHelperText()`` — descriptive/helper copy under a title or header.
///
/// Defining these here (not ad-hoc per view) is what makes the hierarchy
/// consistent across every settings screen.
public extension View {
    /// L1 — the detail pane's feature title (e.g. "Hero"). Matches the master
    /// list's page title weight/size so the two column titles read as peers.
    func settingsFeatureTitle() -> some View {
        font(.title2.weight(.bold)).foregroundStyle(.primary)
    }

    /// L2 — a section header inside a detail pane (e.g. "SOURCES"). Uppercase,
    /// tracked, bold and secondary — the classic grouped-list header idiom, so it
    /// reads as a *header* and never collides with the sentence-case, primary
    /// control labels beneath it, nor with its own regular-weight, dimmer description.
    func settingsSectionHeader() -> some View {
        #if os(tvOS)
        font(SettingsRowMetrics.descriptionFont.weight(.semibold))
            .textCase(.uppercase)
            .tracking(1.8)
            .plozzForeground(.secondary)
            .settingsFormTextLayout()
        #else
        font(.subheadline.weight(.bold))
            .textCase(.uppercase)
            .tracking(1.8)
            .plozzForeground(.secondary)
        #endif
    }

    /// L3 — a **feature** description: the intro sentence under the pane's feature
    /// title (e.g. under "Hero"). Readable but secondary.
    func settingsHelperText() -> some View {
        font(SettingsRowMetrics.helperFont).plozzForeground(.secondary)
            .settingsFormTextLayout()
    }

    /// L4 — a **section** description: a small, dim note under a section header.
    /// Shares the helper-copy size, with quieter emphasis beneath a group heading.
    func settingsSectionDescription() -> some View {
        font(SettingsRowMetrics.descriptionFont).plozzForeground(.tertiary)
            .settingsFormTextLayout()
    }
}
#endif
