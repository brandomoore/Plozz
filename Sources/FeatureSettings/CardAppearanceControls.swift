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
            CardCaptionPicker(selection: $settings.preference, style: style)
            ViewCustomizationLink(count: settings.overrides.count) {
                CardCaptionCustomizationContent(settings: $settings)
            }
            .accessibilityIdentifier("card-label-customization")
            if !settings.overrides.isEmpty {
                ViewCustomizationResetButton(isEnabled: true) { settings.resetOverrides() }
                    .accessibilityIdentifier("card-label-remove-customizations")
            }
        }
    }
}

private struct CardCaptionPicker: View {
    @Binding var selection: CardCaptionPreference
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
                    isSelected: selection == preference,
                    accent: palette.accent,
                    compact: true,
                    swatchHeight: swatchHeight,
                    titleLineLimit: nil,
                    titleSizeGroup: CardCaptionPreference.allCases.map(\.displayName),
                    action: { selection = preference }
                ) {
                    CardStyleSwatch(
                        style: style,
                        showsCaptions: preference != .hide,
                        showsMixedCaptions: preference == .recommended
                    )
                        .accessibilityHidden(true)
                }
                .accessibilityAddTraits(selection == preference ? .isSelected : [])
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
        CardCaptionCustomizationContent(settings: $cards.captions)
    }
}

struct CardCaptionCustomizationContent: View {
    @Binding var settings: CardCaptionSettings
    var selection: Binding<String?>? = nil

    var body: some View {
        #if os(tvOS)
        SettingsSplitLayout(
            title: "Labels by view",
            rows: CardCaptionView.customizableCases.map { view in
                SettingsSplitRow(
                    id: view.rawValue,
                    title: view.displayName,
                    description: "Choices apply across all libraries. Titles inside collections and playlists use Browse.",
                    sectionStart: view == .recommended ? .heading(Text("Libraries"))
                        : view == .search ? .heading(Text("Other views")) : nil
                ) {
                    CardCaptionViewChoices(view: view, settings: $settings)
                }
            } + [
                SettingsSplitRow(id: "reset", title: "Remove view customizations", sectionStart: .divider) {
                    ViewCustomizationResetButton(isEnabled: !settings.overrides.isEmpty) { settings.resetOverrides() }
                        .accessibilityIdentifier("card-label-remove-customizations")
                }
            ],
            selection: selection
        )
        #else
        List {
            ForEach(CardCaptionView.customizableCases, id: \.rawValue) { view in
                SettingsSectionGroup(view.displayName) {
                    CardCaptionViewChoices(view: view, settings: $settings)
                }
            }
            SettingsSectionGroup {
                ViewCustomizationResetButton(isEnabled: !settings.overrides.isEmpty) { settings.resetOverrides() }
                    .accessibilityIdentifier("card-label-remove-customizations")
            } footer: {
                Text("Choices apply across all libraries. Titles inside collections and playlists use Browse.")
            }
        }
        .settingsPageSurface()
        .navigationTitle("Labels by view")
        #endif
    }

}

struct CardCaptionViewChoices: View {
    let view: CardCaptionView
    @Binding var settings: CardCaptionSettings

    var body: some View {
        ViewPreferenceChoiceGroup {
            ForEach(CardCaptionOverride.allCases) { option in
                ViewPreferenceChoiceRow(
                    title: option == .automatic ? "Use default" : option.displayName,
                    isSelected: settings.override(for: view) == option
                ) {
                    settings.setOverride(option, for: view)
                }
                .accessibilityIdentifier("card-label-view-\(view.rawValue)-\(option.rawValue)")
            }
        }
    }

}
#endif
