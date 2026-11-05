#if canImport(SwiftUI)
import SwiftUI
import CoreModels
#if canImport(UIKit)
import UIKit
#endif

/// Shared title-level detail sections. Platform shells keep their own Cast rail
/// first, then place this view beneath it so content and ordering stay identical
/// while the adaptive grids naturally collapse on iPhone.
enum DetailInformationLayout {
    static let labelSpacing = PlozzTheme.Spacing.xSmall
    #if os(tvOS)
    static let cellPadding = PlozzTheme.Spacing.large
    static let gutter = PlozzTheme.Spacing.large
    static let focusPadding: CGFloat = 22
    static let factSpacing = focusPadding * 2 + PlozzTheme.Spacing.small
    static let sectionSpacing = factSpacing
    static let headingSpacing = PlozzTheme.Spacing.medium
    static let cornerRadius: CGFloat = 20
    #else
    static let cellPadding = PlozzTheme.Spacing.medium
    static let gutter = PlozzTheme.Spacing.medium
    static let factSpacing = gutter
    static let sectionSpacing = PlozzTheme.Spacing.xLarge
    static let headingSpacing = PlozzTheme.Spacing.small
    static let cornerRadius: CGFloat = 16
    static let maximumMobileContentWidth: CGFloat = 1120
    #endif
}

public struct DetailInformationSections: View {
    static let bandFillOpacity = 0.4

    private let item: MediaItem
    private let horizontalInset: CGFloat
    private let selectedSource: MediaSourceRef?
    private let selectedVersion: MediaVersion?
    private let externalAvailability: ExternalTitleAvailability?
    /// The viewer's spoiler protection. Ratings honour it here exactly as the
    /// heroes above do — the section is blurred, not removed, so a deliberate
    /// press can still lift it.
    private let spoilerSettings: SpoilerSettings
    /// Only omit prose already accessible in the header. A focused episode
    /// can have a different synopsis from the series represented below.
    private let overviewAlreadyShown: String?

    @State private var showsFullOverview = false
    @State private var expandedGroup: InformationGroup?
    @State private var ratingsRevealed = false
    @State private var overviewFullHeight: CGFloat = 0
    @State private var overviewVisibleHeight: CGFloat = 0
    @Environment(\.themePalette) private var palette
    @Environment(\.gradientBackgroundsEnabled) private var gradientEnabled
    @Environment(\.plozzShowsContentRatings) private var showsContentRatings
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    public init(
        item: MediaItem,
        horizontalInset: CGFloat,
        selectedSource: MediaSourceRef? = nil,
        selectedVersion: MediaVersion? = nil,
        externalAvailability: ExternalTitleAvailability? = nil,
        spoilerSettings: SpoilerSettings = .default,
        overviewAlreadyShown: String? = nil
    ) {
        self.item = item
        self.horizontalInset = horizontalInset
        self.selectedSource = selectedSource
        self.selectedVersion = selectedVersion
        self.externalAvailability = externalAvailability
        self.spoilerSettings = spoilerSettings
        self.overviewAlreadyShown = overviewAlreadyShown
    }

    public var body: some View {
        Group {
            if let url = item.metadataProvenance.wetrakrWatchlistURL {
                WetrakrWatchlistLink(url: url)
                    .frame(maxWidth: maximumContentWidth, alignment: .leading)
                    .padding(.horizontal, horizontalInset)
                    .frame(maxWidth: .infinity)
            }
            if hasContent {
                sectionBody
                    .environment(\.plozzNativeInformationFocus, true)
                    .plozzAdaptiveCardSurface(fillOpacity: ThemePalette.detailGradientSurfaceFillOpacity)
                    .frame(maxWidth: maximumContentWidth, alignment: .leading)
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, bandTopPadding)
                    .padding(.bottom, bandBottomPadding)
                    .frame(maxWidth: .infinity)
                    .background {
                        palette.informationSurface
                            .opacity(gradientEnabled && !reduceTransparency ? Self.bandFillOpacity : 1)
                            .padding(.horizontal, -Self.backgroundBleed)
                            .padding(.bottom, -Self.backgroundBleed)
                    }
            }
        }
        .plozzSheet(item: $expandedGroup, style: .detailReader) { group in
            DetailMoreSheet(title: Text(group.title)) {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if let current = informationGroups.first(where: { $0.id == group.id }) {
                        ForEach(current.facts) { fact in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(fact.label)
                                    #if os(tvOS)
                                    .font(.system(size: 26))
                                    #else
                                    .font(.subheadline.weight(.semibold))
                                    #endif
                                    .plozzForeground(.secondary)
                                    .accessibilityAddTraits(.isHeader)
                                if let values = fact.listValues {
                                    ForEach(values, id: \.self) { value in
                                        Text(value).fixedSize(horizontal: false, vertical: true)
                                            .plozzForeground(.primary)
                                            #if os(tvOS)
                                            .focusable()
                                            #endif
                                    }
                                } else {
                                    Text(fact.value).fixedSize(horizontal: false, vertical: true)
                                        .plozzForeground(.primary)
                                        #if os(tvOS)
                                        .focusable()
                                        #endif
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .onChange(of: [item.id, item.sourceAccountID, selectedSource?.accountID]) { _, _ in
            showsFullOverview = false
            expandedGroup = nil
            ratingsRevealed = false
        }
        .onChange(of: sectionIDs) { _, _ in
            if let expandedGroup, !informationGroups.contains(where: { $0.id == expandedGroup.id }) {
                self.expandedGroup = nil
            }
        }
        .onChange(of: hidesRatings) { _, _ in ratingsRevealed = false }
    }

    /// Overshoot for the band's tint. Generous on purpose: it only has to exceed
    /// the largest inset it might be sitting inside (tvOS overscan, an iPhone home
    /// indicator, a tab bar), and the screen edge does the clipping. It is drawn
    /// behind the content and below the last of it, so there is nothing for the
    /// overshoot to cover up.
    private static let backgroundBleed: CGFloat = 400

    private var maximumContentWidth: CGFloat {
        #if os(tvOS)
        .infinity
        #else
        horizontalSizeClass == .regular ? DetailInformationLayout.maximumMobileContentWidth : .infinity
        #endif
    }

    @ViewBuilder
    private var sectionBody: some View {
        if isSingleRating {
            DetailSingleRatingLayout(
                preferredColumns: informationSectionColumns,
                minimumColumnWidth: informationSectionMinimumWidth,
                ratingMinimumWidth: ratingMinimumWidth,
                hasOverview: hasAbout,
                hasDetails: !detailFacts.isEmpty,
                spacing: sectionSpacing
            ) {
                if hasAbout { aboutSection }
                ratingsSection
                if let details = informationGroups.first(where: { $0.id == "details" }) {
                    informationGroup(details)
                }
                ForEach(informationGroups.filter { $0.id != "details" }) { group in
                    informationGroup(group)
                }
            }
        } else {
            standardSectionBody
        }
    }

    private var aboutSection: some View {
        detailSection(title: LocalizedStringResource(
            "mediaDetail.section.about",
            defaultValue: "About",
            comment: "Header of the synopsis section on a movie or series detail page. A noun meaning 'about this title', not the Settings > About page."
        )) {
            aboutContent.frame(maxWidth: .infinity, alignment: .leading)
        }
        .id("about")
    }

    private var ratingsSection: some View {
        detailSection(title: "Ratings") { ratingsContent }
            .id("ratings")
    }

    private var isSingleRating: Bool {
        sortedRatings.count == 1 && familyGuidanceSummary == nil
    }

    private var standardSectionBody: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            if hasAbout || hasRatings {
                DetailSummaryLayout(
                    minimumColumnWidth: informationSectionMinimumWidth,
                    preferredColumns: informationSectionColumns,
                    hasOverview: hasAbout,
                    ratingsWidth: ratingsWidth,
                    fillsRatingsColumn: expandsRatingsToAvailableWidth,
                    maximumRatingsColumnSpan: maximumRatingsColumnSpan,
                    spacing: sectionSpacing
                ) {
                    if hasAbout {
                        aboutSection
                    }
                    if hasRatings {
                        ratingsSection
                    }
                }
            }
            if !informationGroups.isEmpty {
                DetailSectionLayout(
                    preferredColumns: informationSectionColumns,
                    minimumColumnWidth: informationSectionMinimumWidth,
                    spacing: sectionSpacing
                ) {
                    ForEach(informationGroups) { group in
                        informationGroup(group)
                    }
                }
            }
        }
    }

    private func informationGroup(_ group: InformationGroup) -> some View {
        DetailInformationGroup(
            group: group,
            titleFont: group.id == "playback" ? technicalTitleFont : sectionTitleFont,
            labelFont: factLabelFont,
            valueFont: group.id == "playback" ? technicalValueFont : factValueFont,
            pairsShortFacts: group.id == "details" && informationSectionColumns > 1
        ) {
            expandedGroup = group
        }
        .id(group.id)
    }

    private var ratingColumns: Int {
        let count = sortedRatings.count
        #if os(tvOS)
        if count == 4, familyGuidanceSummary == nil { return 4 }
        #endif
        let columns = familyGuidanceSummary != nil ? max(2, count + 1) : (count > 3 ? (count + 1) / 2 : count)
        return max(1, min(4, columns))
    }

    private var ratingsWidth: CGFloat {
        let columns = ratingColumns
        return CGFloat(columns) * ratingMinimumWidth + CGFloat(columns - 1) * informationColumnSpacing
    }

    private var ratingMinimumWidth: CGFloat {
        #if os(tvOS)
        220
        #else
        mobileRatingMinimumWidth
        #endif
    }

    private var ratingsContent: some View {
        protectedRating {
            ProportionalWrapLayout(
                preferredColumns: ratingColumns,
                minimumCellWidth: ratingMinimumWidth,
                spacing: informationColumnSpacing,
                rowSpacing: informationRowSpacing,
                lastSubviewFillsRemainingColumns: familyGuidanceSummary != nil,
                maximumLastSubviewSpan: maximumGuidanceSpan,
                fillsProposedHeight: true
            ) {
                ForEach(sortedRatings) { rating in
                    RatingTile(rating: rating)
                        .accessibilityIdentifier("detail-rating-\(rating.source.rawValue)")
                }
                if let summary = familyGuidanceSummary {
                    FamilyGuidanceTile(item: item, summary: summary)
                        .id(item.stablePresentationID)
                }
            }
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Ratings")
        }
        .frame(maxWidth: expandsRatingsToAvailableWidth ? .infinity : ratingsWidth, alignment: .leading)
    }

    private var expandsRatingsToAvailableWidth: Bool {
        #if os(tvOS)
        true
        #else
        horizontalSizeClass == .regular || sortedRatings.count > 1 || familyGuidanceSummary != nil
        #endif
    }

    private var maximumRatingsColumnSpan: Int {
        #if os(tvOS)
        sortedRatings.count + (familyGuidanceSummary == nil ? 0 : 1) > 1 ? 2 : 1
        #else
        1
        #endif
    }

    private var maximumGuidanceSpan: Int? {
        #if os(tvOS)
        2
        #else
        nil
        #endif
    }

    var sectionIDs: [String] {
        var result: [String] = []
        if hasAbout { result.append("about") }
        if hasRatings { result.append("ratings") }
        if isSingleRating, !detailFacts.isEmpty { result.append("details") }
        result += informationGroups.filter { !isSingleRating || $0.id != "details" }.map(\.id)
        return result
    }

    private var bandTopPadding: CGFloat {
        #if os(tvOS)
        44
        #else
        horizontalSizeClass == .regular ? 32 : 24
        #endif
    }

    private var bandBottomPadding: CGFloat {
        #if os(tvOS)
        60
        #else
        horizontalSizeClass == .regular ? 44 : 32
        #endif
    }

    #if !os(tvOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .body) private var mobileColumnMinimumWidth: CGFloat = 200
    @ScaledMetric(relativeTo: .body) private var mobileRatingMinimumWidth: CGFloat = 160
    #endif

    private func protectedRating<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        SpoilerRevealBox(
            isHidden: hidesRatings && !ratingsRevealed,
            prompt: LocalizedStringResource(
                "mediaDetail.ratings.reveal",
                defaultValue: "Show Ratings",
                comment: "Button over the blurred Ratings section of a title's detail page; pressing it reveals scores that spoiler protection is hiding."
            ),
            identity: item.id,
            onReveal: { ratingsRevealed = true }
        ) {
            content()
        }
    }

    /// Whether spoiler protection currently covers this title's scores.
    ///
    /// Deliberately the same `shouldHideRatings` the detail and Home heroes ask,
    /// so one setting cannot produce two answers on a single screen: an unwatched
    /// movie whose hero badges are suppressed must not have its scores printed at
    /// display size two sections further down.
    private var hidesRatings: Bool {
        spoilerSettings.shouldHideRatings(for: item)
    }
    private var hasContent: Bool {
        hasAbout || hasRatings || !informationGroups.isEmpty
    }

    var hasAbout: Bool {
        guard let overview = nonempty(item.overview) else { return false }
        return overview != nonempty(overviewAlreadyShown)
    }

    /// `S1 · E1` for an episode, `nil` for anything else.
    private var seasonEpisodeLocator: String? {
        guard item.kind == .episode,
              let season = item.seasonNumber,
              let episode = item.episodeNumber
        else { return nil }
        return "S\(season) · E\(episode)"
    }

    @ViewBuilder
    private var aboutContent: some View {
        // Keep the native owner stable while the responsive layout measures text.
        Button {
            if isOverviewTruncated { showsFullOverview = true }
        } label: {
            aboutCardBody
        }
        .plozzCardButton(
            cornerRadius: cardCornerRadius,
            focusedScale: PlozzTheme.Metrics.readOnlyFocusedCardScale
        )
        .accessibilityRemoveTraits(isOverviewTruncated ? [] : .isButton)
        .accessibilityIdentifier("detail-about")
        .plozzSheet(isPresented: $showsFullOverview, style: overviewPresentationStyle) {
            overviewSheet
        }
    }

    private var aboutCardBody: some View {
        Group {
            VStack(alignment: .leading, spacing: aboutContentSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // "S1 · E1" ahead of the episode's title, so the card says
                    // where in the show it sits without a separate line.
                    if let locator = seasonEpisodeLocator {
                        Text(locator)
                            .font(aboutTitleFont)
                            .plozzForeground(.secondary)
                    }
                    Text(item.title)
                        .font(aboutTitleFont)
                        .plozzForeground(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let overview = nonempty(item.overview) {
                    aboutOverview(overview)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onPreferenceChange(OverviewFullHeightKey.self) { overviewFullHeight = $0 }
            .onPreferenceChange(OverviewVisibleHeightKey.self) { overviewVisibleHeight = $0 }
            .padding(cardPadding)
        }
    }

    /// The synopsis, capped to `aboutLineLimit` lines — the line count (not a fixed
    /// point height) drives the card height, so it scales correctly with Dynamic
    /// Type. When the text overflows the cap, the tail of the last visible line
    /// gradient-fades into the background and **MORE** sits inline on that line
    /// (never on a line below it). Truncation is measured (line-limited height vs
    /// full text height), so it's exact at any width or type size.
    @ViewBuilder
    private func aboutOverview(_ overview: String) -> some View {
        DetailInlineMoreLabel(
            isTruncated: isOverviewTruncated, fadeWidth: moreFadeWidth, textFont: bodyFont
        ) {
            overviewText(overview)
                .font(bodyFont)
                .plozzForeground(.primary)
                .lineLimit(aboutLineLimit)
                // Measure the visible (line-limited) height…
                .background {
                    GeometryReader { limited in
                        Color.clear.preference(
                            key: OverviewVisibleHeightKey.self,
                            value: limited.size.height
                        )
                    }
                }
                // …and the height the full text wants, unconstrained.
                .background(alignment: .top) {
                    overviewText(overview)
                        .font(bodyFont)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .hidden()
                        .overlay {
                            GeometryReader { full in
                                Color.clear.preference(
                                    key: OverviewFullHeightKey.self,
                                    value: full.size.height
                                )
                            }
                        }
                }
        }
    }

    @ViewBuilder
    private var overviewSheet: some View {
        #if os(tvOS)
        tvOverviewCard
        #else
        overviewSheetForms
        #endif
    }

    private var overviewPresentationStyle: PlozzSheetStyle {
        .detailReader
    }

    #if os(tvOS)
    private var tvOverviewCard: some View {
        DetailReaderCard {
            Text(item.title)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !item.genres.isEmpty {
                Text(item.genres.prefix(3).joined(separator: ", "))
                    .font(.system(size: 26))
                    .plozzForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let overview = nonempty(item.overview) {
                overviewText(overview)
                    .font(.system(size: 29))
                    .foregroundStyle(palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    #endif

    private var overviewSheetForms: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let overview = nonempty(item.overview) {
                        overviewText(overview)
                            .font(bodyFont)
                            .foregroundStyle(palette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(sheetPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            #if !os(tvOS)
            .scrollContentBackground(.hidden)
            #endif
            .background { SettingsPageBackground() }
            .navigationTitle(item.title)
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsFullOverview = false } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }
            #endif
        }
        #if !os(tvOS)
        .presentationCornerRadius(overviewSheetCornerRadius)
        .preferredColorScheme(palette.isLight ? .light : .dark)
        // Elevation edge for dark themes, reusing the Settings sheet treatment:
        // Compact layouts show only the floating top rim (sides/bottom sit at the
        // edge); a regular-width card floats on all sides, so it gets a full
        // border. Light themes already separate from the page behind them.
        .overlay {
            if !palette.isLight {
                overviewSheetElevationBorder
            }
        }
        #endif
    }

    #if !os(tvOS)
    /// Corner radius pinned on the overview sheet so the elevation border traces
    /// the card's rounded edge exactly. Matches the Settings sheet.
    private var overviewSheetCornerRadius: CGFloat { 20 }

    @ViewBuilder
    private var overviewSheetElevationBorder: some View {
        let stroke = RoundedRectangle(
            cornerRadius: overviewSheetCornerRadius,
            style: .continuous
        )
        .strokeBorder(palette.overlay.border ?? .clear, lineWidth: palette.overlay.borderWidth)

        if horizontalSizeClass == .regular {
            // Full border: the whole card floats.
            stroke
                .ignoresSafeArea()
                .allowsHitTesting(false)
        } else {
            // Top rim only: mask so just the floating top edge shows.
            stroke
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.04),
                            .init(color: .clear, location: 0.12)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
    #endif

    /// Whether the synopsis is actually clipped — the full text wants more height
    /// than the line-limited (visible) copy. Measured, so it's exact at any width
    /// or Dynamic Type size, unlike a chars-per-line estimate.
    private var isOverviewTruncated: Bool {
        overviewVisibleHeight > 1 && overviewFullHeight > overviewVisibleHeight + 1
    }

    /// Renders the synopsis with inline markdown resolved the same way the rest of
    /// the app does: tvOS flattens `[label](url)` links to plain label text (no
    /// pointer to tap them); iOS/iPadOS renders them as tappable links.
    @ViewBuilder
    private func overviewText(_ overview: String) -> some View {
        #if os(tvOS)
        Text(verbatim: overview.overviewPlainText)
        #else
        Text(overview.overviewMarkdownWithLegibleLinks(
            textColor: palette.primaryText,
            accent: palette.accent
        ))
        #endif
    }

    private func detailSection<Content: View>(
        title: LocalizedStringResource,
        contentSpacing: CGFloat = DetailInformationLayout.headingSpacing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            Text(title)
                .font(sectionTitleFont)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var informationGroups: [InformationGroup] {
        [
            InformationGroup(
                id: "availability",
                title: "Release & Availability",
                facts: availabilityFacts
            ),
            InformationGroup(id: "details", title: "Details", facts: detailFacts),
            InformationGroup(id: "crew", title: "Crew", facts: crewFacts),
            InformationGroup(id: "playback", title: "Playback", facts: playbackFacts)
        ]
        .filter { !$0.facts.isEmpty }
    }

    var sortedRatings: [ExternalRating] {
        // Header preferences select a preview, never a subset of the detail scores.
        item.ratings.sorted { $0.sortRank < $1.sortRank }
    }

    var familyGuidanceSummary: FamilyGuidanceSummary? {
        guard item.kind == .movie || item.kind == .series,
              let summary = item.familyGuidance, summary.hasContent else { return nil }
        return summary
    }

    var hasRatings: Bool { !sortedRatings.isEmpty || familyGuidanceSummary != nil }

    /// "Details" — the editorial facts about the *title* itself.
    private var detailFacts: [InformationFact] {
        var facts: [InformationFact] = []
        // The exact day when the server knows it, the bare year when it doesn't.
        // Never both: "Released 14 Apr 2019" already contains "Year 2019", and a
        // list of facts that restates one of its own entries reads as a bug.
        if let released = item.releaseDateLabel {
            facts.append(InformationFact(
                id: "released",
                label: LocalizedStringResource(
                    "mediaDetail.fact.released",
                    defaultValue: "Released",
                    comment: "Label on a movie or episode's detail page beside the date it first came out. A noun-style field label ('Released: 14 Apr 2019'), not a verb or a status."
                ),
                value: released
            ))
        } else if let year = item.productionYear {
            facts.append(InformationFact(id: "year", label: "Year", value: String(year)))
        }
        if let runtime = item.runtime?.runtimeBadgeText {
            facts.append(InformationFact(id: "runtime", label: "Runtime", value: runtime))
        }
        if item.kind == .series {
            if let status = item.seriesStatus {
                facts.append(InformationFact(id: "series-status", label: "Status", value: status.displayName))
            }
            if let count = item.catalogSeasonCount, count > 0 {
                facts.append(InformationFact(id: "seasons", label: "Total Seasons", value: count.formatted()))
            }
            if let count = item.catalogEpisodeCount, count > 0 {
                facts.append(InformationFact(id: "episodes", label: "Total Episodes", value: count.formatted()))
            }
        }
        if let code = nonempty(item.originalLanguage),
           !["xx", "und", "zxx", "mul"].contains(code.lowercased()),
           let language = Locale.current.localizedString(forLanguageCode: code) {
            facts.append(InformationFact(id: "original-language", label: "Original Language", value: language))
        }
        if showsContentRatings, let rating = nonempty(item.officialRating) {
            facts.append(InformationFact(id: "content-rating", label: "Content Rating", value: rating))
        }
        if let originalTitle = nonempty(item.originalTitle), originalTitle != item.title {
            facts.append(InformationFact(id: "original-title", label: "Original Title", value: originalTitle))
        }
        appendListFact(id: "genres", label: "Genres", values: item.genres, to: &facts)
        appendListFact(id: "tags", label: "Tags", values: item.tags, to: &facts)
        return facts
    }

    /// "Crew" — the people and studios behind the title (the photo cast rail above
    /// covers the on-screen cast; this carries the crew the rail doesn't).
    private var crewFacts: [InformationFact] {
        var facts: [InformationFact] = []
        appendListFact(id: "directors", label: "Directed By", values: crew(kind: "director"), to: &facts)
        appendListFact(id: "writers", label: "Written By", values: crew(kind: "writer"), to: &facts)
        appendListFact(id: "studios", label: "Studios", values: item.studios, to: &facts)
        return facts
    }

    private var availabilityFacts: [InformationFact] {
        guard let availability = externalAvailability else { return [] }
        let locale = Locale.current
        let region = locale.localizedString(
            forRegionCode: availability.regionCode
        ) ?? availability.regionCode
        var facts: [InformationFact] = []
        for event in availability.releaseEvents.sorted(by: { $0.date < $1.date }) {
            let label: LocalizedStringResource
            switch event.kind {
            case .premiere: label = "Premiere"
            case .theatricalLimited: label = "Limited Theatrical"
            case .theatrical: label = "Theatrical"
            case .digital: label = "Digital"
            case .physical: label = "Physical"
            case .television: label = "TV Premiere"
            }
            facts.append(InformationFact(
                id: "release-\(event.kind.rawValue)-\(event.date.timeIntervalSinceReferenceDate)",
                label: label,
                value: "\(event.date.formatted(.dateTime.month(.abbreviated).day().year())) · \(region)"
            ))
        }
        func offerFact(
            id: String,
            label: LocalizedStringResource,
            _ matching: (TitleWatchOffer) -> Bool
        ) -> InformationFact? {
            let offers = availability.watchOffers.filter(matching)
            let names = providerNames(offers)
            guard !names.isEmpty else { return nil }
            return InformationFact(
                id: id,
                label: label,
                value: names.joined(separator: " · "),
                listValues: names,
                logos: providerLogos(offers)
            )
        }
        if let fact = offerFact(id: "streaming", label: "Streaming", {
            $0.kind == .subscription || $0.kind == .free || $0.kind == .ads
        }) {
            facts.append(fact)
        }
        if let fact = offerFact(id: "rent", label: "Rent", { $0.kind == .rent }) {
            facts.append(fact)
        }
        if let fact = offerFact(id: "buy", label: "Buy", { $0.kind == .buy }) {
            facts.append(fact)
        }
        if !availability.watchOffers.isEmpty {
            facts.append(InformationFact(
                id: "availability-attribution",
                label: "Availability Data",
                value: "JustWatch",
                isRequiredAttribution: true
            ))
        }
        return facts
    }

    /// Collapsed by SERVICE, not by the source's provider id.
    ///
    /// Starz sells through its own app and as an add-on channel on Apple TV, Roku
    /// and Amazon; each carries a different id, so an id-keyed dedupe listed it four
    /// times and pushed the genuinely different services off the end of the line.
    /// One mark per SERVICE, in the source's order, collapsed the same way the
    /// names are so the logo row and the text fallback can never disagree.
    private func providerLogos(_ offers: [TitleWatchOffer]) -> [WatchProviderLogo] {
        var seen = Set<String>()
        return offers.compactMap { offer in
            let name = ExternalTitleAvailability.collapsedServiceName(offer.providerName)
            guard seen.insert(name).inserted, let url = offer.logoURL else { return nil }
            return WatchProviderLogo(id: name, name: name, url: url)
        }
    }

    private func providerNames(_ offers: [TitleWatchOffer]) -> [String] {
        var seen = Set<String>()
        return offers
            .map { ExternalTitleAvailability.collapsedServiceName($0.providerName) }
            .filter { seen.insert($0).inserted }
    }

    /// "Playback" — everything about *this copy* in one place: where it streams
    /// from, and the selected version's quality + file facts. Replaces the old
    /// overlapping Playback/Source/File split (Quality vs Version vs Source, Runtime
    /// vs Duration, a "Size" that was really the bitrate).
    private var playbackFacts: [InformationFact] {
        var facts: [InformationFact] = []
        if let selectedSource {
            facts.append(InformationFact(id: "server", label: "Server", value: selectedSource.displayName))
            if let locality = localityLabel(selectedSource.locality) {
                facts.append(InformationFact(id: "connection", label: "Connection", value: locality))
            }
            if let account = nonempty(selectedSource.accountName),
               !selectedSource.displayName.localizedCaseInsensitiveContains(account) {
                facts.append(InformationFact(id: "account", label: "Account", value: account))
            }
        }
        if let selectedVersion {
            if let edition = nonempty(selectedVersion.editionLabel) {
                facts.append(InformationFact(id: "edition", label: "Edition", value: edition))
            }
            let quality = [selectedVersion.resolutionLabel, selectedVersion.hdrLabel, selectedVersion.audioLabel]
                .compactMap { $0 }
                .joined(separator: " · ")
            if !quality.isEmpty {
                facts.append(InformationFact(id: "quality", label: "Quality", value: quality))
            }
            if let source = nonempty(selectedVersion.sourceQualityLabel) {
                facts.append(InformationFact(id: "source", label: "Source", value: source))
            }
            if let bitrate = nonempty(selectedVersion.bitrateLabel) {
                facts.append(InformationFact(id: "bitrate", label: "Bitrate", value: bitrate))
            }
            if let size = nonempty(selectedVersion.sizeLabel) {
                facts.append(InformationFact(id: "size", label: "Size", value: size))
            }
            if let filename = nonempty(selectedVersion.fileName) {
                facts.append(InformationFact(id: "filename", label: "File", value: filename))
            }
        }
        return facts
    }

    private func appendVersionFact(
        id: String,
        label: LocalizedStringResource,
        value: String?,
        alwaysInclude: Bool = false,
        to facts: inout [InformationFact]
    ) {
        guard let value = nonempty(value) else { return }
        if !alwaysInclude, selectedVersion?.displayLabel?.localizedCaseInsensitiveContains(value) == true {
            return
        }
        facts.append(InformationFact(id: id, label: label, value: value))
    }

    private func localityLabel(_ locality: SourceLocality?) -> String? {   // l10n:content — source locality detail from the provider
        switch locality {
        case .local: return "Local network"
        case .remote: return "Remote"
        case .unknown, nil: return nil
        }
    }

    private func appendListFact(
        id: String,
        label: LocalizedStringResource,
        values: [String],
        to facts: inout [InformationFact]
    ) {
        let unique = orderedUnique(values)
        guard !unique.isEmpty else { return }
        facts.append(InformationFact(
            id: id,
            label: label,
            value: ListFormatter.localizedString(byJoining: unique),
            listValues: unique
        ))
    }

    private func crew(kind: String) -> [String] {
        item.people.compactMap { person in
            person.kind?.caseInsensitiveCompare(kind) == .orderedSame ? person.name : nil
        }
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seen.insert(key).inserted ? trimmed : nil
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var sectionTitleFont: Font {
        #if os(tvOS)
        .system(size: 34, weight: .bold)
        #else
        .title2.bold()
        #endif
    }

    private var bodyFont: Font {
        #if os(tvOS)
        .system(size: 24)
        #else
        .body
        #endif
    }

    private var aboutTitleFont: Font {
        #if os(tvOS)
        .system(size: 28, weight: .semibold)
        #else
        .title3.weight(.semibold)
        #endif
    }

    private var aboutContentSpacing: CGFloat {
        #if os(tvOS)
        12
        #else
        10
        #endif
    }

    private var aboutLineLimit: Int {
        #if os(tvOS)
        return 6
        #else
        return horizontalSizeClass == .regular ? 6 : 7
        #endif
    }

    private var moreFadeWidth: CGFloat {
        #if os(tvOS)
        220
        #else
        150
        #endif
    }

    private var sheetPadding: CGFloat {
        #if os(tvOS)
        60
        #else
        24
        #endif
    }

    private var factLabelFont: Font {
        #if os(tvOS)
        .system(size: 18, weight: .semibold)
        #else
        .caption.weight(.semibold)
        #endif
    }

    private var factValueFont: Font {
        #if os(tvOS)
        .system(size: 23, weight: .medium)
        #else
        .body.weight(.medium)
        #endif
    }

    private var technicalTitleFont: Font {
        #if os(tvOS)
        .system(size: 28, weight: .semibold)
        #else
        .title3.weight(.semibold)
        #endif
    }

    private var technicalValueFont: Font {
        #if os(tvOS)
        .system(size: 20)
        #else
        .subheadline
        #endif
    }

    private var sectionSpacing: CGFloat {
        DetailInformationLayout.sectionSpacing
    }

    private var informationColumnSpacing: CGFloat {
        DetailInformationLayout.gutter
    }

    private var informationRowSpacing: CGFloat {
        DetailInformationLayout.gutter
    }

    private var informationGroupSpacing: CGFloat {
        DetailInformationLayout.headingSpacing
    }

    private var cardPadding: CGFloat {
        DetailInformationLayout.cellPadding
    }

    private var cardCornerRadius: CGFloat {
        DetailInformationLayout.cornerRadius
    }

    private var informationColumnMinimumWidth: CGFloat {
        #if os(tvOS)
        320
        #else
        mobileColumnMinimumWidth
        #endif
    }

    private var informationSectionMinimumWidth: CGFloat {
        informationColumnMinimumWidth * 1.5
    }

    private var informationSectionColumns: Int {
        #if os(tvOS)
        3
        #else
        horizontalSizeClass == .regular ? 2 : 1
        #endif
    }
}

private struct DetailInformationGroup: View {
    let group: InformationGroup
    let titleFont: Font
    let labelFont: Font
    let valueFont: Font
    let pairsShortFacts: Bool
    let onExpand: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    #if os(tvOS)
    private let minimumFactWidth: CGFloat = 220
    #else
    @ScaledMetric(relativeTo: .body) private var minimumFactWidth: CGFloat = 160
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: DetailInformationLayout.headingSpacing) {
            Text(group.title)
                .font(titleFont)
                .frame(maxWidth: .infinity, alignment: .leading)
            facts
                .padding(.vertical, DetailInformationLayout.headingSpacing)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var facts: some View {
        DetailFactLayout(
            pairsShortFacts: pairsShortFacts && !dynamicTypeSize.isAccessibilitySize,
            minimumColumnWidth: minimumFactWidth,
            spacing: DetailInformationLayout.factSpacing
        ) {
            ForEach(group.previewFacts) { fact in
                factCell(fact)
                    .layoutValue(key: DetailCompactFactKey.self, value: fact.supportsPairing)
            }
            if group.hasOmittedFacts {
                Button(action: onExpand) {
                    DetailMoreLabel()
                }
                    #if os(tvOS)
                    .modifier(DetailInformationFocus())
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("detail-\(group.id)-more")
            }
        }
    }

    private func factCell(_ fact: InformationFact) -> some View {
        InformationFactCell(
            fact: fact, labelFont: labelFont, valueFont: valueFont,
            isTechnical: group.id == "playback",
            accessibilityID: "detail-\(group.id)-\(fact.id)-more",
            onExpand: onExpand
        )
    }
}

private struct DetailCompactFactKey: LayoutValueKey {
    static let defaultValue = false
}

/// Keep short facts together without squeezing prose or the native focus gutters.
private struct DetailFactLayout: Layout {
    let pairsShortFacts: Bool
    let minimumColumnWidth: CGFloat
    let spacing: CGFloat

    private func frames(for width: CGFloat, subviews: Subviews) -> [CGRect] {
        let halfWidth = max(0, (width - spacing) / 2)
        var frames: [CGRect] = []
        var pending: Int?
        var nextY: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let compact = pairsShortFacts && halfWidth >= minimumColumnWidth
                && subview[DetailCompactFactKey.self]
                && subview.sizeThatFits(.unspecified).width <= halfWidth
            if let previous = pending, !compact {
                nextY = frames[previous].maxY + spacing
                pending = nil
            }
            let childWidth = compact ? halfWidth : width
            let height = subview.sizeThatFits(.init(width: childWidth, height: nil)).height
            if let previous = pending {
                let rowHeight = max(height, frames[previous].height)
                frames[previous].size.height = rowHeight
                frames.append(CGRect(x: halfWidth + spacing, y: nextY, width: childWidth, height: rowHeight))
                nextY += rowHeight + spacing
                pending = nil
            } else {
                frames.append(CGRect(x: 0, y: nextY, width: childWidth, height: height))
                if compact {
                    pending = index
                } else {
                    nextY += height + spacing
                }
            }
        }
        return frames
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumColumnWidth
        return CGSize(width: width, height: frames(for: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: .init(frame.size))
        }
    }
}

#if os(tvOS)
private struct DetailInformationFocus: ViewModifier {
    @FocusState private var isFocused: Bool
    @Environment(\.plozzReduceTransparency) private var reduceTransparency

    private var usesOpaqueFocus: Bool {
        if #available(tvOS 26.0, *) { reduceTransparency } else { true }
    }

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderless)
            .environment(\.settingsRowIsFocused, isFocused && usesOpaqueFocus)
            .environment(\.settingsRowFocusForeground, .black)
            .focused($isFocused)
            .background {
                // Glass must stay outside text fitting; the gutters reserve its full outset.
                if isFocused {
                    Color.clear
                        .plozzGlassCard(cornerRadius: DetailInformationLayout.cornerRadius, isFocused: true)
                        .padding(-DetailInformationLayout.focusPadding)
                        .allowsHitTesting(false)
                }
            }
    }
}
#endif

/// Whole sections occupy readable columns; subsequent sections use the shortest
/// column without stretching their neighbors or reserving missing content.
struct DetailSectionLayout: Layout {
    let preferredColumns: Int
    let minimumColumnWidth: CGFloat
    let spacing: CGFloat

    func columnCount(for width: CGFloat) -> Int {
        max(1, Int(min(CGFloat(preferredColumns), (width + spacing) / (minimumColumnWidth + spacing))))
    }

    func columnWidth(for width: CGFloat) -> CGFloat {
        let columns = columnCount(for: width)
        return max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    }

    private func frames(for width: CGFloat, subviews: Subviews) -> [CGRect] {
        let columnWidth = columnWidth(for: width)
        let columns = columnCount(for: width)
        var bottoms = Array(repeating: CGFloat.zero, count: columns)
        return subviews.map { subview in
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
            let height = subview.sizeThatFits(.init(width: columnWidth, height: nil)).height
            let frame = CGRect(x: CGFloat(column) * (columnWidth + spacing),
                               y: bottoms[column], width: columnWidth, height: height)
            bottoms[column] = frame.maxY + spacing
            return frame
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? minimumColumnWidth * CGFloat(preferredColumns) + CGFloat(preferredColumns - 1) * spacing
        return CGSize(width: width, height: frames(for: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: .init(frame.size))
        }
    }
}

/// A narrow lone score matches About's height when beside it. Details uses the spare column, while
/// lower sections can begin beneath About instead of waiting for a long fact list.
private struct DetailSingleRatingLayout: Layout {
    let preferredColumns: Int
    let minimumColumnWidth: CGFloat
    let ratingMinimumWidth: CGFloat
    let hasOverview: Bool
    let hasDetails: Bool
    let spacing: CGFloat

    private func frames(for width: CGFloat, subviews: Subviews) -> [CGRect] {
        let grid = DetailSectionLayout(
            preferredColumns: preferredColumns, minimumColumnWidth: minimumColumnWidth, spacing: spacing
        )
        let columns = grid.columnCount(for: width)
        let columnWidth = grid.columnWidth(for: width)
        let ratingIndex = hasOverview ? 1 : 0
        let detailsIndex = hasDetails ? ratingIndex + 1 : nil
        let lowerStart = ratingIndex + 1 + (hasDetails ? 1 : 0)
        let ratingWidth = min(columnWidth, columns == 1 ? ratingMinimumWidth
                              : max(ratingMinimumWidth, (columnWidth - spacing) / 2))
        let summaryHeight: CGFloat? = hasOverview && columns > 1
            ? ceil(max(
                subviews[0].sizeThatFits(.init(width: columnWidth, height: nil)).height,
                subviews[ratingIndex].sizeThatFits(.init(width: ratingWidth, height: nil)).height
            )) : nil
        var bottoms = Array(repeating: CGFloat.zero, count: columns)
        var frames: [CGRect] = []
        for (index, subview) in subviews.enumerated() {
            let column: Int
            if columns == 1 || index == lowerStart {
                column = 0
            } else if index == ratingIndex {
                column = hasOverview ? 1 : 0
            } else if index == detailsIndex {
                column = columns >= 3 ? (hasOverview ? 2 : 1) : 1
            } else {
                column = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
            }
            let childWidth = index == ratingIndex ? ratingWidth : columnWidth
            let intrinsicHeight = subview.sizeThatFits(.init(width: childWidth, height: nil)).height
            let height = (index == 0 || index == ratingIndex) ? summaryHeight ?? intrinsicHeight : intrinsicHeight
            let frame = CGRect(x: CGFloat(column) * (columnWidth + spacing),
                               y: bottoms[column], width: childWidth, height: height)
            frames.append(frame)
            bottoms[column] = frame.maxY + spacing
            if columns >= 3, index == lowerStart - 1 {
                let summaryBottom = frames.prefix(ratingIndex + 1).map(\.maxY).max() ?? 0
                bottoms = bottoms.map { max($0, summaryBottom + spacing) }
            }
        }
        return frames
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumColumnWidth
        return CGSize(width: width, height: frames(for: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: .init(frame.size))
        }
    }
}

/// Side-by-side sections share a height; stacked sections retain their intrinsic height.
private struct DetailSummaryLayout: Layout {
    let minimumColumnWidth: CGFloat
    let preferredColumns: Int
    let hasOverview: Bool
    let ratingsWidth: CGFloat
    let fillsRatingsColumn: Bool
    let maximumRatingsColumnSpan: Int
    let spacing: CGFloat

    private func widths(for width: CGFloat, count: Int) -> [CGFloat] {
        let columnWidth = DetailSectionLayout(
            preferredColumns: preferredColumns, minimumColumnWidth: minimumColumnWidth, spacing: spacing
        ).columnWidth(for: width)
        let ratingsLimit = columnWidth * CGFloat(maximumRatingsColumnSpan)
            + spacing * CGFloat(maximumRatingsColumnSpan - 1)
        if count == 2, columnWidth < width {
            let available = width - columnWidth - spacing
            return [columnWidth, min(fillsRatingsColumn ? ratingsLimit : ratingsWidth, available)]
        }
        if count == 1 {
            return [hasOverview ? columnWidth : min(fillsRatingsColumn ? ratingsLimit : ratingsWidth, width)]
        }
        return [width, fillsRatingsColumn ? width : min(ratingsWidth, width)]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? minimumColumnWidth + ratingsWidth + spacing
        let widths = widths(for: width, count: subviews.count)
        let heights = zip(subviews, widths).map { $0.sizeThatFits(.init(width: $1, height: nil)).height }
        let horizontal = subviews.count == 2 && widths[0] < width
        let height = horizontal ? ceil(max(heights[0], heights[1]))
            : heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = widths(for: bounds.width, count: subviews.count)
        let horizontal = subviews.count == 2 && widths[0] < bounds.width
        var origin = bounds.origin
        for pair in zip(subviews, widths) {
            let (subview, width) = pair
            let size = subview.sizeThatFits(.init(width: width, height: nil))
            subview.place(at: origin, proposal: .init(
                width: width, height: horizontal ? bounds.height : size.height
            ))
            if horizontal {
                origin.x += width + spacing
            } else {
                origin.y += size.height + spacing
            }
        }
    }
}

private struct OverviewFullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct OverviewVisibleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A wrapping row of service marks.
///
/// Wrapping rather than scrolling: this sits inside a static information column
/// that nothing focuses through, so a horizontal scroller would hide services with
/// no affordance to reveal them.
private struct WatchProviderLogoRow: View {
    let logos: [WatchProviderLogo]
    /// The same services as text, used as the single accessibility label — a
    /// screen reader should hear "Starz, Philo, YouTube TV", not twelve images.
    let names: String

    #if os(tvOS)
    private static let side: CGFloat = 64
    #else
    private static let side: CGFloat = 46
    #endif

    var body: some View {
        WrappingHStackLayout(spacing: 10, lineSpacing: 10) {
            ForEach(logos) { logo in
                FallbackAsyncImage(
                    urls: [logo.url],
                    variant: .serviceLogo
                ) {
                    // Never a blank tile: an unreachable logo falls back to the
                    // service's own name rather than a grey square.
                    Text(logo.name)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(4)
                }
                .frame(width: Self.side, height: Self.side)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(names))
    }
}

struct InformationGroup: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let facts: [InformationFact]

    var previewFacts: [InformationFact] {
        let notices = facts.filter(\.isRequiredAttribution)
        let limit = max(0, DetailPreviewLimits.facts - notices.count)
        let previewIDs = Set(facts.filter { !$0.isRequiredAttribution }.prefix(limit).map(\.id))
        return facts.filter { $0.isRequiredAttribution || previewIDs.contains($0.id) }
    }

    var hasOmittedFacts: Bool { facts.count > previewFacts.count }
}

struct InformationFact: Identifiable {
    let id: String
    /// `LocalizedStringResource`, not `LocalizedStringKey`, so a label that needs
    /// a translator note can carry one. Several of these are ambiguous out of
    /// context — "Released" reads as a past-tense verb as easily as a date label,
    /// and "Rent" is a verb in English and a noun in half the languages we ship.
    /// Bare string literals still work at the call site.
    let label: LocalizedStringResource
    let value: String
    var listValues: [String]? = nil
    /// Service artwork for a "where to watch" row. A logo is read at a glance from
    /// across a room where a list of names has to be parsed, so where these exist
    /// they replace the text — `value` stays as the accessibility description and
    /// as the fallback when a logo is missing.
    var logos: [WatchProviderLogo] = []
    var isRequiredAttribution = false

    var supportsPairing: Bool {
        switch id {
        case "year", "runtime", "series-status", "seasons", "episodes", "original-language", "content-rating":
            true
        default:
            false
        }
    }

    var hasOmittedValues: Bool {
        if !logos.isEmpty {
            let visible = Set(logos.prefix(DetailPreviewLimits.serviceLogos).map(\.name))
            return logos.count > DetailPreviewLimits.serviceLogos
                || (listValues ?? []).contains { !visible.contains($0) }
        }
        return false
    }

    func needsExpansion(textTruncated: Bool) -> Bool {
        hasOmittedValues || textTruncated
    }
}

private struct InformationFactCell: View {
    let fact: InformationFact
    let labelFont: Font
    let valueFont: Font
    let isTechnical: Bool
    let accessibilityID: String
    let onExpand: () -> Void
    @State private var textTruncated = false

    private var hasMore: Bool { fact.needsExpansion(textTruncated: textTruncated) }

    @ViewBuilder
    var body: some View {
        #if os(tvOS)
        // A stable borderless control preserves remote scrolling and inline expansion
        // without turning metadata into a permanently filled card.
        cardButton
            .accessibilityRemoveTraits(hasMore ? [] : .isButton)
        #else
        if hasMore {
            cardButton
        } else {
            label
        }
        #endif
    }

    private var cardButton: some View {
        Button {
            if hasMore { onExpand() }
        } label: {
            label
        }
        #if os(tvOS)
        .modifier(DetailInformationFocus())
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityIdentifier(accessibilityID)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: DetailInformationLayout.labelSpacing) {
            Text(fact.label)
                .font(labelFont)
                .plozzForeground(.secondary)
            if fact.logos.isEmpty {
                InformationValuePreview(fact: fact, font: valueFont) { textTruncated = $0 }
                    .plozzForeground(isTechnical ? .secondary : .primary)
            } else {
                WatchProviderLogoRow(
                    logos: Array(fact.logos.prefix(DetailPreviewLimits.serviceLogos)), names: fact.value
                )
                if hasMore { DetailMoreLabel() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .multilineTextAlignment(.leading)
    }
}

private struct InformationValuePreview: View {
    let fact: InformationFact
    let font: Font
    let onTruncationChange: (Bool) -> Void
    @State private var visibleSize: CGSize = .zero
    @State private var fullSize: CGSize = .zero

    private var measuredTruncation: Bool? {
        guard visibleSize.height > 0, fullSize.height > 0,
              visibleSize.width > 0, abs(visibleSize.width - fullSize.width) < 0.5 else { return nil }
        return fullSize.height > visibleSize.height + 0.5
    }

    var body: some View {
        DetailInlineMoreLabel(
            isTruncated: fact.needsExpansion(textTruncated: measuredTruncation == true),
            fadeWidth: fadeWidth, textFont: font
        ) {
            Text(fact.value)
                .font(font)
                .lineLimit(DetailPreviewLimits.valueLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { visibleSize = $0 }
                .background(alignment: .topLeading) {
                    Text(fact.value)
                        .font(font)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { fullSize = $0 }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: measuredTruncation, initial: true) { _, value in
            if let value { onTruncationChange(value) }
        }
    }

    private var fadeWidth: CGFloat {
        #if os(tvOS)
        120
        #else
        90
        #endif
    }
}

/// One service's mark. Identified by the collapsed service NAME rather than the
/// source's provider id, so Starz billed through four storefronts shows one logo.
struct WatchProviderLogo: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

#endif
