import CoreModels
import FeatureHomeCore
import XCTest

@MainActor
final class DiscoverBrowseModelTests: XCTestCase {
    func testAvailableNowHidesAndDefersBothUpcomingFeeds() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DiscoverFiltersStore(defaults: defaults)
        store.save(.init(availableNow: true))
        let probe = Probe()
        let model = DiscoverBrowseModel(store: store, isCurrent: { true }) { feed, _ in
            probe.requests.append(feed)
            return DiscoverPage(items: [], nextPage: nil)
        }

        await model.load()
        await model.loadMore(.upcomingMovies)
        await model.loadMoreVisibleItems(.upcomingSeries)
        let playableFeeds: [DiscoverFeed] = [.trending, .popularMovies, .popularSeries]
        XCTAssertEqual(model.visibleRows.map(\.feed), playableFeeds)
        XCTAssertEqual(Set(probe.requests), Set(playableFeeds))
        XCTAssertEqual(probe.requests.count, 3)
        XCTAssertEqual(model.rows.first { $0.feed == .upcomingMovies }?.nextPage, 1)
        XCTAssertEqual(model.rows.first { $0.feed == .upcomingSeries }?.nextPage, 1)

        model.filters.availableNow = false
        model.filters.hideWatched = true
        await model.load()
        XCTAssertEqual(model.visibleRows.map(\.feed), DiscoverFeed.defaultOrder)
        XCTAssertEqual(Set(probe.requests), Set(DiscoverFeed.allCases))
        XCTAssertEqual(probe.requests.count, 5)
    }

    func testAvailableNowPreservesHiddenUpcomingPagesAndResumesWithoutReloading() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var pages: [Int] = []
        let model = DiscoverBrowseModel(store: .init(defaults: defaults), isCurrent: { true }) { _, page in
            pages.append(page)
            return DiscoverPage(items: [
                MediaItem(id: "page-\(page)", title: "Title", kind: .movie)
            ], nextPage: page < 3 ? page + 1 : nil)
        }
        await model.loadMore(.upcomingMovies)
        model.filters.availableNow = true
        await model.loadMoreVisibleItems(.upcomingMovies)
        XCTAssertFalse(model.visibleRows.contains { $0.feed == .upcomingMovies })
        let hidden = try XCTUnwrap(model.rows.first { $0.feed == .upcomingMovies })
        XCTAssertEqual(hidden.items.map(\.id), ["page-1"])
        XCTAssertEqual(hidden.nextPage, 2)
        XCTAssertEqual(pages, [1])

        model.filters.availableNow = false
        let restored = try XCTUnwrap(model.visibleRows.first { $0.feed == .upcomingMovies })
        XCTAssertEqual(restored.items.map(\.id), ["page-1"])
        await model.loadMoreVisibleItems(.upcomingMovies)
        XCTAssertEqual(pages, [1, 2])
    }

    func testAllFeedsLoadOnceAndOneFailureDoesNotHideSuccessfulRows() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = Probe()
        let model = DiscoverBrowseModel(store: .init(defaults: defaults), isCurrent: { true }) { feed, _ in
            probe.requests.append(feed)
            if feed == .upcomingMovies { throw AppError.serverUnreachable }
            return DiscoverPage(
                items: [MediaItem(id: feed.rawValue, title: feed.rawValue, kind: feed.kind ?? .movie)],
                nextPage: nil
            )
        }
        await model.load()
        XCTAssertEqual(Set(probe.requests), Set(DiscoverFeed.allCases))
        XCTAssertEqual(model.rows.filter { !$0.items.isEmpty }.count, 4)
        XCTAssertEqual(model.rows.first { $0.feed == .upcomingMovies }?.error, .service(.serverUnreachable))
        await model.load()
        XCTAssertEqual(probe.requests.count, 5)
        await model.loadMore(.upcomingMovies)
        XCTAssertEqual(probe.requests.count, 6)
    }

    func testChildGatePreventsRequestsAndLatePublication() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = Probe()
        probe.allowed = false
        let model = DiscoverBrowseModel(
            store: .init(defaults: defaults), isCurrent: { probe.allowed }
        ) { feed, _ in
            probe.requests.append(feed)
            probe.allowed = false
            return DiscoverPage(items: [MediaItem(id: "adult", title: "Adult", kind: .movie)], nextPage: nil)
        }
        await model.load()
        XCTAssertTrue(probe.requests.isEmpty)
        probe.allowed = true
        await model.loadMore(.trending)
        XCTAssertEqual(probe.requests, [.trending])
        XCTAssertTrue(model.rows.allSatisfy { $0.items.isEmpty && $0.error == nil })
    }

    func testDuplicatePagesStopAndCancellationIsRetryable() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = Probe()
        let model = DiscoverBrowseModel(store: .init(defaults: defaults), isCurrent: { true }) { feed, page in
            probe.requests.append(feed)
            if probe.requests.count == 1 { throw CancellationError() }
            let item = MediaItem(id: "same", title: "Same", kind: .movie)
            return DiscoverPage(items: [item, item], nextPage: page + 1)
        }
        await model.loadMore(.trending)
        XCTAssertNil(model.rows[0].error)
        XCTAssertEqual(model.rows[0].nextPage, 1)
        await model.loadMore(.trending)
        XCTAssertEqual(model.rows[0].items.count, 1)
        XCTAssertEqual(model.rows[0].nextPage, 2)
        await model.loadMore(.trending)
        XCTAssertEqual(model.rows[0].items.count, 1)
        XCTAssertNil(model.rows[0].nextPage)
    }

    func testFiltersPersistPerProfileAndPreserveConcurrentSyncedChoices() throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DiscoverFiltersStore(namespace: "one", defaults: defaults)
        let model = DiscoverBrowseModel(store: store, isCurrent: { true }) { _, _ in
            DiscoverPage(items: [], nextPage: nil)
        }
        store.save(.init(availableNow: true))
        model.filters.hideWatched = true
        XCTAssertEqual(store.load(), .init(availableNow: true, hideWatched: true))
        XCTAssertEqual(DiscoverFiltersStore(namespace: "two", defaults: defaults).load(), .init())
        store.save(.init())
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(model.filters, .init())
    }

    func testCancelledPageAdmissionPreservesPreviouslyLoadedRows() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = Probe()
        let model = DiscoverBrowseModel(store: .init(defaults: defaults), isCurrent: { true }) { feed, _ in
            probe.requests.append(feed)
            return DiscoverPage(
                items: [MediaItem(id: "retained", title: "Retained", kind: .movie)], nextPage: 2
            )
        }
        await model.loadMore(.trending)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.loadMore(.popularMovies)
        }
        await cancelled.value
        XCTAssertEqual(model.rows[0].items.map(\.id), ["retained"])
        XCTAssertEqual(model.rows[0].nextPage, 2)
        XCTAssertEqual(probe.requests, [.trending])
    }

    func testIndexRefreshRevalidatesLoadedTitlesWithoutLosingPagination() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = Probe()
        let model = DiscoverBrowseModel(
            store: .init(defaults: defaults), isCurrent: { probe.allowed },
            resolveLibrarySources: { items in
                items.map {
                    var item = $0
                    item.locallyValidatedPlayableSource = true
                    return item
                }
            }
        ) { feed, _ in
            probe.requests.append(feed)
            return DiscoverPage(items: [
                MediaItem(id: "external", title: "External", kind: .movie,
                          locallyValidatedPlayableSource: false)
            ], nextPage: 2)
        }
        await model.loadMore(.trending)
        XCTAssertFalse(model.rows[0].items[0].locallyValidatedPlayableSource)
        await model.refreshLibrarySources()
        XCTAssertTrue(model.rows[0].items[0].locallyValidatedPlayableSource)
        XCTAssertEqual(model.rows[0].nextPage, 2)
        XCTAssertEqual(probe.requests, [.trending])
        probe.allowed = false
        model.invalidate()
        await model.refreshLibrarySources()
        XCTAssertTrue(model.rows.allSatisfy { $0.items.isEmpty })
    }

    func testAutomaticPaginationStopsAfterAddingVisibleTitles() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var pages: [Int] = []
        let model = DiscoverBrowseModel(store: .init(defaults: defaults), isCurrent: { true }) { _, page in
            pages.append(page)
            return DiscoverPage(items: [
                MediaItem(id: "page-\(page)", title: "Title", kind: .movie)
            ], nextPage: page < 3 ? page + 1 : nil)
        }
        await model.loadMore(.trending)
        await model.loadMoreVisibleItems(.trending)
        XCTAssertEqual(pages, [1, 2])
        XCTAssertEqual(model.rows[0].items.count, 2)
        await model.loadMoreVisibleItems(.trending)
        await model.loadMoreVisibleItems(.trending)
        XCTAssertEqual(pages, [1, 2, 3])
        XCTAssertNil(model.rows[0].nextPage)
    }

    func testAutomaticPaginationBackfillsFilteredPages() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var pages: [Int] = []
        let model = DiscoverBrowseModel(store: .init(defaults: defaults), isCurrent: { true }) { _, page in
            pages.append(page)
            return DiscoverPage(items: [
                MediaItem(id: "page-\(page)", title: "Title", kind: .movie, isPlayed: page == 2)
            ], nextPage: page < 4 ? page + 1 : nil)
        }
        model.filters.hideWatched = true
        await model.loadMore(.trending)
        await model.loadMoreVisibleItems(.trending)
        XCTAssertEqual(pages, [1, 2, 3])
        XCTAssertEqual(model.rows[0].items.filter(model.filters.includes).map(\.id), ["page-1", "page-3"])
        XCTAssertEqual(model.rows[0].nextPage, 4)
    }

    func testAutomaticPaginationDoesNotRetryFailures() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests = 0
        let model = DiscoverBrowseModel(store: .init(defaults: defaults), isCurrent: { true }) { _, _ in
            requests += 1
            throw AppError.serverUnreachable
        }
        await model.loadMoreVisibleItems(.trending)
        await model.loadMoreVisibleItems(.trending)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(model.rows[0].error, .service(.serverUnreachable))
        await model.loadMore(.trending)
        XCTAssertEqual(requests, 2)
    }

    func testAutomaticPaginationStopsAtEmptyLastPage() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var pages: [Int] = []
        let model = DiscoverBrowseModel(store: .init(defaults: defaults), isCurrent: { true }) { _, page in
            pages.append(page)
            return DiscoverPage(items: [], nextPage: page < 3 ? page + 1 : nil)
        }
        await model.loadMoreVisibleItems(.trending)
        XCTAssertEqual(pages, [1, 2, 3])
        XCTAssertTrue(model.rows[0].items.isEmpty)
        XCTAssertNil(model.rows[0].nextPage)
    }

    func testInvalidationStopsAutomaticBackfill() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = Probe()
        let model = DiscoverBrowseModel(store: .init(defaults: defaults), isCurrent: { true }) { _, page in
            probe.onRequest?()
            return DiscoverPage(items: [], nextPage: page + 1)
        }
        probe.onRequest = { model.invalidate() }
        await model.loadMoreVisibleItems(.trending)
        XCTAssertTrue(model.rows.allSatisfy { $0.items.isEmpty && $0.nextPage == 1 })
        probe.onRequest = nil
    }

    func testRefreshAndPaginationPreserveOptimisticWatchedChanges() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        let model = DiscoverBrowseModel(
            store: .init(defaults: defaults), isCurrent: { true },
            resolveLibrarySources: { _ in [item] }
        ) { _, _ in DiscoverPage(items: [item], nextPage: nil) }
        model.filters.hideWatched = true
        await model.loadMore(.trending)
        model.applyWatchedState(.init(itemIDs: ["movie"], played: true))
        await model.refreshLibrarySources()
        XCTAssertFalse(model.filters.includes(model.rows[0].items[0]))
        await model.loadMore(.popularMovies)
        XCTAssertFalse(model.filters.includes(model.rows[1].items[0]))

        model.applyWatchedState(.init(itemIDs: ["movie"], played: false))
        await model.refreshLibrarySources()
        XCTAssertTrue(model.filters.includes(model.rows[0].items[0]))
    }

    func testPendingWatchStateSurvivesDrainingDuringPageLoad() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = Probe()
        var pending = [MediaItemMutation(itemIDs: ["movie"], played: true)]
        let model = DiscoverBrowseModel(
            store: .init(defaults: defaults), isCurrent: { probe.allowed },
            pendingWatchedStates: { pending }
        ) { _, _ in
            pending = []
            probe.onRequest?()
            return DiscoverPage(items: [MediaItem(id: "movie", title: "Movie", kind: .movie)], nextPage: nil)
        }
        model.filters.hideWatched = true
        await model.loadMore(.trending)
        XCTAssertFalse(model.filters.includes(model.rows[0].items[0]))

        // A newer in-flight action wins over the pending snapshot.
        pending = [.init(itemIDs: ["movie"], played: true)]
        probe.onRequest = { model.applyWatchedState(.init(itemIDs: ["movie"], played: false)) }
        await model.loadMore(.popularMovies)
        XCTAssertTrue(model.filters.includes(model.rows[1].items[0]))

        probe.allowed = false
        model.applyWatchedState(.init(itemIDs: ["movie"], played: true))
        XCTAssertTrue(model.rows.allSatisfy { $0.items.isEmpty })
        probe.onRequest = nil
    }

    func testConfirmedWatchStateAllowsSubsequentChangesFromAnotherClient() async throws {
        let suite = "DiscoverBrowseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var serverItem = MediaItem(id: "movie", title: "Movie", kind: .movie)
        serverItem.sources = [.init(accountID: "jellyfin", itemID: "movie", kind: .movie)]
        let model = DiscoverBrowseModel(
            store: .init(defaults: defaults), isCurrent: { true },
            resolveLibrarySources: { _ in [serverItem] }
        ) { _, _ in DiscoverPage(items: [serverItem], nextPage: nil) }
        model.filters.hideWatched = true
        await model.loadMore(.trending)
        model.applyWatchedState(.init(
            itemIDs: ["movie"], scopedItemIDs: ["jellyfin:movie"],
            played: true, resumePosition: 0, playedPercentage: 1
        ))
        serverItem.isPlayed = true
        serverItem.hasBeenPlayed = true
        serverItem.sources[0].isPlayed = true
        serverItem.sources[0].hasBeenPlayed = true
        await model.refreshLibrarySources()
        XCTAssertFalse(model.filters.includes(model.rows[0].items[0]))
        XCTAssertNil(model.rows[0].items[0].playedPercentage)
        serverItem.isPlayed = false
        serverItem.hasBeenPlayed = false
        serverItem.sources[0].isPlayed = false
        serverItem.sources[0].hasBeenPlayed = false
        await model.refreshLibrarySources()
        XCTAssertTrue(model.filters.includes(model.rows[0].items[0]))
    }

    private final class Probe {
        var requests: [DiscoverFeed] = []
        var allowed = true
        var onRequest: (() -> Void)?
    }
}
