#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

enum CardCaptionSettingsPage: String, CaseIterable {
    case home, recommended, browse, collections, playlists, search, watchlist, detail, people

    var title: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .recommended: "Recommended"
        case .browse: "Browse"
        case .collections: "Collections"
        case .playlists: "Playlists"
        case .search: "Search"
        case .watchlist: "Watchlist"
        case .detail: "Detail Page"
        case .people: "People"
        }
    }

    var controls: [CardCaptionView] {
        switch self {
        case .home: [.home, .continueWatching]
        case .recommended: [.recommended, .continueWatching]
        case .browse: [.browse]
        case .collections: [.collections]
        case .playlists: [.playlists]
        case .search: [.search]
        case .watchlist: [.watchlist]
        case .detail: [.episodes, .related, .extras]
        case .people: [.filmography]
        }
    }

    var firstControl: CardCaptionView { controls[0] }

    var hasOverrides: Bool { controls.contains(.continueWatching) }

    func controlTitle(for view: CardCaptionView) -> LocalizedStringResource {
        if self == .detail || view == .continueWatching { return view.cardLabelTitle }
        return hasOverrides ? "Default" : "Card labels"
    }

    var sharedRowNote: LocalizedStringResource? {
        switch self {
        case .home: "Shared with Recommended."
        case .recommended: "Shared with Home."
        default: nil
        }
    }
}

extension CardCaptionSettingsScope {
    var pages: [CardCaptionSettingsPage] {
        switch self {
        case .all: CardCaptionSettingsPage.allCases
        case .home: [.home]
        case .libraries: [.recommended, .browse, .collections, .playlists]
        case .detail: [.detail]
        }
    }
}

struct CardCaptionCustomizationContent: View {
    @Binding var settings: CardCaptionSettings
    var style: CardStyle
    let scope: CardCaptionSettingsScope
    let visibility: HomeLibraryVisibilityModel?
    @Environment(HeroSettingsModel.self) private var hero: HeroSettingsModel?
    @State private var selectedPage: CardCaptionSettingsPage
    @State private var previewView: CardCaptionView

    init(
        settings: Binding<CardCaptionSettings>, style: CardStyle = .borderless,
        scope: CardCaptionSettingsScope = .all, visibility: HomeLibraryVisibilityModel? = nil
    ) {
        _settings = settings
        self.style = style
        self.scope = scope
        self.visibility = visibility
        _selectedPage = State(initialValue: scope.pages[0])
        _previewView = State(initialValue: scope.pages[0].firstControl)
    }

    private var views: [CardCaptionView] { selectedPage.controls }
    private var initialRowID: String {
        scope.pages.count > 1 ? "card-label-page" : "card-label-view-\(selectedPage.firstControl.rawValue)"
    }
    private var title: LocalizedStringResource {
        scope == .home ? "Card labels" : "Customize labels"
    }

    var body: some View {
        #if os(tvOS)
        ViewCustomizationList(
            title: title, initialRowID: initialRowID,
            focusedHelp: { id in
                let view = views.first { "card-label-view-\($0.rawValue)" == id } ?? selectedPage.firstControl
                return ViewCustomizationHelp(
                    detail: settings.cardLabelHelp(in: view),
                    illustration: .pageCaptions(preview(editing: view), style: style)
                )
            },
            pinsFocusedHelp: scope != .home
        ) {
            if scope.pages.count > 1 {
                Section {
                    SettingsMenuRow(title: "Page", value: Text(selectedPage.title)) {
                        Picker("Page", selection: $selectedPage) {
                            ForEach(scope.pages, id: \.self) { page in
                                Text(page.title).tag(page)
                            }
                        }
                    }
                    .accessibilityIdentifier("card-label-page")
                    .modifier(ViewCustomizationRowFocus(id: "card-label-page"))
                }
            }
            labelSections
        }
        #else
        ViewCustomizationList(title: title, initialRowID: "") {
            if scope.pages.count > 1 {
                Section {
                    ViewCustomizationMenu(
                        id: "card-label-page", title: "Page",
                        value: selectedPage.title, selection: $selectedPage
                    ) {
                        ForEach(scope.pages, id: \.self) { page in
                            Text(page.title).tag(page)
                        }
                    }
                }
            }
            labelSections
            Section {
                CardLabelScopePreview(preview: preview(editing: previewView), style: style)
            }
        }
        .onChange(of: selectedPage) { _, page in previewView = page.firstControl }
        #endif
    }

    @ViewBuilder
    private var labelSections: some View {
        Section {
            ForEach(views.filter { $0 != .continueWatching }, id: \.self) { view in
                labelControl(view)
            }
        } footer: {
            #if !os(tvOS)
            VStack(alignment: .leading, spacing: 4) {
                if selectedPage != .detail && !selectedPage.hasOverrides {
                    Text(selectedPage.firstControl.cardLabelDetail)
                }
                if let explanation = settings.cardLabelMixedExplanation(in: selectedPage.firstControl) {
                    Text(explanation)
                        .accessibilityIdentifier("card-label-mixed-help")
                }
            }
            #endif
        }
        if selectedPage.hasOverrides {
            Section {
                labelControl(.continueWatching)
            } header: {
                Text("Overrides", comment: "Card label settings that override the selected page's Default choice.")
            } footer: {
                if let note = selectedPage.sharedRowNote {
                    Text(note)
                }
            }
        }
    }

    private func labelControl(_ view: CardCaptionView) -> some View {
        CardCaptionViewChoices(
            view: view,
            settings: Binding(
                get: { settings },
                set: {
                    previewView = view
                    settings = $0
                }
            ),
            title: selectedPage.controlTitle(for: view)
        )
    }

    private func preview(editing view: CardCaptionView) -> CardLabelScopePreview.Snapshot {
        #if os(tvOS)
        let showcase = selectedPage == .recommended
            || (selectedPage == .home && (hero?.effectiveSettings.followsFocus ?? HeroSettings.default.followsFocus))
        #else
        let showcase = false
        #endif
        return CardLabelScopePreview.snapshot(
            page: selectedPage, editing: views.contains(view) ? view : selectedPage.firstControl,
            settings: settings, isShowcase: showcase,
            seriesArtwork: visibility?.continueWatchingUsesSeriesArtwork ?? true,
            layout: visibility?.continueWatchingLayout ?? .landscape
        )
    }
}

extension CardCaptionView {
    var cardLabelTitle: LocalizedStringResource {
        self == .episodes ? "Episodes" : displayName
    }

    var cardLabelDetail: LocalizedStringResource {
        switch self {
        case .home:
            "Changes labels below Home cards, not the hero logo or description."
        case .recommended:
            "Changes labels below Recommended cards in all libraries."
        case .browse:
            "Changes labels below Browse cards, including titles inside collections and playlists."
        case .collections:
            "Changes labels below collection covers in all libraries. Titles inside a collection use Browse."
        case .playlists:
            "Changes labels below playlist covers in all libraries. Titles inside a playlist use Browse."
        case .continueWatching:
            "Use default follows each page. On or Off applies to both Home and Recommended."
        case .search: "Changes labels below cards in search results."
        case .watchlist: "Changes labels below cards on the Watchlist page."
        case .episodes: "Changes episode labels in the episode browser and on detail pages."
        case .related: "Changes labels below related titles on detail pages."
        case .extras: "Changes labels below trailers, clips, and other extras on detail pages."
        case .filmography: "Changes labels below titles on a person's page."
        }
    }
}

extension CardCaptionSettings {
    func cardLabelMixedExplanation(in view: CardCaptionView) -> LocalizedStringResource? {
        guard customization(in: view) == .mixed else { return nil }
        #if os(tvOS)
        return "Mixed hides labels in Showcase and on series artwork; other cards keep their labels."
        #else
        return "Mixed hides labels on series artwork; other cards keep their labels."
        #endif
    }

    func cardLabelHelp(in view: CardCaptionView) -> LocalizedStringResource {
        if view == .continueWatching {
            return customization(in: view) == .automatic ? "Uses this page's default." : customizationDetail(in: view)
        }
        return cardLabelMixedExplanation(in: view) ?? view.cardLabelDetail
    }
}

struct CardLabelScopePreview: View {
    struct Snapshot: Hashable {
        let page: CardCaptionSettingsPage
        let rows: [Row]
        let layout: ContinueWatchingCardLayout
        var seriesArtwork = true

        var isGrid: Bool {
            switch page {
            case .browse, .collections, .playlists, .search, .watchlist: true
            case .home, .recommended, .detail, .people: false
            }
        }

        var accessibilitySummary: Text {
            var text = Text(page.title)
            for row in rows {
                text = text + Text(verbatim: ". ")
                    + Text(row.title)
                    + Text(verbatim: ": ")
                    + Text(row.showsLabels ? CardCaptionOverride.show.displayName : CardCaptionOverride.hide.displayName)
            }
            return text
        }
    }

    struct Row: Hashable {
        let view: CardCaptionView
        let showsLabels: Bool
        let highlighted: Bool

        var isContinueWatching: Bool { view == .continueWatching }
        var title: LocalizedStringResource {
            switch view {
            case .home, .recommended: HomeGlobalRow.recentlyAdded.title
            default: view.cardLabelTitle
            }
        }
    }

    let preview: Snapshot
    let style: CardStyle
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.page.title)
                .font(.caption.weight(.semibold))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(preview.rows, id: \.view) { row in
                    CardLabelPreviewRow(row: row, preview: preview, style: style)
                }
            }
                .padding(12)
                .background(palette.settingsBackground, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preview.accessibilitySummary)
        .accessibilityIdentifier("card-label-preview-\(preview.page.rawValue)")
    }

    #if os(tvOS)
    static let illustrationWidth: CGFloat = 420
    #endif

    static func snapshot(
        page: CardCaptionSettingsPage, editing view: CardCaptionView, settings: CardCaptionSettings,
        isShowcase: Bool,
        seriesArtwork: Bool, layout: ContinueWatchingCardLayout
    ) -> Snapshot {
        let rowViews = page == .home || page == .recommended
            ? [.continueWatching, page.firstControl] : page.controls
        let rows = rowViews.map { rowView in
            Row(
                view: rowView,
                showsLabels: settings.showsLabels(
                    in: rowView == .continueWatching ? page.firstControl : rowView,
                    isShowcase: isShowcase,
                    hasArtworkTitle: rowView == .continueWatching && seriesArtwork,
                    isContinueWatching: rowView == .continueWatching
                ),
                highlighted: rowView == view || (rowView == .continueWatching && view == page.firstControl
                    && settings.override(for: .continueWatching) == .automatic)
            )
        }
        return Snapshot(page: page, rows: rows, layout: layout, seriesArtwork: seriesArtwork)
    }
}

private struct CardLabelPreviewRow: View {
    let row: CardLabelScopePreview.Row
    let preview: CardLabelScopePreview.Snapshot
    let style: CardStyle
    @Environment(\.themePalette) private var palette
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzContinueWatchingPlaybackDetails) private var playbackDetails
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var viewportWidth: CGFloat {
        #if os(tvOS)
        1920
        #else
        sizeClass == .regular ? 1024 : 390
        #endif
    }

    var body: some View {
        let geometry = SettingsIllustrationCardGeometry(
            row: row, preview: preview, style: style, metrics: metrics,
            playbackDetails: playbackDetails, viewportWidth: viewportWidth
        )
        VStack(alignment: .leading, spacing: 8) {
            if !preview.isGrid {
                Text(row.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Canvas { context, size in
                let scale = size.width / SettingsIllustrationCardGeometry.width
                context.scaleBy(x: scale, y: scale)
                if layoutDirection == .rightToLeft {
                    context.translateBy(x: SettingsIllustrationCardGeometry.width, y: 0)
                    context.scaleBy(x: -1, y: 1)
                }
                for card in geometry.cards {
                    if style == .framed {
                        context.fill(Path(roundedRect: card.surface, cornerRadius: 4), with: .color(palette.fill))
                    }
                    let artwork = Path(roundedRect: card.artwork, cornerRadius: 3)
                    context.fill(artwork, with: .linearGradient(
                        Gradient(colors: [palette.tertiaryText.opacity(0.5), palette.tertiaryText.opacity(0.2)]),
                        startPoint: card.artwork.origin,
                        endPoint: CGPoint(x: card.artwork.maxX, y: card.artwork.maxY)
                    ))
                    var icon = context.resolve(Image(systemName: "photo"))
                    icon.shading = .color(palette.tertiaryText)
                    let iconWidth = min(20, card.artwork.width * 0.32)
                    context.draw(icon, in: CGRect(
                        x: card.artwork.midX - iconWidth / 2, y: card.artwork.midY - iconWidth * 0.35,
                        width: iconWidth, height: iconWidth * 0.7
                    ))
                    if row.isContinueWatching {
                        if preview.seriesArtwork && preview.layout == .landscape {
                            context.fill(Path(roundedRect: CGRect(
                                x: card.artwork.minX + card.artwork.width * 0.2,
                                y: card.artwork.maxY - 14,
                                width: card.artwork.width * 0.6, height: 4
                            ), cornerRadius: 1), with: .color(palette.secondaryText))
                        }
                        let progress = CGRect(
                            x: card.artwork.minX + 4, y: card.artwork.maxY - 6,
                            width: card.artwork.width - 8, height: 2
                        )
                        context.fill(Path(roundedRect: progress, cornerRadius: 1), with: .color(palette.secondaryText.opacity(0.3)))
                        context.fill(Path(roundedRect: CGRect(
                            origin: progress.origin, size: CGSize(width: progress.width * 0.42, height: progress.height)
                        ), cornerRadius: 1), with: .color(palette.secondaryText))
                    }
                    if row.showsLabels {
                        let ink = row.highlighted ? palette.accent : palette.secondaryText
                        for (index, caption) in card.captions.enumerated() {
                            context.fill(Path(roundedRect: caption, cornerRadius: 1),
                                         with: .color(ink.opacity(index == 0 ? 0.9 : 0.45)))
                        }
                    }
                }
            }
            .aspectRatio(SettingsIllustrationCardGeometry.width / geometry.height, contentMode: .fit)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
        }
    }
}

struct SettingsIllustrationCardGeometry {
    struct Card {
        let artwork: CGRect
        let surface: CGRect
        let captions: [CGRect]
    }

    static let width: CGFloat = 320
    let cards: [Card]
    let height: CGFloat
    let gap: CGFloat

    init(
        row: CardLabelScopePreview.Row, preview: CardLabelScopePreview.Snapshot,
        style: CardStyle, metrics: PlozzMetrics, playbackDetails: ContinueWatchingPlaybackDetails,
        viewportWidth: CGFloat
    ) {
        let landscape = row.isContinueWatching ? preview.layout == .landscape
            : row.view == .episodes || row.view == .extras
        let cardStyle: PosterCardView.Style = landscape ? .landscape : .poster
        var size = metrics.artworkSize(
            for: cardStyle, showsSeriesArtwork: row.isContinueWatching && preview.seriesArtwork,
            playbackDetails: playbackDetails
        )
        if row.isContinueWatching && !landscape {
            size.height = size.width / playbackDetails.cardAspectRatio
        }
        let scale = Self.width / viewportWidth
        let inset = style == .framed ? metrics.cardInset * scale : 0
        let spacing = Self.visibleGap(metrics: metrics, style: style) * scale
        let captionGap = max(3, (landscape ? metrics.landscapeCaptionTopSpacing : metrics.posterCaptionTopSpacing) * scale)
        let captionHeight = max(2, metrics.cardTitleFontSize * scale * 0.65)
        let captionLineGap = max(2, captionHeight * 0.6)
        let columns: Int
        let artworkWidth: CGFloat
        if preview.isGrid {
            columns = max(2, Int(viewportWidth / (metrics.posterWidth + metrics.gridSpacing)))
            artworkWidth = (Self.width - CGFloat(columns - 1) * spacing) / CGFloat(columns) - inset * 2
        } else {
            artworkWidth = size.width * scale
            columns = Int(ceil(Self.width / (artworkWidth + inset * 2 + spacing)))
        }
        let artworkHeight = artworkWidth * size.height / size.width
        let captionBlock = captionGap + captionHeight * 1.75 + captionLineGap
        let surfaceHeight = artworkHeight + inset * 2 + (row.showsLabels ? captionBlock : 0)
        let rowHeight = artworkHeight + inset * 2 + captionBlock
        let rows = preview.isGrid ? 2 : 1
        gap = spacing
        height = CGFloat(rows) * rowHeight + CGFloat(rows - 1) * max(8, metrics.gridSpacing * scale)
        cards = (0..<rows).flatMap { line in
            (0..<columns).map { column in
                let x = CGFloat(column) * (artworkWidth + inset * 2 + spacing)
                let y = CGFloat(line) * (rowHeight + max(8, metrics.gridSpacing * scale))
                let artwork = CGRect(x: x + inset, y: y + inset, width: artworkWidth, height: artworkHeight)
                return Card(
                    artwork: artwork,
                    surface: CGRect(x: x, y: y, width: artworkWidth + inset * 2, height: surfaceHeight),
                    captions: [
                        CGRect(x: artwork.minX, y: artwork.maxY + captionGap, width: artworkWidth * 0.78, height: captionHeight),
                        CGRect(x: artwork.minX, y: artwork.maxY + captionGap + captionHeight + captionLineGap,
                               width: artworkWidth * 0.52, height: captionHeight * 0.75)
                    ]
                )
            }
        }
    }

    static func visibleGap(metrics: PlozzMetrics, style: CardStyle) -> CGFloat {
        metrics.cardSpacing + (style == .borderless ? metrics.borderlessCardSideMargin * 2 : 0)
    }
}
#endif
