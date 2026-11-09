#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public enum HeroSettingsPage: String, CaseIterable {
    case titles, ratings, trailers, discovery, libraries, collections

    var title: LocalizedStringResource {
        switch self {
        case .titles:
            #if os(tvOS)
            "Content sources"
            #else
            "Hero content sources"
            #endif
        case .ratings: "Ratings"
        case .trailers: "Trailers & music"
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
        #if os(tvOS)
        HomeHeroEnabledPicker(settings: $hero.settings)
        #else
        HeroSettingsGroup(searchTargets: ["hero-enabled"] + enableTargets) {
            Toggle("Show hero", isOn: $hero.settings.isEnabled)
                .accessibilityIdentifier("hero-enabled")
                .settingsSearchAnchor("hero-enabled", fallbackFor: enableTargets)
        }
        #endif
        if showsControls {
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

    private var showsControls: Bool {
        #if os(tvOS)
        hero.settings.spotlightEnabled
        #else
        hero.settings.isEnabled
        #endif
    }

    private var enableTargets: [String] {
        showsControls ? [] : SettingsSearchCatalog.carouselHeroTargets
    }
}

private struct HeroTitleControls: View {
    let libraries: [AggregatedLibrary]
    let accounts: [ResolvedAccount]
    @Environment(HeroSettingsModel.self) private var hero

    var body: some View {
        @Bindable var hero = hero
        HeroSettingsGroup(title: "Content", searchTargets: ["hero-content", "hero-items"]) {
            HeroSettingsLink(page: .titles, libraries: libraries, accounts: accounts)
            #if os(tvOS)
            SettingsStepper(
                options: Array(HeroSettings.maxItemsRange), selection: $hero.settings.maxItems,
                compact: true, label: "Items to show", title: { "\($0)" }
            )
            .settingsSearchAnchor("hero-items")
            #else
            Stepper("Items to show: \(hero.settings.maxItems)",
                    value: $hero.settings.maxItems, in: HeroSettings.maxItemsRange)
                .settingsSearchAnchor("hero-items")
            #endif
        }
    }
}

private struct HeroAutomaticChangeControls: View {
    @Environment(HeroSettingsModel.self) private var hero

    var body: some View {
        @Bindable var hero = hero
        HeroSettingsGroup(searchTargets: ["hero-auto-advance", "hero-advance-seconds"]) {
            Toggle("Advance automatically", isOn: $hero.settings.autoAdvance)
                .accessibilityIdentifier("hero-auto-advance")
                .settingsSearchAnchor(
                    "hero-auto-advance", fallbackFor: hero.settings.autoAdvance ? [] : ["hero-advance-seconds"]
                )
            if hero.settings.autoAdvance {
                #if os(tvOS)
                SettingsStepper(
                    options: Array(HeroSettings.autoAdvanceRange), selection: $hero.settings.autoAdvanceSeconds,
                    compact: true, label: "Seconds per item",
                    verbatimTitle: { Duration.seconds($0).formatted(.units(allowed: [.seconds], width: .narrow)) }
                )
                .settingsSearchAnchor("hero-advance-seconds")
                #else
                Stepper("Seconds per item: \(hero.settings.autoAdvanceSeconds)",
                        value: $hero.settings.autoAdvanceSeconds, in: HeroSettings.autoAdvanceRange)
                    .settingsSearchAnchor("hero-advance-seconds")
                #endif
            }
        }
    }
}

struct HeroRatingControls: View {
    var isShowcase = false
    @Environment(HeroSettingsModel.self) private var hero

    var body: some View {
        @Bindable var hero = hero
        HeroSettingsGroup(searchTargets: isShowcase
            ? ["showcase-ratings", "showcase-age", "showcase-rating-count"]
            : SettingsSearchCatalog.targets(on: .heroRatings)) {
            Toggle("Show ratings", isOn: $hero.settings.showsRatings)
                .accessibilityIdentifier("hero-ratings")
                .modifier(ViewCustomizationRowFocus(id: "hero-ratings"))
                .settingsSearchAnchor(
                    isShowcase ? "showcase-ratings" : "hero-ratings",
                    fallbackFor: hero.settings.showsRatings ? []
                        : (isShowcase ? ["showcase-age", "showcase-rating-count"] : ["hero-age", "hero-rating-count"])
                )
            if hero.settings.showsRatings {
                Toggle("Show Common Sense age", isOn: $hero.settings.ratingPreferences.showsHeaderFamilyGuidance)
                    .accessibilityIdentifier("hero-common-sense-age")
                    .settingsSearchAnchor(isShowcase ? "showcase-age" : "hero-age")
                HeaderReviewScoreCountPicker(settings: $hero.settings.ratingPreferences)
                    .settingsSearchAnchor(isShowcase ? "showcase-rating-count" : "hero-rating-count")
            }
        }
    }
}

public struct TrailersAndMusicSettingsView: View {
    @Bindable private var background: HeroBackgroundSettingsModel
    private let themeMusic: ThemeMusicSettingsModel

    public init(background: HeroBackgroundSettingsModel, themeMusic: ThemeMusicSettingsModel) {
        self.background = background
        self.themeMusic = themeMusic
    }

    public var body: some View {
        ViewCustomizationList(
            title: "Trailers & music", initialRowID: "trailer-sources",
            sectionSpacing: SettingsRowMetrics.formSectionSpacing, hasGroupedContent: true
        ) {
            HeroSettingsGroup(
                detail: background.settings.trailerSources.allowsYouTube
                    ? "YouTube trailers open externally and never autoplay." : nil,
                searchTargets: ["trailer-sources"]
            ) {
                sourcePicker
                .accessibilityIdentifier("trailer-sources")
                .modifier(ViewCustomizationRowFocus(id: "trailer-sources"))
                .settingsSearchAnchor(
                    "trailer-sources",
                    fallbackFor: background.settings.trailerSources.allowsServerTrailers ? [] : ["hero-trailers"]
                )
            }
            HeroSettingsGroup(title: "Home", searchTargets: ["hero-trailers", "hero-trailers-muted"]) {
                Toggle("Home autoplay", isOn: Binding(
                    get: { background.settings.homeTrailerPlaybackEnabled },
                    set: { background.settings.homeTrailerEnabled = $0 }
                ))
                .disabled(!background.settings.trailerSources.allowsServerTrailers)
                .accessibilityIdentifier("hero-trailers")
                .modifier(ViewCustomizationRowFocus(id: "hero-trailers"))
                .settingsSearchAnchor(
                    "hero-trailers", fallbackFor: background.settings.homeTrailerPlaybackEnabled ? [] : ["hero-trailers-muted"]
                )
                if background.settings.homeTrailerPlaybackEnabled {
                    Toggle("Start muted", isOn: $background.settings.homeTrailerMuted)
                        .accessibilityIdentifier("hero-trailers-muted")
                        .settingsSearchAnchor("hero-trailers-muted")
                }
            }
            HeroSettingsGroup(
                title: "Details", searchTargets: ["detail-background", "detail-trailer-muted", "theme-music-volume"]
            ) {
                detailPicker
                .accessibilityIdentifier("detail-background")
                .settingsSearchAnchor(
                    "detail-background",
                    fallbackFor: (background.settings.detailTrailerEnabled ? [] : ["detail-trailer-muted"])
                        + (background.settings.themeMusicEnabled ? [] : ["theme-music-volume"])
                )
                if background.settings.detailTrailerEnabled {
                    Toggle("Start muted", isOn: $background.settings.detailTrailerMuted)
                        .settingsSearchAnchor("detail-trailer-muted")
                }
                if background.settings.themeMusicEnabled {
                    ThemeMusicVolumeControl(model: themeMusic)
                }
            }
        }
    }

    private var sourcePicker: some View {
        let picker = Picker("Trailers", selection: $background.settings.trailerSources) {
            ForEach(TrailerSourcePolicy.allCases, id: \.self) {
                Text($0.displayName).tag($0)
            }
        }
        .settingsSearchAnchor("trailer-sources")
        #if os(tvOS)
        return SettingsMenuRow(title: "Trailers", value: Text(background.settings.trailerSources.displayName)) {
            picker.pickerStyle(.inline)
        }
        .settingsSearchAnchor("trailer-sources")
        #else
        return picker.pickerStyle(.menu)
            .settingsSearchAnchor("trailer-sources")
        #endif
    }

    private var detailPicker: some View {
        let picker = Picker("Detail background", selection: Binding(
            get: { background.settings.effectiveDetailMode },
            set: { background.settings.detailMode = $0 }
        )) {
            ForEach(background.settings.availableDetailModes, id: \.self) {
                Text($0.displayName).tag($0)
            }
        }
        .settingsSearchAnchor("detail-background")
        #if os(tvOS)
        return SettingsMenuRow(title: "Detail background", value: Text(background.settings.effectiveDetailMode.displayName)) {
            picker.pickerStyle(.inline)
        }
        .settingsSearchAnchor("detail-background")
        #else
        return picker.pickerStyle(.menu)
            .settingsSearchAnchor("detail-background")
        #endif
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
            .settingsActionRow()
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
        .settingsSearchAnchor(searchID)
    }

    private var searchID: String {
        switch page {
        case .titles: "hero-content"
        case .libraries: "hero-choose-libraries"
        case .collections: "hero-choose-collections"
        default: "hero-settings-\(page.rawValue)"
        }
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
    @Environment(HeroBackgroundSettingsModel.self) private var background
    @Environment(ThemeMusicSettingsModel.self) private var themeMusic
    @Environment(SettingsDetailNavigation.self) private var parentNavigation: SettingsDetailNavigation?
    @State var childNavigation = SettingsDetailNavigation()

    var body: some View {
        @Bindable var hero = hero
        if page == .trailers {
            TrailersAndMusicSettingsView(background: background, themeMusic: themeMusic)
        } else if page == .collections {
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
        case .trailers: EmptyView()
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
                detail: "Show provider names on Discovery content. This does not change what appears.",
                searchTargets: ["hero-provider-labels"]
            ) {
                Toggle("Show provider labels", isOn: $hero.settings.showsDiscoverySources)
                    .modifier(ViewCustomizationRowFocus(id: "hero-provider-labels"))
                    .settingsSearchAnchor("hero-provider-labels")
            }
            HeroSettingsGroup(
                title: "Discovery providers",
                detail: "Recommendations may include content outside your libraries. Seerr is only needed to request it.",
                searchTargets: HeroDiscoverySource.allCases.map { "hero-discovery-\($0.rawValue)" }
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
                    .settingsSearchAnchor("hero-discovery-\(source.rawValue)")
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
            detail: "Choose at least one library. All libraries includes new libraries added to Home.",
            searchTargets: ["hero-all-libraries"]
        ) {
            if eligibleLibraries.isEmpty {
                Text("No movie or TV libraries are enabled on Home.")
            } else {
                Toggle("All libraries on Home", isOn: Binding(
                    get: { hero.settings.randomLibraryKeys.isEmpty },
                    set: { all in hero.settings.randomLibraryKeys = all ? [] : Set(eligibleLibraries.map(\.key)) }
                ))
                .modifier(ViewCustomizationRowFocus(id: "hero-all-libraries"))
                .settingsSearchAnchor("hero-all-libraries")
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
                    .settingsSearchAnchor(
                        "hero-source-\(source.rawValue)",
                        fallbackFor: hero.effectiveSettings.isEnabled(source) ? [] : dependentTargets(for: source)
                    )
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
                            .settingsSearchAnchor("hero-watchlist-rotation")
                    case .continueWatching, .recentlyAdded:
                        EmptyView()
                    }
                }
            }
            #if os(tvOS)
            .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
            .buttonStyle(SettingsFormButtonStyle())
            #else
            .settingsSearchGroup(["hero-source-\(source.rawValue)"] + dependentTargets(for: source))
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

    private func dependentTargets(for source: HeroSourceKind) -> [String] {
        switch source {
        case .randomFromLibrary: return ["hero-choose-libraries"] + SettingsSearchCatalog.targets(on: .heroLibraries)
        case .collection: return ["hero-choose-collections"] + SettingsSearchCatalog.targets(on: .heroCollections)
        case .featured: return SettingsSearchCatalog.targets(on: .heroDiscovery)
        case .watchlist: return ["hero-watchlist-rotation"]
        default: return []
        }
    }
}

private struct HeroSettingsGroup<Content: View>: View {
    var title: LocalizedStringResource? = nil
    var detail: LocalizedStringResource? = nil
    var searchTargets: [String] = []
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
        .settingsSearchGroup(searchTargets)
        #endif
    }
}
#endif
