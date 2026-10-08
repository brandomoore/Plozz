#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct ArtworkSettingsControls: View {
    @Bindable private var cards: CardStyleSettingsModel

    public init(cards: CardStyleSettingsModel) { self.cards = cards }

    public var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Choose the posters, backgrounds, and logos you see.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ArtworkPresetPicker(settings: $cards.artwork)
            ViewCustomizationLink(count: cards.artwork.overrides.count) {
                ArtworkCustomizationView(cards: cards)
            }
            .accessibilityIdentifier("artwork-customization")
            if !cards.artwork.overrides.isEmpty {
                ArtworkResetButton(settings: $cards.artwork)
            }
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
                        isSelected: settings.preference == preference
                    ) {
                        settings.preference = preference
                    }
                    .accessibilityIdentifier("artwork-preset-\(preference.rawValue)")
                }
            }
        }
    }
}

struct ArtworkCustomizationView: View {
    @Bindable var cards: CardStyleSettingsModel

    private var areas: [ArtworkArea] {
        #if os(tvOS)
        ArtworkArea.allCases.filter { $0 != .downloads }
        #else
        ArtworkArea.allCases.filter { $0 != .topShelf && $0 != .music }
        #endif
    }

    var body: some View {
        ViewCustomizationList(title: "Artwork by view", initialRowID: "artwork-view-home") {
            ForEach(areas) { area in
                ArtworkAreaChoices(area: area, settings: $cards.artwork)
            }
            if !cards.artwork.overrides.isEmpty {
                Divider()
                ArtworkResetButton(settings: $cards.artwork)
            }
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
            value: settings.preference(in: area).summary,
            isCustomized: settings.overrides[area] != nil,
            choices: [ArtworkOverride.library, .online].map { option in
                ViewCustomizationChoice(
                    id: "artwork-view-\(area.rawValue)-\(option.rawValue)",
                    title: option.displayName,
                    isSelected: settings.overrides[area] == (option == .library ? .library : .online)
                ) {
                    settings.setOverride(option, for: area)
                }
            }
        ) {
            settings.setOverride(.automatic, for: area)
        }
    }
}

private extension ArtworkPreference {
    var summary: LocalizedStringResource {
        switch self {
        case .recommended: "Recommended"
        case .library: "Library artwork"
        case .online: "Metadata providers"
        }
    }
}

private struct ArtworkResetButton: View {
    @Binding var settings: ArtworkSettings

    var body: some View {
        ViewCustomizationResetButton(isEnabled: !settings.overrides.isEmpty) { settings.resetOverrides() }
            .accessibilityIdentifier("artwork-remove-customizations")
    }
}

#endif
