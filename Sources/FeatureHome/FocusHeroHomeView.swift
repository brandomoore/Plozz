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
    /// this sliver is also what lets Down reach it.
    static let nextRowPeek: CGFloat = 84
    /// Keeps the hero column usable if a row ever measures unexpectedly tall.
    static let lowestSlotTop: CGFloat = 360
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
    static let rowAnimation = Animation.smooth(duration: 0.5)
    /// Quick enough to read as immediate as focus moves card to card, but not a cut.
    static let foregroundAnimation = Animation.easeOut(duration: 0.15)
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

    private enum Subject: Equatable {
        case item(MediaItem)
        case library(AggregatedLibrary)

        var id: String {
            switch self {
            case .item(let item): "item-\(item.id)"
            case .library(let library): "library-\(library.key)"
            }
        }
    }

    @State private var activeRowID: String?
    @State private var subject: Subject?
    @State private var movingForward = true
    /// Until the viewer focuses a title the hero stands in with the first row's
    /// first, and has to follow it as Home swaps cached rows for live ones.
    @State private var hasFocusedTitle = false
    /// Row heights, the only thing measured. Positions are derived from them, so
    /// moving the rows can never change what was measured.
    @State private var rowHeights: [String: CGFloat] = [:]
    @State private var schedules = HeroScheduleLines()
    @Namespace private var focusScope
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.plozzMetrics) private var metrics
    @Environment(\.plozzNavigationContentInset) private var navigationContentInset

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            heroColumn
            rowsLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(
            .container,
            edges: navigationStyle == .rail ? [.vertical, .trailing] : .vertical
        )
        .onAppear(perform: seedSubjectIfNeeded)
        .onChange(of: rows.map(\.itemIDs)) { _, _ in seedSubjectIfNeeded() }
        .task(id: rows.map(\.itemIDs)) {
            await schedules.loadCached(rows.compactMap(\.leadItem))
        }
        .task(id: schedules.fetchKey(for: subjectItem)) {
            guard let item = subjectItem else { return }
            // Only the title the viewer settles on is fetched, not every card
            // passed on the way.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await schedules.refreshFronted(item)
        }
    }

    // MARK: - Backdrop

    @ViewBuilder
    private var backdrop: some View {
        if let subject {
            HomeHeroBackdrop(
                references: backdropReferences(for: subject),
                asyncFallbackURL: subjectItem.flatMap(HomeHeroArtwork.backdropFallback(for:)),
                slideID: subject.id,
                forward: movingForward,
                width: FocusHeroLayout.screenWidth,
                height: FocusHeroLayout.screenHeight,
                scrimTone: colorScheme == .dark ? .black : .white,
                alignsArtworkToLeadingEdge: navigationStyle == .rail,
                scrimOpacity: isFrontmost ? 1 : 0,
                transition: settings.backdropTransition == .slide ? .wipe : .crossfade,
                scrimStyle: .browse
            )
            .allowsHitTesting(false)
        }
    }

    private func backdropReferences(for subject: Subject) -> [ArtworkReference] {
        switch subject {
        case .item(let item):
            HomeHeroArtwork.backdropReferences(for: item)
        case .library(let library):
            [library.library.imageURL].compactMap { $0 }.map(ArtworkReference.remote)
        }
    }

    // MARK: - Hero column

    private var columnTop: CGFloat {
        navigationStyle == .tabBar ? FocusHeroLayout.columnTopUnderTabBar : FocusHeroLayout.columnTop
    }

    private var heroColumn: some View {
        ZStack(alignment: .bottomLeading) {
            if let subject {
                columnContent(for: subject)
                    .id(subject.id)
                    .transition(.opacity)
            }
        }
        .animation(FocusHeroLayout.foregroundAnimation, value: subject?.id)
        .frame(width: FocusHeroLayout.columnWidth, alignment: .bottomLeading)
        .frame(height: max(0, slotTop - FocusHeroLayout.columnGap - columnTop), alignment: .bottomLeading)
        .padding(.top, columnTop)
        .padding(.leading, FocusHeroLayout.horizontalMargin + navigationContentInset)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func columnContent(for subject: Subject) -> some View {
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

    // MARK: - Rows

    private var rowsLayer: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowContent(row, reporter(for: row))
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                let known = rowHeights[row.id] ?? 0
                                guard abs(known - height) > FocusHeroLayout.measurementTolerance else { return }
                                rowHeights[row.id] = height
                                HeroFocusDiagnostics.emit("FHOME height row=\(row.id) h=\(Int(height)) | \(layoutSummary)")
                            }
                            .prefersDefaultFocus(index == 0, in: focusScope)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, FocusHeroLayout.horizontalMargin)
                .offset(y: rowsBottom - top(ofRowAt: activeIndex) - activeRowHeight)
                .focusScope(focusScope)
            }
            .mask(rowsMask)
            .animation(FocusHeroLayout.rowAnimation, value: resolvedActiveRowID)
            .environment(\.plozzCardCaptionsHidden, !settings.showsCardCaptions)
    }

    /// Clear above the pinned row, fading through the band a lifting row leaves
    /// by, and solid from its title down through the next row's peek. A mask
    /// rather than opacity: masked rows keep their focusability.
    private var rowsMask: some View {
        let height = FocusHeroLayout.screenHeight
        let top = max(0, rowsBottom - activeRowHeight - 6)
        let fadeTop = max(0, top - FocusHeroLayout.fadeBand)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: fadeTop / height),
                .init(color: .black, location: top / height),
                .init(color: .black, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Where every pinned row's cards end: low on the screen, with just the next
    /// row's peek beneath. Rows are anchored by this edge, so a shorter row gets
    /// room above its title instead of sitting higher than the others.
    private var rowsBottom: CGFloat {
        FocusHeroLayout.screenHeight - metrics.rowSpacing - FocusHeroLayout.nextRowPeek
    }

    /// The top of the space every row occupies: the tallest row's title. The
    /// hero column always ends above it, whichever row is pinned.
    private var slotTop: CGFloat {
        let tallest = rowHeights.values.max() ?? 0
        return max(FocusHeroLayout.lowestSlotTop, rowsBottom - tallest)
    }

    private var activeIndex: Int {
        rows.firstIndex { $0.id == resolvedActiveRowID } ?? 0
    }

    private var activeRowHeight: CGFloat {
        rows.indices.contains(activeIndex) ? rowHeights[rows[activeIndex].id] ?? 0 : 0
    }

    /// A row's top edge within the stack, from the heights above it.
    private func top(ofRowAt index: Int) -> CGFloat {
        rows.prefix(index).reduce(0) { total, row in
            total + (rowHeights[row.id] ?? 0) + metrics.rowSpacing
        }
    }

    private var resolvedActiveRowID: String? {
        if let activeRowID, rows.contains(where: { $0.id == activeRowID }) { return activeRowID }
        return rows.first?.id
    }

    private func reporter(for row: FocusHeroRow) -> FocusHeroRowReporter {
        FocusHeroRowReporter(
            entered: { activate(row) },
            // Also pins here: the row only reports entry the first time focus
            // arrives, but reports every card it settles on.
            focusedItem: { item in
                activate(row)
                show(.item(item), in: row)
            },
            focusedLibrary: { library in
                activate(row)
                show(.library(library), in: row)
            }
        )
    }

    private func activate(_ row: FocusHeroRow) {
        guard resolvedActiveRowID != row.id else { return }
        let from = rows.firstIndex { $0.id == resolvedActiveRowID } ?? 0
        let to = rows.firstIndex { $0.id == row.id } ?? 0
        movingForward = to >= from
        activeRowID = row.id
        HeroFocusDiagnostics.emit("FHOME activate \(from)->\(to) row=\(row.id) | \(layoutSummary)")
    }

    /// Every row's id, height and top, plus where the pinned row lands, for
    /// `PLZHFOCUS` diagnostics.
    private var layoutSummary: String {
        let parts = rows.enumerated().map { index, row in
            "\(index):\(row.id) h=\(Int(rowHeights[row.id] ?? -1)) top=\(Int(top(ofRowAt: index)))"
        }
        return "active=\(activeIndex) rowsBottom=\(Int(rowsBottom)) slotTop=\(Int(slotTop)) "
            + "offset=\(Int(rowsBottom - top(ofRowAt: activeIndex) - activeRowHeight)) rows=[\(parts.joined(separator: ", "))]"
    }

    private func show(_ next: Subject, in row: FocusHeroRow) {
        hasFocusedTitle = true
        guard next != subject else { return }
        if case .item(let item) = next, case .item(let current)? = subject,
           let from = row.itemIDs.firstIndex(of: current.id),
           let to = row.itemIDs.firstIndex(of: item.id) {
            movingForward = to >= from
        }
        subject = next
    }

    private func seedSubjectIfNeeded() {
        if hasFocusedTitle {
            if case .item(let item)? = subject,
               rows.contains(where: { $0.itemIDs.contains(item.id) }) {
                return
            }
            if case .library? = subject { return }
        }
        let row = rows.first { $0.id == resolvedActiveRowID } ?? rows.first
        subject = row?.leadItem.map(Subject.item)
    }

    private var subjectItem: MediaItem? {
        if case .item(let item)? = subject { return item }
        return nil
    }
}
#endif
