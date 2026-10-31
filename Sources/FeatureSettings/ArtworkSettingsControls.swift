#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct ArtworkSettingsControls: View {
    @Bindable private var cards: CardStyleSettingsModel
    @Environment(\.themePalette) private var palette
    private let continueWatchingShowsSeriesArtwork: Bool
    private let continueWatchingLayout: ContinueWatchingCardLayout

    public init(
        cards: CardStyleSettingsModel, continueWatchingShowsSeriesArtwork: Bool = true,
        continueWatchingLayout: ContinueWatchingCardLayout = .landscape
    ) {
        self.cards = cards
        self.continueWatchingShowsSeriesArtwork = continueWatchingShowsSeriesArtwork
        self.continueWatchingLayout = continueWatchingLayout
    }

    public var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 28) {
            Text("Choose the posters, backgrounds, and logos you see.")
                .settingsHelperText()
            ArtworkPresetPicker(settings: $cards.artwork)
            SettingsControlGroup { customizationLink }
        }
        #else
        Section {
            ArtworkPresetPicker(settings: $cards.artwork)
        } header: {
            Text("Choose the posters, backgrounds, and logos you see.")
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .textCase(nil)
                .accessibilityIdentifier("artwork-preset-heading")
        }
        SettingsSectionGroup {
            customizationLink
        }
        .padding(.top, 16)
        #endif
    }

    private var customizationLink: some View {
        ViewCustomizationLink(isCustomized: cards.artwork.selectedPreset == nil) {
            ArtworkCustomizationView(
                cards: cards, continueWatchingShowsSeriesArtwork: continueWatchingShowsSeriesArtwork,
                continueWatchingLayout: continueWatchingLayout
            )
        }
        .accessibilityIdentifier("artwork-customization")
    }
}

private struct ArtworkPresetPicker: View {
    @Binding var settings: ArtworkSettings

    var body: some View {
        ViewPreferenceChoiceGroup {
            ForEach(ArtworkPreference.allCases) { preference in
                ViewPreferenceChoiceRow(
                    title: preference.displayName,
                    detail: preference.detail,
                    isSelected: settings.selectedPreset == preference
                ) {
                    settings.applyPreset(preference)
                }
                .accessibilityIdentifier("artwork-preset-\(preference.rawValue)")
                .settingsSearchAnchor(
                    "artwork-preset-\(preference.rawValue)",
                    fallbackFor: preference == (settings.selectedPreset ?? .recommended) ? ["artwork-preset"] : []
                )
            }
        }
    }
}

public struct ArtworkCustomizationView: View {
    @Bindable var cards: CardStyleSettingsModel
    var continueWatchingShowsSeriesArtwork = true
    var continueWatchingLayout: ContinueWatchingCardLayout = .landscape
    @Environment(HeroSettingsModel.self) private var hero: HeroSettingsModel?

    public init(
        cards: CardStyleSettingsModel, continueWatchingShowsSeriesArtwork: Bool = true,
        continueWatchingLayout: ContinueWatchingCardLayout = .landscape
    ) {
        self.cards = cards
        self.continueWatchingShowsSeriesArtwork = continueWatchingShowsSeriesArtwork
        self.continueWatchingLayout = continueWatchingLayout
    }

    private var areas: [ArtworkArea] {
        #if os(tvOS)
        ArtworkArea.allCases.filter { $0 != .downloads }
        #else
        ArtworkArea.allCases.filter { $0 != .topShelf && $0 != .music && $0 != .recommendedHero }
        #endif
    }

    public var body: some View {
        ViewCustomizationList(
            title: "Artwork by view", initialRowID: "artwork-view-home",
            focusedHelp: { id in
                areas.first { "artwork-view-\($0.rawValue)" == id }
                    .flatMap { area in
                        cards.artwork.customizationDetail(in: area).map {
                            let settings = hero?.settings ?? .default
                            let detail: LocalizedStringResource =
                                area == .home && !settings.followsFocus && !settings.isActive
                                ? "No hero is currently shown with your Home layout." : $0
                            return ViewCustomizationHelp(
                                detail: detail, illustration: .artwork(area),
                                continueWatchingShowsSeriesArtwork: continueWatchingShowsSeriesArtwork,
                                continueWatchingLayout: continueWatchingLayout
                            )
                        }
                    }
            }
        ) {
            section("Home", areas: [.home, .homeRows])
            section("Libraries", areas: [.recommendedHero, .recommended, .browse, .collections, .playlists])
            section("Across the app", areas: [
                .continueWatching, .search, .watchlist, .details, .episodes,
                .playback, .music, .topShelf, .downloads
            ])
        }
    }

    private func section(_ title: LocalizedStringResource, areas sectionAreas: [ArtworkArea]) -> some View {
        Section {
            ForEach(sectionAreas.filter { areas.contains($0) }) { area in
                ArtworkAreaChoices(area: area, settings: $cards.artwork)
            }
        } header: {
            Text(title)
                #if os(tvOS)
                .settingsSectionHeader()
                #endif
        }
    }
}

struct ArtworkAreaChoices: View {
    let area: ArtworkArea
    @Binding var settings: ArtworkSettings

    var body: some View {
        #if os(iOS)
        ViewCustomizationMenu(
            id: "artwork-view-\(area.rawValue)",
            title: area.displayName,
            value: settings.customizationValue(in: area),
            detail: settings.customizationDetail(in: area),
            selection: Binding(
                get: { settings.customization(in: area) },
                set: { settings.setOverride($0, for: area) }
            )
        ) {
            ForEach(area.customizationChoices) { choice in
                Text(choice.displayName).tag(choice)
            }
        }
        .settingsSearchAnchor("artwork-view-\(area.rawValue)")
        #else
        ViewCustomizationRow(
            id: "artwork-view-\(area.rawValue)",
            title: area.displayName,
            value: settings.customizationValue(in: area),
            detail: settings.customizationDetail(in: area)
        ) {
            settings.toggleCustomization(in: area)
        }
        .settingsSearchAnchor("artwork-view-\(area.rawValue)")
        #endif
    }
}

extension ArtworkSettings {
    func customizationValue(in area: ArtworkArea) -> LocalizedStringResource {
        customization(in: area).displayName
    }

    func customizationDetail(in area: ArtworkArea) -> LocalizedStringResource? {
        if preference(in: area) == .recommended, area == .details {
            return "Metadata-provider backgrounds and logos, with library artwork for related-title posters."
        }
        return area.detail
    }
}

#endif
