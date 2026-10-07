#if os(tvOS)
import XCTest
import UIKit
import Observation
import CoreModels
import CoreUI
@testable import FeatureHome

/// Locks the Immersive Home's pin and hero rules: which row is pinned, which
/// title the hero stands in with before anything is focused, and how the hero's
/// backdrop steers off the picture the focused card already shows.
@MainActor
final class FocusHeroModelTests: XCTestCase {
    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, title: id, kind: .movie)
    }

    private func row(_ id: String, _ items: [String]) -> FocusHeroRow {
        FocusHeroRow(id: id, itemIDs: items, leadItem: items.first.map(item), items: items.map(item))
    }

    func testTheFirstRowStandsInUntilSomethingIsFocused() {
        let model = FocusHeroModel()
        let watchlist = row("watchlist", ["terror", "dune"])
        model.seed(from: [watchlist])
        XCTAssertEqual(model.subject?.item?.id, "terror")

        // Live Continue Watching arrives above the cached rows.
        let continueWatching = row("continue", ["tbate", "arcane"])
        model.seed(from: [continueWatching, watchlist])
        XCTAssertEqual(model.subject?.item?.id, "tbate", "Nothing focused yet, so the hero follows the new first row")
    }

    func testEarlierLoadingRowKeepsTheInitialAnchorUntilTheViewerNavigates() {
        let model = FocusHeroModel()
        var resume = row("continue", [])
        resume.isPlaceholder = true
        var watchlist = row("watchlist", [])
        watchlist.isPlaceholder = true
        let latest = row("latest", ["first", "second"])
        let loading = [resume, watchlist, latest]
        model.seed(from: loading)
        XCTAssertEqual(model.resolvedActiveRowID(in: loading), resume.id)
        XCTAssertNil(model.subject, "A ready lower row must not choose the starting title or scroll position.")

        let resumeReady = [row("continue", ["resume"]), watchlist, latest]
        model.seed(from: resumeReady)
        XCTAssertEqual(model.resolvedActiveRowID(in: resumeReady), resume.id)
        XCTAssertEqual(model.subject?.item?.id, "resume")
    }

    func testManualNavigationToReadyRowSurvivesAnEarlierRowFinishing() {
        let model = FocusHeroModel()
        var resume = row("continue", [])
        resume.isPlaceholder = true
        let latest = row("latest", ["first", "second"])
        let loading = [resume, latest]
        model.seed(from: loading)
        model.activate(latest, in: loading)
        model.show(.item(item("second")), in: latest)
        let settled = [row("continue", ["resume"]), latest]
        model.seed(from: settled)
        XCTAssertEqual(model.resolvedActiveRowID(in: settled), latest.id)
        XCTAssertEqual(model.subject?.item?.id, "second")
    }

    func testAFocusedRowKeepsThePinWhenARowArrivesAboveIt() {
        let model = FocusHeroModel()
        let watchlist = row("watchlist", ["terror", "dune"])
        let rows = [watchlist]
        model.seed(from: rows)
        // Focus lands on the first row: already the stand-in, but it must be recorded.
        model.activate(watchlist, in: rows)
        model.show(.item(item("dune")), in: watchlist)

        let continueWatching = row("continue", ["tbate"])
        let grown = [continueWatching, watchlist]
        model.seed(from: grown)
        XCTAssertEqual(model.resolvedActiveRowID(in: grown), "watchlist")
        XCTAssertEqual(model.subject?.item?.id, "dune", "The focused title stays in the hero")
    }

    func testRowTopsHeightAndConcealmentComeFromCurrentRowsOnly() {
        let model = FocusHeroModel()
        let notice = row("notice", [])
        let continueWatching = row("continue", ["tbate"])
        let watchlist = row("watchlist", ["terror"])
        model.record(height: 900, for: notice.id)
        model.record(height: 406, for: continueWatching.id)
        model.record(height: 540, for: watchlist.id)

        let rows = [continueWatching, watchlist]
        XCTAssertEqual(model.top(ofRowAt: 1, in: rows, rowSpacing: 28), 434)
        XCTAssertEqual(model.activeHeight(in: rows), 406)
        XCTAssertEqual(model.tuckOffsets(in: rows), ["continue": 0, "watchlist": 0])
        model.activate(watchlist, in: rows)
        XCTAssertEqual(model.activeHeight(in: rows), 540)
        XCTAssertEqual(model.tuckOffsets(in: rows), ["continue": -110, "watchlist": 0])
        model.activate(continueWatching, in: rows)
        XCTAssertEqual(model.tuckOffsets(in: rows), ["continue": 0, "watchlist": 0])
    }

    func testSubPointMeasurementNoiseIsIgnored() {
        let model = FocusHeroModel()
        model.record(height: 540, for: "watchlist")
        model.record(height: 540.3, for: "watchlist")
        XCTAssertEqual(model.rowHeights["watchlist"], 540)
    }

    func testNativeMotionTargetsDoNotInvalidateHeroContents() async {
        let model = FocusHeroModel()
        let rows = [row("continue", ["one"]), row("discover", ["two"])]
        model.record(height: 340, for: rows[0].id)
        model.record(height: 540, for: rows[1].id)
        model.activate(rows[1], in: rows)
        let invalidation = expectation(description: "Animation frames must not rebuild the hero's contents")
        invalidation.isInverted = true
        withObservationTracking {
            _ = model.activeHeight(in: rows)
            _ = model.details
        } onChange: {
            invalidation.fulfill()
        }
        for frame in 1...60 {
            model.motion.height = 340 + 200 * CGFloat(frame) / 60
            model.motion.applyTargets()
        }
        XCTAssertEqual(model.motion.height, 540)
        await fulfillment(of: [invalidation], timeout: 0.05)
    }

    func testInitialBindingAndLateMeasurementsRefreshDrawingGeometryWithoutScrolling() {
        let motion = FocusHeroRowMotion()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let controller = UIViewController()
        window.rootViewController = controller
        let viewport = UIScrollView(frame: window.bounds)
        viewport.contentSize = CGSize(width: 1920, height: 3000)
        let position = FocusHeroNativeScrollPosition.PositionView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        let mask = UIView()
        motion.mask = mask
        motion.height = 340
        position.rowMotion = motion
        controller.view.addSubview(viewport)
        viewport.addSubview(position)
        window.isHidden = false
        defer { position.stop(); window.isHidden = true }
        position.move(to: 0, rowID: "continue")
        let maskBottom = FocusHeroLayout.rowsBottom(rowSpacing: FocusHeroLayout.rowSpacing)
            - FocusHeroLayout.activeTitleLift - 6 - FocusHeroLayout.fadeBand
        XCTAssertEqual(mask.transform.ty, maskBottom - 340)
        motion.height = 540
        position.move(to: 0, rowID: "continue")
        XCTAssertEqual(viewport.contentOffset.y, 0)
        XCTAssertEqual(mask.transform.ty, maskBottom - 540,
                       "The first row's height can change while its native scroll offset remains zero.")
    }

    func testNativeSpringRejectsCompetingFocusScrollBeforeItCanBePresented() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let controller = UIViewController()
        window.rootViewController = controller
        let viewport = UIScrollView(frame: window.bounds)
        viewport.contentSize = CGSize(width: 1920, height: 3000)
        let position = FocusHeroNativeScrollPosition.PositionView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        controller.view.addSubview(viewport)
        viewport.addSubview(position)
        window.isHidden = false
        defer { position.stop(); window.isHidden = true }
        position.move(to: 340, rowID: "continue")
        position.move(to: 840, rowID: "posters")
        let nativePosition = viewport.contentOffset.y
        XCTAssertEqual(nativePosition, 840, "Only the compositor interpolates intermediate frames.")
        viewport.setContentOffset(CGPoint(x: 20, y: 600), animated: false)
        XCTAssertEqual(viewport.contentOffset.x, 0)
        XCTAssertEqual(viewport.contentOffset.y, nativePosition, accuracy: 0.5,
                       "UIKit's focus reveal must not replace the owned animation's destination.")
        settle(viewport, at: 840)
    }

    func testScrollOriginKeepsTheFirstRowAtZeroWithoutMovingRowAnchors() {
        let model = FocusHeroModel()
        let rows = [row("continue", ["one"]), row("recent", ["two"])]
        XCTAssertEqual(model.scrollOrigin(in: rows), 0)
        model.record(height: 340, for: rows[0].id)
        model.record(height: 540, for: rows[1].id)
        let spacing = FocusHeroLayout.rowSpacing
        let bottom = FocusHeroLayout.rowsBottom(rowSpacing: spacing)
        let origin = model.scrollOrigin(in: rows)
        XCTAssertEqual(origin, 340)
        XCTAssertEqual(model.activeHeight(in: rows) - origin, 0)
        for index in rows.indices {
            model.activate(rows[index], in: rows)
            let rowTop = model.top(ofRowAt: index, in: rows, rowSpacing: spacing)
            let destination = rowTop + model.activeHeight(in: rows) - origin
            XCTAssertEqual(bottom - origin + rowTop - destination, bottom - model.activeHeight(in: rows))
        }
        XCTAssertEqual(model.scrollOrigin(in: Array(rows.reversed())), 540)
        XCTAssertEqual(model.scrollOrigin(in: []), 0)
        model.record(height: bottom + 100, for: rows[0].id)
        XCTAssertEqual(model.scrollOrigin(in: rows), bottom, "The initial spacer cannot have negative height.")
    }

    func testNativeScrollOwnsRowMovementWithoutRestartingAnUnchangedDestination() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let controller = UIViewController()
        window.rootViewController = controller
        let viewport = ScrollRecorder(frame: window.bounds)
        viewport.contentSize = CGSize(width: 1920, height: 3000)
        controller.view.addSubview(viewport)
        let horizontal = UIScrollView()
        viewport.addSubview(horizontal)
        let position = FocusHeroNativeScrollPosition.PositionView()
        viewport.addSubview(position)
        window.isHidden = false
        defer {
            position.stop()
            window.isHidden = true
        }

        position.move(to: 340, rowID: "continue")
        XCTAssertEqual(viewport.contentOffset.y, 340)
        XCTAssertEqual(viewport.requests.last?.animated, false)
        XCTAssertFalse(viewport.isScrollEnabled)
        XCTAssertTrue(horizontal.isScrollEnabled, "Pinning must not disable native horizontal navigation.")

        position.move(to: 840, rowID: "posters")
        let requestCount = viewport.requests.count
        position.move(to: 840, rowID: "posters")
        XCTAssertEqual(viewport.requests.count, requestCount, "An unchanged destination must not restart the move.")
        settle(viewport, at: 840)

        position.move(to: 340, rowID: "continue")
        settle(viewport, at: 340)
        XCTAssertEqual(viewport.contentOffset.y, 340, "Reversals retarget the same native viewport.")
        position.move(to: 356, rowID: "continue")
        XCTAssertEqual(viewport.contentOffset.y, 356)
        XCTAssertEqual(viewport.requests.last?.animated, false, "New measurements preserve the settled anchor.")
        position.stop()
        XCTAssertTrue(viewport.isScrollEnabled, "Teardown restores the viewport's original policy.")
    }

    private func settle(_ viewport: UIScrollView, at y: CGFloat) {
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(viewport.contentOffset.y, y)
    }

    private final class ScrollRecorder: UIScrollView {
        var requests: [(point: CGPoint, animated: Bool)] = []
        override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            requests.append((contentOffset, animated))
            super.setContentOffset(contentOffset, animated: animated)
        }
    }

    func testFocusedSubjectTakesFreshRowStateWithoutAnotherFocusMove() {
        let model = FocusHeroModel()
        var episode = MediaItem(id: "episode", title: "Episode", kind: .episode)
        episode.isPlayed = true
        let initial = FocusHeroRow(id: "row", itemIDs: [episode.stablePresentationID], leadItem: episode, items: [episode])
        model.activate(initial, in: [initial])
        model.show(.item(episode), in: initial)
        episode.isPlayed = false
        let fresh = FocusHeroRow(id: "row", itemIDs: [episode.stablePresentationID], leadItem: episode, items: [episode])
        model.seed(from: [fresh])
        XCTAssertEqual(model.subject?.item?.isPlayed, false)
        XCTAssertEqual(model.activeRowID, "row")
    }

    func testSameProviderIDOnDifferentAccountsDoesNotKeepRemovedSubject() {
        let model = FocusHeroModel()
        var first = item("shared-id")
        first.sourceAccountID = "first"
        var second = first
        second.sourceAccountID = "second"
        let initial = FocusHeroRow(id: "row", itemIDs: [first.stablePresentationID], leadItem: first, items: [first])
        model.activate(initial, in: [initial])
        model.show(.item(first), in: initial)
        let fresh = FocusHeroRow(id: "row", itemIDs: [second.stablePresentationID], leadItem: second, items: [second])
        model.seed(from: [fresh])
        XCTAssertEqual(model.subject?.item?.sourceAccountID, "second")
        XCTAssertNotEqual(FocusHeroSubject.item(first).id, FocusHeroSubject.item(second).id)
    }

    func testEveryTitleGetsTheSameFilledInDetails() async {
        let metadata = FocusHeroMetadata()
        let sparse = MediaItem(id: "arcane", title: "Arcane", kind: .series)
        XCTAssertEqual(metadata.item(for: sparse).genres, [], "A title shows as it is until its details load")
        await metadata.load(sparse) { items in
            items.map { item in
                var full = item
                full.genres = ["Animation"]
                full.officialRating = "TV-14"
                return full
            }
        }
        XCTAssertEqual(metadata.item(for: sparse).genres, ["Animation"])
        XCTAssertEqual(metadata.item(for: sparse).officialRating, "TV-14")
    }

    func testPrefetchingAnotherTitleDoesNotInvalidateTheVisibleMetadata() async {
        let metadata = FocusHeroMetadata()
        let focused = item("visible")
        let invalidation = expectation(description: "Background metadata must not rebuild the current title")
        invalidation.isInverted = true
        withObservationTracking {
            _ = metadata.item(for: focused)
            _ = metadata.hasDetails(for: focused)
        } onChange: {
            invalidation.fulfill()
        }
        await metadata.load(item("background")) { items in
            items.map { var full = $0; full.genres = ["Drama"]; return full }
        }
        XCTAssertFalse(metadata.hasDetails(for: focused))
        await fulfillment(of: [invalidation], timeout: 0.05)

        let arrival = expectation(description: "The visible title updates when its own metadata arrives")
        withObservationTracking {
            _ = metadata.item(for: focused)
        } onChange: {
            arrival.fulfill()
        }
        await metadata.load(focused) { items in
            items.map { var full = $0; full.genres = ["Animation"]; return full }
        }
        await fulfillment(of: [arrival], timeout: 0.2)
        XCTAssertEqual(metadata.item(for: focused).genres, ["Animation"])
    }

    func testAFocusThatMovesOnLoadsNothingAndCanLoadLater() async {
        let metadata = FocusHeroMetadata()
        let item = MediaItem(id: "dune", title: "Dune", kind: .movie)
        let passing = Task { @MainActor in
            await metadata.load(item) { items in
                items.map { var full = $0; full.genres = ["Drama"]; return full }
            }
        }
        passing.cancel()
        await passing.value
        XCTAssertNil(metadata.item(for: item).genres.first, "A card passed on the way isn't fetched")
        await metadata.load(item) { items in
            items.map { var full = $0; full.genres = ["Drama"]; return full }
        }
        XCTAssertEqual(metadata.item(for: item).genres, ["Drama"])
    }

    func testProviderFirstHeroSkipsThePictureTheFocusedCardShows() {
        let policy = ArtworkPresentationPolicy(area: .home, settings: .init(preference: .online))
        let main = ArtworkReference.remote(URL(string: "https://example.com/main.jpg")!)
        let second = ArtworkReference.remote(URL(string: "https://example.com/second.jpg")!)
        let item = MediaItem(
            id: "arcane",
            title: "Arcane",
            kind: .series,
            artworkSelections: [ArtworkSelection(placement: .homeHero, references: [main, second])]
        )
        XCTAssertEqual(HomeHeroArtwork.backdropReferences(for: item, avoiding: [main], policy: policy).prefix(2), [second, main])
        XCTAssertEqual(
            HomeHeroArtwork.backdropReferences(for: item, avoiding: [], policy: policy).prefix(2), [main, second],
            "A poster row's card shows no backdrop, so the hero keeps its first choice"
        )

        let single = MediaItem(
            id: "solo",
            title: "Solo",
            kind: .series,
            artworkSelections: [ArtworkSelection(placement: .homeHero, references: [main])]
        )
        XCTAssertEqual(
            HomeHeroArtwork.backdropReferences(for: single, avoiding: [main], policy: policy).first, main,
            "With only one picture the hero keeps it"
        )
    }

    func testLibraryFirstHeroDoesNotAvoidTheServerArtworkOnTheFocusedCard() throws {
        let selected = try XCTUnwrap(URL(string: "https://example.test/selected.jpg"))
        let other = ArtworkReference.remote(try XCTUnwrap(URL(string: "https://example.test/other.jpg")))
        let item = MediaItem(
            id: "series", title: "Series", kind: .series, heroBackdropURL: selected,
            artworkSelections: [.init(placement: .homeHero, references: [.remote(selected), other])]
        )
        let library = ArtworkPresentationPolicy(area: .home, settings: .init(preference: .library))
        XCTAssertEqual(
            HomeHeroArtwork.backdropReferences(for: item, avoiding: [.remote(selected)], policy: library).first,
            .remote(selected)
        )
        XCTAssertEqual(
            HomeHeroArtwork.backdropReferences(for: item, avoiding: [.remote(selected)]).first,
            .remote(selected)
        )
        let online = ArtworkPresentationPolicy(area: .home, settings: .init(preference: .online))
        XCTAssertEqual(
            HomeHeroArtwork.backdropReferences(for: item, avoiding: [.remote(selected)], policy: online).first,
            other
        )
    }
}
#endif
