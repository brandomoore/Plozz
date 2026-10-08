#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct ArtworkSettingsControls: View {
    @Bindable private var cards: CardStyleSettingsModel
    private let continueWatchingShowsSeriesArtwork: Bool

    public init(cards: CardStyleSettingsModel, continueWatchingShowsSeriesArtwork: Bool = true) {
        self.cards = cards
        self.continueWatchingShowsSeriesArtwork = continueWatchingShowsSeriesArtwork
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Choose the posters, backgrounds, and logos you see.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ArtworkPresetPicker(settings: $cards.artwork)
            ViewCustomizationLink(isCustomized: cards.artwork.selectedPreset == nil) {
                ArtworkCustomizationView(
                    cards: cards, continueWatchingShowsSeriesArtwork: continueWatchingShowsSeriesArtwork
                )
            }
            .accessibilityIdentifier("artwork-customization")
        }
    }
}

private struct ArtworkPresetPicker: View {
    @Binding var settings: ArtworkSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                }
            }
        }
    }
}

struct ArtworkCustomizationView: View {
    @Bindable var cards: CardStyleSettingsModel
    var continueWatchingShowsSeriesArtwork = true
    @Environment(HeroSettingsModel.self) private var hero: HeroSettingsModel?

    private var areas: [ArtworkArea] {
        #if os(tvOS)
        ArtworkArea.allCases.filter { $0 != .downloads }
        #else
        ArtworkArea.allCases.filter { $0 != .topShelf && $0 != .music && $0 != .recommendedHero }
        #endif
    }

    var body: some View {
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
                                continueWatchingShowsSeriesArtwork: continueWatchingShowsSeriesArtwork
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
                .padding(.top, 20)
                .padding(.bottom, 6)
                #endif
        }
    }
}

struct ArtworkAreaChoices: View {
    let area: ArtworkArea
    @Binding var settings: ArtworkSettings

    var body: some View {
        ViewCustomizationRow(
            id: "artwork-view-\(area.rawValue)",
            title: area.displayName,
            value: settings.customizationValue(in: area),
            detail: settings.customizationDetail(in: area)
        ) {
            settings.toggleCustomization(in: area)
        }
    }
}

extension ArtworkSettings {
    func customizationValue(in area: ArtworkArea) -> LocalizedStringResource {
        if preference(in: area) == .recommended, area == .details { return "Mixed" }
        return prefersOnlineArtwork(in: area) ? "Metadata providers" : "Library"
    }

    func customizationDetail(in area: ArtworkArea) -> LocalizedStringResource? {
        if preference(in: area) == .recommended, area == .details {
            return "Metadata-provider backgrounds and logos, with library artwork for related-title posters."
        }
        return area.detail
    }
}

#endif
