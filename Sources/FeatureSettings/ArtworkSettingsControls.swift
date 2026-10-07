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
    var selection: Binding<String?>? = nil

    private var areas: [ArtworkArea] {
        #if os(tvOS)
        ArtworkArea.allCases.filter { $0 != .downloads }
        #else
        ArtworkArea.allCases.filter { $0 != .topShelf && $0 != .music }
        #endif
    }

    var body: some View {
        #if os(tvOS)
        SettingsSplitLayout(
            title: "Artwork by view",
            rows: areas.map { area in
                SettingsSplitRow(
                    id: area.rawValue, title: area.displayName, description: area.detail
                ) {
                    ArtworkAreaChoices(area: area, settings: $cards.artwork)
                }
            } + [
                SettingsSplitRow(
                    id: "reset", title: "Remove view customizations",
                    description: "All views will follow your main artwork preference."
                ) {
                    ArtworkResetButton(settings: $cards.artwork)
                }
            ],
            selection: selection
        )
        #else
        List {
            ForEach(areas) { area in
                SettingsSectionGroup(area.displayName) {
                    ArtworkAreaChoices(area: area, settings: $cards.artwork)
                } footer: {
                    if let detail = area.detail { Text(detail) }
                }
            }
            SettingsSectionGroup {
                ArtworkResetButton(settings: $cards.artwork)
            }
        }
        .settingsPageSurface()
        .navigationTitle("Artwork by view")
        #endif
    }
}

struct ArtworkAreaChoices: View {
    let area: ArtworkArea
    @Binding var settings: ArtworkSettings

    var body: some View {
        ViewPreferenceChoiceGroup {
            ForEach(ArtworkOverride.allCases) { option in
                ViewPreferenceChoiceRow(
                    title: title(for: option),
                    isSelected: settings.override(for: area) == option
                ) {
                    settings.setOverride(option, for: area)
                }
                .accessibilityIdentifier("artwork-view-\(area.rawValue)-\(option.rawValue)")
            }
        }
    }

    private func title(for option: ArtworkOverride) -> LocalizedStringResource {
        switch option {
        case .automatic:
            settings.inheritedPreference(in: area) == .online
                ? "Use default: metadata providers preferred"
                : "Use default: library preferred"
        case .library, .online: option.displayName
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
