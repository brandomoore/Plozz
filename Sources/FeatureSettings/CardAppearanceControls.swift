#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct CardAppearanceControls: View {
    @Bindable private var cards: CardStyleSettingsModel
    @Bindable private var watchIndicator: WatchStatusIndicatorSettingsModel
    private let density: UIDensitySettingsModel?

    public init(
        cards: CardStyleSettingsModel, watchIndicator: WatchStatusIndicatorSettingsModel,
        density: UIDensitySettingsModel? = nil
    ) {
        self.cards = cards
        self.watchIndicator = watchIndicator
        self.density = density
    }

    public var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            SettingsDetailGroup(title: "Labels", illustrated: true) {
                CardLabelControls(settings: $cards.captions, style: cards.style)
            }
            SettingsDetailGroup(title: "Watched Indicator", illustrated: true) {
                CompactWatchIndicatorPicker(selection: $watchIndicator.indicator, swatchHeight: 150)
                colorMenu
                episodeCountToggle
            }
            SettingsDetailGroup(
                title: LocalizedStringResource(
                    "settings.cards.focus",
                    defaultValue: "Focus",
                    comment: "Section header in tvOS Settings > Appearance > Cards, above the picker that chooses what a media card does when the remote's focus lands on it. Not camera focus and not a concentration/Focus mode — this is the on-screen selection highlight."
                ),
                illustrated: true
            ) {
                CompactCardFocusStylePicker(selection: $cards.focusStyle, swatchHeight: 150)
            }
            SettingsDetailGroup(title: "Style", illustrated: true) {
                CompactCardStylePicker(selection: $cards.style, swatchHeight: 150)
            }
            if let density {
                @Bindable var density = density
                SettingsDetailGroup(title: "Display Size", illustrated: true) {
                    CompactDisplaySizePicker(selection: $density.density)
                }
            }
        }
        #else
        List {
            SettingsSectionGroup("Labels") {
                CardLabelControls(settings: $cards.captions, style: cards.style)
            }
            SettingsSectionGroup("Watched Indicator") {
                CompactWatchIndicatorPicker(selection: $watchIndicator.indicator, swatchHeight: 112)
                colorMenu
                episodeCountToggle
            }
            SettingsSectionGroup("Style") {
                CompactCardStylePicker(selection: $cards.style, swatchHeight: 112)
            }
            if let density {
                @Bindable var density = density
                SettingsSectionGroup("Display Size") {
                    Picker("Display Size", selection: $density.density) {
                        ForEach(UIDensity.allCases) { density in
                            Label(density.displayName, systemImage: density.symbolName)
                                .tag(density)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("appearance-display-size")
                } footer: {
                    Text("Scales card size, columns and spacing across the app.")
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Cards")
        #endif
    }

    private var colorMenu: some View {
        SettingsMenuRow(title: "Color", value: Text(watchIndicator.color.displayName)) {
            Picker("Color", selection: $watchIndicator.color) {
                ForEach(WatchIndicatorColor.allCases) { color in
                    Text(color.displayName).tag(color)
                }
            }
        }
        .accessibilityIdentifier("watch-indicator-color")
    }

    private var episodeCountToggle: some View {
        Toggle("Show unwatched episode count", isOn: $watchIndicator.showsUnwatchedEpisodeCount)
            .accessibilityIdentifier("unwatched-episode-count-toggle")
    }
}

struct CardLabelControls: View {
    @Binding var settings: CardCaptionSettings
    let style: CardStyle

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            CardCaptionPicker(settings: $settings, style: style)
            ViewCustomizationLink(isCustomized: settings.selectedPreset == nil) {
                CardCaptionCustomizationContent(settings: $settings, style: style)
            }
            .accessibilityIdentifier("card-label-customization")
        }
    }

    private var spacing: CGFloat {
        #if os(tvOS)
        SettingsFormMetrics.illustratedGroupSpacing
        #else
        20
        #endif
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
            #if os(tvOS)
            CardCaptionViewChoices(view: .home, settings: $settings)
            CardCaptionViewChoices(view: .continueWatching, settings: $settings)
            #else
            Section("Home") {
                CardCaptionViewChoices(view: .home, settings: $settings)
                CardCaptionViewChoices(view: .continueWatching, settings: $settings)
            }
            #endif
            Section {
                ForEach(CardCaptionView.customizableCases.filter(\.isLibraryView), id: \.rawValue) { view in
                    CardCaptionViewChoices(view: view, settings: $settings)
                }
            } header: {
                Text("Libraries")
                    #if os(tvOS)
                    .settingsSectionHeader()
                    #endif
            }
            Section {
                ForEach(CardCaptionView.customizableCases.filter {
                    $0 != .home && $0 != .continueWatching && !$0.isLibraryView
                }, id: \.rawValue) { view in
                    CardCaptionViewChoices(view: view, settings: $settings)
                }
            } header: {
                Text("Other views")
                    #if os(tvOS)
                    .settingsSectionHeader()
                    #endif
            } footer: {
                Text("Choices apply across all libraries. Titles inside collections and playlists use Browse.")
            }
        }
    }

}

struct CardCaptionViewChoices: View {
    let view: CardCaptionView
    @Binding var settings: CardCaptionSettings
    var title: LocalizedStringResource?

    var body: some View {
        #if os(iOS)
        ViewCustomizationMenu(
            id: "card-label-view-\(view.rawValue)",
            title: title ?? view.displayName,
            value: settings.customizationValue(in: view),
            detail: settings.customizationDetail(in: view),
            selection: Binding(
                get: { settings.customization(in: view) },
                set: { settings.setOverride($0, for: view) }
            )
        ) {
            ForEach(view.customizationChoices) { choice in
                Text(view == .continueWatching && choice == .automatic
                    ? LocalizedStringResource("Follow Appearance") : choice.displayName).tag(choice)
            }
        }
        #else
        ViewCustomizationRow(
            id: "card-label-view-\(view.rawValue)",
            title: title ?? view.displayName,
            value: settings.customizationValue(in: view),
            detail: settings.customizationDetail(in: view)
        ) { settings.toggleCustomization(in: view) }
        #endif
    }
}

extension CardCaptionSettings {
    func customizationHelp(in view: CardCaptionView, style: CardStyle) -> ViewCustomizationHelp {
        let isContinueWatching = view == .continueWatching
        let parent = isContinueWatching ? CardCaptionView.home : view
        let showsCaptions = showsLabels(in: parent, isContinueWatching: isContinueWatching)
        let showsArtworkCaptions = showsLabels(
            in: parent, hasArtworkTitle: true, isContinueWatching: isContinueWatching
        )
        return ViewCustomizationHelp(
            detail: customizationDetail(in: view),
            illustration: .captions(
                style: style, showsCaptions: showsCaptions,
                showsMixedCaptions: customization(in: view) == .mixed
                    || (isContinueWatching && showsCaptions != showsArtworkCaptions)
            )
        )
    }

    func customizationValue(in view: CardCaptionView) -> LocalizedStringResource {
        if view == .continueWatching, customization(in: view) == .automatic {
            return "Follow Appearance"
        }
        return customization(in: view).displayName
    }

    func customizationDetail(in view: CardCaptionView) -> LocalizedStringResource {
        if view == .continueWatching {
            switch customization(in: view) {
            case .automatic: return "Uses Home rows or Recommended, depending on where the row appears."
            case .show: return "Labels are visible below Continue Watching artwork."
            case .hide: return "Labels are hidden below Continue Watching artwork."
            case .mixed: preconditionFailure("Continue Watching does not support mixed label overrides.")
            }
        }
        if customization(in: view) == .mixed {
            return "Labels are visible except in Showcase and on series artwork."
        }
        return showsLabels(in: view) ? "Labels are visible in this view." : "Labels are hidden in this view."
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
