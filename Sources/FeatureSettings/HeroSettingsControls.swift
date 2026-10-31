#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

enum HeroSettingsPage: String, CaseIterable {
    case titles, ratings, trailers, discovery, libraries, collections

    var title: LocalizedStringResource {
        switch self {
        case .titles: "Hero content sources"
        case .ratings: "Ratings"
        case .trailers: "Trailers"
        case .discovery: "Discovery"
        case .libraries: "Random libraries"
        case .collections: "Collections"
        }
    }

    var linkTitle: LocalizedStringResource {
        switch self {
        case .titles, .ratings, .trailers: title
        case .discovery: "Discovery providers"
        case .libraries: "Choose libraries"
        case .collections: "Choose collections"
        }
    }

    var initialRowID: String {
        switch self {
        case .titles: "hero-source-continueWatching"
        case .ratings: "hero-ratings"
        case .trailers: "hero-trailers"
        case .discovery: "hero-provider-labels"
        case .libraries: "hero-all-libraries"
        case .collections: "hero-collection-done"
        }
    }
}

/// Shared controls keep TV and mobile terminology, grouping and Kids policy aligned.
public struct HeroSettingsControls: View {
    private let libraries: [AggregatedLibrary]
    private let accounts: [ResolvedAccount]
    @Environment(HeroSettingsModel.self) private var hero

    public init(libraries: [AggregatedLibrary], accounts: [ResolvedAccount]) {
        self.libraries = libraries
        self.accounts = accounts
    }

    public var body: some View {
        @Bindable var hero = hero
        HeroSettingsGroup {
            Toggle("Show hero", isOn: $hero.settings.isEnabled)
                .accessibilityIdentifier("hero-enabled")
        }
        if hero.settings.isEnabled {
            HeroSettingsGroup {
                HeroLogoSizeControl(size: $hero.settings.logoSize, textSize: $hero.settings.textSize, surface: .home)
            }
            HeroTitleControls(libraries: libraries, accounts: accounts)
            HeroAutomaticChangeControls()
            HeroSettingsGroup {
                HeroSettingsLink(page: .ratings, libraries: libraries, accounts: accounts)
                HeroSettingsLink(page: .trailers, libraries: libraries, accounts: accounts)
            }
        }
    }
}

private struct HeroTitleControls: View {
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    @Environment(HeroSettingsModel.self) private var hero

    var body: some View {
        @Bindable var hero = hero
        HeroSettingsGroup(title: "Content") {
            HeroSettingsLink(page: .titles, libraries: libraries, accounts: accounts)
            #if os(tvOS)
            SettingsStepper(
                options: Array(HeroSettings.maxItemsRange), selection: $hero.settings.maxItems,
                compact: true, label: "Items to show", title: { "\($0)" }
            )
            #else
            Stepper("Items to show: \(hero.settings.maxItems)",
                    value: $hero.settings.maxItems, in: HeroSettings.maxItemsRange)
            #endif
        }
    }
}

private struct HeroAutomaticChangeControls: View {
    @Environment(HeroSettingsModel.self) private var hero

    var body: some View {
        @Bindable var hero = hero
        HeroSettingsGroup {
            Toggle("Advance automatically", isOn: $hero.settings.autoAdvance)
                .accessibilityIdentifier("hero-auto-advance")
            if hero.settings.autoAdvance {
                #if os(tvOS)
                SettingsStepper(
                    options: Array(HeroSettings.autoAdvanceRange), selection: $hero.settings.autoAdvanceSeconds,
                    compact: true, label: "Seconds per item",
                    verbatimTitle: { Duration.seconds($0).formatted(.units(allowed: [.seconds], width: .narrow)) }
                )
                #else
                Stepper("Seconds per item: \(hero.settings.autoAdvanceSeconds)",
                        value: $hero.settings.autoAdvanceSeconds, in: HeroSettings.autoAdvanceRange)
                #endif
            }
        }
    }
}

private struct HeroRatingControls: View {
    @Environment(HeroSettingsModel.self) private var hero

    var body: some View {
        @Bindable var hero = hero
        HeroSettingsGroup {
            Toggle("Show ratings", isOn: $hero.settings.showsRatings)
                .accessibilityIdentifier("hero-ratings")
                .modifier(ViewCustomizationRowFocus(id: "hero-ratings"))
            if hero.settings.showsRatings {
                Toggle("Show Common Sense age", isOn: $hero.settings.ratingPreferences.showsHeaderFamilyGuidance)
                    .accessibilityIdentifier("hero-common-sense-age")
                HeaderReviewScoreCountPicker(settings: $hero.settings.ratingPreferences)
            }
        }
    }
}

private struct HeroTrailerControls: View {
    @Environment(HeroBackgroundSettingsModel.self) private var background

    var body: some View {
        @Bindable var background = background
        HeroSettingsGroup {
            Toggle("Play trailer behind the hero", isOn: $background.settings.homeTrailerEnabled)
                .accessibilityIdentifier("hero-trailers")
                .modifier(ViewCustomizationRowFocus(id: "hero-trailers"))
            if background.settings.homeTrailerEnabled {
                Toggle("Start muted", isOn: $background.settings.homeTrailerMuted)
                    .accessibilityIdentifier("hero-trailers-muted")
            }
        }
    }
}

struct HeroSettingsLink: View {
    let page: HeroSettingsPage
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    @Environment(HeroSettingsModel.self) private var hero
    @Environment(HeroBackgroundSettingsModel.self) private var background
    #if os(iOS)
    @State private var isPresented = false
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            Button {
                isPresented = true
            } label: {
                label
            }
            .buttonStyle(.plain)
            .navigationDestination(isPresented: $isPresented) {
                HeroSettingsScreen(page: page, libraries: libraries, accounts: accounts)
                    .environment(hero)
                    .environment(background)
            }
            #else
            SettingsDetailLink(pageID: page.rawValue) {
                HeroSettingsScreen(page: page, libraries: libraries, accounts: accounts)
            } label: {
                label
            }
            #endif
        }
        .accessibilityIdentifier("hero-settings-\(page.rawValue)")
        .modifier(ViewCustomizationRowFocus(id: "hero-settings-\(page.rawValue)"))
    }

    private var label: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.linkTitle)
                    .font(SettingsRowMetrics.titleFont)
                if page == .titles {
                    HeroTitleSourceSummary(sources: hero.effectiveSettings.sources)
                        .font(.footnote)
                        .settingsRowSecondary()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 16)
            if let enabledState {
                Group {
                    if enabledState { Text("On") }
                    else { Text("Off") }
                }
                .settingsRowSecondary()
            }
            Image(systemName: "chevron.forward")
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var enabledState: Bool? {
        switch page {
        case .ratings: hero.settings.showsRatings
        case .trailers: background.settings.homeTrailerEnabled
        default: nil
        }
    }
}

private struct HeroTitleSourceSummary: View {
    let sources: [HeroSourceKind]
    @Environment(\.locale) private var locale

    var body: some View {
        if sources.isEmpty {
            Text("No content sources selected")
        } else {
            Text(sources.map { source in
                var title = source.displayName
                title.locale = locale
                return String(localized: title) // l10n:content - Foundation list boundary; resolved from the environment locale on every body update.
            }, format: .list(type: .and).locale(locale))
        }
    }
}

struct HeroSettingsDestination: View {
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    @Environment(SettingsDetailNavigation.self) private var navigation

    var body: some View {
        if let page = navigation.pageID.flatMap(HeroSettingsPage.init(rawValue:)) {
            HeroSettingsScreen(page: page, libraries: libraries, accounts: accounts)
        }
    }
}

struct HeroSettingsScreen: View {
    let page: HeroSettingsPage
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    @Environment(HeroSettingsModel.self) private var hero
    @Environment(SettingsDetailNavigation.self) private var parentNavigation: SettingsDetailNavigation?
    @State var childNavigation = SettingsDetailNavigation()

    var body: some View {
        @Bindable var hero = hero
        if page == .collections {
            HeroCollectionPickerView(selections: $hero.settings.collections, libraries: libraries, accounts: accounts)
        } else {
            #if os(tvOS)
            SettingsDetailPages(navigation: childNavigation) {
                ViewCustomizationList(
                    title: page.title, initialRowID: initialRowID,
                    sectionSpacing: SettingsRowMetrics.formSectionSpacing,
                    hasGroupedContent: true
                ) {
                    form
                        .environment(childNavigation)
                        .toggleStyle(SettingsSwitchToggleStyle())
                }
                .environment(parentNavigation)
            } detail: {
                HeroSettingsDestination(libraries: libraries, accounts: accounts)
            }
            #else
            ViewCustomizationList(title: page.title, initialRowID: initialRowID) {
                form
            }
            #endif
        }
    }

    private var initialRowID: String {
        if page == .discovery && !hero.allowsDiscovery { return "view-customization-back" }
        if page == .libraries && eligibleLibraries.isEmpty { return "view-customization-back" }
        return page.initialRowID
    }

    @ViewBuilder private var form: some View {
        switch page {
        case .titles: HeroTitleSources(libraries: libraries, accounts: accounts)
        case .ratings: HeroRatingControls()
        case .trailers: HeroTrailerControls()
        case .discovery: discovery
        case .libraries: randomLibraries
        case .collections: EmptyView()
        }
    }

    @ViewBuilder private var discovery: some View {
        @Bindable var hero = hero
        if hero.allowsDiscovery {
            HeroSettingsGroup(
                title: "Provider labels",
                detail: "Show provider names on Discovery content. This does not change what appears."
            ) {
                Toggle("Show provider labels", isOn: $hero.settings.showsDiscoverySources)
                    .modifier(ViewCustomizationRowFocus(id: "hero-provider-labels"))
            }
            HeroSettingsGroup(
                title: "Discovery providers",
                detail: "Recommendations may include content outside your libraries. Seerr is only needed to request it."
            ) {
                ForEach(HeroDiscoverySource.allCases) { source in
                    Toggle(isOn: discoveryBinding(source)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: source.displayName)
                            Text(source.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if hero.settings.discoverySources.isEmpty {
                    Text("Select a provider to see Discovery recommendations.")
                }
            }
        } else {
            kidsExplanation
        }
    }

    private var kidsExplanation: some View {
        Text("Discovery is unavailable in Kids profiles. Library content follows the connected server user's restrictions.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var eligibleLibraries: [AggregatedLibrary] {
        libraries.filter { $0.library.kind == .movie || $0.library.kind == .series }
    }

    private var randomLibraries: some View {
        @Bindable var hero = hero
        return HeroSettingsGroup(
            detail: "Choose at least one library. All libraries includes new libraries added to Home."
        ) {
            if eligibleLibraries.isEmpty {
                Text("No movie or TV libraries are enabled on Home.")
            } else {
                Toggle("All libraries on Home", isOn: Binding(
                    get: { hero.settings.randomLibraryKeys.isEmpty },
                    set: { all in hero.settings.randomLibraryKeys = all ? [] : Set(eligibleLibraries.map(\.key)) }
                ))
                .modifier(ViewCustomizationRowFocus(id: "hero-all-libraries"))
                if !hero.settings.randomLibraryKeys.isEmpty {
                    ForEach(eligibleLibraries) { library in
                        Toggle(isOn: Binding(
                            get: { hero.settings.randomLibraryKeys.contains(library.key) },
                            set: { selected in
                                if selected { hero.settings.randomLibraryKeys.insert(library.key) }
                                else { hero.settings.randomLibraryKeys.remove(library.key) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                library.library.displayName
                                Text(verbatim: library.serverName).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(hero.settings.randomLibraryKeys == [library.key])
                    }
                }
            }
        }
    }

    private func discoveryBinding(_ source: HeroDiscoverySource) -> Binding<Bool> {
        Binding(
            get: { hero.settings.discoverySources.contains(source) },
            set: { selected in
                guard hero.allowsDiscovery else { return }
                var sources = Set(hero.settings.discoverySources)
                if selected { sources.insert(source) } else { sources.remove(source) }
                hero.settings.discoverySources = HeroDiscoverySource.allCases.filter(sources.contains)
            }
        )
    }
}

private struct HeroTitleSources: View {
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    @Environment(HeroSettingsModel.self) private var hero

    var body: some View {
        @Bindable var hero = hero
        ForEach(HeroSourceKind.allCases.filter { $0 != .featured } + (hero.allowsDiscovery ? [.featured] : [])) { source in
            ViewPreferenceChoiceGroup(rowSize: .contained) {
                Toggle(source.displayName, isOn: sourceBinding(source))
                    .modifier(ViewCustomizationRowFocus(id: "hero-source-\(source.rawValue)"))
                if hero.effectiveSettings.isEnabled(source) {
                    switch source {
                    case .featured:
                        HeroSettingsLink(page: .discovery, libraries: libraries, accounts: accounts)
                    case .randomFromLibrary:
                        HeroSettingsLink(page: .libraries, libraries: libraries, accounts: accounts)
                    case .collection:
                        HeroSettingsLink(page: .collections, libraries: libraries, accounts: accounts)
                    case .watchlist:
                        Toggle("Prefer less recently shown Watchlist items", isOn: $hero.settings.watchlistDiscoveryEnabled)
                    case .continueWatching, .recentlyAdded:
                        EmptyView()
                    }
                }
            }
            #if os(tvOS)
            .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
            .buttonStyle(SettingsFormButtonStyle())
            #endif
        }
        if !hero.allowsDiscovery {
            Text("Discovery is unavailable in Kids profiles. Library content follows the connected server user's restrictions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sourceBinding(_ source: HeroSourceKind) -> Binding<Bool> {
        Binding(
            get: { hero.effectiveSettings.isEnabled(source) },
            set: { selected in
                guard source != .featured || hero.allowsDiscovery else { return }
                hero.settings.setEnabled(source, enabled: selected)
            }
        )
    }
}

private struct HeroSettingsGroup<Content: View>: View {
    var title: LocalizedStringResource? = nil
    var detail: LocalizedStringResource? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).settingsSectionHeader()
                    .padding(.horizontal, SettingsRowMetrics.formGroupInset + SettingsRowMetrics.horizontalPadding)
            }
            ViewPreferenceChoiceGroup(rowSize: .contained, content: content)
                .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
                .buttonStyle(SettingsFormButtonStyle())
            if let detail {
                Text(detail).settingsHelperText().fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsRowMetrics.formGroupInset + SettingsRowMetrics.horizontalPadding)
            }
        }
        #else
        SettingsSectionGroup(title, content: content) {
            if let detail { Text(detail) }
        }
        #endif
    }
}
#endif
