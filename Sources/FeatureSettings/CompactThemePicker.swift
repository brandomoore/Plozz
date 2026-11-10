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

    public init(selection: Binding<AppTheme>) {
        self._selection = selection
    }

    public var body: some View {
        #if os(iOS)
        AppearancePreviewLayout(options: AppTheme.pickerOrder) { theme in
            option(theme)
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
    private func option(_ theme: AppTheme) -> some View {
        PreviewCard(
            title: theme.displayName, isSelected: selection == theme,
            accent: palette.accent, compact: true, swatchAspectRatio: 1.6,
            titleLineLimit: nil, action: { selection = theme }
        ) {
            ThemeSwatch(theme: theme, cornerRadius: PlozzTheme.Metrics.Radius.content)
        }
        .accessibilityLabel(Text(theme.displayName))
        .accessibilityAddTraits(selection == theme ? .isSelected : [])
        .accessibilityIdentifier("theme-option-\(theme.rawValue)")
    }
    #endif
}

#if os(iOS)
struct AppearancePreviewLayout<Option: Identifiable, Content: View>: View {
    let options: [Option]
    @ViewBuilder let content: (Option) -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12) {
                ForEach(options) { content($0) }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    ForEach(options) { content($0).frame(width: 144) }
                }
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    ForEach(Array(stride(from: 0, to: options.count, by: 2)), id: \.self) { index in
                        GridRow {
                            content(options[index])
                            if index + 1 < options.count {
                                content(options[index + 1])
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
#endif
#endif
