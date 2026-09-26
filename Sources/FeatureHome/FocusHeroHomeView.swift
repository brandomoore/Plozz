#if os(tvOS)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHomeCore
import HeroUI

/// One row of the Home that follows focus, as the hero needs to know it.
struct FocusHeroRow: Identifiable {
    let id: String
    /// Item ids in on-screen order, to tell which way the viewer moved.
    let itemIDs: [String]
    /// What the hero shows before anything in the row has been focused.
    let leadItem: MediaItem?
    /// The wide picture a card in this row leads with, for rows whose cards show
    /// wide art. The hero steers its backdrop off it. `nil` for poster rows.
    var cardArtwork: ((MediaItem) -> [ArtworkReference])? = nil

    /// The picture a focused card in this row is most likely showing.
    func shownArtwork(for item: MediaItem) -> [ArtworkReference] {
        cardArtwork.map { Array($0(item).prefix(1)) } ?? []
    }
}

/// What a row reports as focus moves through it.
struct FocusHeroRowReporter {
    /// Focus reached the row. Synchronous, so the row pins without waiting.
    let entered: () -> Void
    let focusedItem: (MediaItem) -> Void
    let focusedLibrary: (AggregatedLibrary) -> Void
}

/// Geometry and timing for ``FocusHeroHomeView``.
enum FocusHeroLayout {
    static var screenHeight: CGFloat { HomeHeroLayout.screenHeight }
    static var screenWidth: CGFloat { HomeHeroLayout.screenWidth }
    /// What shows of the next row under the pinned one: its title and the top
    /// edge of its cards. The focus engine only moves to something on screen, so
    /// this sliver is also what lets Down reach it. A row's cards start about 82pt
    /// below its top (title, spacing and lift room), so this leaves roughly 30pt
    /// of card on screen; much less and Down only works some of the time.
    static let nextRowPeek: CGFloat = 112
    /// Keeps the hero column usable if a row ever measures unexpectedly tall.
    static let lowestSlotTop: CGFloat = 360
    /// A backdrop's own shape. The art is sized to it rather than cropped to the
    /// screen, so the whole picture shows above the rows.
    static let artAspectRatio: CGFloat = 16.0 / 9.0
    /// How far the art reaches past the tallest row's title. Its bottom fade is
    /// all but transparent by then, so it meets the row without touching it.
    static let artOverhang: CGFloat = 24
    /// The soft edge above the pinned row's title. Narrower than the gap between
    /// rows, so nothing of the row above survives it once it has lifted out.
    static let fadeBand: CGFloat = 16
    /// Ignores sub-point measurement noise so a row settling can't re-lay itself out.
    static let measurementTolerance: CGFloat = 0.5
    /// Clear space between the hero's last line and the pinned row's title.
    static let columnGap: CGFloat = 40
    static let columnTop: CGFloat = 56
    /// The leading margin the classic Home's scroll view gives its content. The
    /// rail publishes its inset on top of this rather than insetting the page, so
    /// without a scroll view here the margin has to be applied by hand.
    static let horizontalMargin: CGFloat = 80
    /// Smaller than the carousel's wordmark box: the column above a pinned poster
    /// row is short, and the description needs its lines more than the logo needs
    /// the extra size.
    static let logoBox = CGSize(width: 440, height: 124)
    /// With the top tab bar the column starts below it: nothing scrolls here, so
    /// the bar never tucks away the way it does over the carousel.
    static let columnTopUnderTabBar: CGFloat = 150
    static let columnWidth: CGFloat = 900
    /// A spring, so a press arriving mid-move carries the motion on from its
    /// current speed rather than restarting it.
    static let rowAnimation = Animation.smooth(duration: 0.35)
    /// Quick enough to read as immediate as focus moves card to card, but not a cut.
    static let foregroundAnimation = Animation.easeOut(duration: 0.15)

    /// Where every pinned row's cards end: low on the screen, with just the next
    /// row's peek beneath. Rows are anchored by this edge, so a shorter row gets
    /// room above its title instead of sitting higher than the others.
    static func rowsBottom(rowSpacing: CGFloat) -> CGFloat {
        screenHeight - rowSpacing - nextRowPeek
    }

    static func columnTop(for style: NavigationStyle) -> CGFloat {
        style == .tabBar ? columnTopUnderTabBar : columnTop
    }
}

/// What the hero shows.
enum FocusHeroSubject: Equatable {
    case item(MediaItem)
    case library(AggregatedLibrary)

    var id: String {
        switch self {
        case .item(let item): "item-\(item.id)"
        case .library(let library): "library-\(library.key)"
        }
    }

    var item: MediaItem? {
        if case .item(let item) = self { return item }
        return nil
    }
}

/// Which row is pinned and what the hero shows.
///
/// Kept out of the view that builds the rows, so moving from row to row
/// re-renders only what moves — the rows' offset, their mask, the hero column
/// and the backdrop — and never the rows themselves. Rebuilding every row on
/// each press is what made quick presses stutter.
@Observable
@MainActor
final class FocusHeroModel {
    private(set) var activeRowID: String?
    private(set) var subject: FocusHeroSubject?
    /// The picture the focused card shows, which the backdrop avoids.
    private(set) var shownArtwork: [ArtworkReference] = []
    private(set) var movingForward = true
    /// Row heights, the only thing measured. Positions are derived from them, so
    /// moving the rows can never change what was measured.
    private(set) var rowHeights: [String: CGFloat] = [:]
    /// Until the viewer focuses a title the hero stands in with the first row's
    /// first, and has to follow it as Home swaps cached rows for live ones.
    @ObservationIgnored private var hasFocusedTitle = false

    func activate(_ row: FocusHeroRow, in rows: [FocusHeroRow]) {
        // Compared with the recorded row, not the resolved one: before anything is
        // recorded the first row stands in, and a row loading in above it must not
        // take the pin from the row that actually holds focus.
        guard activeRowID != row.id else { return }
        let from = rows.firstIndex { $0.id == resolvedActiveRowID(in: rows) } ?? 0
        let to = rows.firstIndex { $0.id == row.id } ?? 0
        movingForward = to >= from
        withAnimation(FocusHeroLayout.rowAnimation) {
            activeRowID = row.id
        }
        HeroFocusDiagnostics.emit("FHOME activate \(from)->\(to) row=\(row.id)")
    }

    func show(_ next: FocusHeroSubject, in row: FocusHeroRow) {
        hasFocusedTitle = true
        guard next != subject else { return }
        if let item = next.item, let current = subject?.item,
           let from = row.itemIDs.firstIndex(of: current.id),
           let to = row.itemIDs.firstIndex(of: item.id) {
            movingForward = to >= from
        }
        withAnimation(FocusHeroLayout.foregroundAnimation) {
            shownArtwork = next.item.map(row.shownArtwork(for:)) ?? []
            subject = next
        }
    }

    func seed(from rows: [FocusHeroRow]) {
        if hasFocusedTitle {
            if let item = subject?.item, rows.contains(where: { $0.itemIDs.contains(item.id) }) {
                return
            }
            if case .library? = subject { return }
        }
        let row = rows.first { $0.id == resolvedActiveRowID(in: rows) } ?? rows.first
        shownArtwork = row.flatMap { row in row.leadItem.map(row.shownArtwork(for:)) } ?? []
        subject = row?.leadItem.map(FocusHeroSubject.item)
    }

    func record(height: CGFloat, for rowID: String) {
        let known = rowHeights[rowID] ?? 0
        guard abs(known - height) > FocusHeroLayout.measurementTolerance else { return }
        rowHeights[rowID] = height
    }

    func resolvedActiveRowID(in rows: [FocusHeroRow]) -> String? {
        if let activeRowID, rows.contains(where: { $0.id == activeRowID }) { return activeRowID }
        return rows.first?.id
    }

    func activeIndex(in rows: [FocusHeroRow]) -> Int {
        let id = resolvedActiveRowID(in: rows)
        return rows.firstIndex { $0.id == id } ?? 0
    }

    func activeHeight(in rows: [FocusHeroRow]) -> CGFloat {
        let index = activeIndex(in: rows)
        return rows.indices.contains(index) ? rowHeights[rows[index].id] ?? 0 : 0
    }

    /// A row's top edge within the stack, from the heights above it.
    func top(ofRowAt index: Int, in rows: [FocusHeroRow], rowSpacing: CGFloat) -> CGFloat {
        rows.prefix(index).reduce(0) { total, row in
            total + (rowHeights[row.id] ?? 0) + rowSpacing
        }
    }

    /// The top of the space every row occupies: the tallest current row's title.
    /// The hero column always ends above it, whichever row is pinned. Only rows
    /// still on Home count, so a row that goes away can't hold the column short.
    func slotTop(in rows: [FocusHeroRow], rowSpacing: CGFloat) -> CGFloat {
        let tallest = rows.compactMap { rowHeights[$0.id] }.max() ?? 0
        return max(
            FocusHeroLayout.lowestSlotTop,
            FocusHeroLayout.rowsBottom(rowSpacing: rowSpacing) - tallest
        )
    }
}

/// Apple TV Home where the hero is whatever is focused.
///
/// Every title gets the full-screen treatment the carousel gives its picks: its
/// backdrop fills the screen and its logo, details and description sit top left.
/// There are no hero buttons, because the rows are how you move through it.
///
/// The focused row always sits at the same height. Moving down lifts it up and
/// out while the next one rises into its place. Rows above and below stay laid
/// out where they would be and are only hidden by a mask, never by opacity, so
/// the focus engine still finds them: a click or a swipe moves focus natively,
/// and the row that receives it animates into the pinned position.
struct FocusHeroHomeView<RowContent: View>: View {
    let rows: [FocusHeroRow]
    let settings: HeroSettings
    let spoilerSettings: SpoilerSettings
    let navigationStyle: NavigationStyle
    let isFrontmost: Bool
    let rowContent: (FocusHeroRow, FocusHeroRowReporter) -> RowContent

    init(
        rows: [FocusHeroRow],
        settings: HeroSettings,
        spoilerSettings: SpoilerSettings,
        navigationStyle: NavigationStyle,
        isFrontmost: Bool,
        @ViewBuilder rowContent: @escaping (FocusHeroRow, FocusHeroRowReporter) -> RowContent
    ) {
        self.rows = rows
        self.settings = settings
        self.spoilerSettings = spoilerSettings
        self.navigationStyle = navigationStyle
        self.isFrontmost = isFrontmost
        self.rowContent = rowContent
    }

    @State private var model = FocusHeroModel()

    // Reads nothing from `model`: this body builds the rows, and must not run
    // again when the pinned row or the hero title changes.
    var body: some View {
        ZStack(alignment: .topLeading) {
            FocusHeroBackdropLayer(
                model: model,
                rows: rows,
                transition: settings.backdropTransition,
                navigationStyle: navigationStyle,
                isFrontmost: isFrontmost
            )
            FocusHeroColumn(
                model: model,
                rows: rows,
                settings: settings,
                spoilerSettings: spoilerSettings,
                navigationStyle: navigationStyle
            )
            Color.clear
                .overlay(alignment: .topLeading) {
                    FocusHeroRowStack(rows: rows, model: model, rowContent: rowContent)
                        .modifier(FocusHeroRowOffset(model: model, rows: rows))
                }
                .modifier(FocusHeroRowMask(model: model, rows: rows))
                .environment(\.plozzCardCaptionsHidden, !settings.showsCardCaptions)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(
            .container,
            edges: navigationStyle == .rail ? [.vertical, .trailing] : .vertical
        )
        .onAppear { model.seed(from: rows) }
        .onChange(of: rows.map(\.itemIDs)) { _, _ in model.seed(from: rows) }
    }
}

// MARK: - Rows

/// The rows themselves. Built from `rows` alone, so a change of pinned row or
/// hero title never rebuilds them: the model is only ever written from here.
private struct FocusHeroRowStack<RowContent: View>: View {
    let rows: [FocusHeroRow]
    let model: FocusHeroModel
    let rowContent: (FocusHeroRow, FocusHeroRowReporter) -> RowContent
    @Namespace private var focusScope
    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowContent(row, reporter(for: row))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        model.record(height: height, for: row.id)
                    }
                    .prefersDefaultFocus(index == 0, in: focusScope)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, FocusHeroLayout.horizontalMargin)
        .focusScope(focusScope)
    }

    private func reporter(for row: FocusHeroRow) -> FocusHeroRowReporter {
        let rows = rows
        let model = model
        return FocusHeroRowReporter(
            entered: { model.activate(row, in: rows) },
            // Also pins here: a row reports entry only the first time focus
            // arrives, but reports every card it settles on.
            focusedItem: { item in
                model.activate(row, in: rows)
                model.show(.item(item), in: row)
            },
            focusedLibrary: { library in
                model.activate(row, in: rows)
                model.show(.library(library), in: row)
            }
        )
    }
}

/// Moves the stack so the pinned row's cards end on the shared line.
private struct FocusHeroRowOffset: ViewModifier {
    let model: FocusHeroModel
    let rows: [FocusHeroRow]
    @Environment(\.plozzMetrics) private var metrics

    func body(content: Content) -> some View {
        let spacing = metrics.rowSpacing
        let index = model.activeIndex(in: rows)
        let bottom = FocusHeroLayout.rowsBottom(rowSpacing: spacing)
        let y = bottom - model.top(ofRowAt: index, in: rows, rowSpacing: spacing) - model.activeHeight(in: rows)
        content.offset(y: y)
    }
}

/// Clear above the pinned row, solid from its title down through the next row's
/// peek. A mask rather than opacity: masked rows keep their focusability.
private struct FocusHeroRowMask: ViewModifier {
    let model: FocusHeroModel
    let rows: [FocusHeroRow]
    @Environment(\.plozzMetrics) private var metrics

    func body(content: Content) -> some View {
        let height = FocusHeroLayout.screenHeight
        let bottom = FocusHeroLayout.rowsBottom(rowSpacing: metrics.rowSpacing)
        let top = max(0, bottom - model.activeHeight(in: rows) - 6)
        let fadeTop = max(0, top - FocusHeroLayout.fadeBand)
        content.mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: fadeTop / height),
                    .init(color: .black, location: top / height),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Backdrop

private struct FocusHeroBackdropLayer: View {
    let model: FocusHeroModel
    let rows: [FocusHeroRow]
    let transition: HeroBackdropTransition
    let navigationStyle: NavigationStyle
    let isFrontmost: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.plozzMetrics) private var metrics

    var body: some View {
        // The art fills the space above the rows at a backdrop's own shape,
        // rather than the whole screen, so none of it is cropped away behind
        // the rows. It fades out just above the tallest row's title.
        let height = model.slotTop(in: rows, rowSpacing: metrics.rowSpacing)
            + FocusHeroLayout.artOverhang
        let width = min(FocusHeroLayout.screenWidth, height * FocusHeroLayout.artAspectRatio)
        if let subject = model.subject {
            HomeHeroBackdrop(
                references: references(for: subject),
                asyncFallbackURL: subject.item.flatMap(HomeHeroArtwork.backdropFallback(for:)),
                slideID: subject.id,
                forward: model.movingForward,
                width: width,
                height: height,
                scrimTone: colorScheme == .dark ? .black : .white,
                scrimOpacity: isFrontmost ? 1 : 0,
                transition: transition == .slide ? .wipe : .crossfade,
                scrimStyle: .browse
            )
            .allowsHitTesting(false)
        }
    }

    private func references(for subject: FocusHeroSubject) -> [ArtworkReference] {
        switch subject {
        case .item(let item):
            HomeHeroArtwork.backdropReferences(for: item, avoiding: model.shownArtwork)
        case .library(let library):
            [library.library.imageURL].compactMap { $0 }.map(ArtworkReference.remote)
        }
    }
}

// MARK: - Hero column

private struct FocusHeroColumn: View {
    let model: FocusHeroModel
    let rows: [FocusHeroRow]
    let settings: HeroSettings
    let spoilerSettings: SpoilerSettings
    let navigationStyle: NavigationStyle
    @State private var schedules = HeroScheduleLines()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzNavigationContentInset) private var navigationContentInset

    var body: some View {
        let top = FocusHeroLayout.columnTop(for: navigationStyle)
        let slotTop = model.slotTop(in: rows, rowSpacing: metrics.rowSpacing)
        ZStack(alignment: .bottomLeading) {
            if let subject = model.subject {
                content(for: subject)
                    .id(subject.id)
                    .transition(.opacity)
            }
        }
        .frame(width: FocusHeroLayout.columnWidth, alignment: .bottomLeading)
        .frame(height: max(0, slotTop - FocusHeroLayout.columnGap - top), alignment: .bottomLeading)
        .padding(.top, top)
        .padding(.leading, FocusHeroLayout.horizontalMargin + navigationContentInset)
        .allowsHitTesting(false)
        .task(id: schedules.fetchKey(for: model.subject?.item)) {
            guard let item = model.subject?.item else { return }
            await schedules.loadCached([item])
            // Only the title the viewer settles on is fetched, not every card
            // passed on the way.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await schedules.refreshFronted(item)
        }
    }

    @ViewBuilder
    private func content(for subject: FocusHeroSubject) -> some View {
        switch subject {
        case .item(let item):
            itemColumn(item)
        case .library(let library):
            VStack(alignment: .leading, spacing: 12) {
                library.library.displayName
                    .font(.system(size: 64, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                if !library.serverName.isEmpty {
                    Text(verbatim: library.serverName)
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .modifier(HeroTextLegibilityShadow(colorScheme: colorScheme))
        }
    }

    private func itemColumn(_ item: MediaItem) -> some View {
        let hideText = spoilerSettings.shouldHideText(for: item)
        let references = HomeHeroArtwork.backdropReferences(for: item)
        return VStack(alignment: .leading, spacing: 12) {
            if let scheduleLine = schedules.line(for: item) {
                HeroScheduleBadge(text: scheduleLine)
            }
            HeroLogoArtwork(
                references: item.artworkReferences(for: .logo),
                asyncFallbackURL: HomeHeroArtwork.logoFallback(for: item),
                backgroundSample: HomeHeroArtwork.backgroundSample(for: item, references: references),
                maxWidth: FocusHeroLayout.logoBox.width,
                maxHeight: FocusHeroLayout.logoBox.height,
                presentationPolicy: .onArrival(maximumWait: 0.25)
            ) {
                title(for: item, hideText: hideText)
                    .font(.system(size: 64, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .multilineTextAlignment(.leading)
            }
            .padding(.bottom, 6)

            HeroMetadataLine(item: item)
                .modifier(HeroTextLegibilityShadow(colorScheme: colorScheme))

            if !hideText, let description = item.tagline ?? item.overview {
                Text(description.overviewPlainText)
                    .font(.system(size: 22))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .frame(maxWidth: 820, alignment: .topLeading)
                    .modifier(HeroTextLegibilityShadow(colorScheme: colorScheme))
            }

            if settings.shouldShowRatings(for: item, spoilerSettings: spoilerSettings) {
                let presentation = HeroPresentation(item: item, artworkStyle: .landscape, surface: .home)
                RatingsBadgeRow(
                    ratings: settings.ratingPreferences.headerRatings(
                        from: item.ratings, isAnime: presentation.isAnime, hidesRatings: false
                    ),
                    familyGuidanceAge: settings.ratingPreferences.headerFamilyGuidanceAge(
                        from: presentation.familyGuidanceAge, hidesRatings: false
                    )
                )
            }
        }
    }

    /// An episode leads with its show, as the carousel does.
    private func title(for item: MediaItem, hideText: Bool) -> Text {
        if item.kind == .episode,
           let parentTitle = item.parentTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !parentTitle.isEmpty {
            return Text(verbatim: parentTitle)
        }
        if hideText {
            return Text(spoilerSettings.maskedTitle(for: item))
        }
        return Text(verbatim: item.title)
    }
}

// MARK: - Loading

/// What the Home that follows focus shows until Continue Watching is live: the
/// real rows' own loading placeholders, in the place the real rows will take, so
/// nothing shifts when they arrive. Nothing here is focusable, so focus arrives
/// on a real card, once.
struct FocusHeroSkeletonView: View {
    var continueWatchingCount: Int = 0
    var continueWatchingShowsSeriesArtwork: Bool = true
    var showsCardCaptions: Bool = false
    @State private var firstRowHeight: CGFloat = 0
    @Environment(\.plozzMetrics) private var metrics

    /// Enough to fill the row when last launch's count isn't known.
    private static let fallbackCount = 8

    var body: some View {
        let bottom = FocusHeroLayout.rowsBottom(rowSpacing: metrics.rowSpacing)
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            MediaRowView(
                title: Text(HomeRowKind.continueWatching.title),
                items: [],
                style: .landscape,
                showsSeriesArtwork: continueWatchingShowsSeriesArtwork,
                loadingPlaceholderCount: continueWatchingCount > 0
                    ? continueWatchingCount : Self.fallbackCount,
                onSelect: { _ in }
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { firstRowHeight = $0 }
            MediaRowView(
                title: nil,
                items: [],
                style: .poster,
                loadingPlaceholderCount: Self.fallbackCount,
                onSelect: { _ in }
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, FocusHeroLayout.horizontalMargin)
        // The first placeholder's bottom sits on the shared row line, where the
        // real Continue Watching cards will.
        .offset(y: bottom - firstRowHeight)
        .opacity(firstRowHeight > 0 ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: .vertical)
        .allowsHitTesting(false)
        .environment(\.plozzCardCaptionsHidden, !showsCardCaptions)
        .accessibilityLabel("Loading")
    }
}
#endif
