#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI

enum AppearanceSettingsSection {
    case appearance, screensNavigation, artwork, navigation
}

struct AppearanceDetailView: View {
    /// The household's libraries + per-profile availability, needed by the
    /// navigation-arrangement pane. Passed in (rather than reached for) so this
    /// view stays a plain function of what Settings already resolved.
    let librariesScope: ProfileLibrariesScope
    /// Keeps the selected Appearance feature stable while navigation shell changes.
    let settingsNavigation: SettingsNavigationModel
    var canManageProviders = false
    @Bindable var theme: ThemeSettingsModel
    /// Circadian Mode (night-warming) settings, folded in as sections here — it's
    /// a display concern, so it no longer earns its own top-level row.
    @Bindable var nightShift: NightShiftSettingsModel
    /// Profile-scoped browsing protection, presented under All screens.
    @Bindable var spoilers: SpoilerSettingsModel
    var section: AppearanceSettingsSection = .appearance
    #if os(tvOS)
    @Environment(\.settingsInWorkspace) private var inWorkspace
    #endif
    @Environment(MusicPlayerSettingsModel.self) private var musicPlayer
    /// App-wide card presentation — scale + style — that applies across every row
    /// and grid in the app (not just Home), so it lives in Appearance rather than
    /// Customize Home.
    @Environment(UIDensitySettingsModel.self) private var density
    @Environment(CardStyleSettingsModel.self) private var cardStyle
    @Environment(WatchStatusIndicatorSettingsModel.self) private var watchStatusIndicator
    /// Per-profile navigation chrome + transparency, edited here and injected into
    /// the environment by `MainTabView` (rebuilt on profile switch like the other
    /// per-profile appearance models).
    @Environment(NavigationStyleSettingsModel.self) private var navigation
    @Environment(TransparencyPreferenceModel.self) private var transparency
    @Environment(AppLanguageSettingsModel.self) private var appLanguage

    var body: some View {
        @Bindable var settingsNavigation = settingsNavigation
        Group {
            #if os(tvOS)
            if section == .artwork || section == .navigation,
               let row = allRows.first(where: { $0.id == (section == .artwork ? "artwork" : "navigation") }) {
                SettingsFormRowPage(row: row, route: section == .artwork ? .artwork : .navigationLayout)
            } else {
                SettingsSplitLayout(
                    title: section == .screensNavigation ? "Screens & Navigation" : "Appearance",
                    rows: rows,
                    selection: $settingsNavigation.appearanceRowID
                )
            }
            #else
            SettingsSplitLayout(title: "Appearance", rows: allRows, selection: $settingsNavigation.appearanceRowID)
            #endif
        }
            // Circadian's day/night preview animates a model flag; make sure it
            // never keeps running once you leave Appearance or turn Circadian off.
            .onChange(of: nightShift.settings.isEnabled) { _, enabled in
                if !enabled { nightShift.isPreviewing = false }
            }
            .onDisappear { nightShift.isPreviewing = false }
    }

    private var rows: [SettingsSplitRow] {
        let availableRows = allRows
        if section == .screensNavigation {
            return availableRows.filter { $0.id == "navigation" }.map { $0.destination(.navigationLayout) } + [
                SettingsSplitRow(id: "all-screens", title: "All screens") { EmptyView() }
                    .destination(.allScreens),
                SettingsSplitRow(
                    id: "customize-home", title: "Home",
                    sectionStart: .divider
                ) { EmptyView() }.destination(.customizeHome),
                SettingsSplitRow(id: "customize-libraries", title: "Libraries") { EmptyView() }
                    .destination(.customizeLibraries),
                SettingsSplitRow(id: "title-details", title: "Movie & show details") { EmptyView() }
                    .destination(.detailPage)
            ] + availableRows.filter { $0.id == "music-player" }.map { $0.page() }
        }
        #if os(tvOS)
        if inWorkspace {
            return ["theme", "cards", "artwork", "night-shift"].flatMap { id in
                availableRows.filter { $0.id == id }.map { row in
                    switch id {
                    case "artwork": row.destination(.artwork)
                    default: row.page()
                    }
                }
            }
        }
        #endif
        return availableRows
    }

    private var allRows: [SettingsSplitRow] {
        @Bindable var musicPlayer = musicPlayer
        @Bindable var density = density
        @Bindable var navigation = navigation

        return [
                SettingsSplitRow(
                    id: "language",
                    title: "Language"
                ) {
                    AppLanguagePicker(model: appLanguage)
                }.labeledControl(),
                SettingsSplitRow(
                    id: "theme",
                    title: "Theme"
                ) {
                    themeAndTransparency
                }.groupedContent(),
                SettingsSplitRow(
                    id: "display-size",
                    title: "Display Size",
                    description: "Scales card size, columns and spacing across the app.",
                ) {
                    CompactDisplaySizePicker(selection: $density.density)
                }.illustratedContent(),
                SettingsSplitRow(
                    id: "artwork",
                    title: "Artwork",
                    subpage: SettingsDetailSubpage {
                        ArtworkCustomizationView(
                            cards: cardStyle,
                            continueWatchingShowsSeriesArtwork: librariesScope.homeVisibility.continueWatchingUsesSeriesArtwork,
                            continueWatchingLayout: librariesScope.homeVisibility.continueWatchingLayout
                        )
                    }
                ) {
                    VStack(alignment: .leading, spacing: 32) {
                        ArtworkSettingsControls(
                            cards: cardStyle,
                            continueWatchingShowsSeriesArtwork: librariesScope.homeVisibility.continueWatchingUsesSeriesArtwork,
                            continueWatchingLayout: librariesScope.homeVisibility.continueWatchingLayout
                        )
                        if canManageProviders {
                            #if os(tvOS)
                            SettingsControlGroup { metadataProviderLink }
                            #else
                            metadataProviderLink
                            #endif
                        }
                    }
                }.groupedContent(),
                SettingsSplitRow(
                    id: "cards",
                    title: "Cards",
                    description: "How media cards look across the app.",
                    subpage: SettingsDetailSubpage {
                        CardCaptionCustomizationView(cards: cardStyle, visibility: librariesScope.homeVisibility)
                    }
                ) {
                    cardsControls
                }.groupedContent(),
                SettingsSplitRow(
                    id: "navigation",
                    title: "App navigation"
                ) {
                    NavigationAppearanceDetail(
                        navigation: navigation,
                        librariesScope: librariesScope
                    )
                }.groupedContent(),
                SettingsSplitRow(
                    id: "music-player",
                    title: "Music player",
                    description: "How the now-playing music screen looks.",
                ) {
                    MusicPlayerStyleDetail(
                        appearance: $musicPlayer.appearance,
                        showTrackDetails: $musicPlayer.showTrackDetails
                    )
                }.illustratedContent()
        ] + CircadianRowsBuilder(model: nightShift).rows
    }

    /// Theme cards plus the transparency (liquid-glass) control folded in beneath
    /// them — transparency isn't a top-level concern, so it rides along in the
    /// "overall look" pane rather than owning a row. Its self-explanatory label +
    /// the tri-toggle's focus-following subtext carry the meaning, so it needs no
    /// separate description paragraph.
    @ViewBuilder private var themeAndTransparency: some View {
        @Bindable var transparency = transparency
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
            #if os(tvOS)
            SettingsControlGroup(illustrated: true) { themeControls }
            #else
            themeControls
            #endif
            SettingsDetailGroup(title: "Liquid Glass") {
                DescribedSegmentedPicker(
                    options: TransparencyPreference.allCases,
                    selection: $transparency.preference,
                    title: { $0.displayName },
                    detail: { $0.detail }
                )
            }
        }
    }

    @ViewBuilder private var themeControls: some View {
        CompactThemePicker(selection: $theme.theme)
        Toggle("Gradient Backgrounds", isOn: $theme.gradientEnabled)
    }

    private var metadataProviderLink: some View {
        VStack(alignment: .leading, spacing: SettingsFormMetrics.relatedControlSpacing) {
            Button(action: settingsNavigation.openMetadataProviders) {
                Label("Metadata Providers (TMDB, TheTVDB…)", systemImage: "globe")
            }
            .buttonStyle(SettingsFormButtonStyle())
            .accessibilityIdentifier("artwork-metadata-providers")
            Text("Shared by all profiles.").settingsHelperText()
        }
    }

    /// Everything controlled by the single Navigation master row.
    ///
    /// Style and destination arrangement share one pane for every navigation style.
    private struct NavigationAppearanceDetail: View {
        @Bindable var navigation: NavigationStyleSettingsModel
        let librariesScope: ProfileLibrariesScope

        var body: some View {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                #if os(tvOS)
                SettingsControlGroup(illustrated: true) {
                    CompactNavigationPicker(selection: $navigation.style)
                    Toggle("Prevent Accidental Exit", isOn: $navigation.preventsAccidentalExit)
                }
                #else
                CompactNavigationPicker(selection: $navigation.style)
                #endif

                SettingsDetailGroup(
                    title: "Hide or Reorder Navigation"
                ) {
                    NavigationLibrariesDetailView(
                        scope: librariesScope,
                        navigation: navigation
                    )
                }
            }
        }
    }

    @ViewBuilder private var cardsControls: some View {
        CardAppearanceControls(
            cards: cardStyle, watchIndicator: watchStatusIndicator,
            density: density, visibility: librariesScope.homeVisibility
        )
    }
}

struct AllScreensDetailView: View {
    @Environment(ContentRatingSettingsModel.self) private var contentRatings
    let spoilers: SpoilerSettingsModel

    var body: some View {
        SettingsSplitLayout(title: "All screens", rows: [
            SettingsSplitRow(id: "content-ratings", title: "Show content ratings") {
                ContentRatingToggle(model: contentRatings)
            }.labeledControl()
        ] + SpoilerRowsBuilder(spoilers: spoilers).rows)
    }
}

struct SpoilersDetailView: View {
    @Bindable var spoilers: SpoilerSettingsModel

    var body: some View {
        SettingsSplitLayout(title: "Spoilers", rows: SpoilerRowsBuilder(spoilers: spoilers).rows)
    }
}

/// Shared spoiler controls for Screens & Navigation and the legacy detail layout.
@MainActor
struct SpoilerRowsBuilder {
    let spoilers: SpoilerSettingsModel

    var rows: [SettingsSplitRow] {
        @Bindable var spoilers = spoilers
        return [
            SettingsSplitRow(
                id: "spoilers",
                title: title,
                description: LocalizedStringResource(
                    "settings.spoilers.description",
                    defaultValue: "Hide unwatched episodes and ratings until you've seen them. Blurred ratings reveal when you press them.",
                    comment: "Description under the Spoilers heading in tvOS Settings, explaining what the switches below it do. 'Press' is the Apple TV remote's Select button."
                ),
            ) {
                SettingsControlRows(nonTVSpacing: SettingsMetrics.sectionSpacing) {
                    SettingsRevealSection(
                        isOn: $spoilers.settings.isEnabled,
                        masterLabel: "Hide spoilers for unwatched episodes"
                    ) {
                        SettingsDetailGroup(title: "Mode", illustrated: true) {
                            SpoilerModePicker(mode: $spoilers.settings.mode)
                        }
                    }

                    Toggle("Hide ratings until watched", isOn: $spoilers.settings.hideRatingsUntilWatched)
                        .toggleStyle(SettingsSwitchToggleStyle())
                }
            }
        ]
    }

    private var title: LocalizedStringResource {
        #if os(tvOS)
        "Spoiler Protection"
        #else
        "Spoilers"
        #endif
    }
}
/// Detail-page customization (a sibling to Customize Home): what plays behind the
/// hero on a movie/show detail page — static art, the trailer, or the title's
/// theme music. Kept separate from the Home hero (which lives in Customize Home)
/// and from Playback (which is video-playback behaviour).
struct DetailPageDetailView: View {
    let cards: CardStyleSettingsModel
    @Bindable var themeMusic: ThemeMusicSettingsModel
    @Bindable var heroBackground: HeroBackgroundSettingsModel
    @Environment(\.detailHeaderSettings) private var detailHeaderSettings

    var body: some View {
        SettingsSplitLayout(title: "Movie & show details", rows: heroRows)
    }

    private var heroRows: [SettingsSplitRow] {
        var rows = [
            SettingsSplitRow(
                id: "detail-page-hero-mode",
                title: "Background",
                sectionStart: detailHeaderSettings == nil ? .heading(Text("Hero")) : nil
            ) {
                SettingsControlRows(nonTVSpacing: SettingsMetrics.sectionSpacing) {
                    DescribedSegmentedPicker(
                        options: HeroBackgroundMode.allCases,
                        selection: $heroBackground.settings.detailMode,
                        title: { $0.displayName },
                        detail: { $0.detail }
                    )
                    if heroBackground.settings.detailMode == .trailer {
                        Toggle("Start muted", isOn: $heroBackground.settings.detailTrailerMuted)
                    }
                    if heroBackground.settings.detailMode == .themeMusic {
                        ThemeMusicVolumeControl(model: themeMusic)
                    }
                }
            }
        ]
        if let detailHeaderSettings {
            rows.insert(SettingsSplitRow(
                id: "detail-page-logo-size",
                title: "Logo & text size",
                sectionStart: .heading(Text("Hero"))
            ) {
                DetailLogoSizeSettingsForm(model: detailHeaderSettings)
            }, at: 0)
            rows.append(SettingsSplitRow(
                id: "detail-page-header-ratings",
                title: "Review scores"
            ) {
                DetailHeaderRatingsSettingsForm(model: detailHeaderSettings)
            })
            rows.append(SettingsSplitRow(
                id: "detail-page-age-recommendation",
                title: "Age recommendation"
            ) {
                DetailHeaderAgeSettingsForm(model: detailHeaderSettings)
            })
        }
        rows.append(SettingsSplitRow(
            id: "detail-page-card-labels", title: "Customize labels", sectionStart: .heading(Text("Cards"))
        ) {
            CardCaptionSettingsLink(cards: cards, scope: .detail)
        }.labeledControl())
        return rows
    }
}

private struct DetailLogoSizeSettingsForm: View {
    @Bindable var model: DetailPageSettingsModel

    var body: some View {
        HeroLogoSizeControl(size: $model.settings.logoSize, textSize: $model.settings.textSize, surface: .detail)
    }
}

private struct DetailHeaderRatingsSettingsForm: View {
    @Bindable var model: DetailPageSettingsModel

    var body: some View {
        SettingsControlRows(nonTVSpacing: SettingsMetrics.sectionSpacing) {
            Toggle("Show review scores", isOn: $model.settings.showsHeaderRatings)
            if model.settings.showsHeaderRatings {
                HeaderReviewScoreCountPicker(settings: $model.settings)
            }
        }
    }
}

private struct DetailHeaderAgeSettingsForm: View {
    @Bindable var model: DetailPageSettingsModel

    var body: some View {
        Toggle("Show Common Sense age", isOn: $model.settings.showsHeaderFamilyGuidance)
    }
}

enum PlaybackSettingsSection {
    case playback, subtitles
}

struct PlaybackDetailView: View {
    @Environment(\.locale) private var locale
    #if os(tvOS)
    @Environment(\.settingsInWorkspace) private var inWorkspace
    #else
    @State private var showsSkipMarkerSettings = false
    #endif
    @Bindable var playback: PlaybackSettingsModel
    /// The profile base subtitle mode/language now lives in `SubtitleBehavior`
    /// (behaviour half of the retired `CaptionSettings`).
    @Bindable var subtitleBehavior: SubtitleBehaviorModel
    /// Profile appearance shared by Settings and the in-player editor.
    @Bindable var subtitleStyle: SubtitleStyleModel
    /// Per-content-type overrides ("forced-only on movies, full subs on anime").
    @Bindable var subtitlePolicy: SubtitlePolicyModel
    /// Per-content-type audio-language overrides ("original audio for anime,
    /// device language for everything else").
    @Bindable var audioPolicy: AudioPolicyModel
    /// Whether the active profile has a server that can download subtitles
    /// (Jellyfin or Plex). SDH selection is independent of this capability.
    var canDownloadSubtitles: Bool = true
    var section: PlaybackSettingsSection = .playback

    /// The three classifiable content types the per-type rules apply to, in the
    /// order shown in Settings (`.other` always follows the base, so it isn't
    /// shown as its own row).
    private static let policyCategories: [SubtitleContentCategory] = [.movie, .tvShow, .anime]

    /// Whether the profile has opted into per-content-type rules (any override set).
    private var perContentTypeEnabled: Bool { !subtitlePolicy.overrides.isEmpty }

    /// The profile base rule, derived live from the subtitle behaviour settings.
    private var baseRule: SubtitlePolicy.Rule {
        SubtitlePolicy.inheriting(from: subtitleBehavior.settings).basePolicy
    }

    /// Toggles the whole per-content-type matrix: adopting the smart seed
    /// (forced-only movies, full anime/TV) on, or clearing back to the single
    /// base everywhere off.
    private var perContentTypeBinding: Binding<Bool> {
        Binding(
            get: { perContentTypeEnabled },
            set: { on in
                subtitlePolicy.overrides = on
                    ? SubtitlePolicy.smartDefaultOverrides(base: baseRule)
                    : [:]
            }
        )
    }

    /// A picker binding for one category's subtitle mode, falling back to the
    /// base mode when no override is stored yet.
    private func modeBinding(for category: SubtitleContentCategory) -> Binding<SubtitleMode> {
        Binding(
            get: { subtitlePolicy.overrides[category]?.mode ?? baseRule.mode },
            set: { newMode in
                var rule = subtitlePolicy.overrides[category] ?? baseRule
                rule.mode = newMode
                subtitlePolicy.overrides[category] = rule
            }
        )
    }

    // MARK: Subtitle-language helpers

    private var subtitleLanguageOptions: [String] {
        [""] + SubtitleLanguageCatalog.languages.map(\.code)
    }

    private var subtitleLanguageSelection: Binding<String> {
        Binding(
            get: { subtitleBehavior.settings.preferredSubtitleLanguage ?? "" },
            set: { subtitleBehavior.settings.preferredSubtitleLanguage = $0.isEmpty ? nil : $0 }
        )
    }

    private func subtitleLanguageName(for code: String) -> Text {
        guard !code.isEmpty else { return Text("Device Default") }
        return Text(
            verbatim: SubtitleLanguageCatalog.displayName(
                forCode: code,
                in: locale
            ) ?? code
        )
    }

    // MARK: Audio-language policy helpers

    /// The selectable audio-language preferences for the dropdowns: Original /
    /// Device, then the shared common-language list.
    private static let audioPreferenceOptions: [AudioLanguagePreference] =
        [.original, .device] + SubtitleLanguageCatalog.languages.map { .language($0.code) }

    /// Human-readable label for an audio-language preference.
    private func audioPreferenceName(
        _ preference: AudioLanguagePreference
    ) -> Text {
        switch preference {
        case .original: return Text("Original")
        case .device: return Text("Device")
        case .language(let code):
            return Text(
                verbatim: SubtitleLanguageCatalog.displayName(
                    forCode: code,
                    in: locale
                ) ?? code
            )
        }
    }

    /// Whether the profile has opted into per-content-type audio rules.
    private var audioPerContentTypeEnabled: Bool { !audioPolicy.overrides.isEmpty }

    /// Toggles the whole per-content-type audio matrix: adopting the smart seed
    /// (original audio for anime, device language for movies/TV) on, or clearing
    /// back to the single base preference everywhere off.
    private var audioPerContentTypeBinding: Binding<Bool> {
        Binding(
            get: { audioPerContentTypeEnabled },
            set: { on in
                audioPolicy.overrides = on
                    ? AudioPolicy.smartDefaultOverrides()
                    : [:]
            }
        )
    }

    /// A dropdown binding for one category's audio-language preference, falling
    /// back to the base preference when no override is stored yet.
    private func audioPreferenceBinding(for category: ContentCategory) -> Binding<AudioLanguagePreference> {
        Binding(
            get: { audioPolicy.overrides[category] ?? playback.settings.audioLanguagePreference },
            set: { audioPolicy.overrides[category] = $0 }
        )
    }

    /// A native pop-up menu for choosing an audio-language preference (the
    /// common-language list is too long for the inline pill picker).
    @ViewBuilder
    private func audioLanguageMenu(
        _ selection: Binding<AudioLanguagePreference>,
        title: LocalizedStringResource,
        subtitle: LocalizedStringResource? = nil
    ) -> some View {
        SettingsMenuRow(
            title: title, value: audioPreferenceName(selection.wrappedValue), subtitle: subtitle
        ) {
            Picker("Audio language", selection: selection) {
                ForEach(Self.audioPreferenceOptions, id: \.self) { preference in
                    audioPreferenceName(preference).tag(preference)
                }
            }
        }
    }

    var body: some View {
        SettingsSplitLayout(title: section == .subtitles ? "Subtitles" : "Playback", rows: rows)
            #if !os(tvOS)
            .navigationDestination(isPresented: $showsSkipMarkerSettings) {
                SkipMarkerSettingsView(model: playback)
            }
            #endif
    }

    // MARK: - Split sections

    private var versionSelectionRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "version-selection", title: "Version selection",
                description: "Ask before each multi-version video, including autoplay, or choose automatically without opening the version picker."
            ) {
                #if os(tvOS)
                SettingsControlRows {
                    if playback.settings.versionSelectionMode == nil {
                        Text("Choose on first play")
                            .settingsHelperText()
                    }
                    ForEach(PlaybackVersionSelectionMode.allCases, id: \.self) { mode in
                        SettingsCheckableRow(
                            title: Text(mode.title), titleLineLimit: nil,
                            isChecked: playback.settings.versionSelectionMode == mode
                        ) {
                            playback.settings.versionSelectionMode = mode
                        }
                    }
                }
                #else
                PlaybackVersionPreferencePicker(model: playback)
                #endif
            },
            SettingsSplitRow(
                id: "remember-series-version", title: "Remember series version choices",
                description: "Reuse the version type you pick for later episodes. When choosing automatically, use the best available version if that type is missing."
            ) {
                Toggle("Remember per series", isOn: $playback.settings.rememberVersionPerSeries)
                    .accessibilityIdentifier("playback-remember-series-version")
            }
        ]
    }

    private var rows: [SettingsSplitRow] {
        #if os(tvOS)
        if inWorkspace {
            if section == .subtitles { return subtitleRows }
            return [
                SettingsSplitRow(id: "audio", title: "Audio") {
                    SettingsConnectedControlGroups {
                        ForEach(audioRows) { row in
                            VStack(alignment: .leading, spacing: SettingsFormMetrics.relatedControlSpacing) {
                                row.detail()
                                if let description = row.description {
                                    description.settingsHelperText().fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }.groupedContent(),
                SettingsSplitRow(id: "autoplay-up-next", title: "Autoplay & Up Next") {
                    SettingsConnectedControlGroups {
                        ForEach(upNextRows) { $0.detail() }
                    }
                }.groupedContent()
            ] + versionSelectionRows + readAheadRows + skipIntroRows + [
                SettingsSplitRow(id: "seeking", title: "Seeking") {
                    SettingsControlRows {
                        ForEach(skipIntervalRows) { $0.detail() }
                        ForEach(resumeRows) { $0.detail() }
                        ForEach(scrubbingRows) { row in
                            VStack(alignment: .leading, spacing: SettingsFormMetrics.relatedControlSpacing) {
                                row.detail()
                                if let description = row.description {
                                    description.settingsHelperText().fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            ] + displayFadeRows + advancedRows
        }
        #endif
        return subtitleRows
            + audioRows
            + versionSelectionRows
            + skipIntroRows
            + skipIntervalRows
            + resumeRows
            + readAheadRows
            + scrubbingRows
            + displayFadeRows
            + upNextRows
            + advancedRows
    }

    private var advancedRows: [SettingsSplitRow] {
        [.page(id: "playback-advanced", title: "Advanced") {
            PlaybackAdvancedSettingsView.rows(playback: playback)
        }]
    }

    private var readAheadRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(id: "read-ahead", title: "Video buffer") {
                PlaybackReadAheadControl()
            }.labeledControl(),
            SettingsSplitRow(id: "live-buffer", title: "Live TV buffer") {
                LivePlaybackBufferControl()
            }.labeledControl()
        ]
    }

    private var subtitleRows: [SettingsSplitRow] {
        var rows: [SettingsSplitRow] = [
            SettingsSplitRow(
                id: "subtitle-default",
                title: "Show subtitles",
                description: "What Plozz does with subtitles when playback starts."
            ) {
                SubtitleModeControl(
                    baseMode: $subtitleBehavior.settings.subtitleMode,
                    perTypeEnabled: perContentTypeBinding,
                    categories: Self.policyCategories,
                    categoryMode: { modeBinding(for: $0) }
                )
            },
            SettingsSplitRow(
                id: "subtitle-language",
                title: "Subtitle language",
                description: "The language Plozz prefers when choosing subtitles."
            ) {
                SettingsMenuRow(
                    title: "Subtitle language",
                    value: subtitleLanguageName(for: subtitleLanguageSelection.wrappedValue)
                ) {
                    Picker("Subtitle language", selection: subtitleLanguageSelection) {
                        ForEach(subtitleLanguageOptions, id: \.self) { code in
                            subtitleLanguageName(for: code).tag(code)
                        }
                    }
                }
            }.labeledControl(),
            SettingsSplitRow(
                id: "subtitle-sdh",
                title: "SDH subtitles",
                description: subtitleBehavior.settings.hearingImpairedPreference.detail
            ) {
                SettingsMenuRow(
                    title: "SDH subtitles",
                    value: Text(subtitleBehavior.settings.hearingImpairedPreference.displayName)
                ) {
                    Picker("SDH subtitles", selection: $subtitleBehavior.settings.hearingImpairedPreference) {
                        ForEach(HearingImpairedPreference.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }
            }.labeledControl()
        ]

        // "Downloading subtitles" only makes sense with a server that can actually
        // fetch them (Jellyfin/Plex). A share-only profile can't download — it can
        // only use sidecar files already on the share — so hide the row entirely
        // rather than imply downloading works.
        if canDownloadSubtitles {
            rows.append(SettingsSplitRow(
                id: "subtitle-downloading",
                title: "Downloading subtitles",
                description: "Download subtitles you don't already have."
            ) {
                SettingsControlRows(nonTVSpacing: 28) {
                    Toggle("Automatically download", isOn: $subtitleBehavior.settings.autoDownloadSubtitles)
                    SettingsMenuRow(
                        title: "Forced",
                        value: Text(subtitleBehavior.settings.forcedSearchPreference.displayName)
                    ) {
                        Picker("Forced subtitles", selection: $subtitleBehavior.settings.forcedSearchPreference) {
                            ForEach(ForcedSubtitlePreference.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            })
        }

        rows.append(SettingsSplitRow(
            id: "subtitle-remember",
            title: "Remember subtitles per series",
            description: "Reuse the subtitle you pick for the rest of a series."
        ) {
            Toggle("Remember per series", isOn: $playback.settings.rememberSubtitleTrackPerSeries)
        })

        #if os(tvOS)
        rows.insert(contentsOf: subtitleStyleRows, at: 1)
        #else
        rows.append(contentsOf: subtitleStyleRows)
        #endif
        return rows
    }

    private var subtitleStyleRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "subtitle-style",
                title: "Subtitle style",
                description: "Use the full player controls to customize subtitles, with a live preview."
            ) {
                SettingsRouteLink("Customize subtitle style", value: SettingsRoute.subtitleStyle(liveTV: false))
            },
            SettingsSplitRow(
                id: "live-subtitle-style",
                title: "Live TV subtitle style",
                description: "Use the same subtitle appearance everywhere, or choose a separate look for Live TV."
            ) {
                SettingsControlRows {
                    Toggle("Use a separate style for Live TV", isOn: $subtitleStyle.usesSeparateLiveTVStyle)
                    if subtitleStyle.usesSeparateLiveTVStyle {
                        SettingsRouteLink("Customize Live TV subtitles", value: SettingsRoute.subtitleStyle(liveTV: true))
                    }
                }
            }
        ]
    }

    var audioRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "audio-defaults",
                title: "Audio defaults"
            ) {
                SettingsControlRows(nonTVSpacing: 32) {
                    // Set separately, "Everything else" takes over the one
                    // preference, so it isn't shown twice.
                    if !audioPerContentTypeEnabled {
                        audioLanguageMenu(
                            $playback.settings.audioLanguagePreference, title: "Preferred audio language"
                        )
                    }

                    SettingsRevealSection(
                        isOn: audioPerContentTypeBinding,
                        masterLabel: "Set separately for movies, TV shows & anime"
                    ) {
                        ForEach(Self.policyCategories + [.other], id: \.self) { category in
                            audioLanguageMenu(
                                category == .other
                                    ? $playback.settings.audioLanguagePreference
                                    : audioPreferenceBinding(for: category),
                                title: category.separateSettingTitle, subtitle: category.separateSettingHint
                            )
                        }
                    }

                    Toggle("Remember audio language per series", isOn: $playback.settings.rememberAudioTrackPerSeries)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            },
            SettingsSplitRow(id: "lossless-surround", title: "Audio") {
                SettingsControlRows {
                    LosslessAudioControl()
                    SpatialAudioControl(isOn: $playback.settings.trueHDAtmosEnabled)
                }
            }
        ]
    }

    private var skipIntroRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "skip-intros-mode",
                title: "Skip intros, credits & more"
            ) {
                #if os(tvOS)
                SkipMarkerSettingsControl(model: playback)
                #else
                SkipMarkerSettingsControl(model: playback, onOpenSettings: { showsSkipMarkerSettings = true })
                #endif
            }.labeledControl()
        ]
    }

    private var skipIntervalRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "skip-intervals",
                title: "Skip Intervals",
                description: "How far the remote's left and right buttons jump during playback.",
            ) {
                SettingsControlRows(nonTVSpacing: 28) {
                    SettingsStepper(
                        options: SkipInterval.allCases,
                        selection: $playback.settings.skipBackwardInterval,
                        label: "Backward",
                        verbatimTitle: { $0.title(locale: locale) }
                    )
                    SettingsStepper(
                        options: SkipInterval.allCases,
                        selection: $playback.settings.skipForwardInterval,
                        label: "Forward",
                        verbatimTitle: { $0.title(locale: locale) }
                    )
                }
            }
        ]
    }

    private var resumeRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(id: "ask-before-resuming", title: "Ask to resume or start over") {
                Toggle("Ask to resume or start over", isOn: $playback.settings.askBeforeResuming)
                    .accessibilityIdentifier("playback-ask-before-resuming")
            },
            SettingsSplitRow(
                id: "resume-rewind",
                title: "Rewind on resume",
                description: "When you return to a partially-watched title, playback starts a little before where you left off. Set anywhere from 0 to 60 seconds.",
            ) {
                VStack(alignment: .leading, spacing: 20) {
                    resumeRewindStepper
                    Text(playback.settings.resumeRewindInterval.effectDescription)
                        .settingsHelperText()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        ]
    }

    private var resumeRewindStepper: some View {
        SettingsStepper(
            options: ResumeRewindInterval.allCases,
            selection: $playback.settings.resumeRewindInterval,
            label: resumeRewindLabel,
            verbatimTitle: { $0.title(locale: locale) }
        )
    }

    private var resumeRewindLabel: LocalizedStringResource? {
        #if os(tvOS)
        inWorkspace ? "Rewind on resume" : nil
        #else
        nil
        #endif
    }

    private var scrubbingRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "seek-without-pausing",
                title: "Seek without pausing",
                description: playback.settings.seekWithoutPausing
                    ? "Swipe to scrub while a title is playing and it resumes the moment you land — faster, but a stray swipe can move your position."
                    : "You must pause before you can scrub — a swipe while playing won't seek or pause. Pause (Play/Pause, or center-press the scrubber), scrub, then press Play to resume. Prevents accidental seeks.",
            ) {
                Toggle("Seek without pausing", isOn: $playback.settings.seekWithoutPausing)
            }
        ]
    }

    /// Both display fades live in ONE row. They're the same idea — hide the blank
    /// your TV shows while it renegotiates the picture — and splitting them made
    /// the page imply a "Display Transitions" grouping the flat master list never
    /// renders. The toggles are labelled by what they cover, so they need no
    /// headers or per-toggle paragraphs above them.
    private var displayFadeRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "display-fades",
                title: "Fade on display changes",
                description: "If you don't match dynamic range or frame rate on your Apple TV, turn these off for faster transitions.",
            ) {
                SettingsControlRows {
                    // "HDR" and "Dolby Vision" are both `neverTranslate` brands, so
                    // this label must reach the UI verbatim rather than entering the
                    // catalog where a translator would have no way to know that.
                    Toggle(isOn: $playback.settings.fadeOnDynamicRangeChange) {
                        Text(verbatim: "HDR & Dolby Vision")
                    }
                    Toggle("Frame rate", isOn: $playback.settings.fadeOnFrameRateChange)
                }
            }
        ]
    }

    /// Autoplay and the Up Next card, in that order: whether the next episode
    /// starts, then whether you're told about it first. They're independent (see
    /// ``PlaybackSettings/autoPlayNextEpisode``), so the card's own controls stay
    /// available with autoplay off — the card is still a one-press shortcut.
    private var upNextRows: [SettingsSplitRow] {
        [
            SettingsSplitRow(
                id: "autoplay-next-episode",
                title: "Autoplay"
            ) {
                SettingsControlRows(nonTVSpacing: 8) {
                    Toggle("Autoplay next episode", isOn: $playback.settings.autoPlayNextEpisode)
                    Toggle("Autoplay next playlist item", isOn: $playback.settings.autoPlayNextPlaylistItem)
                }
            },
            SettingsSplitRow(
                id: "show-up-next-card",
                title: "Show Up Next card",
                description: "Jump straight to the next episode.",
            ) {
                SettingsControlRows {
                    Toggle("Show Up Next card", isOn: $playback.settings.showUpNextCard)
                    if playback.settings.showUpNextCard {
                        SettingsStepper(
                            options: PlaybackSettings.upNextLeadSecondsOptions,
                            selection: $playback.settings.upNextLeadSeconds,
                            label: "Time before the end", subtitle: "When credits can't be detected",
                            verbatimTitle: { Duration.seconds($0).formatted(.units(allowed: [.seconds], width: .narrow)) }
                        )
                    }
                }
            }
        ]
    }
}

/// A `SettingsSegmentedPicker` paired with a live description of what the
/// *focused* option does. Moving focus across the segments updates the line
/// beneath immediately — before you commit with Select — so each option's
/// behavior is explained as you browse, not only after you pick. When focus
/// isn't in the picker it falls back to describing the current selection.
private struct DescribedSegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> LocalizedStringResource
    let detail: (Option) -> LocalizedStringResource

    @State private var focusedOption: Option?

    /// Focused option wins (live browsing); otherwise describe what's selected.
    private var describedOption: Option { focusedOption ?? selection }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSegmentedPicker(
                options: options,
                selection: $selection,
                title: title,
                onFocusedOptionChange: { focusedOption = $0 }
            )
            Text(detail(describedOption))
                .settingsHelperText()
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeInOut(duration: 0.18), value: describedOption)
    }
}

/// The unified "Show subtitles" control: an Off / On / Forced Only tri-toggle
/// with its explanation directly beneath, or, set separately, a
/// ``SeparateSettingRow`` each for movies, TV shows, anime and "Everything else"
/// (which takes over the one mode).
private struct SubtitleModeControl: View {
    @Binding var baseMode: SubtitleMode
    @Binding var perTypeEnabled: Bool
    let categories: [SubtitleContentCategory]
    let categoryMode: (SubtitleContentCategory) -> Binding<SubtitleMode>

    var body: some View {
        SettingsControlRows(nonTVSpacing: 32) {
            if !perTypeEnabled {
                DescribedSegmentedPicker(
                    options: SubtitleMode.allCases,
                    selection: $baseMode,
                    title: { $0.displayName },
                    detail: { $0.detail }
                )
                .transition(.opacity)
            }

            SettingsRevealSection(
                isOn: $perTypeEnabled,
                masterLabel: "Set separately for movies, TV shows & anime"
            ) {
                ForEach(categories + [.other], id: \.self) { category in
                    SeparateSettingRow(
                        title: category.separateSettingTitle,
                        hint: category.separateSettingHint,
                        // Short names sit beside their pickers; "Everything
                        // else" and its hint need the width above.
                        namePlacement: category == .other ? .above : .beside,
                        options: SubtitleMode.allCases,
                        // "Everything else" edits the one mode, which covers
                        // whatever the named types don't.
                        selection: category == .other ? $baseMode : categoryMode(category),
                        optionTitle: { $0.displayName },
                        detail: { $0.detail }
                    )
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: perTypeEnabled)
    }
}

/// One row of a "set separately" reveal: its name (and a hint, when the name
/// alone doesn't say what it covers) beside or above its picker, and the focused
/// option's explanation beneath the picker while it has focus.
private struct SeparateSettingRow<Option: Hashable>: View {
    enum NamePlacement { case beside, above }

    let title: LocalizedStringResource
    let hint: LocalizedStringResource?
    let namePlacement: NamePlacement
    let options: [Option]
    @Binding var selection: Option
    let optionTitle: (Option) -> LocalizedStringResource
    let detail: (Option) -> LocalizedStringResource

    @State private var focusedOption: Option?

    /// The name column beside a picker, so pickers down the reveal line up.
    private static var nameWidth: CGFloat { 240 }
    private static var nameSpacing: CGFloat { 24 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch namePlacement {
            case .beside:
                LabeledSettingRow(title, subtitle: hint, labelWidth: Self.nameWidth) { picker }
            case .above:
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                        .font(SettingsRowMetrics.titleFont)
                    if let hint {
                        Text(hint)
                            .settingsHelperText()
                    }
                }
                picker
            }
            if let focusedOption {
                Text(detail(focusedOption))
                    .settingsHelperText()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Under the picker, not the name.
                    .padding(.leading, namePlacement == .beside ? Self.nameWidth + Self.nameSpacing : 0)
                    .transition(.opacity)
            }
        }
        .padding(.top, namePlacement == .above ? 8 : 0)
        .animation(.easeInOut(duration: 0.18), value: focusedOption)
    }

    private var picker: some View {
        SettingsSegmentedPicker(
            options: options,
            selection: $selection,
            title: optionTitle,
            onFocusedOptionChange: { focusedOption = $0 }
        )
    }
}
#endif
