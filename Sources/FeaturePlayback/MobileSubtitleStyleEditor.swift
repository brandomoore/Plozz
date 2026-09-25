#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

public struct MobileSubtitleStyleEditor: View {
    let viewModel: SubtitleStyleEditingContext
    @Environment(\.locale) private var locale

    public init(viewModel: SubtitleStyleEditingContext) { self.viewModel = viewModel }

    /// The device style decides the look (font, size, colours, box, edge) while
    /// it's followed, so only placement and HDR brightness stay editable here.
    private var followsSystemStyle: Bool { viewModel.controls.subtitleStyle.followsSystemStyle }

    public var body: some View {
        Form {
            Section {
                Toggle(
                    "Use System Caption Style",
                    isOn: subtitleStyleBinding(viewModel, \.followsSystemStyle)
                )
            } footer: {
                Text("Draw subtitles in the style set in Settings › Accessibility › Subtitles & Captioning.")
            }

            Section("Text") {
                if !followsSystemStyle {
                    NavigationLink {
                        MobileSubtitleFontView(viewModel: viewModel)
                    } label: {
                        LabeledContent(
                            "Font",
                            value: viewModel.controls.subtitleStyle.fontDisplayName
                        )
                    }

                    Picker(
                        "Weight",
                        selection: subtitleStyleBinding(viewModel, \.fontWeight)
                    ) {
                        ForEach(
                            viewModel.controls.subtitleStyle.availableFontWeights,
                            id: \.self
                        ) {
                            Text($0.displayName).tag($0)
                        }
                    }

                    MobileSubtitleSliderRow(
                        title: "Text Size",
                        value: subtitleStyleBinding(viewModel, \.fontScale),
                        range: SubtitleStyle.fontScaleRange,
                        step: SubtitleStyle.fontScaleStep,
                        formattedValue: {
                            "\((100 * $0).rounded().formatted())%"
                        }
                    )
                }
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
                if !followsSystemStyle {
                    subtitleColorPicker(
                        "Text Color",
                        viewModel: viewModel,
                        keyPath: \.textColor,
                        options: SubtitleColor.presets
                    )
                    MobileSubtitleSliderRow(
                        title: "Opacity",
                        value: subtitleStyleBinding(viewModel, \.opacity),
                        range: 0.2...1,
                        step: 0.05,
                        formattedValue: {
                            "\((100 * $0).rounded().formatted())%"
                        }
                    )
                }
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

            Section {
                Toggle(
                    "Use File Positions",
                    isOn: subtitleStyleBinding(viewModel, \.usesSourcePosition)
                )
                Toggle(
                    "Use File Colors",
                    isOn: subtitleStyleBinding(viewModel, \.usesSourceColors)
                )
            } header: {
                Text("From the Subtitle File")
            } footer: {
                Text("When a subtitle places or colors text itself, show it that way. Lines without their own placement or color use the settings above.")
            }

            Section("Details") {
                if !followsSystemStyle {
                    NavigationLink("Shadow & Outline") {
                        MobileSubtitleShadowOutlineView(viewModel: viewModel)
                    }
                    NavigationLink {
                        MobileSubtitleBackgroundView(viewModel: viewModel)
                    } label: {
                        LabeledContent(
                            "Background",
                            value: viewModel.controls.subtitleStyle.background.isEnabled
                                ? "On"
                                : "Off"
                        )
                    }
                }
                NavigationLink {
                    MobileSubtitleDualView(viewModel: viewModel)
                } label: {
                    LabeledContent(
                        "Dual Subtitles",
                        value: viewModel.hasSecondarySubtitle ? "On" : "Off"
                    )
                }
            }

            Section {
                Button("Reset to Default", role: .destructive) {
                    viewModel.applySubtitleStyle(.default)
                }
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MobileSubtitleFontView: View {
    let viewModel: SubtitleStyleEditingContext

    var body: some View {
        List {
            ForEach(SubtitleFontFamily.allCases, id: \.self) { family in
                Button {
                    var style = viewModel.controls.subtitleStyle
                    style.fontFamily = family
                    style.systemFont = nil
                    style.fontWeight = style.fontWeight.snapped(
                        to: family.availableWeights
                    )
                    viewModel.applySubtitleStyle(style)
                } label: {
                    HStack {
                        Text(family.displayName)
                            .font(subtitlePreviewFont(for: family))
                        Spacer()
                        if viewModel.controls.subtitleStyle.systemFont == nil, family ==
                            viewModel.controls.subtitleStyle.fontFamily {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            NavigationLink("System") {
                List {
                    ForEach(SubtitleSystemFonts.all) { entry in
                        Button {
                            var style = viewModel.controls.subtitleStyle
                            style.systemFont = entry.id
                            viewModel.applySubtitleStyle(style)
                        } label: {
                            HStack {
                                Text(verbatim: entry.name).font(entry.preview)
                                Spacer()
                                if viewModel.controls.subtitleStyle.systemFont == entry.id {
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
        .none, .dropShadow, .raised, .depressed
    ]

    var body: some View {
        Form {
            Section("Shadow") {
                Picker(
                    "Style",
                    selection: subtitleStyleBinding(viewModel, \.edge.style)
                ) {
                    ForEach(shadowStyles, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                if viewModel.controls.subtitleStyle.edge.style != .none {
                    subtitleColorPicker(
                        "Color",
                        viewModel: viewModel,
                        keyPath: \.edge.color,
                        options: SubtitleColor.presets
                    )
                    MobileSubtitleSliderRow(
                        title: "Thickness",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.edge.thickness
                        ),
                        range: 0...10,
                        step: 1,
                        formattedValue: { $0.rounded().formatted() }
                    )
                }
            }

            Section("Outline") {
                Toggle(
                    "Show Outline",
                    isOn: subtitleStyleBinding(
                        viewModel,
                        \.border.isEnabled
                    )
                )
                if viewModel.controls.subtitleStyle.border.isEnabled {
                    subtitleColorPicker(
                        "Color",
                        viewModel: viewModel,
                        keyPath: \.border.color,
                        options: SubtitleColor.presets
                    )
                    MobileSubtitleSliderRow(
                        title: "Width",
                        value: subtitleStyleBinding(
                            viewModel,
                            \.border.width
                        ),
                        range: 0...10,
                        step: 0.5,
                        formattedValue: {
                            $0.formatted(
                                .number.precision(.fractionLength(0...1))
                            )
                        }
                    )
                }
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
                    "Show Box",
                    isOn: subtitleStyleBinding(
                        viewModel,
                        \.background.isEnabled
                    )
                )
            }

            if viewModel.controls.subtitleStyle.background.isEnabled {
                Section("Box") {
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
                        range: 0.05...1,
                        step: 0.05,
                        formattedValue: {
                            "\((100 * $0).rounded().formatted())%"
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
                            "\($0.rounded().formatted()) pt"
                        }
                    )
                    MobileSubtitleSliderRow(
                        title: "Horizontal Padding",
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
                        title: "Vertical Padding",
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
                }
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
               viewModel.controls.subtitleStyle.secondary != nil {
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
                    if viewModel.controls.subtitleStyle.secondary?
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
            Slider(value: $value, in: range, step: step)
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
            viewModel.controls.subtitleStyle[keyPath: keyPath]
        },
        set: { value in
            var style = viewModel.controls.subtitleStyle
            style[keyPath: keyPath] = value
            viewModel.applySubtitleStyle(style)
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
            viewModel.controls.subtitleStyle[keyPath: keyPath].alpha
        },
        set: { alpha in
            var style = viewModel.controls.subtitleStyle
            style[keyPath: keyPath].alpha = alpha
            viewModel.applySubtitleStyle(style)
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
    Picker(
        title,
        selection: Binding(
            get: {
                let current =
                    viewModel.controls.subtitleStyle[keyPath: keyPath]
                return options.first {
                    $0.color.red == current.red
                        && $0.color.green == current.green
                        && $0.color.blue == current.blue
                }?.color ?? current
            },
            set: { selected in
                var style = viewModel.controls.subtitleStyle
                let alpha = style[keyPath: keyPath].alpha
                var color = selected
                color.alpha = alpha
                style[keyPath: keyPath] = color
                viewModel.applySubtitleStyle(style)
            }
        )
    ) {
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
