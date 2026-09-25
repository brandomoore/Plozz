#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

public struct MobileSubtitleStyleEditor: View {
    let viewModel: SubtitleStyleEditingContext
    @Environment(\.locale) private var locale
    @State private var systemStyleConfirmation = SystemCaptionStyleConfirmation()

    public init(viewModel: SubtitleStyleEditingContext) { self.viewModel = viewModel }

    public var body: some View {
        Form {
            Section {
                Toggle(
                    "Use System Caption Style",
                    isOn: Binding(
                        get: { viewModel.controls.subtitleStyle.followsSystemStyle },
                        set: { enabled in
                            systemStyleConfirmation.request(
                                enabled, currentlyMatching: viewModel.controls.subtitleStyle.followsSystemStyle
                            ) { value in viewModel.editSubtitleStyle { $0.followsSystemStyle = value } }
                        }
                    )
                )
            } footer: {
                Text("Matching shows the current values from Settings › Accessibility › Subtitles & Captioning. Editing a value keeps this appearance and turns matching off.")
            }

            Section("Text") {
                NavigationLink {
                    MobileSubtitleFontView(viewModel: viewModel)
                } label: {
                    LabeledContent(
                        "Font",
                        value: viewModel.effectiveStyle.fontDisplayName
                    )
                }

                Picker(
                    "Weight",
                    selection: subtitleWeightBinding(viewModel)
                ) {
                    if viewModel.effectiveStyle.fontDescriptor != nil {
                        Text(verbatim: viewModel.effectiveStyle.fontWeightDisplayName).tag(Optional<SubtitleFontWeight>.none)
                    }
                    ForEach(
                        viewModel.effectiveStyle.availableFontWeights,
                        id: \.self
                    ) {
                        Text($0.displayName).tag(Optional($0))
                    }
                }
                MobileSubtitleSliderRow(
                    title: "Text Size",
                    value: subtitleStyleBinding(viewModel, \.fontScale),
                    range: SubtitleStyle.fontScaleRange,
                    step: SubtitleStyle.fontScaleStep,
                    formattedValue: {
                        $0.formatted(.percent.precision(.fractionLength(0...3)))
                    }
                )
                MobileSubtitleSliderRow(
                    title: "Position",
                    value: subtitleStyleBinding(viewModel, \.verticalPosition),
                    range: SubtitleStyle.verticalPositionRange,
                    step: SubtitleStyle.verticalPositionStep,
                    formattedValue: {
                        $0.formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
                    }
                )
                Picker(selection: subtitleStyleBinding(viewModel, \.verticalAnchor)) {
                    ForEach(SubtitleStyle.VerticalAnchor.allCases, id: \.self) { anchor in
                        Text(anchor.displayName).tag(anchor)
                    }
                } label: {
                    Text(
                        "Extra Line Position",
                        comment: "Subtitle setting for where additional wrapped lines appear: Above, Center, or Below. Not the placement of a second-language subtitle track."
                    )
                }
                MobileSubtitleSliderRow(
                    title: "Horizontal Offset",
                    value: subtitleStyleBinding(viewModel, \.horizontalOffset),
                    range: -1...1,
                    step: 0.05,
                    formattedValue: {
                        let percent = Int(($0 * 100).rounded())
                        return percent == 0
                            ? "Center"
                            : "\(percent > 0 ? "+" : "")\(percent)%"
                    }
                )
                subtitleColorPicker(
                    "Text Color", viewModel: viewModel, keyPath: \.textColor, options: SubtitleColor.presets
                )
                MobileSubtitleSliderRow(
                    title: "Text Opacity",
                    value: subtitleColorAlphaBinding(viewModel, \.textColor),
                    range: 0...1, step: 0.05,
                    formattedValue: { $0.formatted(.percent.precision(.fractionLength(0...3))) }
                )
                MobileSubtitleSliderRow(
                    title: "Overall Opacity",
                    value: subtitleStyleBinding(viewModel, \.opacity),
                    range: 0.2...1, step: 0.05,
                    formattedValue: { $0.formatted(.percent.precision(.fractionLength(0...3))) }
                )
                if viewModel.controls.subtitlesRenderHDR {
                    MobileSubtitleSliderRow(
                        title: "HDR Brightness",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.hdrLuminanceScale
                        ),
                        range: 0.2...1,
                        step: 0.05,
                        formattedValue: {
                            "\((100 * $0).rounded().formatted())%"
                        }
                    )
                }
            }

            Section("Details") {
                NavigationLink("Shadow & Outline") {
                    MobileSubtitleShadowOutlineView(viewModel: viewModel)
                }
                NavigationLink {
                    MobileSubtitleBackgroundView(viewModel: viewModel)
                } label: {
                    LabeledContent(
                        "Background",
                        value: viewModel.effectiveStyle.background.isEnabled || viewModel.effectiveStyle.glyphBackground.alpha > 0
                            ? "On"
                            : "Off"
                    )
                }
                NavigationLink {
                    MobileSubtitleDualView(viewModel: viewModel)
                } label: {
                    LabeledContent(
                        "Dual Subtitles",
                        value: viewModel.hasSecondarySubtitle ? "On" : "Off"
                    )
                }
                NavigationLink("Subtitle file formatting") {
                    MobileSubtitleFileFormattingView(viewModel: viewModel)
                }
            }

            Section {
                Button("Reset to Default", role: .destructive) {
                    viewModel.applySubtitleStyle(.profileDefault)
                }
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(SystemCaptionStyleConfirmationDialog(
            confirmation: systemStyleConfirmation,
            apply: { enabled in viewModel.editSubtitleStyle { $0.followsSystemStyle = enabled } }
        ))
    }
}

private struct MobileSubtitleFileFormattingView: View {
    let viewModel: SubtitleStyleEditingContext

    var body: some View {
        Form {
            Section {
                Toggle("Use File Positions", isOn: subtitleStyleBinding(viewModel, \.usesSourcePosition))
                Toggle("Use File Colors", isOn: subtitleStyleBinding(viewModel, \.usesSourceColors))
                Toggle("Use Bold and Italic", isOn: subtitleStyleBinding(viewModel, \.usesSourceEmphasis))
            } footer: {
                Text("Some subtitle files specify colors, bold or italic text, or where a line should appear. Turn these off to use your chosen style instead.")
            }
        }
        .navigationTitle("Subtitle file formatting")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileSubtitleFontView: View {
    let viewModel: SubtitleStyleEditingContext

    var body: some View {
        List {
            ForEach(SubtitleFontFamily.allCases, id: \.self) { family in
                Button {
                    viewModel.editSubtitleStyle {
                        $0.fontFamily = family
                        $0.systemFont = nil
                        $0.fontDescriptor = nil
                        $0.fontWeight = $0.fontWeight.snapped(to: family.availableWeights)
                    }
                } label: {
                    HStack {
                        Text(family.displayName)
                            .font(subtitlePreviewFont(for: family))
                        Spacer()
                        if viewModel.effectiveStyle.fontDescriptor == nil,
                           viewModel.effectiveStyle.systemFont == nil, family ==
                            viewModel.effectiveStyle.fontFamily {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            NavigationLink("System") {
                List {
                    ForEach(SubtitleSystemFonts.all) { entry in
                        Button {
                            viewModel.editSubtitleStyle {
                                $0.systemFont = entry.id
                                $0.fontDescriptor = nil
                            }
                        } label: {
                            HStack {
                                Text(verbatim: entry.name).font(entry.preview)
                                Spacer()
                                if viewModel.effectiveStyle.systemFont == entry.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                .navigationTitle("System")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileSubtitleShadowOutlineView: View {
    let viewModel: SubtitleStyleEditingContext
    private let shadowStyles: [SubtitleEdgeStyle] = [
        .none, .dropShadow, .raised, .depressed, .uniform
    ]

    var body: some View {
        Form {
            Section {
                Picker(
                    "Style",
                    selection: subtitleStyleBinding(viewModel, \.edge.style)
                ) {
                    ForEach(shadowStyles, id: \.self) {
                        Text($0 == viewModel.effectiveStyle.edge.style
                             ? SubtitleStyleEditorValues.edgeName(viewModel.effectiveStyle) : $0.displayName).tag($0)
                    }
                }
                subtitleColorPicker(
                    "Color", viewModel: viewModel, keyPath: \.edge.color, options: SubtitleColor.presets
                )
                MobileSubtitleSliderRow(
                    title: "Thickness",
                    value: subtitleStyleBinding(viewModel, \.edge.thickness),
                    range: 0...10, step: 1,
                    formattedValue: { $0.formatted(.number.precision(.fractionLength(0...3))) }
                )
            } header: {
                Text("Text Edge")
            } footer: {
                Text("Apple supplies the edge style, including Uniform Outline, but not its color or thickness. Those are Plozz rendering values.")
            }

            Section("Outline") {
                Toggle(
                    "Show Outline",
                    isOn: subtitleStyleBinding(
                        viewModel,
                        \.border.isEnabled
                    )
                )
                subtitleColorPicker(
                    "Color", viewModel: viewModel, keyPath: \.border.color, options: SubtitleColor.presets
                )
                MobileSubtitleSliderRow(
                    title: "Width",
                    value: subtitleStyleBinding(viewModel, \.border.width),
                    range: 0...10, step: 0.5,
                    formattedValue: { $0.formatted(.number.precision(.fractionLength(0...3))) }
                )
            }
        }
        .navigationTitle("Shadow & Outline")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileSubtitleBackgroundView: View {
    let viewModel: SubtitleStyleEditingContext
    private let backgroundColors: [(name: String, color: SubtitleColor)] = [
        ("Black", .black),
        (
            "Dark Gray",
            SubtitleColor(red: 0.15, green: 0.15, blue: 0.15)
        ),
        ("White", .white)
    ]

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Show Window",
                    isOn: subtitleStyleBinding(
                        viewModel,
                        \.background.isEnabled
                    )
                )
            }

                Section {
                    subtitleColorPicker(
                        "Color",
                        viewModel: viewModel,
                        keyPath: \.background.color,
                        options: backgroundColors
                    )
                    MobileSubtitleSliderRow(
                        title: "Opacity",
                        value: subtitleColorAlphaBinding(
                            viewModel,
                            \.background.color
                        ),
                        range: 0...1,
                        step: 0.05,
                        formattedValue: {
                            $0.formatted(.percent.precision(.fractionLength(0...3)))
                        }
                    )
                    MobileSubtitleSliderRow(
                        title: "Corner Radius",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.background.cornerRadius
                        ),
                        range: 0...50,
                        step: 2,
                        formattedValue: {
                            "\($0.formatted(.number.precision(.fractionLength(0...3)))) pt"
                        }
                    )
                    MobileSubtitleSliderRow(
                        title: "Horizontal Padding (Plozz)",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.background.horizontalPadding
                        ),
                        range: 0...40,
                        step: 2,
                        formattedValue: {
                            "\($0.rounded().formatted()) pt"
                        }
                    )
                    MobileSubtitleSliderRow(
                        title: "Vertical Padding (Plozz)",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.background.verticalPadding
                        ),
                        range: 0...40,
                        step: 2,
                        formattedValue: {
                            "\($0.rounded().formatted()) pt"
                        }
                    )
                } header: {
                    Text("Window")
                } footer: {
                    Text("Window padding is set by Plozz. Apple does not expose caption padding or line spacing.")
                }
            Section("Line Background") {
                subtitleColorPicker("Color", viewModel: viewModel, keyPath: \.glyphBackground, options: SubtitleColor.presets)
                MobileSubtitleSliderRow(
                    title: "Opacity",
                    value: subtitleColorAlphaBinding(viewModel, \.glyphBackground),
                    range: 0...1, step: 0.05,
                    formattedValue: { $0.formatted(.percent.precision(.fractionLength(0...3))) }
                )
            }
        }
        .navigationTitle("Background")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileSubtitleDualView: View {
    let viewModel: SubtitleStyleEditingContext

    var body: some View {
        Form {
            Section("Second Track") {
                if let preview = viewModel.secondaryPreview {
                    Toggle("Show second subtitle", isOn: preview)
                    Text("This changes the preview only. Choose subtitle tracks while watching.")
                        .plozzForeground(.secondary)
                } else if let format =
                    viewModel.controls.secondarySubtitleImagePrimaryFormat {
                    Text("Unavailable with \(format) image subtitles.")
                        .plozzForeground(.secondary)
                } else if viewModel.controls.secondarySubtitleOptions.isEmpty {
                    Text("No additional text tracks are available.")
                        .plozzForeground(.secondary)
                } else {
                    ForEach(
                        viewModel.controls.secondarySubtitleOptions
                    ) { option in
                        Button {
                            viewModel.selectSecondarySubtitleOption(id: option.id)
                        } label: {
                            HStack {
                                option.title
                                Spacer()
                                if option.isSelected {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            if viewModel.hasSecondarySubtitle,
               viewModel.effectiveStyle.secondary != nil {
                Section("Layout") {
                    Picker(
                        "Placement",
                        selection: subtitleStyleBinding(
                            viewModel,
                            \.secondary!.placement
                        )
                    ) {
                        Text("Above").tag(
                            SubtitleStyle.Secondary.Placement.above
                        )
                        Text("Below").tag(
                            SubtitleStyle.Secondary.Placement.below
                        )
                    }
                    Toggle(
                        "Distinct Style",
                        isOn: subtitleStyleBinding(
                            viewModel,
                            \.secondary!.differentiate
                        )
                    )
                    if viewModel.effectiveStyle.secondary?
                        .differentiate == true {
                        MobileSubtitleSliderRow(
                            title: "Size",
                            value: subtitleStyleBinding(
                                viewModel,
                                \.secondary!.relativeScale
                            ),
                            range: 0.5...1,
                            step: 0.05,
                            formattedValue: {
                                "\((100 * $0).rounded().formatted())%"
                            }
                        )
                        subtitleColorPicker(
                            "Color",
                            viewModel: viewModel,
                            keyPath: \.secondary!.textColor,
                            options: SubtitleColor.presets
                        )
                    }
                    MobileSubtitleSliderRow(
                        title: "Gap",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.secondary!.gap
                        ),
                        range: 0...24,
                        step: 2,
                        formattedValue: {
                            "\($0.rounded().formatted()) pt"
                        }
                    )
                }
            }
        }
        .navigationTitle("Dual Subtitles")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileSubtitleSliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formattedValue: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(formattedValue(value))
                    .plozzForeground(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { min(max(value, range.lowerBound), range.upperBound) },
                    set: { value = $0 }
                ),
                in: range, step: step
            )
        }
    }
}

@MainActor
private func subtitleStyleBinding<Value>(
    _ viewModel: SubtitleStyleEditingContext,
    _ keyPath: WritableKeyPath<SubtitleStyle, Value>
) -> Binding<Value> {
    Binding(
        get: {
            viewModel.effectiveStyle[keyPath: keyPath]
        },
        set: { value in
            viewModel.editSubtitleStyle { $0[keyPath: keyPath] = value }
        }
    )
}

@MainActor
private func subtitleColorAlphaBinding(
    _ viewModel: SubtitleStyleEditingContext,
    _ keyPath: WritableKeyPath<SubtitleStyle, SubtitleColor>
) -> Binding<Double> {
    Binding(
        get: {
            viewModel.effectiveStyle[keyPath: keyPath].alpha
        },
        set: { alpha in
            viewModel.editSubtitleStyle {
                $0[keyPath: keyPath].alpha = alpha
                if keyPath == \SubtitleStyle.background.color { $0.background.isEnabled = alpha > 0 }
            }
        }
    )
}

@MainActor
private func subtitleColorPicker(
    _ title: LocalizedStringKey,
    viewModel: SubtitleStyleEditingContext,
    keyPath: WritableKeyPath<SubtitleStyle, SubtitleColor>,
    options: [(name: String, color: SubtitleColor)]
) -> some View {
    var current = viewModel.effectiveStyle[keyPath: keyPath]
    current.alpha = 1
    return Picker(
        title,
        selection: Binding(
            get: {
                var color = viewModel.effectiveStyle[keyPath: keyPath]
                color.alpha = 1
                return color
            },
            set: { selected in
                viewModel.editSubtitleStyle {
                    var color = selected
                    color.alpha = $0[keyPath: keyPath].alpha
                    $0[keyPath: keyPath] = color
                }
            }
        )
    ) {
        if !options.contains(where: { $0.color == current }) {
            Text(verbatim: SubtitleStyleEditorValues.color(current)).tag(current)
        }
        ForEach(options, id: \.name) { option in
            Label {
                Text(option.name)
            } icon: {
                Circle()
                    .fill(
                        Color(
                            red: option.color.red,
                            green: option.color.green,
                            blue: option.color.blue
                        )
                    )
            }

            .tag(option.color)
        }
    }
}

@MainActor
private func subtitleWeightBinding(_ viewModel: SubtitleStyleEditingContext) -> Binding<SubtitleFontWeight?> {
    Binding(
        get: { viewModel.effectiveStyle.fontDescriptor == nil ? viewModel.effectiveStyle.fontWeight : nil },
        set: { weight in
            guard let weight else { return }
            viewModel.editSubtitleStyle { $0.selectFontWeight(weight) }
        }
    )
}

private func subtitlePreviewFont(
    for family: SubtitleFontFamily
) -> Font {
    let size: CGFloat = family == .openDyslexic ? 17 : 22
    if family.usesRoundedDesign {
        return .system(size: size, design: .rounded)
    }
    if let name = family.postScriptNameCandidates().first {
        return .custom(name, size: size)
    }
    return .system(size: size)
}

#endif
