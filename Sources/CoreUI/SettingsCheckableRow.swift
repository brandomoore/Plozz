#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// One focusable, checkable row for the Settings detail pane — a leading optional
/// icon, a title, and a trailing checkmark shown when `isChecked`.
///
/// Shared by both ``SettingsOptionList`` (single-select — Theme, Display Size,
/// Music Player style) and ``SettingsCheckList`` (multi-select — the Customize
/// Home row checklists), so the checkmark and focus-card look are identical
/// everywhere and defined **once**. All heights come from the shared
/// ``SettingsRowMetrics``, so at `.primary` prominence a checkable row is exactly
/// as tall as a switch row on the same screen, and `.secondary` steps that down
/// for child rows — matching selector rows of the same prominence.
/// Subtitles use the shared focus-aware secondary style to remain readable on
/// the inverted focus background.
public struct SettingsCheckableRow: View {
    let title: Text
    var subtitle: Text? = nil
    var subtitleProvider: ProviderKind? = nil
    var titleLineLimit: Int? = 1
    var subtitleLineLimit: Int? = 2
    var icon: String? = nil
    let isChecked: Bool
    /// When false the row is dimmed and pulled out of the focus order (can't be
    /// selected). `SettingsFocusButtonStyle` ignores `\.isEnabled`, so `.disabled`
    /// alone wouldn't dim it — the opacity below supplies the disabled look.
    var isEnabled: Bool = true
    /// Full weight (default) or a lighter child treatment — see
    /// ``SettingsRowProminence``.
    var prominence: SettingsRowProminence = .primary
    /// When false the row does NOT pull its leading edge outward — pass this
    /// inside a bordered card so the focus card nests concentrically instead of
    /// hugging the card's border. Default true (flush-left, for split panes).
    var flushLeading: Bool = true
    var size: SettingsRowSize = .standard
    /// Matches SettingsSectionGroup insets, keeping them inside the focus target.
    var usesGroupInsets = false
    let action: () -> Void
    @Environment(\.settingsFormRowsFlushLeading) private var groupFlushLeading
    @ScaledMetric(relativeTo: .footnote) private var sourceMarkSize: CGFloat = 20

    public init(
        title: Text, subtitle: Text? = nil, subtitleProvider: ProviderKind? = nil, titleLineLimit: Int? = 1,
        subtitleLineLimit: Int? = 2, icon: String? = nil, isChecked: Bool,
        isEnabled: Bool = true, prominence: SettingsRowProminence = .primary,
        flushLeading: Bool = true, size: SettingsRowSize = .standard, usesGroupInsets: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleProvider = subtitleProvider
        self.titleLineLimit = titleLineLimit
        self.subtitleLineLimit = subtitleLineLimit
        self.icon = icon
        self.isChecked = isChecked
        self.isEnabled = isEnabled
        self.prominence = prominence
        self.flushLeading = flushLeading
        self.size = size
        self.usesGroupInsets = usesGroupInsets
        self.action = action
    }

    // ``SettingsRowLabel`` insets content horizontally; cancel the leading inset
    // (unless `flushLeading` is off) so titles line up flush-left with the pane
    // heading while the focus card still bleeds outward symmetrically.
    private var labelInset: CGFloat { SettingsRowMetrics.horizontalPadding }

    private var rowSpacing: CGFloat { SettingsRowMetrics.spacing(prominence) }
    private var iconSize: CGFloat { prominence == .primary ? 24 : 20 }
    private var iconFrame: CGFloat { prominence == .primary ? 34 : 30 }
    private var titleFont: Font {
        if usesGroupInsets { return .body.weight(.medium) }
        #if os(tvOS)
        return SettingsRowMetrics.titleFont
        #else
        return prominence == .primary ? .headline.weight(.semibold) : .callout.weight(.medium)
        #endif
    }
    private var minRowHeight: CGFloat { SettingsRowMetrics.minHeight(prominence) }
    private var verticalPadding: CGFloat { SettingsRowMetrics.verticalPadding(prominence) }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: rowSpacing) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: iconSize, weight: .semibold))
                        .frame(width: iconFrame, alignment: .center)
                        .settingsRowIcon()
                }
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .font(titleFont)
                        .lineLimit(titleLineLimit)
                    if let subtitle {
                        HStack(spacing: 6) {
                            if let subtitleProvider {
                                ProviderBrandMark(provider: subtitleProvider, size: sourceMarkSize, showsBackground: false)
                                    .accessibilityHidden(true)
                            }
                            subtitle
                                .font(SettingsRowMetrics.descriptionFont)
                                .settingsRowSecondary()
                                .lineLimit(subtitleLineLimit)
                        }
                    }
                }
                Spacer(minLength: rowSpacing)
                SettingsCheckmark(isChecked: isChecked, prominence: prominence)
            }
            .frame(minHeight: usesGroupInsets ? 44 : minRowHeight)
            .padding(.vertical, usesGroupInsets ? 12 : verticalPadding)
            .padding(.horizontal, usesGroupInsets ? 16 : labelInset)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(SettingsFocusButtonStyle(size: size))
        .disabled(!isEnabled)
        .padding(.leading, !usesGroupInsets && flushLeading && groupFlushLeading ? -labelInset : 0)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
        .containerValue(\.settingsActionOwnsInsets, usesGroupInsets)
    }
}

#endif
