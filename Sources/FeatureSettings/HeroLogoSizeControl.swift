#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct HeroLogoSizeControl: View {
    @Binding private var size: HeroLogoSize
    private let textSize: Binding<HeroTextSize>?
    private let surface: HeroLogoSizing.Surface
    private let showsLibraryPreview: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        size: Binding<HeroLogoSize>, textSize: Binding<HeroTextSize>? = nil,
        surface: HeroLogoSizing.Surface, showsLibraryPreview: Bool = false
    ) {
        _size = size
        self.textSize = textSize
        self.surface = surface
        self.showsLibraryPreview = showsLibraryPreview
    }

    private var layout: HeroLogoSizing.Layout {
        #if os(tvOS)
        surface == .showcase ? .showcase : .television
        #else
        sizeClass == .compact ? .compact : .regular
        #endif
    }

    private var position: Binding<Int> {
        Binding(get: { size.position }, set: { size = HeroLogoSize.allSizes[$0] })
    }

    private var textPosition: Binding<Int>? {
        textSize.map { size in
            Binding(get: { size.wrappedValue.position }, set: { size.wrappedValue = HeroTextSize.allSizes[$0] })
        }
    }

    private var searchPrefix: String {
        if showsLibraryPreview { return "recommended" }
        switch surface {
        case .home: return "hero"
        case .showcase: return "showcase"
        case .detail: return "detail"
        }
    }

    private var preview: some View {
        HeroLogoSizePreview(
            size: size, surface: surface, layout: layout,
            textSize: textSize?.wrappedValue ?? .default, cornerRadius: 0
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: size)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: textSize?.wrappedValue)
    }

    public var body: some View {
        #if os(tvOS)
        HStack(spacing: SettingsFormMetrics.groupInset) {
            if surface == .detail || showsLibraryPreview {
                Color.clear
                    .frame(width: surface == .detail ? 400 : 320)
                    .frame(minHeight: surface == .detail ? 300 : 180)
                    .overlay {
                        preview
                            .aspectRatio(surface == .detail ? 4.0 / 3.0 : 16.0 / 9.0, contentMode: .fill)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: SettingsRowMetrics.formRowCornerRadius))
            }
            VStack(alignment: .leading, spacing: 8) {
                SettingsStepper(
                    options: Array(HeroLogoSize.allSizes.indices), selection: position, compact: true,
                    label: "Logo size", labelWidth: 160, rangeLabels: ("Small", "Large"),
                    inlineRange: true,
                    title: { $0 == HeroLogoSize.default.position ? "Default" : "\($0 + 1) of \(HeroLogoSize.allSizes.count)" }
                )
                .accessibilityIdentifier("logo-size-adjustment")
                .settingsSearchAnchor("\(searchPrefix)-logo-size")
                if let textPosition {
                    SettingsStepper(
                        options: Array(HeroTextSize.allSizes.indices), selection: textPosition, compact: true,
                        label: "Text size", labelWidth: 160, rangeLabels: ("Small", "Large"),
                        inlineRange: true,
                        title: {
                            $0 == HeroTextSize.default.position ? "Default" : "\($0 + 1) of \(HeroTextSize.allSizes.count)"
                        }
                    )
                    .accessibilityIdentifier("text-size-adjustment")
                    .settingsSearchAnchor("\(searchPrefix)-text-size")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .focusSection()
        .environment(\.settingsFormRowsFlushLeading, false)
        .accessibilityElement(children: .contain)
        #else
        VStack(alignment: .leading, spacing: 20) {
            preview
                .frame(maxWidth: 720)
                .clipShape(RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.content))
            slider(
                "Logo size", position: position, count: HeroLogoSize.allSizes.count,
                isDefault: size == .default, identifier: "logo-size-adjustment"
            )
            .settingsSearchAnchor("\(searchPrefix)-logo-size")
            if let textPosition {
                slider(
                    "Text size", position: textPosition, count: HeroTextSize.allSizes.count,
                    isDefault: textSize?.wrappedValue == .default, identifier: "text-size-adjustment"
                )
                .settingsSearchAnchor("\(searchPrefix)-text-size")
            }
        }
        .accessibilityElement(children: .contain)
        #endif
    }

    #if !os(tvOS)
    private func slider(
        _ label: LocalizedStringResource, position: Binding<Int>, count: Int,
        isDefault: Bool, identifier: String
    ) -> some View {
        HStack(spacing: 16) {
            Text(label).frame(minWidth: 80, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(position.wrappedValue) },
                    set: { position.wrappedValue = Int($0.rounded()) }
                ),
                in: 0...Double(count - 1), step: 1
            ) { Text(label) }
            .accessibilityValue(isDefault ? Text("Default") : Text("\(position.wrappedValue + 1) of \(count)"))
            .accessibilityIdentifier(identifier)
        }
    }
    #endif
}
#endif
