#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct ArtworkSettingsControls: View {
    @Bindable private var cards: CardStyleSettingsModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(cards: CardStyleSettingsModel) { self.cards = cards }

    public var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Choose the posters, backgrounds, and logos you see.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ArtworkPresetPicker(settings: $cards.artwork)
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
                                Text("Using defaults")
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
            ArtworkChoiceGroup {
                ForEach(ArtworkPreference.allCases) { preference in
                    ArtworkChoiceRow(
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
        ArtworkChoiceGroup {
            ForEach(ArtworkOverride.allCases) { option in
                ArtworkChoiceRow(
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

private struct ArtworkChoiceGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(tvOS)
        SettingsCheckGroup {
            VStack(alignment: .leading, spacing: 8, content: content)
        }
        #else
        VStack(alignment: .leading, spacing: 20, content: content)
        #endif
    }
}

private struct ArtworkChoiceRow: View {
    let title: LocalizedStringResource
    var detail: LocalizedStringResource? = nil
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        #if os(tvOS)
        SettingsCheckableRow(
            title: Text(title),
            subtitle: isFocused ? detail.map { Text($0) } : nil,
            titleLineLimit: nil, subtitleLineLimit: nil,
            isChecked: isSelected,
            flushLeading: false, action: action
        )
        .focused($isFocused)
        #else
        Button(action: action) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.body.weight(.medium))
                    if isSelected, let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        #endif
    }
}

private struct ArtworkResetButton: View {
    @Binding var settings: ArtworkSettings

    var body: some View {
        Button("Remove view customizations") { settings.resetOverrides() }
            .disabled(settings.overrides.isEmpty)
            .accessibilityIdentifier("artwork-remove-customizations")
    }
}

#endif
