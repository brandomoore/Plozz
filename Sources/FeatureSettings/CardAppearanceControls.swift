#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct CardAppearanceControls: View {
    @Bindable private var cards: CardStyleSettingsModel
    @Bindable private var watchIndicator: WatchStatusIndicatorSettingsModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(cards: CardStyleSettingsModel, watchIndicator: WatchStatusIndicatorSettingsModel) {
        self.cards = cards
        self.watchIndicator = watchIndicator
    }

    public var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            SettingsDetailGroup(title: "Labels") { labelControls }
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
            SettingsSectionGroup("Labels") { labelControls }
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

    private var labelControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            CardCaptionPicker(selection: $cards.captions.showsLabels, style: cards.style)
            NavigationLink {
                CardCaptionCustomizationView(cards: cards)
            } label: {
                HStack {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout())
                    layout {
                        Text("Customize by view")
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Group {
                            if cards.captions.overrides.isEmpty {
                                Text("Default everywhere")
                            } else {
                                Text("\(cards.captions.overrides.count) customized")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    #if os(tvOS)
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                    #endif
                }
            }
            .accessibilityIdentifier("card-label-customization")
        }
    }
}

private struct CardCaptionPicker: View {
    @Binding var selection: Bool
    let style: CardStyle
    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 16))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            ForEach([false, true], id: \.self) { showsLabels in
                PreviewCard(
                    title: showsLabels ? "Labels" : "No labels",
                    isSelected: selection == showsLabels,
                    accent: palette.accent,
                    compact: true,
                    swatchHeight: swatchHeight,
                    action: { selection = showsLabels }
                ) {
                    CardStyleSwatch(style: style, showsCaptions: showsLabels)
                }
                .accessibilityAddTraits(selection == showsLabels ? .isSelected : [])
                .accessibilityIdentifier(showsLabels ? "card-labels-on" : "card-labels-off")
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(cards: CardStyleSettingsModel) { self.cards = cards }

    public var body: some View {
        #if os(tvOS)
        SettingsSplitLayout(
            title: "Labels by view",
            rows: CardCaptionView.allCases.map { view in
                SettingsSplitRow(
                    id: view.rawValue,
                    title: view.displayName,
                    description: "Choices apply across all libraries. Titles inside collections and playlists use Browse."
                ) {
                    Picker(view.displayName, selection: selection(for: view)) { options }
                        .pickerStyle(.segmented)
                }
            } + [
                SettingsSplitRow(id: "reset", title: "Reset all to default") {
                    resetButton
                }
            ]
        )
        #else
        List {
            if dynamicTypeSize.isAccessibilitySize {
                Text(resolvedDefault)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            SettingsSectionGroup {
                ForEach(CardCaptionView.allCases, id: \.rawValue) { view in
                    Picker(view.displayName, selection: selection(for: view)) { options }
                }
            } footer: {
                Text("Choices apply across all libraries. Titles inside collections and playlists use Browse.")
            }
            SettingsSectionGroup { resetButton }
        }
        .settingsPageSurface()
        .navigationTitle("Labels by view")
        #endif
    }

    private func selection(for view: CardCaptionView) -> Binding<CardCaptionOverride> {
        Binding(
            get: { cards.captions.override(for: view) },
            set: { cards.captions.setOverride($0, for: view) }
        )
    }

    private var options: some View {
        ForEach(CardCaptionOverride.allCases) { option in
            Group {
                if option == .automatic {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text("Default")
                    } else {
                        Text(resolvedDefault)
                    }
                } else {
                    Text(option.displayName)
                }
            }
            .tag(option)
        }
    }

    private var resolvedDefault: LocalizedStringResource {
        cards.captions.showsLabels ? "Default · Labels" : "Default · No labels"
    }

    private var resetButton: some View {
        Button("Reset all to default") { cards.captions.resetOverrides() }
            .disabled(cards.captions.overrides.isEmpty)
    }
}
#endif
