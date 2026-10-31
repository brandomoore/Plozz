import CoreModels
@testable import FeatureHomeCore
import XCTest

@MainActor
final class HomeRowBrowseTests: XCTestCase {
    func testCombinedRecentlyAddedExcludesMusicWithoutChangingRawPageOffsets() async throws {
        let all = (0..<125).map {
            MediaItem(id: "\($0)", title: "Title \($0)", kind: .movie)
                .taggingLibrary($0 < 60 ? "music" : "movies")
        }
        for hasKnownLibraries in [true, false] {
            let provider = BrowseFactoryProvider(all)
            let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
            let choice = try XCTUnwrap(HomeRowChoice.shared.first { $0.id == .global(.recentlyAdded) })
            let visibility = HomeLibraryVisibility(
                rowCustomization: .init(defaults: .custom, order: [choice.id], shown: [choice.id])
            )
            let model = HomeRowBrowseFactory.make(
                .init(choice: choice, source: .home(.init(kind: .recentlyAdded))),
                accounts: [account], visibility: visibility,
                libraries: hasKnownLibraries ? [movieLibrary] : [], isCurrent: { true }
            )
            await model.load()
            XCTAssertNil(model.error)
            XCTAssertTrue(model.items.isEmpty)
            XCTAssertTrue(model.hasMore)
            await model.load()
            XCTAssertEqual(model.items.map(\.id), (60..<120).map(String.init))
            await model.load()
            XCTAssertNil(model.error)
            XCTAssertEqual(model.items.map(\.id), (60..<125).map(String.init))
            XCTAssertFalse(model.hasMore)
            let offsets = await provider.offsets
            XCTAssertEqual(offsets, [0, 60, 120])
        }
    }

    func testRecentlyAddedWatchMutationsReprojectAllRowScopesAndRestoreHiddenCandidates() async throws {
        let all = [
            MediaItem(id: "unwatched", title: "Unwatched", kind: .movie),
            MediaItem(id: "watched", title: "Watched", kind: .movie, isPlayed: true)
        ].map { $0.taggingLibrary("movies") }
        for scope in ["combined", "library", "server", "nextUp"] {
            let provider = BrowseFactoryProvider(all)
            let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
            let row: HomePresentationRow
            switch scope {
            case "combined":
                let choice = try XCTUnwrap(HomeRowChoice.shared.first { $0.id == .global(.recentlyAdded) })
                row = .init(choice: choice, source: .home(.init(kind: .recentlyAdded)))
            case "server":
                let server = HomeServerRowDefinition(
                    accountID: "account", serverName: "Server", providerKind: .plex,
                    section: .init(id: "latest", kind: .recentlyAdded, libraryID: "movies")
                )
                row = .init(choice: .init(serverRow: server), source: .library(HomeServerRow(definition: server).row))
            default:
                let section = LibrarySection(id: scope == "nextUp" ? "nextUp" : "recentlyAdded", title: "Shelf", items: [])
                row = .init(choice: .init(section: section, library: movieLibrary),
                            source: .library(.init(section: section, isLoading: false, failure: nil)))
            }
            var visibility = HomeLibraryVisibility(
                rowCustomization: .init(defaults: .custom, order: [row.id], shown: [row.id])
            )
            visibility.hideWatchedRecentlyAdded = true
            let model = HomeRowBrowseFactory.make(
                row, accounts: [account], visibility: visibility, libraries: [movieLibrary], isCurrent: { true }
            )
            await model.load()
            XCTAssertNil(model.error, scope)
            XCTAssertEqual(model.items.map(\.id), scope == "nextUp" ? ["unwatched", "watched"] : ["unwatched"], scope)
            model.applyMutation(.init(itemIDs: ["unwatched"], scopedItemIDs: ["account:unwatched"], played: true))
            XCTAssertEqual(model.items.count, scope == "nextUp" ? 2 : 0, scope)
            await model.load()
            XCTAssertEqual(model.items.count, scope == "nextUp" ? 2 : 0, scope)
            model.applyMutation(.init(itemIDs: ["watched"], scopedItemIDs: ["other:watched"], played: false))
            XCTAssertEqual(model.items.count, scope == "nextUp" ? 2 : 0, scope)
            model.applyMutation(.init(itemIDs: ["watched"], scopedItemIDs: ["account:watched"], played: false))
            XCTAssertEqual(model.items.map(\.id), scope == "nextUp" ? ["unwatched", "watched"] : ["watched"], scope)
        }
    }

    func testMissingLibraryDiscoveryDoesNotBypassDisabledLibraryScope() async throws {
        let provider = BrowseFactoryProvider(
            [MediaItem(id: "unknown", title: "Unknown library", kind: .movie)], hasLibraries: false
        )
        let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
        let choice = try XCTUnwrap(HomeRowChoice.shared.first { $0.id == .global(.recentlyAdded) })
        var visibility = HomeLibraryVisibility(
            rowCustomization: .init(defaults: .custom, order: [choice.id], shown: [choice.id])
        )
        visibility.setEnabled(false, for: "account:hidden")
        let model = HomeRowBrowseFactory.make(
            .init(choice: choice, source: .home(.init(kind: .recentlyAdded))),
            accounts: [account], visibility: visibility, isCurrent: { true }
        )
        await model.load()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasMore)
        let offsets = await provider.offsets
        XCTAssertTrue(offsets.isEmpty)
    }

    private var movieLibrary: AggregatedLibrary {
        .init(accountID: "account", accountName: "Viewer", serverName: "Server", providerKind: .plex,
              library: .init(id: "movies", title: "Movies", kind: .movie))
    }

    func testBrowseActionRequiresConfirmedEligibleOverflow() throws {
        let id = HomeRowID.global(.recentlyAdded)
        var visibility = HomeLibraryVisibility(
            rowCustomization: .init(defaults: .custom, order: [id], shown: [id])
        )
        func presentation(_ candidates: [MediaItem]) -> HomePresentationRow? {
            HomePresentationRow.resolve(
                rows: [.init(kind: .recentlyAdded, items: Array(candidates.prefix(20)))],
                content: .init(latest: Array(candidates.prefix(20)), recentlyAddedCandidates: candidates),
                visibility: visibility
            ).first
        }
        XCTAssertNil(presentation([]))
        for count in [1, 2, 19, 20, 21, 100] {
            let row = try XCTUnwrap(presentation(items(count)))
            XCTAssertEqual(row.canBrowse, count > 20, "Count \(count)")
            if case let .home(home) = row.source { XCTAssertEqual(home.items.count, min(20, count)) }
        }
        XCTAssertFalse(try XCTUnwrap(presentation(items(20) + [items(1)[0]])).canBrowse)
        visibility.hideWatchedRecentlyAdded = true
        XCTAssertFalse(try XCTUnwrap(presentation(items(40))).canBrowse, "Watched overflow is not additional content")
        XCTAssertTrue(try XCTUnwrap(presentation(items(42))).canBrowse)
        visibility.setEnabled(false, for: "account:hidden")
        let eligible = items(40) + items(2).map { $0.taggingSource("account").taggingLibrary("hidden") }
        XCTAssertFalse(try XCTUnwrap(presentation(eligible)).canBrowse, "Hidden-library overflow must not add an action")
    }

    func testCompleteHistoryAndFailedRowsDoNotOfferBrowse() throws {
        let shared = HomeRowChoice.shared
        let history = try XCTUnwrap(shared.first { $0.id == .global(.continueWatching) })
        let row = HomePresentationRow(choice: history, source: .home(.init(kind: .continueWatching, items: items(100))))
        XCTAssertFalse(row.canBrowse)
        let choice = try XCTUnwrap(shared.first { $0.id == .global(.recentlyAdded) })
        let section = LibrarySection(id: "shelf", title: "Shelf", items: items(20), hasMore: true)
        for (loading, failure): (Bool, AppError?) in [(true, nil), (false, .serverUnreachable)] {
            let row = HomePresentationRow(
                choice: choice, source: .library(.init(section: section, isLoading: loading, failure: failure))
            )
            XCTAssertFalse(row.canBrowse)
        }
        XCTAssertTrue(HomePresentationRow(
            choice: choice, source: .library(.init(section: section, isLoading: false, failure: nil))
        ).canBrowse)
    }

    func testDefaultOrderLoadsBeyondHomePreviewAndStopsAtExhaustion() async {
        let all = items(145)
        let source = Pages(all)
        let model = HomeRowBrowseModel(title: "Shelf", loaders: [{ start, limit in
            await source.page(start, limit)
        }])
        await model.load()
        XCTAssertEqual(model.items, Array(all.prefix(60)))
        XCTAssertTrue(model.hasMore)
        await model.load()
        XCTAssertEqual(model.items.count, 120)
        await model.load()
        XCTAssertEqual(model.items, all)
        XCTAssertFalse(model.hasMore)
        let requests = await source.requests
        XCTAssertEqual(requests, [0, 60, 120])
    }

    func testSortAndFilterIncludeUnloadedPagesBeforePublishing() async {
        let source = Pages(items(143))
        let model = HomeRowBrowseModel(title: "Shelf", loaders: [{ start, limit in
            await source.page(start, limit)
        }])
        await model.load()
        model.query.sort = .init(field: .name, direction: .descending)
        model.query.filters = .init(filter: .unwatched)
        await model.load()
        XCTAssertEqual(model.items.count, 71)
        XCTAssertEqual(model.items.first?.id, "141")
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(model.query, model.appliedQuery)
        let requests = await source.requests
        XCTAssertEqual(requests, [0, 60, 120])
    }

    func testFailedCompleteQueryDoesNotPublishPartialSortedResultsAndCanRetry() async {
        let source = Pages(items(143), failureAt: 60)
        let model = HomeRowBrowseModel(title: "Shelf", loaders: [{ start, limit in
            try await source.falliblePage(start, limit)
        }])
        await model.load()
        let original = model.items
        model.query.sort = .init(field: .name, direction: .descending)
        await model.load()
        XCTAssertEqual(model.error, .serverUnreachable)
        XCTAssertEqual(model.items, original)
        XCTAssertNotEqual(model.query, model.appliedQuery)
        await source.recover()
        await model.load()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.items.count, 143)
        XCTAssertEqual(model.items.first?.id, "142")
    }

    func testScopeChangeClearsItemsAndRejectsLatePage() async {
        var current = true
        let gate = PageGate()
        let model = HomeRowBrowseModel(
            title: "Shelf", loaders: [{ _, _ in await gate.wait() }],
            isCurrent: { current }
        )
        let work = Task { await model.load() }
        await gate.waitUntilStarted()
        current = false
        await gate.finish(.init(items: items(1), nextOffset: nil))
        await work.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(model.error, .notFound)
    }

    func testCancellationNeverPublishesLateResults() async {
        let gate = PageGate()
        let model = HomeRowBrowseModel(title: "Shelf", loaders: [{ _, _ in await gate.wait() }])
        let work = Task { await model.load() }
        await gate.waitUntilStarted()
        work.cancel()
        await gate.finish(.init(items: items(1), nextOffset: nil))
        await work.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.error)
    }

    func testFixedShelfHasNoFetchAndRestoresOriginalOrder() async {
        let original = items(35)
        let model = HomeRowBrowseModel(title: "Fixed", snapshot: original)
        model.query.sort = .init(field: .name, direction: .descending)
        await model.load()
        XCTAssertEqual(model.items.first?.id, "34")
        model.query = .init()
        await model.load()
        XCTAssertEqual(model.items, original)
        XCTAssertFalse(model.hasMore)
    }

    func testSupersededQueryCannotOverwriteNewerResults() async {
        let gate = PageGate()
        let source = SupersededPageSource(gate: gate, current: items(3))
        let model = HomeRowBrowseModel(title: "Shelf", loaders: [{ _, _ in
            await source.page()
        }])
        let original = Task { await model.load() }
        await gate.waitUntilStarted()
        model.query.sort = .init(field: .name, direction: .descending)
        await model.load()
        XCTAssertEqual(model.items.map(\.id), ["2", "1", "0"])
        await gate.finish(.init(items: items(1), nextOffset: nil))
        await original.value
        XCTAssertEqual(model.items.map(\.id), ["2", "1", "0"])
        XCTAssertEqual(model.query, model.appliedQuery)
        XCTAssertFalse(model.isLoading)
    }

    func testTVFilterIncludesEpisodesAndSeasons() {
        let kinds: [MediaItemKind] = [.movie, .series, .season, .episode, .video]
        let all = kinds.enumerated().map {
            MediaItem(id: "\($0.offset)", title: "Title", kind: $0.element)
        }
        var query = HomeRowBrowseQuery()
        query.media = .shows
        XCTAssertEqual(query.applying(to: all).map(\.kind), [.series, .season, .episode])
    }

    func testMalformedContinuationFailsRatherThanLooping() async {
        let model = HomeRowBrowseModel(title: "Shelf", loaders: [{ _, _ in
            .init(items: [], nextOffset: 0)
        }])
        await model.load()
        XCTAssertEqual(model.error, .invalidResponse)
    }

    func testLiveWatchlistUsesSavedDatesAndRefreshesMembership() async {
        var first = MediaItem(id: "first", title: "First", kind: .movie)
        first.watchlistAddedAt = Date(timeIntervalSince1970: 20)
        var second = MediaItem(id: "second", title: "Second", kind: .movie)
        second.watchlistAddedAt = Date(timeIntervalSince1970: 10)
        var snapshot = [second, first]
        let model = HomeRowBrowseModel(
            title: "Watchlist", snapshot: snapshot, snapshotProvider: { snapshot }, watchlistDates: true
        )
        model.query.sort = .init(field: .dateAdded, direction: .descending)
        await model.load()
        XCTAssertEqual(model.items.map(\.id), ["first", "second"])
        snapshot = [second]
        await model.load()
        XCTAssertEqual(model.items.map(\.id), ["second"])
    }

    func testScopedWatchMutationReevaluatesTheWholeLoadedFilter() async {
        let all = [
            MediaItem(id: "same", title: "A", kind: .movie, isPlayed: true).taggingSource("a"),
            MediaItem(id: "same", title: "B", kind: .movie, isPlayed: true).taggingSource("b")
        ]
        let model = HomeRowBrowseModel(title: "Shelf", snapshot: all)
        model.query.filters = .init(filter: .unwatched)
        await model.load()
        XCTAssertTrue(model.items.isEmpty)
        model.applyMutation(.init(itemIDs: ["same"], scopedItemIDs: ["a:same"], played: false))
        XCTAssertEqual(model.items.map(\.sourceAccountID), ["a"])
    }

    private func items(_ count: Int) -> [MediaItem] {
        (0..<count).map {
            MediaItem(id: "\($0)", title: String(format: "Title %03d", $0), kind: .movie, isPlayed: $0 % 2 == 0)
        }
    }

}

private actor Pages {
    let items: [MediaItem]
    var requests: [Int] = []
    var failureAt: Int?
    init(_ items: [MediaItem], failureAt: Int? = nil) { self.items = items; self.failureAt = failureAt }
    func page(_ start: Int, _ limit: Int) -> HomeRowPage {
        requests.append(start)
        return .prefix(items, startIndex: start, limit: limit)
    }
    func falliblePage(_ start: Int, _ limit: Int) throws -> HomeRowPage {
        if failureAt == start { throw AppError.serverUnreachable }
        return page(start, limit)
    }
    func recover() { failureAt = nil }
}

private actor BrowseFactoryProvider: MediaProvider {
    nonisolated let kind = ProviderKind.plex
    nonisolated let session = UserSession(
        server: .init(id: "server", name: "Server", baseURL: URL(string: "https://media.test")!, provider: .plex),
        userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "test-token"
    )
    let media: [MediaItem]
    let hasLibraries: Bool
    private(set) var offsets: [Int] = []
    init(_ media: [MediaItem], hasLibraries: Bool = true) {
        self.media = media
        self.hasLibraries = hasLibraries
    }
    func homeRowPage(_ feed: HomeRowFeed, startIndex: Int, limit: Int) async throws -> HomeRowPage {
        offsets.append(startIndex)
        return .prefix(media, startIndex: startIndex, limit: limit)
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: Array(media.dropFirst(page.startIndex).prefix(page.limit)),
              startIndex: page.startIndex, totalCount: media.count)
    }
    func libraries() async throws -> [MediaLibrary] {
        hasLibraries ? [.init(id: "movies", title: "Movies", kind: .movie),
         .init(id: "music", title: "Music", kind: .video, isMusic: true)]
            : []
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { Array(media.prefix(limit)) }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private actor PageGate {
    private var completion: CheckedContinuation<HomeRowPage, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async -> HomeRowPage {
        await withCheckedContinuation {
            completion = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ page: HomeRowPage) { completion?.resume(returning: page); completion = nil }
}

private actor SupersededPageSource {
    let gate: PageGate
    let current: [MediaItem]
    private var requested = false
    init(gate: PageGate, current: [MediaItem]) { self.gate = gate; self.current = current }
    func page() async -> HomeRowPage {
        if requested { return .init(items: current, nextOffset: nil) }
        requested = true
        return await gate.wait()
    }
}
