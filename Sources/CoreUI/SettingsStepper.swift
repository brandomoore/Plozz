#if canImport(SwiftUI)
import SwiftUI

/// A compact − / value / + stepper for dialing a value through an ordered set of
/// presets (e.g. skip intervals, playback speed).
///
/// A labeled TV stepper makes its entire row one native focus target. Left/Right
/// adjusts, Select increments, and Up/Down leaves. Other platforms retain their
/// labeled row and separate decrement/increment buttons.
public struct SettingsStepper<Value: Hashable>: View {
    public let options: [Value]
    @Binding public var selection: Value
    public let title: (Value) -> Text
    /// Compact spacing for tight surfaces. TV always uses the shared Settings font.
    public let compact: Bool
    /// When true the value wraps from the last option back to the first (and vice
    /// versa) and the − / + buttons never dim — for cyclic ranges like a clock
    /// time. When false (the default) the value clamps at the ends of the preset
    /// list and the end arrow dims.
    public let wraps: Bool
    /// Reports focus entering/leaving the whole control, including live previews.
    public let onFocusChange: ((Bool) -> Void)?
    private let label: LocalizedStringResource?
    private let subtitle: LocalizedStringResource?
    private let labelWidth: CGFloat
    private let rangeLabels: (LocalizedStringResource, LocalizedStringResource)?
    private let rangeMidpointLabel: LocalizedStringResource?
    private let inlineRange: Bool

    @Environment(\.themePalette) private var palette
    @FocusState private var focusedButton: StepperButton?
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.settingsFormRowsFlushLeading) private var flushLeading
    #endif

    private enum StepperButton { case minus, plus }

    public init(
        options: [Value],
        selection: Binding<Value>,
        compact: Bool = false,
        wraps: Bool = false,
        onFocusChange: ((Bool) -> Void)? = nil,
        label: LocalizedStringResource? = nil,
        subtitle: LocalizedStringResource? = nil,
        labelWidth: CGFloat = 240,
        rangeLabels: (LocalizedStringResource, LocalizedStringResource)? = nil,
        rangeMidpointLabel: LocalizedStringResource? = nil,
        inlineRange: Bool = false,
        title: @escaping (Value) -> LocalizedStringResource
    ) {
        self.init(options: options, selection: selection, compact: compact, wraps: wraps,
                  onFocusChange: onFocusChange, label: label, subtitle: subtitle,
                  labelWidth: labelWidth, rangeLabels: rangeLabels, rangeMidpointLabel: rangeMidpointLabel,
                  inlineRange: inlineRange,
                  textTitle: { Text(title($0)) })
    }

    /// A stepper whose values are formatted CONTENT rather than copy — playback
    /// speeds, times, sizes. Spelled separately so content cannot drift into the
    /// catalog by accident.
    public init(
        options: [Value],
        selection: Binding<Value>,
        compact: Bool = false,
        wraps: Bool = false,
        onFocusChange: ((Bool) -> Void)? = nil,
        label: LocalizedStringResource? = nil,
        subtitle: LocalizedStringResource? = nil,
        labelWidth: CGFloat = 240,
        rangeLabels: (LocalizedStringResource, LocalizedStringResource)? = nil,
        rangeMidpointLabel: LocalizedStringResource? = nil,
        inlineRange: Bool = false,
        verbatimTitle: @escaping (Value) -> String
    ) {
        self.init(options: options, selection: selection, compact: compact, wraps: wraps,
                  onFocusChange: onFocusChange, label: label, subtitle: subtitle,
                  labelWidth: labelWidth, rangeLabels: rangeLabels, rangeMidpointLabel: rangeMidpointLabel,
                  inlineRange: inlineRange,
                  textTitle: { Text(verbatim: verbatimTitle($0)) })
    }

    public init(
        options: [Value],
        selection: Binding<Value>,
        compact: Bool = false,
        wraps: Bool = false,
        onFocusChange: ((Bool) -> Void)? = nil,
        label: LocalizedStringResource? = nil,
        subtitle: LocalizedStringResource? = nil,
        labelWidth: CGFloat = 240,
        rangeLabels: (LocalizedStringResource, LocalizedStringResource)? = nil,
        rangeMidpointLabel: LocalizedStringResource? = nil,
        inlineRange: Bool = false,
        textTitle: @escaping (Value) -> Text
    ) {
        self.options = options
        self._selection = selection
        self.compact = compact
        self.wraps = wraps
        self.onFocusChange = onFocusChange
        self.label = label
        self.subtitle = subtitle
        self.labelWidth = labelWidth
        self.rangeLabels = rangeLabels
        self.rangeMidpointLabel = rangeMidpointLabel
        self.inlineRange = inlineRange
        self.title = textTitle
    }

    private var index: Int { options.firstIndex(of: selection) ?? 0 }
    private var rangePositions: [Int] {
        guard options.count > 21 else { return Array(options.indices) }
        return (0...20).map { Int((Double($0) * Double(options.count - 1) / 20).rounded()) }
    }
    private var canDecrement: Bool { !options.isEmpty && (wraps || index > 0) }
    private var canIncrement: Bool { !options.isEmpty && (wraps || index < options.count - 1) }

    private func stepped(by delta: Int) -> Value? {
        guard !options.isEmpty else { return nil }
        let count = options.count
        if wraps {
            return options[((index + delta) % count + count) % count]
        }
        let target = index + delta
        guard options.indices.contains(target) else { return nil }
        return options[target]
    }

    private var buttonSize: CGFloat { compact ? 46 : 72 }
    private var glyphSize: CGFloat { compact ? 16 : 26 }
    private var rowSpacing: CGFloat { compact ? 12 : 24 }
    private var valueMinWidth: CGFloat {
        #if os(tvOS)
        64
        #else
        compact ? 52 : 96
        #endif
    }
    private var valueFont: Font {
        #if os(tvOS)
        SettingsRowMetrics.titleFont.weight(.regular)
        #else
        compact ? .body : .headline.weight(.semibold)
        #endif
    }

    public var body: some View {
        #if os(tvOS)
        SettingsAdjustmentFocusScope(
            content: televisionControl,
            screen: options,
            adjustableRow: { isFocused ? 0 : nil },
            onMove: { direction, _ in
                switch direction {
                case .left: step(by: -1)
                case .right: step(by: 1)
                default: break
                }
            }
        )
        .fixedSize(horizontal: label == nil, vertical: true)
        .onChange(of: isFocused) { _, focused in onFocusChange?(focused) }
        #else
        if let label {
            LabeledSettingRow(label, subtitle: subtitle, labelWidth: labelWidth) {
                buttonPair
            }
        } else {
            buttonPair
        }
        #endif
    }

    #if !os(tvOS)
    private var buttonPair: some View {
        HStack(spacing: rowSpacing) {
            stepButton(symbol: "minus", dimmed: !canDecrement, focus: .minus) {
                if let next = stepped(by: -1) { selection = next }
            }

            value
                .animation(.easeOut(duration: 0.16), value: index)

            stepButton(symbol: "plus", dimmed: !canIncrement, focus: .plus) {
                if let next = stepped(by: 1) { selection = next }
            }
        }
        .fixedSize()
        // Report focus entering/leaving the stepper as a whole (either button) so
        // a caller can drive a live preview while the value is being dialed.
        .onChange(of: focusedButton) { _, focused in
            onFocusChange?(focused != nil)
        }
    }
    #endif

    private func step(by delta: Int) {
        if let next = stepped(by: delta) { selection = next }
    }

    #if os(tvOS)
    @ViewBuilder private var televisionControl: some View {
        if label != nil {
            televisionButton
                .buttonStyle(SettingsFormButtonStyle())
                .padding(.leading, flushLeading ? -SettingsRowMetrics.horizontalPadding : 0)
        } else {
            televisionButton
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var televisionButton: some View {
        Button { step(by: 1) } label: {
            if let label {
                if compact && rangeLabels != nil && !inlineRange {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(label).font(SettingsRowMetrics.titleFont)
                        if let subtitle {
                            Text(subtitle).font(SettingsRowMetrics.helperFont).settingsRowSecondary()
                        }
                        adjustmentValue
                    }
                    .padding(.horizontal, SettingsRowMetrics.verticalPadding(.primary) - SettingsRowMetrics.horizontalPadding)
                } else {
                    LabeledSettingRow(
                        label, subtitle: subtitle, labelWidth: labelWidth, trailingAlignment: .trailing
                    ) {
                        adjustmentValue
                    }
                }
            } else {
                adjustmentValue
            }
        }
        .focused($isFocused)
        .disabled(options.isEmpty)
        .accessibilityLabel(label.map(Text.init) ?? title(selection))
        .accessibilityValue(title(selection))
        .accessibilityHint(subtitle.map(Text.init) ?? Text(verbatim: ""))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .decrement: step(by: -1)
            case .increment: step(by: 1)
            @unknown default: break
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: index)
    }

    @ViewBuilder private var adjustmentValue: some View {
        if rangeLabels != nil, inlineRange {
            HStack(spacing: 12) {
                adjustmentGlyph("minus", enabled: canDecrement)
                HStack(spacing: 4) {
                    ForEach(rangePositions, id: \.self) { position in
                        Capsule()
                            .fill(.primary.opacity(position <= index ? 1 : 0.2))
                            .frame(height: position == options.count / 2 ? 10 : 6)
                    }
                }
                .frame(width: 180)
                adjustmentGlyph("plus", enabled: canIncrement)
            }
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
        } else if let rangeLabels {
            HStack(alignment: .top, spacing: 12) {
                adjustmentGlyph("minus", enabled: canDecrement)
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        ForEach(rangePositions, id: \.self) { position in
                            Capsule()
                                .fill(.primary.opacity(position <= index ? 1 : 0.2))
                                .frame(height: 6)
                        }
                    }
                    .frame(height: SettingsRowMetrics.minHeight(.secondary))
                    HStack {
                        Text(rangeLabels.0)
                        Spacer()
                        Text(rangeLabels.1)
                    }
                    .overlay {
                        if let rangeMidpointLabel { Text(rangeMidpointLabel) }
                    }
                    .font(.caption)
                }
                adjustmentGlyph("plus", enabled: canIncrement)
            }
            .frame(minWidth: compact ? 300 : 380, maxWidth: compact ? .infinity : 380)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityHidden(true)
        } else {
            HStack(spacing: compact ? 12 : 16) {
                adjustmentGlyph("minus", enabled: canDecrement)
                value
                    .environment(\.layoutDirection, layoutDirection)
                adjustmentGlyph("plus", enabled: canIncrement)
            }
            // Keep the physical arrows consistent while the enclosing row follows RTL.
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    private func adjustmentGlyph(_ symbol: String, enabled: Bool) -> some View {
        Image(systemName: symbol)
            .font(SettingsRowMetrics.titleFont.weight(.semibold))
            .frame(width: 32, height: SettingsRowMetrics.minHeight(.secondary))
            .opacity(enabled ? 1 : 0.35)
            .accessibilityHidden(true)
    }
    #endif

    private var value: some View {
        ZStack {
            // Reserve the widest option without exposing hidden sizing labels to VoiceOver.
            ForEach(options.indices, id: \.self) { i in
                valueLabel(title(options[i])).hidden().accessibilityHidden(true)
            }
            valueLabel(title(selection))
                .transaction { $0.animation = nil }
        }
        .frame(minWidth: valueMinWidth)
    }

    private func valueLabel(_ text: Text) -> some View {
        text
            .font(valueFont)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            #if !os(tvOS)
            .foregroundStyle(palette.primaryText)
            #endif
    }

    private func stepButton(symbol: String, dimmed: Bool, focus: StepperButton, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .semibold))
                .frame(width: buttonSize, height: buttonSize)
                // Dim the glyph at the ends, but keep the button focusable so the
                // left-exit point stays consistent (always the − button).
                .opacity(dimmed ? 0.35 : 1)
        }
        .buttonStyle(StepperButtonStyle())
        .focused($focusedButton, equals: focus)
    }
}

/// Round step button mirroring the segmented picker's theme-aware focus thumb:
/// a subtle neutral chip at rest, the bright inverted thumb (white-on-dark /
/// black-on-light) when focused. Public so compact ± steppers built outside this
/// component (e.g. the in-player subtitle-sync control) share the exact look.
public struct StepperButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        StepperButtonBody(configuration: configuration)
    }

    private struct StepperButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.themePalette) private var palette

        private var fill: Color {
            if isFocused { return colorScheme == .dark ? .white : .black }
            return palette.primaryText.opacity(0.14)
        }
        private var foreground: Color {
            if isFocused { return colorScheme == .dark ? .black : .white }
            return palette.primaryText
        }

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .background(
                    Circle()
                        .fill(fill)
                        .shadow(
                            color: .black.opacity(isFocused ? 0.25 : 0),
                            radius: isFocused ? 8 : 0,
                            y: isFocused ? 3 : 0
                        )
                )
                .scaleEffect(configuration.isPressed ? 0.94 : (isFocused ? 1.08 : 1.0))
                .animation(.easeOut(duration: 0.16), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
#endif
