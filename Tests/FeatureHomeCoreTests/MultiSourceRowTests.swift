import CoreModels
import XCTest
@testable import FeatureHomeCore

@MainActor
final class MultiSourceRowTests: XCTestCase {
    func testEveryProviderFeedUsesNativeIDsAndInterleavesInHomeAndBrowse() async throws {
        for kind in [ProviderKind.plex, .jellyfin, .emby] {
            let provider = MultiSourceProvider(kind: kind)
            let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
            let feeds: [HomeContentSource.Feed] = [
                .collection("collection"), .playlist("playlist"), .library(.movie),
                .recommendation(sectionID: "shelf", kind: .movie),
                .server(.init(id: "server-shelf", kind: .recommendations, libraryID: "movies"))
            ]
            let sources = feeds.map {
                HomeContentSource(feed: $0, accountID: "account", serverUserID: "viewer", libraryID: "movies", title: "Source")
            }
            let definition = CollectionSection(id: "combined", sources: sources)
            let visibility = settings(definition)
            let content = await HomeAggregator().unmergedContent(
                from: [account], perLibraryLimit: 20, visibility: visibility
            )
            let row = try XCTUnwrap(content.collectionRows.first)
            XCTAssertNil(row.failure)
            XCTAssertEqual(Array(row.items.prefix(5)).map(\.id),
                           ["collection-0", "playlist-0", "library-0", "recommendation-0", "server-0"])
            XCTAssertEqual(row.items.count, 20)
            XCTAssertTrue(row.hasMore)
            let browser = HomeRowBrowseFactory.make(
                .init(choice: .init(collectionSection: definition), source: .library(row.row)),
                accounts: [account], visibility: visibility, isCurrent: { true }
            )
            await browser.load()
            XCTAssertNil(browser.error)
            XCTAssertFalse(browser.hasMore)
            XCTAssertEqual(browser.items.count, 40)
            XCTAssertEqual(Array(browser.items.prefix(20)), row.items)
            let calls = await provider.calls
            XCTAssertTrue(calls.contains("recommendation:native-shelf"))
            XCTAssertTrue(calls.contains("collection:collection"))
            XCTAssertTrue(calls.contains("playlist:playlist"))
        }
    }

    func testSnapshotFeedsStayStableForPagingAndRefreshFromCurrentHomeContent() async throws {
        let provider = MultiSourceProvider()
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        let counter = SnapshotCounter()
        let session = HomeContentPageLoader.Session(accounts: [account], visibility: .default) { _ in
            await counter.snapshot()
        }
        let first = try await session.load(.init(home: .watchlist), start: 0, limit: 2)
        let next = try await session.load(.init(home: .watchlist), start: 2, limit: 2)
        XCTAssertEqual(first.items.map(\.id), ["saved-0", "saved-1"])
        XCTAssertEqual(next.items.map(\.id), ["saved-2", "saved-3"])
        let count = await counter.count
        XCTAssertEqual(count, 1)

        let definition = CollectionSection(sources: [.init(home: .watchlist)])
        var row = HomeCollectionRow(definition: definition, items: first.items)
        row.sourceItems = [definition.sources[0]: first.items]
        let updated = MediaItem(id: "new-save", title: "New saved title", kind: .movie)
        let presentation = HomePresentationRow.resolve(
            rows: [], content: .init(watchlist: [updated], collectionRows: [row]), visibility: settings(definition)
        )
        guard case let .library(current) = presentation.first?.source else { return XCTFail("Missing custom row") }
        XCTAssertEqual(current.section.items, [updated])
    }

    func testRecentlyAddedSourceBrowsesBeyondHomePreviewEvenWhenNativeRowIsHidden() async throws {
        let provider = MultiSourceProvider()
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        let definition = CollectionSection(sources: [.init(home: .recentlyAdded)])
        let visibility = settings(definition)
        let content = await HomeAggregator().unmergedContent(from: [account], visibility: visibility)
        let row = try XCTUnwrap(content.collectionRows.first)
        XCTAssertNil(row.failure)
        XCTAssertEqual(row.items.count, 20)
        XCTAssertTrue(row.hasMore)
        let browser = HomeRowBrowseFactory.make(
            .init(choice: .init(collectionSection: definition), source: .library(row.row)),
            accounts: [account], visibility: visibility, homeSnapshot: { _ in [] }, isCurrent: { true }
        )
        for _ in 0..<10 where browser.hasMore { await browser.load() }
        XCTAssertNil(browser.error)
        XCTAssertFalse(browser.hasMore)
        XCTAssertEqual(browser.items.count, 180)
    }

    func testUnavailableViewerAndDisabledLibrariesNeverDispatchRequests() async throws {
        let provider = MultiSourceProvider()
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        for viewer in ["viewer", "another"] {
            var visibility = HomeLibraryVisibility.default
            if viewer == "viewer" { visibility.setEnabled(false, for: "account:movies") }
            let source = HomeContentSource(
                feed: .playlist("playlist"), accountID: "account", serverUserID: viewer, libraryID: "movies", title: "Playlist"
            )
            do {
                _ = try await HomeContentPageLoader.load(
                    source, start: 0, limit: 5, accounts: [account], visibility: visibility,
                    homeSnapshot: { _ in XCTFail("Must not use another feed"); return [] }
                )
                XCTFail("Unavailable source must fail")
            } catch { XCTAssertEqual(error as? AppError, .notFound) }
        }
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSameCollectionSelectedByTwoRowsReusesPreviewPages() async throws {
        let provider = MultiSourceProvider()
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        let source = HomeContentSource(
            feed: .collection("collection"), accountID: "account", serverUserID: "viewer", libraryID: "movies", title: "Collection"
        )
        let first = CollectionSection(id: "first", sources: [source])
        let second = CollectionSection(id: "second", sources: [source])
        var visibility = settings(first)
        visibility.collectionSections.append(second)
        visibility.rowCustomization?.setVisible(true, for: second.rowID)
        let content = await HomeAggregator().unmergedContent(from: [account], visibility: visibility)
        XCTAssertEqual(content.collectionRows.count, 2)
        XCTAssertEqual(content.collectionRows[0].items, content.collectionRows[1].items)
        let calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "collection:collection" }.count, 1)
    }

    func testCustomHistoryRetainsDisabledLibraryItemsAndRecentlyAddedKeepsBrowseAffordance() throws {
        let history = HomeContentSource(home: .continueWatching)
        let definition = CollectionSection(sources: [history])
        var visibility = settings(definition)
        visibility.setEnabled(false, for: "account:movies")
        let item = MediaItem(id: "history", title: "History", kind: .movie, sourceAccountID: "account", libraryID: "movies")
        var row = HomeCollectionRow(definition: definition, items: [item])
        row.sourceItems = [history: [item]]
        let resolved = HomePresentationRow.resolve(
            rows: [], content: .init(continueWatching: [item], collectionRows: [row]), visibility: visibility
        )
        guard case let .library(current) = resolved.first?.source else { return XCTFail("Missing history row") }
        XCTAssertEqual(current.section.items, [item])

        let recent = HomeContentSource(home: .recentlyAdded)
        let recentDefinition = CollectionSection(sources: [recent])
        let candidates = (0..<21).map { MediaItem(id: "\($0)", title: "Title \($0)", kind: .movie) }
        var recentRow = HomeCollectionRow(definition: recentDefinition, items: Array(candidates.prefix(20)))
        recentRow.sourceItems = [recent: candidates]
        let recentResolved = HomePresentationRow.resolve(
            rows: [], content: .init(latest: Array(candidates.prefix(20)), collectionRows: [recentRow],
                                    recentlyAddedCandidates: candidates), visibility: settings(recentDefinition)
        )
        guard case let .library(currentRecent) = recentResolved.first?.source else { return XCTFail("Missing recent row") }
        XCTAssertEqual(currentRecent.section.items.count, 20)
        XCTAssertTrue(currentRecent.section.hasMore)
    }

    private func settings(_ row: CollectionSection) -> HomeLibraryVisibility {
        .init(rowCustomization: .init(defaults: .custom, order: [row.rowID], shown: [row.rowID]), collectionSections: [row])
    }
}

private actor SnapshotCounter {
    var count = 0
    func snapshot() -> [MediaItem] {
        count += 1
        return (0..<5).map { .init(id: "saved-\($0)", title: "Saved \($0)", kind: .movie) }
    }
}

private actor MultiSourceProvider: MediaProvider {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    var calls: [String] = []

    init(kind: ProviderKind = .jellyfin) {
        self.kind = kind
        session = .init(
            server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!, provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "fixture"
        )
    }
    private func items(_ prefix: String, count: Int = 8) -> [MediaItem] {
        (0..<count).map { MediaItem(id: "\(prefix)-\($0)", title: "\(prefix) \($0)", kind: .movie, libraryID: "movies") }
    }
    private func page(_ prefix: String, request: PageRequest) -> MediaPage {
        let all = items(prefix)
        return .init(items: Array(all.dropFirst(request.startIndex).prefix(request.limit)),
                     startIndex: request.startIndex, totalCount: all.count)
    }
    func collectionMembers(of collectionID: String, page request: PageRequest) async throws -> MediaPage {
        calls.append("collection:\(collectionID)")
        return page("collection", request: request)
    }
    func videoPlaylistMembers(of playlistID: String, page request: PageRequest) async throws -> MediaPage {
        calls.append("playlist:\(playlistID)")
        return page("playlist", request: request)
    }
    func items(in containerID: String, kind: MediaItemKind, page request: PageRequest) async throws -> MediaPage {
        calls.append("library:\(containerID)")
        return page("library", request: request)
    }
    func homeHubs(libraryID: String, kind: MediaItemKind, limit: Int, includeUnpromoted: Bool) async throws -> [LibrarySection] {
        [.init(id: "shelf", title: "Recommended", items: Array(items("recommendation").prefix(limit)), browseID: "native-shelf")]
    }
    func homeRowPage(_ feed: HomeRowFeed, startIndex: Int, limit: Int) async throws -> HomeRowPage {
        switch feed {
        case let .recommendation(_, _, id, _):
            calls.append("recommendation:\(id)")
            return .prefix(items("recommendation"), startIndex: startIndex, limit: limit)
        case .server:
            calls.append("server")
            return .prefix(items("server"), startIndex: startIndex, limit: limit)
        default: return try await homeRowPrefixPage(feed, startIndex: startIndex, limit: limit)
        }
    }
    func libraries() async throws -> [MediaLibrary] { [.init(id: "movies", title: "Movies", kind: .movie)] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { Array(items("latest", count: 180).prefix(limit)) }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
