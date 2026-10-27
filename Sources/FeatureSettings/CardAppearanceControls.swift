#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct CardAppearanceControls: View {
    @Bindable private var cards: CardStyleSettingsModel
    @Bindable private var watchIndicator: WatchStatusIndicatorSettingsModel
    private let density: UIDensitySettingsModel?
    private let visibility: HomeLibraryVisibilityModel?

    public init(
        cards: CardStyleSettingsModel, watchIndicator: WatchStatusIndicatorSettingsModel,
        density: UIDensitySettingsModel? = nil, visibility: HomeLibraryVisibilityModel? = nil
    ) {
        self.cards = cards
        self.watchIndicator = watchIndicator
        self.density = density
        self.visibility = visibility
    }

    public var body: some View {
        controls
            .environment(\.plozzWatchIndicatorColor, watchIndicator.color)
            .environment(\.plozzShowsUnwatchedEpisodeCount, watchIndicator.showsUnwatchedEpisodeCount)
            .environment(\.plozzEpisodeCountBadgeStyle, watchIndicator.episodeCountStyle)
    }

    @ViewBuilder
    private var controls: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            SettingsDetailGroup(title: "Labels", illustrated: true) {
                CardLabelControls(settings: $cards.captions, style: cards.style, visibility: visibility)
            }
            SettingsDetailGroup(title: "Watched Indicator", illustrated: true) {
                CompactWatchIndicatorPicker(selection: $watchIndicator.indicator, swatchHeight: 150)
                WatchIndicatorColorPicker(selection: $watchIndicator.color)
                episodeCountToggle
                if watchIndicator.showsUnwatchedEpisodeCount { episodeCountStyleMenu }
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
                CardLabelControls(settings: $cards.captions, style: cards.style, visibility: visibility)
            }
            SettingsSectionGroup("Watched Indicator") {
                CompactWatchIndicatorPicker(selection: $watchIndicator.indicator, swatchHeight: 112)
                WatchIndicatorColorPicker(selection: $watchIndicator.color)
                episodeCountToggle
                if watchIndicator.showsUnwatchedEpisodeCount { episodeCountStyleMenu }
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

    private var episodeCountToggle: some View {
        Toggle("Show unwatched episode count", isOn: $watchIndicator.showsUnwatchedEpisodeCount)
            .accessibilityIdentifier("unwatched-episode-count-toggle")
    }

    private var episodeCountStyleMenu: some View {
        let title = LocalizedStringResource(
            "episodeCountStyle.label", defaultValue: "Episode count style",
            comment: "Settings control for choosing an attached or floating unwatched episode-count badge."
        )
        return SettingsMenuRow(title: title, value: Text(watchIndicator.episodeCountStyle.displayName)) {
            Picker(selection: $watchIndicator.episodeCountStyle) {
                ForEach(EpisodeCountBadgeStyle.allCases) { style in
                    Text(style.displayName)
                        .tag(style)
                        .accessibilityIdentifier("episode-count-style-\(style.rawValue)")
                }
            } label: { Text(title) }
            .pickerStyle(.inline)
        }
        .accessibilityIdentifier("episode-count-style")
    }
}

struct CardLabelControls: View {
    @Binding var settings: CardCaptionSettings
    let style: CardStyle
    var visibility: HomeLibraryVisibilityModel? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            CardCaptionPicker(settings: $settings, style: style)
            ViewCustomizationLink(isCustomized: settings.selectedPreset == nil, title: "Customize labels") {
                CardCaptionCustomizationContent(settings: $settings, style: style, visibility: visibility)
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

public enum CardCaptionSettingsScope: CaseIterable, Sendable {
    case all, home, libraries, detail

    public var views: [CardCaptionView] {
        switch self {
        case .all: CardCaptionView.allCases
        case .home: [.home, .continueWatching]
        case .libraries: [.recommended, .browse, .collections, .playlists, .continueWatching]
        case .detail: [.episodes, .related, .extras]
        }
    }
}

public struct CardCaptionSettingsLink: View {
    private let cards: CardStyleSettingsModel
    private let scope: CardCaptionSettingsScope
    private let visibility: HomeLibraryVisibilityModel?
    @State private var isPresented = false

    public init(
        cards: CardStyleSettingsModel, scope: CardCaptionSettingsScope,
        visibility: HomeLibraryVisibilityModel? = nil
    ) {
        self.cards = cards
        self.scope = scope
        self.visibility = visibility
    }

    public var body: some View {
        #if os(tvOS)
        SettingsPageLink {
            destination
        } label: {
            SettingsDisclosureLabel { Text("Customize labels") }
                .settingsFormRowLayout()
        }
        .buttonStyle(SettingsFormButtonStyle())
        .accessibilityIdentifier(identifier)
        #else
        Button { isPresented = true } label: {
            SettingsDisclosureLabel { Text("Customize labels") }
        }
        .navigationDestination(isPresented: $isPresented) { destination }
        .accessibilityIdentifier(identifier)
        #endif
    }

    private var destination: some View {
        CardCaptionCustomizationView(cards: cards, scope: scope, visibility: visibility)
    }

    private var identifier: String {
        switch scope {
        case .all: "card-label-customization"
        case .home: "home-customize-labels"
        case .libraries: "library-customize-labels"
        case .detail: "detail-customize-labels"
        }
    }
}

public struct CardCaptionCustomizationView: View {
    @Bindable private var cards: CardStyleSettingsModel
    private let scope: CardCaptionSettingsScope
    private let visibility: HomeLibraryVisibilityModel?

    public init(
        cards: CardStyleSettingsModel, scope: CardCaptionSettingsScope = .all,
        visibility: HomeLibraryVisibilityModel? = nil
    ) {
        self.cards = cards
        self.scope = scope
        self.visibility = visibility
    }

    public var body: some View {
        CardCaptionCustomizationContent(
            settings: $cards.captions, style: cards.style, scope: scope, visibility: visibility
        )
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
                    ? LocalizedStringResource("Use default") : choice.displayName).tag(choice)
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
            return "Use default"
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
