#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

/// The compact, in-Settings picker for the watch-status indicator: a row of
/// preview cards (`PreviewCard` + `WatchStatusIndicatorSwatch`) that share the
/// detail pane's width, mirroring `CompactThemePicker`. Tapping a card selects
/// that indicator; the active one carries the same accent wash/ring the theme and
/// music-player pickers use.
struct CompactWatchIndicatorPicker: View {
    @Binding var selection: WatchStatusIndicator
    /// Height of side-by-side option illustrations.
    var swatchHeight: CGFloat = 248
    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        #if os(iOS)
        AdaptiveCardSettingsPicker {
            HStack(alignment: .top, spacing: 16) { choices }
        } compact: {
            compactPicker
        }
        #else
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout { choices }
            .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }

    #if os(iOS)
    private var compactPicker: some View {
        VStack(spacing: 12) {
            WatchStatusIndicatorSwatch(indicator: selection)
                .frame(height: 96)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Watch indicator preview")
                .accessibilityValue(Text(selection.displayName))
                .accessibilityIdentifier("watch-indicator-preview")
            Picker("Watch indicators", selection: $selection) {
                ForEach(WatchStatusIndicator.allCases) { indicator in
                    Text(indicator.displayName).tag(indicator)
                        .accessibilityIdentifier("watch-indicator-option-\(indicator.rawValue)")
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("watch-indicator-picker")
        }
    }
    #endif

    private var choices: some View {
        ForEach(WatchStatusIndicator.allCases) { indicator in
            PreviewCard(
                title: indicator.displayName,
                detail: indicator.detail,
                isSelected: selection == indicator,
                accent: palette.accent,
                compact: true,
                swatchHeight: swatchHeight,
                action: { selection = indicator }
            ) {
                WatchStatusIndicatorSwatch(
                    indicator: indicator,
                    cornerRadius: PlozzTheme.Metrics.Radius.content
                )
                .accessibilityHidden(true)
            }
            .accessibilityIdentifier("watch-indicator-preview-\(indicator.rawValue)")
        }
    }
}
#endif
