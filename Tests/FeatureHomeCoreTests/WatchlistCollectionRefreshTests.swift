import CoreModels
import Observation
import XCTest
@testable import FeatureHomeCore

@MainActor
final class WatchlistCollectionRefreshTests: XCTestCase {
    func testNamePriorityCoversPublishedConventionsAndFormattingVariants() throws {
        let names = [
            "Watchlist", "My Watchlist", "Movie Watchlist", "TV Watchlist", "Alex's Watchlist",
            "Watch Later", "To Watch", "Want to Watch", "Watch Next", "Watch Queue",
            "Wishlist", "Favorites", "Favourites", "My List",
            "  WATCH-LIST  ", "Watch_later", "W\u{00e1}tch list", "\u{1f37f} My List"
        ]
        for name in names {
            for useHomeLabel in [false, true] {
                var priority = section("priority", useHomeLabel ? "Custom collection" : name)
                if useHomeLabel { priority.name = name }
                var queue = HomeCollectionRefreshQueue(debounce: .zero)
                let now = ContinuousClock.now
                queue.enqueue([section("ordinary", "Drama"), priority], now: now)
                XCTAssertEqual(try XCTUnwrap(queue.next(now: now)).source.collectionID, "priority", name)
            }
        }
    }

    func testUnrecognizedNamesStillRefreshAndEitherDuplicateLabelCanSetPriority() throws {
        var queue = HomeCollectionRefreshQueue(debounce: .zero)
        let now = ContinuousClock.now
        let custom = ["Top Family Movie Picks", "Watch with friends", "\u{00c0} regarder", "\u{898b}\u{305f}\u{3044}"]
        let sections = custom.enumerated().map { section("custom-\($0.offset)", $0.element) }
        var alias = section("alias", "Another source label", collectionID: "saved")
        alias.name = "My List"
        queue.enqueue(sections + [section("saved", "Custom"), alias], now: now)
        let first = try XCTUnwrap(queue.next(now: now))
        XCTAssertEqual(first.source.collectionID, "saved")
        queue.discard(first)
        for index in custom.indices {
            let request = try XCTUnwrap(queue.next(now: now))
            XCTAssertEqual(request.source.collectionID, "custom-\(index)")
            queue.discard(request)
        }
        XCTAssertTrue(queue.isEmpty)
    }

    func testPriorityDebounceDeduplicationAndBoundedFollowUp() throws {
        var queue = HomeCollectionRefreshQueue()
        let start = ContinuousClock.now
        let sections = [
            section("drama", "Drama"), section("saved", "WATCH LIST"),
            section("later", "Watch Later"), section("queue", "Want to watch"),
            section("duplicate", "Custom", collectionID: "saved")
        ]
        for offset in 0..<100 {
            queue.enqueue(sections, now: start.advanced(by: .milliseconds(offset)))
        }
        let due = start.advanced(by: .milliseconds(849))
        XCTAssertEqual(try XCTUnwrap(queue.next(now: start)).due, due)
        var order: [String] = []
        for _ in 0..<4 {
            let request = try XCTUnwrap(queue.next(now: due))
            order.append(request.source.collectionID)
            queue.finish(request, now: due)
        }
        XCTAssertEqual(order, ["saved", "later", "queue", "drama"])
        XCTAssertEqual(try XCTUnwrap(queue.next(now: due)).due, due.advanced(by: .seconds(3)))
        for _ in 0..<4 {
            let request = try XCTUnwrap(queue.next(now: due.advanced(by: .seconds(3))))
            XCTAssertTrue(request.isFollowUp)
            queue.finish(request, now: due.advanced(by: .seconds(3)))
        }
        XCTAssertTrue(queue.isEmpty)
    }

    func testNewChangeSupersedesAnInFlightPreviewWithoutLosingItsFollowUp() throws {
        var queue = HomeCollectionRefreshQueue(debounce: .zero)
        let now = ContinuousClock.now
        queue.enqueue([section("saved", "Watchlist")], now: now)
        let old = try XCTUnwrap(queue.next(now: now))
        queue.enqueue([section("saved", "Watchlist")], now: now)
        queue.finish(old, now: now)
        XCTAssertFalse(queue.contains(old))
        let latest = try XCTUnwrap(queue.next(now: now))
        XCTAssertFalse(latest.isFollowUp)
        queue.finish(latest, now: now)
        XCTAssertTrue(try XCTUnwrap(queue.next(now: now)).isFollowUp)
    }

    func testMillionItemServersRefreshOnlyBoundedConfiguredPreviewsForBothProviders() async throws {
        for kind in [ProviderKind.jellyfin, .plex, .emby] {
            let provider = RefreshProvider(kind: kind, totalCount: 1_000_000)
            let unrelated = RefreshProvider(kind: kind)
            let sections = [
                section("drama", "Drama"), section("saved", "Watchlist"), section("later", "Watch Later"),
                section("duplicate", "Another label", collectionID: "saved"),
                section("other", "Other Watchlist", account: "other")
            ]
            let settings = visibility(sections)
            let store = InMemoryHomeContentStore()
            let model = makeModel(provider, others: [resolved(unrelated, id: "other")], settings: { settings }, store: store)
            await model.load()
            let before = try XCTUnwrap(model.state.value)
            await provider.reset(version: 1)
            await unrelated.reset(version: 1)
            for _ in 0..<100 { change.post() }
            let immediateRequests = await provider.requests
            XCTAssertTrue(immediateRequests.isEmpty)
            try await waitUntil { model.collectionRefreshQueue.isEmpty }
            let requests = await provider.requests
            XCTAssertEqual(requests.map(\.collectionID), ["saved", "later", "drama", "saved", "later", "drama"])
            XCTAssertTrue(requests.allSatisfy { $0.page.startIndex == 0 && $0.page.limit == 20 })
            let maximumConcurrent = await provider.maximumConcurrent
            let unrelatedRequests = await unrelated.requests
            let extraRequests = await provider.nonCollectionRequests
            XCTAssertEqual(maximumConcurrent, 1)
            XCTAssertEqual(extraRequests, 0, "Never rediscover libraries or reload other feeds.")
            XCTAssertTrue(unrelatedRequests.isEmpty)
            let after = try XCTUnwrap(model.state.value)
            XCTAssertEqual(after.collectionRows.map(\.definition.id), before.collectionRows.map(\.definition.id))
            XCTAssertEqual(after.continueWatching, before.continueWatching)
            XCTAssertEqual(after.latest, before.latest)
            XCTAssertEqual(after.libraries, before.libraries)
            XCTAssertEqual(after.watchlist, before.watchlist)
            XCTAssertEqual(after.collectionRows.last, before.collectionRows.last)
            XCTAssertEqual(after.collectionRows[1].items, after.collectionRows[3].items)
            XCTAssertTrue(after.collectionRows[0].items.allSatisfy { $0.id.hasPrefix("v1-") })
            XCTAssertFalse(model.isRefreshing)
        }
    }

    func testUnchangedPreviewsDoNotPublishAndHiddenWrongProfileOrViewerDoNoWork() async throws {
        let provider = RefreshProvider()
        var settings = visibility([section("saved", "Watchlist"), section("hidden", "Watch Later")])
        let hiddenID = settings.collectionSections[1].rowID
        settings.rowCustomization?.setVisible(false, for: hiddenID)
        let model = makeModel(provider, settings: { settings })
        await model.load()
        await provider.reset(version: 0)
        let notifications = RefreshNotifications()
        withObservationTracking {
            _ = model.state
        } onChange: {
            notifications.increment()
        }
        WatchlistProviderChange(profileNamespace: "another-profile", accountID: "account", serverUserID: "viewer").post()
        WatchlistProviderChange(profileNamespace: "profile", accountID: "account", serverUserID: "other-viewer").post()
        WatchlistProviderChange(profileNamespace: "profile", accountID: "other", serverUserID: "viewer").post()
        XCTAssertTrue(model.collectionRefreshQueue.isEmpty)
        change.post()
        try await waitUntil { model.collectionRefreshQueue.isEmpty }
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.collectionID), ["saved", "saved"])
        XCTAssertEqual(notifications.value, 0)
        settings.setEnabled(false, for: "account:movies")
        change.post()
        XCTAssertTrue(model.collectionRefreshQueue.isEmpty)
    }

    func testNavigationDefersWorkAndServerFailureRetainsCardsWithDiagnostics() async throws {
        let provider = RefreshProvider()
        let settings = visibility([section("saved", "Watchlist")])
        let diagnostics = HomeSectionDiagnosticsModel()
        let account = resolved(provider)
        let model = HomeViewModel(
            accounts: [account], profileNamespace: "profile",
            currentVisibility: { settings }, sectionDiagnostics: diagnostics
        )
        model.collectionRefreshQueue = .init(debounce: .milliseconds(25), followUp: .seconds(1))
        await model.load()
        let original = try XCTUnwrap(model.state.value?.collectionRows.first?.items)
        await provider.reset(version: 1, failure: .serverUnreachable)
        change.post()
        for _ in 0..<4 {
            model.noteHomeNavigationInteraction()
            try await Task.sleep(for: .milliseconds(100))
        }
        let duringNavigation = await provider.requests
        XCTAssertTrue(duringNavigation.isEmpty)
        try await waitUntil { model.state.value?.collectionRows.first?.failure == .serverUnreachable }
        XCTAssertEqual(model.state.value?.collectionRows.first?.items, original)
        XCTAssertEqual(diagnostics.issues(accounts: [account], visibility: settings).first?.reason, .failed(.serverUnreachable))
        await provider.setFailure(nil)
        try await waitUntil { model.collectionRefreshQueue.isEmpty }
        XCTAssertNil(model.state.value?.collectionRows.first?.failure)
        XCTAssertTrue(diagnostics.issues(accounts: [account], visibility: settings).isEmpty)
        XCTAssertTrue(try XCTUnwrap(model.state.value?.collectionRows.first?.items.first?.id).hasPrefix("v1-"))
    }

    func testChangedVisibilityAndSupersededWritesCannotPublishOldPreview() async throws {
        let provider = RefreshProvider()
        var settings = visibility([section("saved", "Watchlist")])
        let rowID = settings.collectionSections[0].rowID
        let model = makeModel(provider, settings: { settings })
        await model.load()
        let original = model.state.value
        await provider.reset(version: 1)
        await provider.setPaused(true)
        change.post()
        try await waitUntil { await provider.inFlight == 1 }
        settings.rowCustomization?.setVisible(false, for: rowID)
        await provider.setPaused(false)
        try await waitUntil { model.collectionRefreshQueue.isEmpty }
        XCTAssertEqual(model.state.value, original)
        settings.rowCustomization?.setVisible(true, for: rowID)
        await provider.setPaused(true)
        change.post()
        try await waitUntil { await provider.inFlight == 1 }
        await provider.setVersion(2)
        change.post()
        let activeRequests = await provider.requests
        let activeCount = await provider.inFlight
        XCTAssertEqual(activeRequests.count, 2, "A new confirmation must not cancel or duplicate the in-flight preview.")
        XCTAssertEqual(activeCount, 1)
        await provider.setPaused(false)
        try await waitUntil { model.collectionRefreshQueue.isEmpty }
        XCTAssertTrue(try XCTUnwrap(model.state.value?.collectionRows.first?.items.first?.id).hasPrefix("v2-"))
    }

    func testModelTeardownCancelsPendingAndInFlightRefreshes() async throws {
        let provider = RefreshProvider()
        let settings = visibility([section("saved", "Watchlist")])
        var model: HomeViewModel? = makeModel(provider, settings: { settings })
        await model?.load()
        await provider.reset(version: 1)
        await provider.setPaused(true)
        change.post()
        try await waitUntil { await provider.inFlight == 1 }
        weak var weakModel = model
        model = nil
        XCTAssertNil(weakModel)
        try await waitUntil { await provider.inFlight == 0 }
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testModelTeardownDuringDebounceStartsNoPreview() async throws {
        let provider = RefreshProvider()
        let settings = visibility([section("saved", "Watchlist")])
        var model: HomeViewModel? = makeModel(provider, settings: { settings })
        model?.collectionRefreshQueue = .init(debounce: .seconds(1))
        await model?.load()
        await provider.reset(version: 1)
        change.post()
        await Task.yield()
        weak var weakModel = model
        model = nil
        XCTAssertNil(weakModel)
        try await Task.sleep(for: .milliseconds(1200))
        let requests = await provider.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testFullHomeLoadSupersedesInFlightPreviewAndKeepsNewContent() async throws {
        let provider = RefreshProvider()
        let settings = visibility([section("saved", "Watchlist")])
        let model = makeModel(provider, settings: { settings })
        await model.load()
        await provider.reset(version: 1)
        await provider.setPaused(true)
        change.post()
        try await waitUntil { await provider.inFlight == 1 }
        await provider.setVersion(2)
        let load = Task { await model.load(showLoadingState: false) }
        try await waitUntil { model.isRefreshing }
        await provider.setPaused(false)
        await load.value
        try await waitUntil { model.collectionRefreshQueue.isEmpty }
        XCTAssertTrue(try XCTUnwrap(model.state.value?.collectionRows.first?.items.first?.id).hasPrefix("v2-"))
    }

    func testNewConfirmationWakesDelayedFollowUpWithoutWaitingForItsDeadline() async throws {
        let provider = RefreshProvider()
        let settings = visibility([section("saved", "Watchlist")])
        let model = makeModel(provider, settings: { settings })
        model.collectionRefreshQueue = .init(debounce: .milliseconds(25), followUp: .seconds(30))
        await model.load()
        await provider.reset(version: 1)
        change.post()
        try await waitUntil { model.state.value?.collectionRows.first?.items.first?.id.hasPrefix("v1-") == true }
        try await Task.sleep(for: .milliseconds(400))
        await provider.setVersion(2)
        change.post()
        try await waitUntil { model.state.value?.collectionRows.first?.items.first?.id.hasPrefix("v2-") == true }
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2, "Wake the deadline wait; do not add another worker or poll.")
    }

    func testNavigationDoesNotTriggerExtraReadsAndDefaultProfileIsScoped() async throws {
        let provider = RefreshProvider()
        let settings = visibility([section("saved", "Watchlist")])
        let model = HomeViewModel(
            accounts: [resolved(provider)], contentStore: NoOpHomeContentStore(),
            currentVisibility: { settings }
        )
        model.collectionRefreshQueue = .init(debounce: .milliseconds(25), followUp: .milliseconds(500))
        await model.load()
        await provider.reset(version: 1)
        for _ in 0..<20 {
            model.noteHomeNavigationInteraction()
            await model.loadIfNeeded(for: settings)
        }
        change.post()
        try await Task.sleep(for: .milliseconds(750))
        let idleRequests = await provider.requests
        let otherRequests = await provider.nonCollectionRequests
        XCTAssertTrue(idleRequests.isEmpty)
        XCTAssertEqual(otherRequests, 0)
        WatchlistProviderChange(profileNamespace: nil, accountID: "account", serverUserID: "viewer").post()
        try await waitUntil { model.collectionRefreshQueue.isEmpty }
        let activeRequests = await provider.requests
        XCTAssertEqual(activeRequests.count, 2)
    }

    func testDelayedAutomationAddsThenRemovesCardsAndStopsAfterFollowUp() async throws {
        let provider = RefreshProvider(totalCount: 0)
        let settings = visibility([section("saved", "Watchlist")])
        let model = makeModel(provider, settings: { settings })
        await model.load()
        await provider.reset(version: 1)
        change.post()
        try await waitUntil { await provider.requests.count == 1 }
        XCTAssertEqual(model.state.value?.collectionRows.first?.items.count, 0)
        await provider.setTotalCount(1)
        try await waitUntil { model.collectionRefreshQueue.isEmpty }
        XCTAssertEqual(model.state.value?.collectionRows.first?.items.count, 1)
        await provider.reset(version: 2)
        change.post()
        try await waitUntil { await provider.requests.count == 1 }
        await provider.setTotalCount(0)
        try await waitUntil { model.collectionRefreshQueue.isEmpty }
        XCTAssertEqual(model.state.value?.collectionRows.first?.items.count, 0)
        XCTAssertNil(model.state.value?.collectionRows.first?.failure)
        try await Task.sleep(for: .milliseconds(1300))
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2, "Do not keep polling after the bounded follow-up.")
    }

    func testPersistentFailureStopsAfterOneFollowUpAndKeepsExistingCards() async throws {
        let provider = RefreshProvider()
        let settings = visibility([section("saved", "Watchlist")])
        let model = makeModel(provider, settings: { settings })
        await model.load()
        let original = model.state.value?.collectionRows.first?.items
        await provider.reset(version: 1, failure: .serverUnreachable)
        change.post()
        try await waitUntil { model.collectionRefreshQueue.isEmpty }
        try await Task.sleep(for: .milliseconds(1300))
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(model.state.value?.collectionRows.first?.items, original)
        XCTAssertEqual(model.state.value?.collectionRows.first?.failure, .serverUnreachable)
    }

    func testShortServerPagesStillStopAfterTwentyMembersPerPreview() async throws {
        let provider = RefreshProvider(totalCount: 1_000_000, pageSize: 3)
        let settings = visibility([section("saved", "Watchlist")])
        let model = makeModel(provider, settings: { settings })
        await model.load()
        await provider.reset(version: 1)
        change.post()
        try await waitUntil { model.collectionRefreshQueue.isEmpty }
        let requests = await provider.requests
        let offsets = [0, 3, 6, 9, 12, 15, 18]
        XCTAssertEqual(requests.map(\.page.startIndex), offsets + offsets)
        XCTAssertEqual(requests.map(\.page.limit), (offsets + offsets).map { 20 - $0 })
        XCTAssertEqual(model.state.value?.collectionRows.first?.items.count, 20)
        let concurrent = await provider.maximumConcurrent
        XCTAssertEqual(concurrent, 1)
    }

    private var change: WatchlistProviderChange {
        .init(profileNamespace: "profile", accountID: "account", serverUserID: "viewer")
    }

    private func section(_ id: String, _ title: String, collectionID: String? = nil, account: String = "account") -> CollectionSection {
        .init(id: id, source: .init(
            accountID: account, libraryID: "movies", collectionID: collectionID ?? id,
            title: title, serverUserID: "viewer"
        ))
    }

    private func visibility(_ sections: [CollectionSection]) -> HomeLibraryVisibility {
        .init(rowCustomization: .init(defaults: .custom, order: sections.map(\.rowID), shown: Set(sections.map(\.rowID))),
              collectionSections: sections)
    }

    private func resolved(_ provider: RefreshProvider, id: String = "account") -> ResolvedAccount {
        .init(account: Account(id: id, from: provider.session), provider: provider)
    }

    private func makeModel(
        _ provider: RefreshProvider, others: [ResolvedAccount] = [],
        settings: @escaping () -> HomeLibraryVisibility,
        store: any HomeContentStoring = NoOpHomeContentStore(),
        diagnostics: HomeSectionDiagnosticsModel? = nil
    ) -> HomeViewModel {
        let model = HomeViewModel(
            accounts: [resolved(provider)] + others, profileNamespace: "profile",
            contentStore: store, currentVisibility: settings, sectionDiagnostics: diagnostics
        )
        model.collectionRefreshQueue = .init(debounce: .milliseconds(25), followUp: .seconds(1))
        return model
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Collection refresh did not settle")
                throw AppError.invalidResponse
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

}

private final class RefreshNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor RefreshProvider: MediaProvider {
    struct Request: Sendable {
        let collectionID: String
        let page: PageRequest
    }
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    private var totalCount: Int
    private let pageSize: Int?
    private var version = 0
    private var failure: AppError?
    private var paused = false
    private(set) var requests: [Request] = []
    private(set) var nonCollectionRequests = 0
    private(set) var inFlight = 0
    private(set) var maximumConcurrent = 0

    init(kind: ProviderKind = .jellyfin, totalCount: Int = 50, pageSize: Int? = nil) {
        self.kind = kind
        self.totalCount = totalCount
        self.pageSize = pageSize
        session = .init(
            server: .init(id: "server", name: "Server", baseURL: URL(string: "https://example.com")!, provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "test-token"
        )
    }

    func reset(version: Int, failure: AppError? = nil) {
        requests = []
        nonCollectionRequests = 0
        maximumConcurrent = 0
        self.version = version
        self.failure = failure
    }
    func setFailure(_ failure: AppError?) { self.failure = failure }
    func setVersion(_ version: Int) { self.version = version }
    func setTotalCount(_ count: Int) { totalCount = count }
    func setPaused(_ value: Bool) { paused = value }

    func collectionMembers(of collectionID: String, page: PageRequest) async throws -> MediaPage {
        requests.append(.init(collectionID: collectionID, page: page))
        inFlight += 1
        maximumConcurrent = max(maximumConcurrent, inFlight)
        defer { inFlight -= 1 }
        let requestedVersion = version
        while paused { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        if let failure { throw failure }
        let end = min(totalCount, page.startIndex + min(page.limit, pageSize ?? page.limit))
        let items = (page.startIndex..<end).map {
            MediaItem(id: "v\(requestedVersion)-\(collectionID)-\($0)", title: "Movie", kind: .movie).taggingLibrary("movies")
        }
        return .init(items: items, startIndex: page.startIndex, totalCount: totalCount)
    }
    func libraries() async throws -> [MediaLibrary] {
        nonCollectionRequests += 1
        return [.init(id: "movies", title: "Movies", kind: .movie)]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { nonCollectionRequests += 1; return [] }
    func latest(limit: Int) async throws -> [MediaItem] { nonCollectionRequests += 1; return [] }
    func item(id: String) async throws -> MediaItem { nonCollectionRequests += 1; throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { nonCollectionRequests += 1; return [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        nonCollectionRequests += 1
        throw AppError.notFound
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { nonCollectionRequests += 1; return [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
