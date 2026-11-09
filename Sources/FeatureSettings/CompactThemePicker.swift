#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The compact, in-Settings variant of the onboarding theme picker: a row of
/// smaller preview cards (`ThemeOptionCard(compact:)`) that share the detail
/// pane's width. Tapping a card selects that theme; the active one carries the
/// same accent wash/ring the full picker uses.
///
/// The swatches are theme-independent graphics, so this needs no device colour
/// scheme — it simply binds the selection.
public struct CompactThemePicker: View {
    @Binding var selection: AppTheme
    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(selection: Binding<AppTheme>) {
        self._selection = selection
    }

    public var body: some View {
        #if os(iOS)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12) { options(AppTheme.pickerOrder) }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { options(AppTheme.pickerOrder, width: 144) }
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow { options(Array(AppTheme.pickerOrder.prefix(2))) }
                    GridRow { options(Array(AppTheme.pickerOrder.suffix(2))) }
                }
            }
            .frame(maxWidth: .infinity)
        }
        #else
        HStack(alignment: .top, spacing: 16) {
            ForEach(AppTheme.pickerOrder) { theme in
                ThemeOptionCard(
                    theme: theme,
                    isSelected: selection == theme,
                    accent: palette.accent,
                    compact: true,
                    action: { selection = theme }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }

    #if os(iOS)
    private func options(_ themes: [AppTheme], width: CGFloat? = nil) -> some View {
        ForEach(themes) { theme in
            PreviewCard(
                title: theme.displayName, isSelected: selection == theme,
                accent: palette.accent, compact: true, swatchAspectRatio: 1.6,
                titleLineLimit: nil, action: { selection = theme }
            ) {
                ThemeSwatch(theme: theme, cornerRadius: PlozzTheme.Metrics.Radius.content)
            }
            .frame(width: width)
            .accessibilityLabel(Text(theme.displayName))
            .accessibilityAddTraits(selection == theme ? .isSelected : [])
            .accessibilityIdentifier("theme-option-\(theme.rawValue)")
        }
    }
    #endif
}
#endif
