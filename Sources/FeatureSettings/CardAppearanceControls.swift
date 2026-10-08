#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct CardAppearanceControls: View {
    @Bindable private var cards: CardStyleSettingsModel
    @Bindable private var watchIndicator: WatchStatusIndicatorSettingsModel

    public init(cards: CardStyleSettingsModel, watchIndicator: WatchStatusIndicatorSettingsModel) {
        self.cards = cards
        self.watchIndicator = watchIndicator
    }

    public var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            SettingsDetailGroup(title: "Labels") {
                CardLabelControls(settings: $cards.captions, style: cards.style)
            }
            SettingsDetailGroup(title: "Watched Indicator") {
                CompactWatchIndicatorPicker(selection: $watchIndicator.indicator, swatchHeight: 150)
            }
            SettingsDetailGroup(
                title: LocalizedStringResource(
                    "settings.cards.focus",
                    defaultValue: "Focus",
                    comment: "Section header in tvOS Settings > Appearance > Cards, above the picker that chooses what a media card does when the remote's focus lands on it. Not camera focus and not a concentration/Focus mode — this is the on-screen selection highlight."
                )
            ) {
                CompactCardFocusStylePicker(selection: $cards.focusStyle, swatchHeight: 150)
            }
            SettingsDetailGroup(title: "Style") {
                CompactCardStylePicker(selection: $cards.style, swatchHeight: 150)
            }
        }
        #else
        List {
            SettingsSectionGroup("Labels") {
                CardLabelControls(settings: $cards.captions, style: cards.style)
            }
            SettingsSectionGroup("Watched Indicator") {
                CompactWatchIndicatorPicker(selection: $watchIndicator.indicator, swatchHeight: 112)
            }
            SettingsSectionGroup("Style") {
                CompactCardStylePicker(selection: $cards.style, swatchHeight: 112)
            }
        }
        .settingsPageSurface()
        .navigationTitle("Cards")
        #endif
    }

}

struct CardLabelControls: View {
    @Binding var settings: CardCaptionSettings
    let style: CardStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            CardCaptionPicker(settings: $settings, style: style)
            ViewCustomizationLink(isCustomized: settings.selectedPreset == nil) {
                CardCaptionCustomizationContent(settings: $settings, style: style)
            }
            .accessibilityIdentifier("card-label-customization")
        }
    }
}

private struct CardCaptionPicker: View {
    @Binding var settings: CardCaptionSettings
    let style: CardStyle
    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize || horizontalSizeClass == .compact
            ? AnyLayout(VStackLayout(spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            ForEach(CardCaptionPreference.allCases) { preference in
                PreviewCard(
                    title: preference.displayName,
                    isSelected: settings.selectedPreset == preference,
                    accent: palette.accent,
                    compact: true,
                    swatchHeight: swatchHeight,
                    titleLineLimit: nil,
                    titleSizeGroup: CardCaptionPreference.allCases.map(\.displayName),
                    action: { settings.applyPreset(preference) }
                ) {
                    CardStyleSwatch(
                        style: style,
                        showsCaptions: preference != .hide,
                        showsMixedCaptions: preference == .recommended
                    )
                        .accessibilityHidden(true)
                }
                .accessibilityAddTraits(settings.selectedPreset == preference ? .isSelected : [])
                .accessibilityIdentifier(preference == .recommended ? "card-labels-recommended"
                                         : preference == .show ? "card-labels-on" : "card-labels-off")
            }
        }
    }

    private var swatchHeight: CGFloat {
        #if os(tvOS)
        150
        #else
        112
        #endif
    }
}

public struct CardCaptionCustomizationView: View {
    @Bindable private var cards: CardStyleSettingsModel

    public init(cards: CardStyleSettingsModel) { self.cards = cards }

    public var body: some View {
        CardCaptionCustomizationContent(settings: $cards.captions, style: cards.style)
    }
}

struct CardCaptionCustomizationContent: View {
    @Binding var settings: CardCaptionSettings
    var style: CardStyle = .borderless

    var body: some View {
        ViewCustomizationList(
            title: "Labels by view", initialRowID: "card-label-view-home",
            focusedHelp: { id in
                CardCaptionView.allCases.first { "card-label-view-\($0.rawValue)" == id }
                    .map { settings.customizationHelp(in: $0, style: style) }
            }
        ) {
            CardCaptionViewChoices(view: .home, settings: $settings)
            Section {
                ForEach(CardCaptionView.customizableCases.filter(\.isLibraryView), id: \.rawValue) { view in
                    CardCaptionViewChoices(view: view, settings: $settings)
                }
            } header: {
                Text("Libraries")
                    #if os(tvOS)
                    .settingsSectionHeader()
                    .padding(.top, 20)
                    .padding(.bottom, 6)
                    #endif
            }
            Section {
                ForEach(CardCaptionView.customizableCases.filter { $0 != .home && !$0.isLibraryView }, id: \.rawValue) { view in
                    CardCaptionViewChoices(view: view, settings: $settings)
                }
            } header: {
                Text("Other views")
                    #if os(tvOS)
                    .settingsSectionHeader()
                    .padding(.top, 20)
                    .padding(.bottom, 6)
                    #endif
            }
            Text("Choices apply across all libraries. Titles inside collections and playlists use Browse.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

}

struct CardCaptionViewChoices: View {
    let view: CardCaptionView
    @Binding var settings: CardCaptionSettings

    var body: some View {
        ViewCustomizationRow(
            id: "card-label-view-\(view.rawValue)",
            title: view.displayName,
            value: settings.customizationValue(in: view),
            detail: settings.customizationDetail(in: view)
        ) { settings.toggleCustomization(in: view) }
    }
}

extension CardCaptionSettings {
    func customizationHelp(in view: CardCaptionView, style: CardStyle) -> ViewCustomizationHelp {
        let mixedDetail = customizationDetail(in: view)
        return ViewCustomizationHelp(
            detail: mixedDetail ?? "Labels are separate from any text already in the artwork.",
            illustration: .captions(
                style: style, showsCaptions: showsLabels(in: view),
                showsMixedCaptions: mixedDetail != nil
            )
        )
    }

    func customizationValue(in view: CardCaptionView) -> LocalizedStringResource {
        if preference == .recommended, overrides[view] == nil, view == .home || view == .recommended {
            return LocalizedStringResource(
                "cardLabels.mixed", defaultValue: "Mixed",
                comment: "Per-view label value: labels are shown except in Showcase and on series artwork."
            )
        }
        return showsLabels(in: view)
            ? LocalizedStringResource("cardLabels.on", defaultValue: "On", comment: "Per-view setting: show card labels.")
            : LocalizedStringResource("cardLabels.off", defaultValue: "Off", comment: "Per-view setting: hide card labels.")
    }

    func customizationDetail(in view: CardCaptionView) -> LocalizedStringResource? {
        if preference == .recommended, overrides[view] == nil, view == .home || view == .recommended {
            return "Labels are hidden in Showcase and on series artwork."
        }
        return nil
    }
}

private extension CardCaptionView {
    var isLibraryView: Bool {
        switch self {
        case .recommended, .browse, .collections, .playlists: true
        default: false
        }
    }
}
#endif
