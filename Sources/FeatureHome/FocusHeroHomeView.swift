#if os(tvOS)
import SwiftUI
import UIKit
import CoreModels
import CoreNetworking
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
    /// The row's titles, so their details can load before focus reaches them.
    var items: [MediaItem] = []
    var isPlaceholder: Bool = false
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
    /// Focus landed on a card. Synchronous, so a row change updates the hero
    /// with the row instead of after the settle delay.
    let cardFocused: (MediaItem) -> Void
    let focusedItem: (MediaItem) -> Void
    let focusedLibrary: (AggregatedLibrary) -> Void
}

/// Geometry and timing for ``FocusHeroHomeView``.
enum FocusHeroLayout {
    static var screenHeight: CGFloat { HomeHeroLayout.screenHeight }
    static var screenWidth: CGFloat { HomeHeroLayout.screenWidth }
    /// What shows of the next row under the pinned one: its title and the top
    /// edge of its cards. Keep real artwork visible below the heading and its
    /// spacing so the native focus engine can reach it with Down.
    static let nextRowPeek: CGFloat = 96
    /// Keeps the hero column usable if a row ever measures unexpectedly tall.
    static let lowestSlotTop: CGFloat = 360
    /// A backdrop's own shape. The art is sized to it rather than cropped to the
    /// screen, so the whole picture shows above the rows.
    static let artAspectRatio: CGFloat = 16.0 / 9.0
    /// How far the rows' vertical mask reaches past their layout bounds sideways,
    /// covering the safe area and a focused card's bloom at either edge.
    static let maskHorizontalOverhang: CGFloat = 160
    /// The gap between rows. Tighter than the classic Home's: rows here are
    /// read one at a time, and every point saved lets the rows sit lower and
    /// leaves the art more room.
    static let rowSpacing: CGFloat = 16
    static let rowBottomTightening: CGFloat = 12
    static let activeTitleLift: CGFloat = 20
    /// How much of the screen's width the art takes.
    static let artWidthFraction: CGFloat = 2.0 / 3.0
    /// The soft edge above the pinned row's title that a leaving row slides
    /// under. Narrow, so that edge stays clear of the hero's details above it.
    static let fadeBand: CGFloat = 24
    /// The extra rise that carries a row above the pinned one clear of the
    /// stack mask's edge: from its resting bottom, beside the pinned title,
    /// past the fade band above it.
    static let rowTuck: CGFloat = 110
    /// Over how much of its own climb a leaving row gains that extra rise.
    static let rowTuckRamp: CGFloat = 300
    /// Ignores sub-point measurement noise so a row settling can't re-lay itself out.
    static let measurementTolerance: CGFloat = 0.5
    /// Clear space between the hero's last line and the pinned row's title.
    static let columnGap: CGFloat = 40
    static let columnTop: CGFloat = 56
    static var detailsFootprintHeight: CGFloat {
        lowestSlotTop - columnGap - columnTop
    }
    /// Smaller than the carousel's wordmark box: the column above a pinned poster
    /// row is short, and the description needs its lines more than the logo needs
    /// the extra size.
    static let logoBox = CGSize(width: 440, height: 124)
    static let logoPresentationPolicy = HeroLogoPresentationPolicy.whenReady
    /// How much closer a row's title sits to its cards than on the classic Home.
    static let rowTitleTightening: CGFloat = 22
    /// With the top tab bar the column starts below it: nothing scrolls here, so
    /// the bar never tucks away the way it does over the carousel.
    static let columnTopUnderTabBar: CGFloat = 150
    static let columnWidth: CGFloat = 900
    /// Shared perceptual timing for the native viewport, heading, mask and hero.
    static let rowSpringDuration: TimeInterval = 0.4
    /// Row changes closer together than this are passing through: the hero
    /// waits for the row focus stops on.
    static let rowPassInterval: TimeInterval = 0.3
    static let rowSpring = Spring(duration: rowSpringDuration, bounce: 0)
    static let rowAnimation = Animation.interpolatingSpring(rowSpring)
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
        case .item(let item): "item-\(item.stablePresentationID)"
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
/// re-renders only what moves — the scroll destination, mask, hero column
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
    /// What the details block shows: the subject, except that it swaps outright
    /// when the title changes with the row. The block slides with the row then,
    /// and crossfading as it slides would show both titles at different heights.
    private(set) var details: FocusHeroSubject?
    private(set) var detailsSwapWithRow = false
    /// Row heights, the only thing measured. Positions are derived from them, so
    /// moving the rows can never change what was measured.
    private(set) var rowHeights: [String: CGFloat] = [:]
    /// Until the viewer focuses a title the hero stands in with the first row's
    /// first, and has to follow it as Home swaps cached rows for live ones.
    @ObservationIgnored private var hasFocusedTitle = false
    /// When the pinned row last changed, and whether that change came hard on
    /// the heels of another: moving quickly through rows, the hero holds its
    /// title until the viewer stops, instead of rebuilding for every row passed.
    @ObservationIgnored private var lastRowChange = -CFTimeInterval.infinity
    @ObservationIgnored private var passingThrough = false
    @ObservationIgnored private var pendingShow: DispatchWorkItem?
    @ObservationIgnored let motion = FocusHeroRowMotion()

    func activate(_ row: FocusHeroRow, in rows: [FocusHeroRow]) {
        // Compared with the recorded row, not the resolved one: before anything is
        // recorded the first row stands in, and a row loading in above it must not
        // take the pin from the row that actually holds focus.
        guard activeRowID != row.id else { return }
        let from = rows.firstIndex { $0.id == resolvedActiveRowID(in: rows) } ?? 0
        let to = rows.firstIndex { $0.id == row.id } ?? 0
        movingForward = to >= from
        let now = CACurrentMediaTime()
        passingThrough = now - lastRowChange < FocusHeroLayout.rowPassInterval
        lastRowChange = now
        withAnimation(FocusHeroLayout.rowAnimation) {
            activeRowID = row.id
        }
        HeroFocusDiagnostics.emit("FHOME activate \(from)->\(to) row=\(row.id)")
    }

    func show(_ next: FocusHeroSubject, in row: FocusHeroRow, withRow: Bool = false) {
        hasFocusedTitle = true
        pendingShow?.cancel()
        pendingShow = nil
        let sinceRowChange = CACurrentMediaTime() - lastRowChange
        if passingThrough, sinceRowChange < FocusHeroLayout.rowPassInterval {
            // Shown once focus stops, outright, as a title that arrives with its row.
            let work = DispatchWorkItem { [weak self] in
                self?.pendingShow = nil
                self?.apply(next, in: row, withRow: true)
            }
            pendingShow = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + FocusHeroLayout.rowPassInterval - sinceRowChange,
                execute: work
            )
            return
        }
        apply(next, in: row, withRow: withRow)
    }

    private func apply(_ next: FocusHeroSubject, in row: FocusHeroRow, withRow: Bool) {
        guard next != subject else { return }
        if let item = next.item, let current = subject?.item,
           let from = row.itemIDs.firstIndex(of: current.stablePresentationID),
           let to = row.itemIDs.firstIndex(of: item.stablePresentationID) {
            movingForward = to >= from
        }
        // With a row change everything moves on the row's own timing, so the
        // details keep pace with the rows and the edge they slide under.
        withAnimation(withRow ? FocusHeroLayout.rowAnimation : FocusHeroLayout.foregroundAnimation) {
            shownArtwork = next.item.map(row.shownArtwork(for:)) ?? []
            subject = next
            detailsSwapWithRow = withRow
            details = next
        }
    }

    func seed(from rows: [FocusHeroRow]) {
        if hasFocusedTitle {
            if let item = subject?.item,
               let row = rows.first(where: {
                   $0.id == activeRowID && $0.itemIDs.contains(item.stablePresentationID)
               }) ?? rows.first(where: { $0.itemIDs.contains(item.stablePresentationID) }),
               let current = row.items.first(where: {
                   $0.stablePresentationID == item.stablePresentationID
               }) {
                subject = .item(current)
                details = subject
                shownArtwork = row.shownArtwork(for: current)
                return
            }
            if case .library? = subject { return }
        }
        let row = rows.first { $0.id == resolvedActiveRowID(in: rows) } ?? rows.first
        shownArtwork = row.flatMap { row in row.leadItem.map(row.shownArtwork(for:)) } ?? []
        subject = row?.leadItem.map(FocusHeroSubject.item)
        details = subject
    }

    func record(height: CGFloat, for rowID: String) {
        let known = rowHeights[rowID] ?? 0
        guard abs(known - height) > FocusHeroLayout.measurementTolerance else { return }
        rowHeights[rowID] = height
        HeroFocusDiagnostics.emit("FHOME row height \(rowID)=\(height)")
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

    /// The first row rests at offset zero so native navigation recognizes Home's
    /// top edge. Subtract the same origin from the spacer and every destination.
    func scrollOrigin(in rows: [FocusHeroRow]) -> CGFloat {
        guard let first = rows.first else { return 0 }
        return min(
            rowHeights[first.id] ?? 0,
            FocusHeroLayout.rowsBottom(rowSpacing: FocusHeroLayout.rowSpacing)
        )
    }

    /// A row's top edge within the stack, from the heights above it.
    func top(ofRowAt index: Int, in rows: [FocusHeroRow], rowSpacing: CGFloat) -> CGFloat {
        rows.prefix(index).reduce(0) { total, row in
            total + (rowHeights[row.id] ?? 0) + rowSpacing
        }
    }

    func tuckOffsets(in rows: [FocusHeroRow]) -> [String: CGFloat] {
        let spacing = FocusHeroLayout.rowSpacing
        let activeTop = top(ofRowAt: activeIndex(in: rows), in: rows, rowSpacing: spacing)
        var rowTop: CGFloat = 0
        var offsets: [String: CGFloat] = [:]
        for row in rows {
            let progress = min(1, max(0, (activeTop - rowTop) / FocusHeroLayout.rowTuckRamp))
            offsets[row.id] = -FocusHeroLayout.rowTuck * progress
            rowTop += (rowHeights[row.id] ?? 0) + spacing
        }
        return offsets
    }

    func heightStops(in rows: [FocusHeroRow]) -> [FocusHeroHeightStop] {
        let origin = scrollOrigin(in: rows)
        var top: CGFloat = 0
        return rows.map { row in
            let height = rowHeights[row.id] ?? 0
            defer { top += height + FocusHeroLayout.rowSpacing }
            return FocusHeroHeightStop(offset: top + height - origin, height: height)
        }
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
    let enrich: FocusHeroMetadata.Enrich?
    let rowContent: (FocusHeroRow, FocusHeroRowReporter) -> RowContent

    init(
        rows: [FocusHeroRow],
        settings: HeroSettings,
        spoilerSettings: SpoilerSettings,
        navigationStyle: NavigationStyle,
        isFrontmost: Bool,
        enrich: FocusHeroMetadata.Enrich? = nil,
        @ViewBuilder rowContent: @escaping (FocusHeroRow, FocusHeroRowReporter) -> RowContent
    ) {
        self.rows = rows
        self.settings = settings
        self.spoilerSettings = spoilerSettings
        self.navigationStyle = navigationStyle
        self.isFrontmost = isFrontmost
        self.enrich = enrich
        self.rowContent = rowContent
    }

    @State private var model = FocusHeroModel()
    @State private var metadata = FocusHeroMetadata()

    // Reads nothing from `model`: this body builds the rows, and must not run
    // again when the pinned row or the hero title changes.
    var body: some View {
        ZStack(alignment: .topLeading) {
            FocusHeroBackdropLayer(
                model: model,
                navigationStyle: navigationStyle,
                isFrontmost: isFrontmost
            )
            FocusHeroColumn(
                model: model,
                metadata: metadata,
                enrich: enrich,
                settings: settings,
                spoilerSettings: spoilerSettings,
                navigationStyle: navigationStyle
            )
            FocusHeroScrollingRows(rows: rows, model: model, rowContent: rowContent)
                .environment(\.plozzRowTitleTightening, FocusHeroLayout.rowTitleTightening)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(
            .container,
            edges: navigationStyle == .rail ? [.vertical, .trailing] : .vertical
        )
        .onAppear { model.seed(from: rows) }
        .onChange(of: rows.map(\.itemIDs)) { _, _ in model.seed(from: rows) }
        .onChange(of: rows.map(\.items)) { _, _ in model.seed(from: rows) }
        .task(id: rows.map { $0.items.map(FocusHeroMetadata.Key.init) }) {
            guard let enrich else { return }
            await metadata.prefetch(rows.map { Array($0.items.prefix(16)) }, using: enrich)
        }
    }
}

/// The room a title's details take: the logo box, one metadata line and a
/// three-line description, or a one-line description and the ratings row. Drawn
/// hidden, it fixes where the details block, and so the logo, sits above the
/// pinned row.
private struct FocusHeroDetailsFootprint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear
                .frame(height: FocusHeroLayout.logoBox.height)
                .padding(.bottom, 6)
            Text(verbatim: " ").font(.system(size: 23, weight: .medium))
            Text(verbatim: " \n \n ")
                .font(.system(size: 22))
                .lineSpacing(2)
        }
        .frame(width: FocusHeroLayout.columnWidth, alignment: .leading)
    }
}

/// The hero's details for each title, filled in the way the classic hero fills
/// its slides. Row records are sparse and differ by row, so without this one title
/// shows genres and a rating and the next shows neither.
@MainActor @Observable
final class FocusHeroMetadata {
    typealias Enrich = @Sendable ([MediaItem]) async -> [MediaItem]

    struct Key: Hashable {
        let presentationID: String
        let accountID: String?
        let itemID: String

        init(_ item: MediaItem) {
            presentationID = item.stablePresentationID
            accountID = item.sourceAccountID
            itemID = item.id
        }
    }

    @Observable final class Entry {
        var item: MediaItem?
    }

    @ObservationIgnored private var details: [Key: Entry] = [:]
    @ObservationIgnored private var requested: Set<Key> = []

    private func entry(for key: Key) -> Entry {
        if let entry = details[key] { return entry }
        let entry = Entry()
        details[key] = entry
        return entry
    }

    /// Enrichment supplies presentation fields, never cached watch state or routing.
    func item(for current: MediaItem) -> MediaItem {
        guard let full = entry(for: Key(current)).item else { return current }
        var item = current
        if item.genres.isEmpty { item.genres = full.genres }
        if item.officialRating?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            item.officialRating = full.officialRating
        }
        if item.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            item.overview = full.overview
        }
        if item.taglines.isEmpty { item.taglines = full.taglines }
        item.mergeHydratedRatings(from: full)
        if item.familyGuidance == nil { item.familyGuidance = full.familyGuidance }
        if item.logoURL == nil { item.logoURL = full.logoURL }
        if item.heroBackdropURL == nil { item.heroBackdropURL = full.heroBackdropURL }
        if item.backdropURL == nil { item.backdropURL = full.backdropURL }
        if item.fallbackArtworkURL == nil { item.fallbackArtworkURL = full.fallbackArtworkURL }
        if item.artworkSelections.isEmpty { item.artworkSelections = full.artworkSelections }
        if item.kind == full.kind {
            if item.productionYear == nil { item.productionYear = full.productionYear }
            if item.releaseDate == nil { item.releaseDate = full.releaseDate }
            if item.runtime == nil { item.runtime = full.runtime }
        }
        return item
    }

    func hasDetails(for item: MediaItem) -> Bool {
        entry(for: Key(item)).item != nil
    }

    /// One small batch at a time bounds provider fan-out and main-actor publication.
    func prefetch(_ rows: [[MediaItem]], using enrich: @escaping Enrich) async {
        for items in rows {
            for start in stride(from: 0, to: items.count, by: 4) {
                guard !Task.isCancelled else { return }
                let batch = items[start..<min(start + 4, items.count)].filter {
                    entry(for: Key($0)).item == nil && requested.insert(Key($0)).inserted
                }
                guard !batch.isEmpty else { continue }
                await store(batch, using: enrich)
            }
        }
    }

    private func store(_ batch: [MediaItem], using enrich: Enrich) async {
        let enriched = await HeroMetadataEnricher.withPinnedSeries({ batch }) {
            await enrich(batch)
        }
        guard !Task.isCancelled, enriched.count == batch.count else {
            if !Task.isCancelled, enriched.count != batch.count {
                PlozzLog.app.error("Showcase metadata returned an incomplete batch; allowing retry")
            }
            batch.forEach { requested.remove(Key($0)) }
            return
        }
        for (original, full) in zip(batch, enriched) {
            entry(for: Key(original)).item = full
            requested.remove(Key(original))
        }
    }

    /// Loads the focused title's details straight away, ahead of the rest of its
    /// row. A load cut short is tried again next time.
    func load(_ item: MediaItem, using enrich: Enrich) async {
        let key = Key(item)
        guard !Task.isCancelled, entry(for: key).item == nil, requested.insert(key).inserted else { return }
        await store([item], using: enrich)
    }
}

// MARK: - Rows

/// Stable row owners outlive the native viewport's in-flight presentation.
/// A lazy stack would recycle for the logical destination before the slide arrives.
private struct FocusHeroRowStack<RowContent: View>: View {
    let rows: [FocusHeroRow]
    let model: FocusHeroModel
    let rowContent: (FocusHeroRow, FocusHeroRowReporter) -> RowContent
    @Namespace private var focusScope
    @State private var hasEnteredContent = false

    var body: some View {
        // Default-focus preference cannot stop an already-ready lower row
        // from winning while the first native target is still being realized.
        let awaitsFirstEntry = !hasEnteredContent && model.activeRowID == nil
            && rows.first.map { $0.isPlaceholder || !$0.itemIDs.isEmpty } == true
        VStack(alignment: .leading, spacing: FocusHeroLayout.rowSpacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                rowBody(row)
                    .disabled(awaitsFirstEntry && index > 0)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        model.record(height: height, for: row.id)
                    }
                    .prefersDefaultFocus(index == 0, in: focusScope)
            }
        }
        .focusScope(focusScope)
    }

    @ViewBuilder
    private func rowBody(_ row: FocusHeroRow) -> some View {
        let content = rowContent(row, reporter(for: row))
            .environment(\.plozzRowTitleOffset, {
                model.resolvedActiveRowID(in: rows) == row.id ? -FocusHeroLayout.activeTitleLift : 0
            })
            .padding(.bottom, -FocusHeroLayout.rowBottomTightening)
        FocusHeroMotionSurface(
            content: content.fixedSize(horizontal: false, vertical: true),
            motion: model.motion, kind: .row(row.id)
        )
        .accessibilityElement(children: .contain)
    }

    private func reporter(for row: FocusHeroRow) -> FocusHeroRowReporter {
        let rows = rows
        let model = model
        return FocusHeroRowReporter(
            entered: {
                hasEnteredContent = true
                model.activate(row, in: rows)
            },
            // Along a row the hero waits for focus to settle; a new row has
            // no card to settle past, so its title shows as the row moves.
            cardFocused: { item in
                hasEnteredContent = true
                let changedRow = model.resolvedActiveRowID(in: rows) != row.id
                model.activate(row, in: rows)
                if changedRow { model.show(.item(item), in: row, withRow: true) }
            },
            // Also pins here: a row reports entry only the first time focus
            // arrives, but reports every card it settles on.
            focusedItem: { item in
                hasEnteredContent = true
                model.activate(row, in: rows)
                model.show(.item(item), in: row)
            },
            focusedLibrary: { library in
                hasEnteredContent = true
                model.activate(row, in: rows)
                model.show(.library(library), in: row)
            }
        )
    }
}

struct FocusHeroScrollingRows<RowContent: View>: View {
    let rows: [FocusHeroRow]
    let model: FocusHeroModel
    let rowContent: (FocusHeroRow, FocusHeroRowReporter) -> RowContent
    var body: some View {
        FocusHeroMotionSurface(content: scroll, motion: model.motion, kind: .mask)
            .accessibilityElement(children: .contain)
    }

    private var scroll: some View {
        let bottom = FocusHeroLayout.rowsBottom(rowSpacing: FocusHeroLayout.rowSpacing)
        return ScrollView(.vertical) {
            FocusHeroRowStack(rows: rows, model: model, rowContent: rowContent)
                .padding(.top, bottom - model.scrollOrigin(in: rows))
                .padding(.bottom, FocusHeroLayout.screenHeight - bottom)
                .background(FocusHeroScrollPosition(model: model, rows: rows))
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .accessibilityIdentifier("showcase-rows")
        .accessibilityLabel(rows.allSatisfy(\.isPlaceholder) ? Text("Loading") : Text(verbatim: ""))
    }
}

/// Only the destination changes in SwiftUI; UIScrollView owns intermediate frames.
private struct FocusHeroScrollPosition: View {
    let model: FocusHeroModel
    let rows: [FocusHeroRow]

    var body: some View {
        let spacing = FocusHeroLayout.rowSpacing
        let index = model.activeIndex(in: rows)
        FocusHeroNativeScrollPosition(
            rowID: model.resolvedActiveRowID(in: rows),
            y: model.top(ofRowAt: index, in: rows, rowSpacing: spacing)
                + model.activeHeight(in: rows) - model.scrollOrigin(in: rows),
            motion: model.motion,
            height: model.activeHeight(in: rows),
            heightStops: model.heightStops(in: rows),
            rowOffsets: model.tuckOffsets(in: rows)
        )
    }
}

struct FocusHeroHeightStop: Equatable {
    let offset: CGFloat
    let height: CGFloat

    static func height(at offset: CGFloat, in stops: [Self]) -> CGFloat? {
        guard let first = stops.first, let last = stops.last else { return nil }
        if offset <= first.offset { return first.height }
        for (lower, upper) in zip(stops, stops.dropFirst()) where offset <= upper.offset {
            let progress = (offset - lower.offset) / (upper.offset - lower.offset)
            let eased = progress * progress * (3 - 2 * progress)
            return lower.height + (upper.height - lower.height) * eased
        }
        return last.height
    }
}

/// Compositor targets and stable native owners; no per-frame SwiftUI publication.
@MainActor
final class FocusHeroRowMotion {
    var height: CGFloat?
    var heightStops: [FocusHeroHeightStop] = []
    weak var column: UIView?
    weak var mask: UIView?
    var rowOffsets: [String: CGFloat] = [:]
    private var rowSurfaces: [String: RowSurface] = [:]
    private static let heightAnimationKey = "plozz.home.viewport-height"

    @MainActor private struct RowSurface {
        weak var view: UIView?
        let motion = FocusHeroTransformMotion()
    }

    func bindRow(_ id: String, view: UIView) {
        rowSurfaces[id]?.motion.stop()
        let surface = RowSurface(view: view)
        rowSurfaces[id] = surface
        surface.motion.move(view, to: rowOffsets[id] ?? 0, animated: false)
    }

    func unbindRow(_ id: String, view: UIView) {
        guard rowSurfaces[id]?.view === view else { return }
        rowSurfaces.removeValue(forKey: id)?.motion.stop()
    }

    func applyTargets(animated: Bool = false) {
        for (id, surface) in rowSurfaces {
            if let view = surface.view, let offset = rowOffsets[id] {
                surface.motion.move(view, to: offset, animated: animated)
            }
        }
        guard !animated, let height else { return }
        let bottom = FocusHeroLayout.rowsBottom(rowSpacing: FocusHeroLayout.rowSpacing)
        if let column {
            column.layer.removeAnimation(forKey: Self.heightAnimationKey)
            column.transform = CGAffineTransform(
                translationX: 0,
                y: max(FocusHeroLayout.lowestSlotTop, bottom - height) - FocusHeroLayout.lowestSlotTop
            )
        }
        if let mask {
            mask.layer.removeAnimation(forKey: Self.heightAnimationKey)
            mask.transform = CGAffineTransform(
                translationX: 0,
                y: max(0, bottom - height - FocusHeroLayout.activeTitleLift - 6 - FocusHeroLayout.fadeBand)
            )
        }
    }

    func followViewport(from departure: CGFloat, to target: CGFloat, velocity: CGFloat) {
        guard !heightStops.isEmpty else { return }
        let timing = FocusHeroLayout.rowSpring
        let duration = timing.settlingDuration
        // Sample once per retarget; Core Animation plays the trajectory without
        // publishing per-frame scroll geometry back through SwiftUI.
        let count = max(1, Int(ceil(duration * 120)))
        let bottom = FocusHeroLayout.rowsBottom(rowSpacing: FocusHeroLayout.rowSpacing)
        let heights = (0...count).map { index in
            let offset = index == count ? target : departure + timing.value(
                target: target - departure, initialVelocity: velocity,
                time: duration * Double(index) / Double(count)
            )
            return FocusHeroHeightStop.height(at: offset, in: heightStops)!
        }
        func animate(_ view: UIView?, values: [CGFloat]) {
            guard let view, let first = values.first, let last = values.last else { return }
            let current = view.layer.presentation()?.affineTransform().ty ?? view.transform.ty
            view.layer.removeAnimation(forKey: Self.heightAnimationKey)
            UIView.performWithoutAnimation {
                view.transform = CGAffineTransform(translationX: 0, y: last)
            }
            guard values.contains(where: { abs($0 - current) > 0.01 }) else { return }
            let correction = current - first
            let animation = CAKeyframeAnimation(keyPath: "transform.translation.y")
            animation.values = values.enumerated().map { index, value in
                let elapsed = duration * Double(index) / Double(count)
                return index == count ? last : value + correction
                    - timing.value(target: correction, initialVelocity: 0, time: elapsed)
            }
            animation.duration = duration
            animation.calculationMode = .linear
            view.layer.add(animation, forKey: Self.heightAnimationKey)
        }
        animate(column, values: heights.map {
            max(FocusHeroLayout.lowestSlotTop, bottom - $0) - FocusHeroLayout.lowestSlotTop
        })
        animate(mask, values: heights.map {
            max(0, bottom - $0 - FocusHeroLayout.activeTitleLift - 6 - FocusHeroLayout.fadeBand)
        })
    }

    func stop() {
        column?.layer.removeAnimation(forKey: Self.heightAnimationKey)
        mask?.layer.removeAnimation(forKey: Self.heightAnimationKey)
        for surface in rowSurfaces.values { surface.motion.stop() }
    }
}

/// Concealment carries its own velocity; unchanged row targets keep moving.
@MainActor
private final class FocusHeroTransformMotion {
    private weak var view: UIView?
    private var animator: UIViewPropertyAnimator?
    private var departure: CGFloat = 0
    private var target: CGFloat?
    private var velocity: CGFloat = 0

    func move(_ view: UIView, to target: CGFloat, animated: Bool) {
        guard self.view !== view || self.target != target || (!animated && animator != nil) else { return }
        let timing = FocusHeroLayout.rowSpring
        let position = view.layer.presentation()?.affineTransform().ty ?? view.transform.ty
        let carriedVelocity: CGFloat
        if self.view === view, let animator, animator.isRunning, let oldTarget = self.target {
            carriedVelocity = timing.velocity(
                target: oldTarget - departure, initialVelocity: velocity,
                time: animator.duration * Double(animator.fractionComplete)
            )
        } else {
            carriedVelocity = 0
        }
        stop()
        self.view = view
        self.target = target
        guard animated && !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation { view.transform = CGAffineTransform(translationX: 0, y: target) }
            return
        }
        departure = position
        velocity = carriedVelocity
        UIView.performWithoutAnimation { view.transform = CGAffineTransform(translationX: 0, y: position) }
        let distance = target - position
        let relativeVelocity = distance == 0 ? 0 : carriedVelocity / distance
        let animator = UIViewPropertyAnimator(
            duration: timing.settlingDuration,
            timingParameters: UISpringTimingParameters(
                mass: timing.mass, stiffness: timing.stiffness, damping: timing.damping,
                initialVelocity: CGVector(dx: relativeVelocity, dy: relativeVelocity)
            )
        )
        animator.addAnimations { [weak view] in
            view?.transform = CGAffineTransform(translationX: 0, y: target)
        }
        self.animator = animator
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, self.animator === animator else { return }
            self.animator = nil
        }
        animator.startAnimation()
    }

    func stop() {
        animator?.stopAnimation(true)
        animator = nil
    }
}

struct FocusHeroNativeScrollPosition: UIViewRepresentable {
    let rowID: String?
    let y: CGFloat
    var motion: FocusHeroRowMotion? = nil
    var height: CGFloat? = nil
    var heightStops: [FocusHeroHeightStop] = []
    var rowOffsets: [String: CGFloat] = [:]

    func makeUIView(context: Context) -> PositionView {
        let view = PositionView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PositionView, context: Context) {
        let heightChanged = motion?.height != height || motion?.heightStops != heightStops
        view.rowMotion = motion
        motion?.height = height
        motion?.heightStops = heightStops
        motion?.rowOffsets = rowOffsets
        view.move(to: y, rowID: rowID, heightChanged: heightChanged)
    }

    static func dismantleUIView(_ view: PositionView, coordinator: ()) {
        view.stop()
    }

    final class PositionView: UIView {
        weak var rowMotion: FocusHeroRowMotion?
        private struct ScrollStep {
            let key: String
            let distance: CGFloat
        }
        private var scrollSteps: [ScrollStep] = []
        private var scrollSequence = 0
        private var compositorTarget: CGFloat = 0
        private weak var scroller: UIScrollView?
        private var wasScrollEnabled = true
        private var rowID: String?
        private var y: CGFloat = 0
        private var offsetObservation: NSKeyValueObservation?
        private var isStepping = false

        private var isMoving: Bool {
            scrollSteps.contains { scroller?.layer.animation(forKey: $0.key) != nil }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            bindScrollView()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            bindScrollView()
        }

        func move(to y: CGFloat, rowID: String?, heightChanged: Bool = false) {
            let changed = self.y != y || self.rowID != rowID
            let animated = self.rowID != nil && self.rowID != rowID
            self.rowID = rowID
            self.y = y
            bindScrollView()
            guard let scroller else { return }
            if changed || (heightChanged && isMoving) {
                moveWithCompositor(in: scroller, animated: animated)
            } else {
                rowMotion?.applyTargets(animated: isMoving)
            }
        }

        private func moveWithCompositor(in scroller: UIScrollView, animated: Bool) {
            let beganAt = CACurrentMediaTime()
            let timing = FocusHeroLayout.rowSpring
            scrollSteps.removeAll { scroller.layer.animation(forKey: $0.key) == nil }
            let shouldAnimate = (animated || !scrollSteps.isEmpty)
                && !UIAccessibility.isReduceMotionEnabled
            var departure = compositorTarget
            var velocity: CGFloat = 0
            for step in scrollSteps {
                guard let animation = scroller.layer.animation(forKey: step.key) else { continue }
                // Core Animation resolves zero beginTime at commit. A requested
                // wall-clock start would skip frames when focus/layout runs long.
                let elapsed = animation.beginTime == 0 ? 0
                    : max(0, scroller.layer.convertTime(beganAt, from: nil) - animation.beginTime)
                departure += timing.value(target: step.distance, initialVelocity: 0, time: elapsed) - step.distance
                velocity += timing.velocity(target: step.distance, initialVelocity: 0, time: elapsed)
            }
            isStepping = true
            if shouldAnimate {
                let distance = y - compositorTarget
                compositorTarget = y
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                scroller.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                if distance != 0 {
                    // The new target and its inverse additive offset cancel at
                    // t=0. Existing springs keep their position, clock and velocity.
                    scrollSequence += 1
                    let key = "plozz.home.scroll.\(scrollSequence)"
                    let animation = CASpringAnimation(keyPath: "bounds.origin.y")
                    animation.mass = timing.mass
                    animation.stiffness = timing.stiffness
                    animation.damping = timing.damping
                    animation.fromValue = -distance
                    animation.toValue = 0
                    animation.isAdditive = true
                    animation.duration = timing.settlingDuration
                    scroller.layer.add(animation, forKey: key)
                    scrollSteps.append(ScrollStep(key: key, distance: distance))
                }
                CATransaction.commit()
                rowMotion?.applyTargets(animated: true)
                rowMotion?.followViewport(from: departure, to: y, velocity: velocity)
            } else {
                for step in scrollSteps { scroller.layer.removeAnimation(forKey: step.key) }
                scrollSteps.removeAll()
                compositorTarget = y
                scroller.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                rowMotion?.applyTargets()
            }
            isStepping = false
        }

        func stop() {
            for step in scrollSteps { scroller?.layer.removeAnimation(forKey: step.key) }
            scrollSteps.removeAll()
            rowMotion?.stop()
            offsetObservation = nil
            scroller?.isScrollEnabled = wasScrollEnabled
            scroller = nil
        }

        /// The focus engine scrolls a focused card into view even with scrolling
        /// disabled. Entering the pinned row from the sidebar leaves the pinned
        /// row unchanged, so nothing else would put the rows back.
        private func holdOffset() {
            guard !isStepping, let scroller else { return }
            let target = CGPoint(x: 0, y: y)
            guard abs(scroller.contentOffset.y - target.y) > 0.5 || scroller.contentOffset.x != 0 else { return }
            isStepping = true
            scroller.setContentOffset(target, animated: false)
            isStepping = false
        }

        private func bindScrollView() {
            guard window != nil else {
                stop()
                return
            }
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    if scroller !== scrollView {
                        stop()
                        scroller = scrollView
                        wasScrollEnabled = scrollView.isScrollEnabled
                        // The row owns its exact resting destination, while UIKit
                        // owns scrolling. Do not disable the nested horizontal rails.
                        scrollView.isScrollEnabled = false
                        scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                        compositorTarget = y
                        offsetObservation = scrollView.observe(\.contentOffset) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.holdOffset() }
                        }
                        rowMotion?.applyTargets()
                    } else {
                        scrollView.isScrollEnabled = false
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

// MARK: - Backdrop

private struct FocusHeroBackdropLayer: View {
    let model: FocusHeroModel
    let navigationStyle: NavigationStyle
    let isFrontmost: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Two thirds of the screen, top right, at a backdrop's own shape: the
        // whole picture shows, uncropped, and melts into the page on the left
        // (under the title) and behind the rows at the bottom.
        let width = FocusHeroLayout.screenWidth * FocusHeroLayout.artWidthFraction
        let height = width / FocusHeroLayout.artAspectRatio
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
                transition: .crossfade,
                scrimStyle: .browse
            )
            .allowsHitTesting(false)
            .heroArtworkSource(
                id: subject.id,
                isActive: isFrontmost
            )
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
    let metadata: FocusHeroMetadata
    let enrich: FocusHeroMetadata.Enrich?
    let settings: HeroSettings
    let spoilerSettings: SpoilerSettings
    let navigationStyle: NavigationStyle
    @State private var schedules = HeroScheduleLines()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.plozzNavigationContentInset) private var navigationContentInset

    var body: some View {
        FocusHeroColumnMotion(content: column, model: model)
    }

    @ViewBuilder private var column: some View {
        let top = FocusHeroLayout.columnTop(for: navigationStyle)
        let reference = FocusHeroLayout.lowestSlotTop
        // A block of fixed height just above the pinned row, its content pinned
        // to the block's top: the logo holds one place from title to title, and a
        // longer description only reaches further down.
        // The footprint alone sets the block's size; the details are laid over
        // it, so no title can move where the logo sits.
        FocusHeroDetailsFootprint()
            .hidden()
            .overlay(alignment: .topLeading) {
                if let subject = model.details {
                    content(for: subject)
                        .id(subject.id)
                        .transition(.opacity)
                }
            }
            .transaction(value: model.details?.id) { transaction in
                if model.detailsSwapWithRow { transaction.animation = nil }
            }
        .frame(width: FocusHeroLayout.columnWidth, alignment: .topLeading)
        // Keep Home's proposal around the complete block; framing the footprint
        // before its overlay would move the details into its unused space.
        .frame(height: FocusHeroLayout.detailsFootprintHeight, alignment: .bottomLeading)
        .frame(height: max(0, reference - FocusHeroLayout.columnGap - top), alignment: .bottomLeading)
        .padding(.top, top)
        // The TV's safe area and the rail's inset, exactly as the classic hero.
        .padding(.leading, PlozzTheme.Metrics.heroLeadingPadding + navigationContentInset)
        .allowsHitTesting(false)
        .task(id: model.subject?.item.map(FocusHeroMetadata.Key.init)) {
            guard let enrich, let item = model.subject?.item else { return }
            await metadata.load(item, using: enrich)
        }
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
            itemColumn(metadata.item(for: item))
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
        // Details show once, complete: a row's own record is sparser than what
        // replaces it, so showing it first would change the text under the viewer.
        let detailed = enrich == nil || metadata.hasDetails(for: item)
        return VStack(alignment: .leading, spacing: 12) {
            HeroLogoArtwork(
                references: item.artworkReferences(for: .logo),
                asyncFallbackURL: HomeHeroArtwork.logoFallback(for: item),
                displayedArtworkID: model.details?.id,
                maxWidth: FocusHeroLayout.logoBox.width,
                maxHeight: FocusHeroLayout.logoBox.height,
                constrainsToBounds: true,
                presentationPolicy: FocusHeroLayout.logoPresentationPolicy
            ) {
                title(for: item, hideText: hideText)
                    .font(.system(size: 64, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .multilineTextAlignment(.leading)
            }
            .accessibilityIdentifier("showcase-title-logo")
            // Every logo and title sits on the same line, whatever its shape.
            .frame(height: FocusHeroLayout.logoBox.height, alignment: .bottomLeading)
            // Above the logo, as on the classic hero, in the free space over the
            // block: it takes no room, so nothing below it moves.
            .overlay(alignment: .topLeading) {
                if let scheduleLine = schedules.line(for: item) {
                    HeroScheduleBadge(text: scheduleLine)
                        .accessibilityIdentifier("showcase-schedule")
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 16)
                        .frame(height: 0, alignment: .bottomLeading)
                }
            }
            .padding(.bottom, 6)

            if detailed {
                HeroMetadataLine(item: item)
                    .modifier(HeroTextLegibilityShadow(colorScheme: colorScheme))

                let ratings = ratingsRow(for: item)
                let showsRatings = ratings.map { !$0.ratings.isEmpty || $0.age != nil } ?? false
                if !hideText, let description = item.tagline ?? item.overview {
                    // The ratings row takes the room of two description lines.
                    Text(description.overviewPlainText)
                        .accessibilityIdentifier("showcase-description")
                        .font(.system(size: 22))
                        .foregroundStyle(.primary)
                        .lineSpacing(2)
                        .lineLimit(showsRatings ? 1 : 3)
                        .frame(maxWidth: 820, alignment: .topLeading)
                        .modifier(HeroTextLegibilityShadow(colorScheme: colorScheme))
                }

                if showsRatings, let ratings {
                    RatingsBadgeRow(ratings: ratings.ratings, familyGuidanceAge: ratings.age)
                }
            }
        }
    }

    /// The ratings the header shows for a title, or `nil` when ratings are off.
    private func ratingsRow(for item: MediaItem) -> (ratings: [ExternalRating], age: Double?)? {
        guard settings.shouldShowRatings(for: item, spoilerSettings: spoilerSettings) else { return nil }
        let presentation = HeroPresentation(item: item, artworkStyle: .landscape, surface: .home)
        return (
            settings.ratingPreferences.headerRatings(
                from: item.ratings, isAnime: presentation.isAnime, hidesRatings: false
            ),
            settings.ratingPreferences.headerFamilyGuidanceAge(
                from: presentation.familyGuidanceAge, hidesRatings: false
            )
        )
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

struct FocusHeroColumnMotion<Content: View>: View {
    let content: Content
    let model: FocusHeroModel

    var body: some View {
        FocusHeroMotionSurface(content: content, motion: model.motion, kind: .column)
            .accessibilityElement(children: .contain)
    }
}

private struct FocusHeroMotionSurface<Content: View>: UIViewControllerRepresentable {
    enum Kind: Equatable { case column, mask, row(String) }
    let content: Content
    let motion: FocusHeroRowMotion
    let kind: Kind

    func makeUIViewController(context: Context) -> Controller {
        Controller(content: hostedContent(environment: context.environment), motion: motion, kind: kind)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.host.rootView = hostedContent(environment: context.environment)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.unbind()
    }

    private func hostedContent(environment source: EnvironmentValues) -> AnyView {
        // Preserve public presentation/actions, not another hosting tree's
        // internal accessibility environment, which hides this tree's children.
        AnyView(content.transformEnvironment(\.self) { target in
            target.colorScheme = source.colorScheme
            target.locale = source.locale
            target.layoutDirection = source.layoutDirection
            target.dynamicTypeSize = source.dynamicTypeSize
            target.displayScale = source.displayScale
            target.isEnabled = source.isEnabled
            target.redactionReasons = source.redactionReasons
            target.scenePhase = source.scenePhase
            target.themePalette = source.themePalette
            target.plozzMetrics = source.plozzMetrics
            target.plozzCardStyle = source.plozzCardStyle
            target.plozzCardFocusStyle = source.plozzCardFocusStyle
            target.plozzCardCaptionSettings = source.plozzCardCaptionSettings
            target.plozzCardCaptionView = source.plozzCardCaptionView
            target.plozzCardCaptionsHidden = source.plozzCardCaptionsHidden
            target.plozzWatchStatusIndicator = source.plozzWatchStatusIndicator
            target.plozzSeerConnected = source.plozzSeerConnected
            target.plozzReduceTransparency = source.plozzReduceTransparency
            target.plozzNavigationStyle = source.plozzNavigationStyle
            target.plozzNavigationContentInset = source.plozzNavigationContentInset
            target.plozzPinnedSidebarActive = source.plozzPinnedSidebarActive
            target.plozzPinnedSidebarInteraction = source.plozzPinnedSidebarInteraction
            target.plozzRowTitleTightening = source.plozzRowTitleTightening
            target.plozzRowTitleOffset = source.plozzRowTitleOffset
            target.mediaItemActionHandler = source.mediaItemActionHandler
            target.mediaItemActionContext = source.mediaItemActionContext
            target.mediaItemNavigator = source.mediaItemNavigator
        })
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        let size = CGSize(width: proposal.width ?? FocusHeroLayout.screenWidth,
                          height: proposal.height ?? FocusHeroLayout.screenHeight)
        return kind == .mask ? size : uiViewController.host.sizeThatFits(in: size)
    }

    final class Controller: UIViewController {
        let host: UIHostingController<AnyView>
        private let motion: FocusHeroRowMotion
        private let kind: Kind
        private let maskView = UIView()
        private let fade = CAGradientLayer()
        private let solid = CALayer()

        init(content: AnyView, motion: FocusHeroRowMotion, kind: Kind) {
            host = UIHostingController(rootView: content)
            host.safeAreaRegions = []
            self.motion = motion
            self.kind = kind
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            host.view.backgroundColor = .clear
            addChild(host)
            view.addSubview(host.view)
            host.didMove(toParent: self)
            switch kind {
            case .column:
                motion.column = host.view
            case .row(let id):
                motion.bindRow(id, view: host.view)
                return
            case .mask:
                fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
                fade.startPoint = CGPoint(x: 0.5, y: 0)
                fade.endPoint = CGPoint(x: 0.5, y: 1)
                solid.backgroundColor = UIColor.black.cgColor
                maskView.layer.addSublayer(fade)
                maskView.layer.addSublayer(solid)
                host.view.layer.mask = maskView.layer
                motion.mask = maskView
            }
            UIView.performWithoutAnimation { motion.applyTargets() }
        }

        func unbind() {
            if case .row(let id) = kind {
                motion.unbindRow(id, view: host.view)
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            host.view.bounds = CGRect(origin: .zero, size: view.bounds.size)
            host.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            guard kind == .mask else { return }
            let overhang = FocusHeroLayout.maskHorizontalOverhang
            let size = CGSize(width: view.bounds.width + overhang * 2,
                              height: FocusHeroLayout.screenHeight + FocusHeroLayout.fadeBand)
            guard maskView.bounds.size != size else { return }
            UIView.performWithoutAnimation {
                maskView.bounds = CGRect(origin: .zero, size: size)
                maskView.center = CGPoint(x: view.bounds.midX, y: size.height / 2)
                fade.frame = CGRect(x: 0, y: 0, width: size.width, height: FocusHeroLayout.fadeBand)
                solid.frame = CGRect(x: 0, y: FocusHeroLayout.fadeBand,
                                     width: size.width, height: FocusHeroLayout.screenHeight)
            }
        }
    }
}

#endif
