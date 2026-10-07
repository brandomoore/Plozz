#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

struct ArtworkSettingsControls: View {
    @Bindable var cards: CardStyleSettingsModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Artwork", selection: $cards.artwork.preference) {
                ForEach(ArtworkPreference.allCases) { preference in
                    Text(preference.displayName).tag(preference)
                }
            }
            #if os(tvOS)
            .pickerStyle(.segmented)
            #endif
            .accessibilityIdentifier("artwork-preference")
            Text("Recommended favors clean backdrops behind titles and your library's music covers. Library first trusts your artwork as supplied. Missing artwork can fall back to the other source.")
                .font(.footnote)
                        .foregroundStyle(.secondary)
            NavigationLink {
                ArtworkCustomizationView(cards: cards)
            } label: {
                HStack {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout())
                    layout {
                        Text("Customize by view")
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Group {
                            if cards.artwork.overrides.isEmpty {
                                Text("Default everywhere")
                            } else {
                                Text("\(cards.artwork.overrides.count) customized")
                            }
                        }
                            .foregroundStyle(.secondary)
                    }
                    #if os(tvOS)
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                    #endif
                }
            }
            .accessibilityIdentifier("artwork-customization")
        }
    }
}

private struct ArtworkCustomizationView: View {
    @Bindable var cards: CardStyleSettingsModel

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
                    id: area.rawValue,
                    title: area.displayName,
                    description: "Choices apply to this profile across all libraries. Continue Watching prefers textless artwork unless you choose Library first."
                ) {
                    ArtworkAreaPicker(area: area, settings: $cards.artwork)
                        .pickerStyle(.segmented)
                }
            } + [
                SettingsSplitRow(id: "reset", title: "Reset all to default") {
                    ArtworkResetButton(settings: $cards.artwork)
                }
            ]
        )
        #else
        List {
            SettingsSectionGroup {
                ForEach(areas) { area in
                    ArtworkAreaPicker(area: area, settings: $cards.artwork)
                }
            } footer: {
                Text("Choices apply to this profile across all libraries. Continue Watching prefers textless artwork unless you choose Library first.")
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

private struct ArtworkAreaPicker: View {
    let area: ArtworkArea
    @Binding var settings: ArtworkSettings

    var body: some View {
        Picker(area.displayName, selection: Binding(
            get: { settings.override(for: area) },
            set: { settings.setOverride($0, for: area) }
        )) {
            ForEach(ArtworkOverride.allCases) { option in
                Text(option.displayName).tag(option)
            }
        }
        .accessibilityIdentifier("artwork-view-\(area.rawValue)")
    }
}

private struct ArtworkResetButton: View {
    @Binding var settings: ArtworkSettings

    var body: some View {
        Button("Reset all to default") { settings.resetOverrides() }
            .disabled(settings.overrides.isEmpty)
    }
}
#endif
