import XCTest
@testable import CoreModels

final class HomeRecentlyAddedPolicyTests: XCTestCase {
    func testMoviesUseCurrentCompletionAndKeepRewatches() {
        let unseen = MediaItem(id: "new", title: "New", kind: .movie)
        let completed = MediaItem(id: "done", title: "Done", kind: .movie, isPlayed: true)
        let rewatch = MediaItem(
            id: "again", title: "Again", kind: .movie, resumePosition: 30,
            isPlayed: false, hasBeenPlayed: true
        )
        XCTAssertEqual(HomeRecentlyAddedPolicy.items(
            [unseen, completed, rewatch], hideWatched: true
        ).map(\.id), ["new", "again"])
        XCTAssertEqual(HomeRecentlyAddedPolicy.items(
            [unseen, completed, rewatch], hideWatched: false
        ).map(\.id), ["new", "done", "again"])
        var siloRewatch = rewatch
        siloRewatch.isPlayed = true
        XCTAssertFalse(HomeRecentlyAddedPolicy.isWatched(siloRewatch))
    }

    func testContainersKeepUnfinishedUnknownAndEmptyShows() {
        for kind: MediaItemKind in [.series, .season] {
            let partial = MediaItem(
                id: "partial", title: "Partial", kind: kind, unwatchedEpisodeCount: 2,
                isPlayed: false, hasBeenPlayed: true
            )
            let complete = MediaItem(
                id: "complete", title: "Complete", kind: kind, unwatchedEpisodeCount: 0,
                isPlayed: false, hasBeenPlayed: true
            )
            let unknown = MediaItem(id: "unknown", title: "Unknown", kind: kind, hasBeenPlayed: true)
            let empty = MediaItem(id: "empty", title: "Empty", kind: kind, unwatchedEpisodeCount: 0)
            XCTAssertEqual(HomeRecentlyAddedPolicy.items(
                [partial, complete, unknown, empty], hideWatched: true
            ).map(\.id), ["partial", "unknown", "empty"])
            var newEpisodes = complete
            newEpisodes.unwatchedEpisodeCount = 1
            XCTAssertFalse(HomeRecentlyAddedPolicy.isWatched(newEpisodes))
        }
    }

    func testNewerCompletionWinsOverOlderSourceRewatch() {
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie, isPlayed: true)
        item.sources = [
            MediaSourceRef(
                accountID: "old", itemID: "movie", resumePosition: 300, isPlayed: true,
                lastPlayedAt: Date(timeIntervalSince1970: 100)
            ),
            MediaSourceRef(
                accountID: "new", itemID: "movie", isPlayed: true,
                lastPlayedAt: Date(timeIntervalSince1970: 200)
            )
        ]
        XCTAssertTrue(HomeRecentlyAddedPolicy.isWatched(item))
        item.sources.removeLast()
        XCTAssertFalse(HomeRecentlyAddedPolicy.isWatched(item))
    }

    func testAlternateCopyWithNewEpisodesKeepsMergedShow() {
        var item = MediaItem(
            id: "show", title: "Show", kind: .series,
            unwatchedEpisodeCount: 0, isPlayed: true
        )
        item.sources = [
            MediaSourceRef(accountID: "a", itemID: "show", unwatchedEpisodeCount: 0, isPlayed: true),
            MediaSourceRef(accountID: "b", itemID: "show", unwatchedEpisodeCount: 1)
        ]
        XCTAssertFalse(HomeRecentlyAddedPolicy.isWatched(item))
    }

    func testFilteringPrecedesLimitAndRetainsInput() {
        let items = (0..<100).map {
            MediaItem(id: "\($0)", title: "Movie \($0)", kind: .movie, isPlayed: $0 < 60)
        }
        XCTAssertEqual(HomeRecentlyAddedPolicy.items(items, hideWatched: true).map(\.id),
                       (60..<80).map(String.init))
        XCTAssertEqual(items.count, 100)
        XCTAssertEqual(HomeRecentlyAddedPolicy.requestLimit(20, hideWatched: true), 100)
        XCTAssertEqual(HomeRecentlyAddedPolicy.requestLimit(20, hideWatched: false), 20)
        XCTAssertEqual(HomeRecentlyAddedPolicy.requestLimit(0, hideWatched: true), 0)
        XCTAssertTrue(HomeRecentlyAddedPolicy.items(items, hideWatched: true, limit: 0).isEmpty)
    }

    @MainActor
    func testPreferenceDefaultsMigrationAndProfileIsolation() throws {
        XCTAssertFalse(HomeLibraryVisibility.default.hideWatchedRecentlyAdded)
        let old = try JSONDecoder().decode(HomeLibraryVisibility.self, from: Data("{}".utf8))
        XCTAssertFalse(old.hideWatchedRecentlyAdded)
        let name = "recently-added-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HomeLibraryVisibilityStore(defaults: defaults)
        let model = HomeLibraryVisibilityModel(store: store)
        model.setHideWatchedRecentlyAdded(true)
        XCTAssertTrue(HomeLibraryVisibilityModel(store: store).visibility.hideWatchedRecentlyAdded)
        XCTAssertFalse(HomeLibraryVisibilityStore(defaults: defaults, namespace: "other").load().hideWatchedRecentlyAdded)
        model.setHideWatchedRecentlyAdded(false)
        XCTAssertFalse(store.load().hideWatchedRecentlyAdded)
    }
}
