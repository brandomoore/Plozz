#if canImport(SwiftUI)
import CoreModels
import SwiftUI

/// The same appearance controls for library and Live TV settings on both platforms.
public struct SubtitleAppearanceSettings: View {
    @Binding private var style: SubtitleStyle

    public init(style: Binding<SubtitleStyle>) {
        _style = style
    }

    public var body: some View {
        Toggle("Use System Caption Style", isOn: $style.followsSystemStyle)
        Text("Draw subtitles in the style set in Settings › Accessibility › Subtitles & Captioning.")
            .font(.caption)
            .plozzForeground(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if !style.followsSystemStyle {
            SubtitleFontSettingsPicker(style: $style)
            Picker("Weight", selection: Binding(
                get: { style.fontWeight.snapped(to: style.availableFontWeights) },
                set: { style.fontWeight = $0 }
            )) {
                ForEach(style.availableFontWeights, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            percentage("Text Size", value: $style.fontScale, range: 0.4...2.0, step: 0.05)
            colorPicker("Text Color", selection: $style.textColor)
            percentage("Opacity", value: $style.opacity, range: 0.2...1, step: 0.05)
            Picker("Shadow", selection: $style.edge.style) {
                ForEach(SubtitleEdgeStyle.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            Toggle("Outline", isOn: $style.border.isEnabled)
            Toggle("Background", isOn: $style.background.isEnabled)
            if style.background.isEnabled {
                colorPicker("Background Color", selection: Binding(
                    get: {
                        var color = style.background.color
                        color.alpha = 1
                        return color
                    },
                    set: {
                        let opacity = style.background.color.alpha
                        style.background.color = $0
                        style.background.color.alpha = opacity
                    }
                ))
                percentage("Background Opacity", value: $style.background.color.alpha, range: 0...1, step: 0.05)
            }
        }
        percentage("Position", value: $style.verticalPosition,
                   range: SubtitleStyle.verticalPositionRange, step: SubtitleStyle.verticalPositionStep)
        Toggle("Use File Positions", isOn: $style.usesSourcePosition)
        Toggle("Use File Colors", isOn: $style.usesSourceColors)
    }

    @ViewBuilder
    private func percentage(
        _ title: LocalizedStringResource, value: Binding<Double>,
        range: ClosedRange<Double>, step: Double
    ) -> some View {
        #if os(tvOS)
        LabeledSettingRow(title) {
            SettingsStepper(
                options: Array(Int((range.lowerBound / step).rounded())...Int((range.upperBound / step).rounded())),
                selection: Binding(
                    get: { Int((value.wrappedValue / step).rounded()) },
                    set: { value.wrappedValue = Double($0) * step }
                ),
                verbatimTitle: { (Double($0) * step).formatted(.percent.precision(.fractionLength(0...1))) }
            )
        }
        #else
        LabeledContent {
            Slider(value: value, in: range, step: step)
                .frame(maxWidth: 360)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(value.wrappedValue, format: .percent))
        } label: {
            Text(title)
        }
        #endif
    }

    private func colorPicker(_ title: LocalizedStringResource, selection: Binding<SubtitleColor>) -> some View {
        Picker(selection: selection) {
            Text("White").tag(SubtitleColor.white)
            Text("Yellow").tag(SubtitleColor.yellow)
            Text("Light Gray").tag(SubtitleColor.lightGray)
            Text("Cyan").tag(SubtitleColor.cyan)
            Text("Pink").tag(SubtitleColor.pink)
            Text("Orange").tag(SubtitleColor.orange)
            Text("Green").tag(SubtitleColor.green)
            Text("Black").tag(SubtitleColor.black)
            if !SubtitleColor.presets.contains(where: { $0.color == selection.wrappedValue }) {
                Text("Custom").tag(selection.wrappedValue)
            }
        } label: {
            Text(title)
        }
    }
}
#endif
