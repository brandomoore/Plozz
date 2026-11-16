import XCTest
@testable import CoreModels

/// Dropping a show takes all of it off Continue Watching, Next Up and Upcoming,
/// on every server, until it is watched again.
@MainActor
final class DroppedShowsTests: XCTestCase {
    private func model(_ defaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!) -> DroppedShowsModel {
        DroppedShowsModel(store: DroppedShowsStore(defaults: defaults))
    }

    private func episode(
        _ id: String, series: String = "series", account: String = "jellyfin",
        tvdb: String? = "81189"
    ) -> MediaItem {
        var item = MediaItem(id: id, title: "Episode", kind: .episode, sourceAccountID: account)
        item.seriesID = series
        if let tvdb { item.providerIDs = ["SeriesTvdb": tvdb] }
        return item
    }

    func testDroppingAnEpisodeDropsEveryEpisodeOfTheShow() {
        let dropped = model()
        XCTAssertTrue(dropped.drop(episode("e1")))
        XCTAssertTrue(dropped.isDropped(episode("e2")))
        XCTAssertFalse(dropped.isDropped(episode("other", series: "another", tvdb: "12345")))
    }

    /// The same show on another server shares its external ids, not its own.
    func testADropFollowsTheShowToAnotherServer() {
        let dropped = model()
        dropped.drop(episode("e1"))
        XCTAssertTrue(dropped.isDropped(episode("plex-e1", series: "plex-series", account: "plex")))
    }

    /// A show with no external ids is still matched on its own server.
    func testAShowWithoutExternalIDsMatchesOnItsOwnServer() {
        let dropped = model()
        dropped.drop(episode("e1", tvdb: nil))
        XCTAssertTrue(dropped.isDropped(episode("e2", tvdb: nil)))
        XCTAssertFalse(dropped.isDropped(episode("e3", account: "other", tvdb: nil)))
    }

    /// A series card carries the show's ids as its own; they still match its
    /// episodes' series ids.
    func testDroppingTheSeriesMatchesItsEpisodes() {
        let dropped = model()
        var series = MediaItem(id: "series", title: "Show", kind: .series, sourceAccountID: "jellyfin")
        series.providerIDs = ["Tvdb": "81189"]
        XCTAssertTrue(dropped.drop(series))
        XCTAssertTrue(dropped.isDropped(episode("e1")))
        XCTAssertTrue(dropped.isDropped(episode("plex-e1", series: "plex-series", account: "plex")))
    }

    func testMoviesCannotBeDropped() {
        let dropped = model()
        XCTAssertFalse(dropped.drop(MediaItem(id: "m", title: "Film", kind: .movie, sourceAccountID: "a")))
        XCTAssertTrue(dropped.isEmpty)
    }

    func testUndropReturnsTheShow() {
        let dropped = model()
        dropped.drop(episode("e1"))
        XCTAssertTrue(dropped.undrop(episode("plex-e1", series: "plex-series", account: "plex")))
        XCTAssertFalse(dropped.isDropped(episode("e1")))
        XCTAssertFalse(dropped.undrop(episode("e1")), "Nothing left to take back")
    }

    /// Meeting the show again with more ids widens the existing drop rather than
    /// adding a second one.
    func testDroppingAgainFoldsInNewKeys() {
        let dropped = model()
        dropped.drop(episode("e1", tvdb: nil))
        XCTAssertTrue(dropped.drop(episode("e1")))
        XCTAssertEqual(dropped.shows.count, 1)
        XCTAssertTrue(dropped.isDropped(episode("plex-e1", series: "plex-series", account: "plex")))
        XCTAssertFalse(dropped.drop(episode("e1")), "Already dropped under every key")
    }

    func testDropsPersistPerProfile() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        DroppedShowsModel(store: DroppedShowsStore(defaults: defaults, namespace: "kid")).drop(episode("e1"))
        XCTAssertTrue(DroppedShowsModel(store: DroppedShowsStore(defaults: defaults, namespace: "kid"))
            .isDropped(episode("e1")))
        XCTAssertFalse(DroppedShowsModel(store: DroppedShowsStore(defaults: defaults, namespace: nil))
            .isDropped(episode("e1")))
    }

    func testChangesAreAnnounced() {
        let dropped = model()
        let announced = expectation(forNotification: .droppedShowsDidChange, object: dropped)
        dropped.drop(episode("e1"))
        wait(for: [announced], timeout: 1)
    }

    // MARK: - Menu

    private func actions(
        _ item: MediaItem, dropped: Bool?, context: MediaItemActionContext = .continueWatching
    ) -> [MediaItemAction] {
        MediaItemActionCatalog.actions(
            for: item, supportsWatchState: true, isShowDropped: dropped, context: context
        )
    }

    func testNextUpOffersDropShow() {
        XCTAssertEqual(actions(episode("e1"), dropped: false, context: .nextUp).last, .dropShow)
    }

    /// Away from Continue Watching and Next Up the show isn't being suggested, so
    /// there is nothing to drop it from; an episode keeps its ordinary removal.
    func testOtherRowsDoNotOfferDropShow() {
        var inProgress = episode("e1")
        inProgress.resumePosition = 600
        var season = MediaItem(id: "s1", title: "Season 1", kind: .season)
        season.seriesID = "series"
        let series = MediaItem(id: "series", title: "Show", kind: .series)
        for item in [inProgress, season, series] {
            XCTAssertFalse(actions(item, dropped: false, context: .none).contains(.dropShow), item.id)
        }
        XCTAssertEqual(actions(inProgress, dropped: false, context: .none).last, .removeFromContinueWatching)
    }

    /// A dropped show never reaches the rows it was dropped from, so it can be
    /// taken back wherever it appears.
    func testUndropIsOfferedOffTheRows() {
        let series = MediaItem(id: "series", title: "Show", kind: .series)
        XCTAssertTrue(actions(series, dropped: true, context: .none).contains(.undropShow))
        XCTAssertEqual(actions(episode("e1"), dropped: true, context: .none).last, .undropShow)
    }

    /// On an episode, Drop Show takes the place of removing it.
    func testAnEpisodeOffersDropShowInsteadOfRemoval() {
        var inProgress = episode("e1")
        inProgress.resumePosition = 600
        let offered = actions(inProgress, dropped: false)
        XCTAssertFalse(offered.contains(.removeFromContinueWatching))
        XCTAssertEqual(offered.last, .dropShow)
        XCTAssertEqual(actions(inProgress, dropped: true).last, .undropShow)
    }

    func testSeasonsAndSeriesOfferDropShow() {
        var season = MediaItem(id: "s1", title: "Season 1", kind: .season)
        season.seriesID = "series"
        XCTAssertTrue(actions(season, dropped: false).contains(.dropShow))
        XCTAssertTrue(actions(MediaItem(id: "series", title: "Show", kind: .series), dropped: true)
            .contains(.undropShow))
    }

    /// A film is not part of a show: it keeps removal, and nothing to drop.
    func testMoviesKeepRemoval() {
        let movie = MediaItem(id: "m", title: "Film", kind: .movie, resumePosition: 600)
        let offered = actions(movie, dropped: false)
        XCTAssertTrue(offered.contains(.removeFromContinueWatching))
        XCTAssertFalse(offered.contains(.dropShow))
    }

    func testWithoutDropSupportEpisodesKeepRemoval() {
        var inProgress = episode("e1")
        inProgress.resumePosition = 600
        let offered = actions(inProgress, dropped: nil)
        XCTAssertTrue(offered.contains(.removeFromContinueWatching))
        XCTAssertFalse(offered.contains(.dropShow))
    }

    /// An episode that does not know its show has nothing to drop.
    func testAnEpisodeWithoutItsSeriesCannotDrop() {
        let orphan = MediaItem(id: "e", title: "Episode", kind: .episode, resumePosition: 600)
        let offered = actions(orphan, dropped: false)
        XCTAssertFalse(offered.contains(.dropShow))
        XCTAssertTrue(offered.contains(.removeFromContinueWatching))
    }

    func testDropAndUndropAreVisibleOnTheShowsPage() {
        XCTAssertTrue(MediaItemAction.undropShow.isPrimaryDetailAction)
        XCTAssertTrue(MediaItemAction.dropShow.isPrimaryDetailAction)
        XCTAssertFalse(MediaItemAction.dropShow.isNavigation)
        XCTAssertFalse(MediaItemAction.dropShow.isDestructive, "A drop hides; nothing is deleted")
    }

    /// A Coming Soon show is not in any library, but it can still be dropped; a
    /// movie there has no show to drop.
    func testComingSoonOffersDropShowForAShowOnly() {
        var series = MediaItem(id: "s1", title: "Soon", kind: .series)
        series.providerIDs = ["Tvdb": "81189"]
        XCTAssertEqual(
            MediaItemActionCatalog.actions(
                for: series, supportsWatchState: false, isShowDropped: false, context: .upcoming),
            [.dropShow])
        XCTAssertEqual(
            MediaItemActionCatalog.actions(
                for: series, supportsWatchState: false, isShowDropped: true, context: .upcoming),
            [.undropShow])
        XCTAssertFalse(
            MediaItemActionCatalog.actions(
                for: MediaItem(id: "m", title: "Film", kind: .movie),
                supportsWatchState: false, isShowDropped: false, context: .upcoming
            ).contains(.dropShow))
    }
}
