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
    /// How far the next row must reach on screen under the tallest pinned row:
    /// its title and the top edge of its cards. The focus engine only moves to
    /// something on screen, so this is what lets Down reach it.
    static let nextRowReach: CGFloat = 90
    /// How much of the next row is actually visible: its title and a sliver of
    /// card. Anything further down stays in place for focus but is masked.
    static let nextRowPeek: CGFloat = 64
    /// Softens the bottom edge of the peek.
    static let peekFade: CGFloat = 36
    /// The pinned row's top edge stays inside these bounds whatever the row mix.
    static let pinnedRange: ClosedRange<CGFloat> = 420...640
    /// Height of the band a row fades through as it lifts out above the pinned row.
    static let fadeBand: CGFloat = 140
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
        .onChange(of: rows.map(\.id)) { _, _ in seedSubjectIfNeeded() }
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
        .frame(height: max(0, pinnedY - FocusHeroLayout.columnGap - columnTop), alignment: .bottomLeading)
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
                            }
                            .prefersDefaultFocus(index == 0, in: focusScope)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, FocusHeroLayout.horizontalMargin)
                .offset(y: pinnedY - top(ofRowAt: activeIndex))
                .focusScope(focusScope)
            }
            .mask(rowsMask)
            .animation(FocusHeroLayout.rowAnimation, value: resolvedActiveRowID)
    }

    /// Solid from the pinned row's title to a sliver of the next row, clear above
    /// (through the band a lifting row fades out in) and below. A mask rather
    /// than opacity: masked rows keep their focusability.
    private var rowsMask: some View {
        let height = FocusHeroLayout.screenHeight
        let top = max(0, pinnedY - 12)
        let fadeTop = max(0, top - FocusHeroLayout.fadeBand)
        let peekEnd = min(
            height,
            pinnedY + activeRowHeight + metrics.rowSpacing + FocusHeroLayout.nextRowPeek
        )
        let bottom = min(height, peekEnd + FocusHeroLayout.peekFade)
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: fadeTop / height),
                .init(color: .black, location: top / height),
                .init(color: .black, location: peekEnd / height),
                .init(color: .clear, location: bottom / height),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Every row pins at one height, low enough for the tallest to fit with the
    /// next one still reachable beneath it.
    private var pinnedY: CGFloat {
        let tallest = rowHeights.values.max() ?? 0
        guard tallest > 0 else { return FocusHeroLayout.pinnedRange.upperBound }
        let fitted = FocusHeroLayout.screenHeight - tallest - metrics.rowSpacing - FocusHeroLayout.nextRowReach
        return min(max(fitted, FocusHeroLayout.pinnedRange.lowerBound), FocusHeroLayout.pinnedRange.upperBound)
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
    }

    private func show(_ next: Subject, in row: FocusHeroRow) {
        guard next != subject else { return }
        if case .item(let item) = next, case .item(let current)? = subject,
           let from = row.itemIDs.firstIndex(of: current.id),
           let to = row.itemIDs.firstIndex(of: item.id) {
            movingForward = to >= from
        }
        subject = next
    }

    private func seedSubjectIfNeeded() {
        if case .item(let item)? = subject,
           rows.contains(where: { $0.itemIDs.contains(item.id) }) {
            return
        }
        if case .library? = subject { return }
        let row = rows.first { $0.id == resolvedActiveRowID } ?? rows.first
        subject = row?.leadItem.map(Subject.item)
    }

    private var subjectItem: MediaItem? {
        if case .item(let item)? = subject { return item }
        return nil
    }
}
#endif
