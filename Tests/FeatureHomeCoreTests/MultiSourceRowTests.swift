import CoreModels
import XCTest
@testable import FeatureHomeCore

@MainActor
final class MultiSourceRowTests: XCTestCase {
    func testVisibilityFilteringPreservesRawContinuationAndInventoryHint() async throws {
        let provider = MultiSourceProvider(memberCount: 250)
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        let source = HomeContentSource(
            feed: .collection("collection"), accountID: "account", serverUserID: "viewer", title: "Collection"
        )
        let visibility = HomeLibraryVisibility(disabledKeys: ["account:movies"])
        let session = HomeContentPageLoader.Session(accounts: [account], visibility: visibility) { _ in [] }
        let first = try await session.load(source, start: 0, limit: 200)
        XCTAssertTrue(first.items.isEmpty)
        XCTAssertEqual(first.nextOffset, 200)
        XCTAssertEqual(first.totalCountHint, 250)
        let pager = HomeContentPager(sources: [source]) { try await session.load($0, start: $1, limit: $2) }
        let result = try await pager.loadAll()
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(result.hasMore)
    }

    func testInventoryLoaderLimitsAndTotalHintsMatchAcrossStaticAndSessionPaths() async throws {
        let provider = MultiSourceProvider(memberCount: 250)
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        let feeds: [HomeContentSource.Feed] = [.collection("collection"), .playlist("playlist"), .library(.movie)]
        let sources = feeds.map {
            HomeContentSource(feed: $0, accountID: "account", serverUserID: "viewer",
                              libraryID: "movies", title: "Inventory")
        }
        let homeSources: [HomeContentSource] = [
            .init(home: .watchlist),
            .init(feed: .recommendation(sectionID: "shelf", kind: .movie), accountID: "account",
                  serverUserID: "viewer", libraryID: "movies", title: "Recommended"),
            .init(feed: .server(.init(id: "recent", kind: .recentlyAdded, libraryID: "movies")), accountID: "account",
                  serverUserID: "viewer", libraryID: "movies", title: "Recent")
        ]
        let session = HomeContentPageLoader.Session(accounts: [account], visibility: .default) { _ in [] }
        for useSession in [false, true] {
            func load(_ source: HomeContentSource, start: Int = 0, limit: Int) async throws -> HomeRowPage {
                if useSession { return try await session.load(source, start: start, limit: limit) }
                return try await HomeContentPageLoader.load(
                    source, start: start, limit: limit, accounts: [account], visibility: .default
                ) { _ in [] }
            }
            for source in sources {
                let page = try await load(source, limit: 200)
                XCTAssertEqual(page.items.count, 200)
                XCTAssertEqual(page.nextOffset, 200)
                XCTAssertEqual(page.totalCountHint, 250)
                for (start, limit) in [(0, 201), (-1, 200), (0, 0), (Int.max, 200)] {
                    do { _ = try await load(source, start: start, limit: limit); XCTFail("Invalid request must fail") }
                    catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
                }
            }
            for source in homeSources {
                _ = try await load(source, limit: 60)
                do { _ = try await load(source, limit: 61); XCTFail("Home endpoint limits must remain unchanged") }
                catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
            }
        }
    }

    func testSavedQueriesAgreeAcrossPreviewHomeAndBrowseForNativeFeeds() async throws {
        for kind in [ProviderKind.plex, .jellyfin, .emby] {
            let provider = MultiSourceProvider(kind: kind, memberCount: 137)
            let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
            let sources: [HomeContentSource] = [
                .init(feed: .collection("collection"), accountID: "account", serverUserID: "viewer",
                      libraryID: "movies", title: "Collection"),
                .init(feed: .playlist("playlist"), accountID: "account", serverUserID: "viewer",
                      libraryID: "movies", title: "Playlist"),
                .init(feed: .library(.movie), accountID: "account", serverUserID: "viewer",
                      libraryID: "movies", title: "Movies"),
                .init(feed: .recommendation(sectionID: "shelf", kind: .movie), accountID: "account",
                      serverUserID: "viewer", libraryID: "movies", title: "Recommended")
            ]
            let definition = CollectionSection(
                sources: sources, query: .init(sort: .init(field: .name, direction: .descending), media: .movies)
            )
            let visibility = settings(definition)
            let session = HomeContentPageLoader.Session(accounts: [account], visibility: visibility) { _ in [] }
            let pager = HomeContentPager(sources: sources) { try await session.load($0, start: $1, limit: $2) }
            let preview = try await pager.load(limit: 20, query: definition.query)
            let content = await HomeAggregator().unmergedContent(from: [account], visibility: visibility)
            let row = try XCTUnwrap(content.collectionRows.first)
            XCTAssertNil(row.failure)
            XCTAssertEqual(row.items, Array(preview.items.prefix(20)))
            XCTAssertEqual(row.items.first?.id, "recommendation-136")
            let browser = HomeRowBrowseFactory.make(
                .init(choice: .init(collectionSection: definition), source: .library(row.row)),
                accounts: [account], visibility: visibility, isCurrent: { true }
            )
            XCTAssertEqual(browser.query, definition.query)
            await browser.load()
            XCTAssertNil(browser.error)
            XCTAssertEqual(browser.items, preview.items)
            XCTAssertFalse(browser.hasMore)
            XCTAssertTrue(row.hasMore)
        }
    }

    func testSavedRecentlyAddedQueryUsesFullMembershipInsteadOfHomeSnapshot() async throws {
        let provider = MultiSourceProvider()
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        let definition = CollectionSection(
            sources: [.init(home: .recentlyAdded)], query: .init(sort: .init(field: .name, direction: .descending))
        )
        let visibility = settings(definition)
        let session = HomeContentPageLoader.Session(
            accounts: [account], visibility: visibility, expandsRecentlyAdded: true
        ) { _ in XCTFail("A sorted Recent row must not use a bounded Home snapshot"); return [] }
        let pager = HomeContentPager(sources: definition.sources) { try await session.load($0, start: $1, limit: $2) }
        let preview = try await pager.load(limit: 20, query: definition.query)
        let content = await HomeAggregator().unmergedContent(from: [account], visibility: visibility)
        let row = try XCTUnwrap(content.collectionRows.first)
        XCTAssertNil(row.failure)
        XCTAssertEqual(row.items.first?.id, "latest-179")
        XCTAssertEqual(row.items, Array(preview.items.prefix(20)))
        let browser = HomeRowBrowseFactory.make(
            .init(choice: .init(collectionSection: definition), source: .library(row.row)),
            accounts: [account], visibility: visibility, isCurrent: { true }
        )
        await browser.load()
        XCTAssertNil(browser.error)
        XCTAssertEqual(browser.items, preview.items)
        let projected = row.resolving(home: [.recentlyAdded: []], visibility: visibility)
        XCTAssertEqual(projected.items, row.items, "A shorter native Home snapshot cannot overwrite full query membership")
    }

    func testSavedWatchlistQueryUsesAddedDatesAndRefreshesItsFilteredSnapshot() {
        let old = MediaItem(id: "old", title: "Zulu", kind: .movie, watchlistAddedAt: Date(timeIntervalSince1970: 1))
        let new = MediaItem(id: "new", title: "Alpha", kind: .movie, watchlistAddedAt: Date(timeIntervalSince1970: 2))
        let source = HomeContentSource(home: .watchlist)
        let definition = CollectionSection(
            sources: [source], query: .init(sort: .init(field: .dateAdded, direction: .ascending), media: .movies)
        )
        var row = HomeCollectionRow(definition: definition)
        row.sourceItems = [source: [new, old]]
        let resolved = row.resolving(home: [.watchlist: [new, old]], visibility: settings(definition))
        XCTAssertEqual(resolved.items.map(\.id), ["old", "new"])
        let refreshed = resolved.resolving(home: [.watchlist: [new]], visibility: settings(definition))
        XCTAssertEqual(refreshed.items.map(\.id), ["new"])
    }

    func testWatchMutationRefillsSavedUnwatchedRowBeyondTheVisiblePrefix() async throws {
        let provider = MultiSourceProvider(memberCount: 45)
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        let definition = CollectionSection(
            sources: [.init(feed: .playlist("playlist"), accountID: "account", serverUserID: "viewer",
                            libraryID: "movies", title: "Playlist")],
            query: .init(filters: .init(filter: .unwatched))
        )
        let visibility = settings(definition)
        let model = HomeViewModel(accounts: [account], currentVisibility: { visibility })
        await model.load()
        XCTAssertEqual(model.state.value?.collectionRows.first?.items.first?.id, "playlist-0")
        model.applyWatchedState(.init(itemIDs: ["playlist-0"], played: true))
        let row = try XCTUnwrap(model.state.value?.collectionRows.first)
        XCTAssertEqual(row.items.count, 20)
        XCTAssertEqual(row.items.first?.id, "playlist-1")
        XCTAssertEqual(row.items.last?.id, "playlist-20")
        model.invalidate()
    }

    func testCachedQueriedWatchlistReconstructsFromCurrentRuntimeMembership() {
        let old = MediaItem(id: "old", title: "Zulu", kind: .movie)
        let new = MediaItem(id: "new", title: "Alpha", kind: .movie)
        let definition = CollectionSection(
            sources: [.init(home: .watchlist)],
            query: .init(sort: .init(field: .name, direction: .ascending))
        )
        let cached = HomeCollectionRow(definition: definition, items: [old], hasMore: true)
        let refreshed = cached.resolving(home: [.watchlist: [old, new]], visibility: settings(definition))
        XCTAssertEqual(refreshed.items.map(\.id), ["new", "old"])
        XCTAssertFalse(refreshed.hasMore)
        let empty = refreshed.resolving(home: [.watchlist: []], visibility: settings(definition))
        XCTAssertTrue(empty.items.isEmpty)
    }

    func testCachedQueriedRowsDoNotReconstructMissingProviderOrRecentMembership() {
        let old = MediaItem(id: "old", title: "Zulu", kind: .movie)
        let new = MediaItem(id: "new", title: "Alpha", kind: .movie)
        let sources: [HomeContentSource] = [
            .init(home: .recentlyAdded),
            .init(feed: .playlist("playlist"), accountID: "account", serverUserID: "viewer",
                  libraryID: "movies", title: "Playlist")
        ]
        for source in sources {
            let definition = CollectionSection(
                sources: [.init(home: .watchlist), source],
                query: .init(sort: .init(field: .name, direction: .ascending))
            )
            let cached = HomeCollectionRow(definition: definition, items: [old], hasMore: true)
            let refreshed = cached.resolving(
                home: [.watchlist: [new], .recentlyAdded: [new]], visibility: settings(definition)
            )
            XCTAssertEqual(refreshed, cached)
        }
    }

    func testRecommendationScopeSurvivesSettingsPauseButRefreshesAndRetiresWithHome() async throws {
        let provider = MultiSourceProvider()
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        var loadingAllowed = true
        let definition = CollectionSection(sources: [
            .init(feed: .recommendation(sectionID: "shelf", kind: .movie), accountID: "account",
                  serverUserID: "viewer", libraryID: "movies", title: "Recommended")
        ])
        let visibility = settings(definition)
        let model = HomeViewModel(
            accounts: [account], currentVisibility: { visibility },
            isLoadingAllowed: { loadingAllowed }, isSnapshotAccessAllowed: { true }
        )
        let scope = try XCTUnwrap(model.recommendationScope)
        let initial = scope.revision
        await model.load()
        XCTAssertNotEqual(scope.revision, initial)
        let loaded = scope.revision
        let discoveredScopes = await provider.discoveredScopes
        XCTAssertFalse(discoveredScopes.isEmpty)
        XCTAssertTrue(discoveredScopes.allSatisfy { $0 == scope.id })
        loadingAllowed = false
        model.cancelPendingLoad()
        XCTAssertTrue(model.recommendationScope === scope)
        XCTAssertEqual(scope.revision, loaded)
        model.applyWatchedState(.init(itemIDs: ["recommendation-0"], played: true))
        XCTAssertNotEqual(scope.revision, loaded, "History changes must expire reuse even while Settings pauses Home")
        let afterHistory = scope.revision
        loadingAllowed = true
        await model.load()
        XCTAssertNotEqual(scope.revision, afterHistory)
        model.invalidate()
        XCTAssertFalse(scope.isActive)
        XCTAssertNil(model.recommendationScope)
    }

    func testPageLoaderRestoresCapturedRecommendationScopeAndRejectsRetirement() async throws {
        let provider = MultiSourceProvider()
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        let scope = HomeRecommendationScope()
        let source = HomeContentSource(
            feed: .recommendation(sectionID: "shelf", kind: .movie),
            accountID: "account", serverUserID: "viewer", libraryID: "movies", title: "Recommended"
        )
        let loader = HomeContentPageLoader.Session(
            accounts: [account], visibility: .default, recommendationScope: scope
        ) { _ in [] }
        _ = try await loader.load(source, start: 0, limit: 3)
        let discoveredScopes = await provider.discoveredScopes
        XCTAssertEqual(discoveredScopes, [scope.id])
        scope.invalidate()
        do { _ = try await loader.load(source, start: 0, limit: 3); XCTFail("Retired traversal must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testPageLoaderRejectsScopeRetiredDuringItsFinalResponse() async throws {
        let provider = MultiSourceProvider(catalogDelay: .milliseconds(50))
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        let scope = HomeRecommendationScope()
        let source = HomeContentSource(
            feed: .recommendation(sectionID: "shelf", kind: .movie),
            accountID: "account", serverUserID: "viewer", libraryID: "movies", title: "Recommended"
        )
        let loader = HomeContentPageLoader.Session(accounts: [account], visibility: .default, recommendationScope: scope) { _ in [] }
        let request = Task { try await loader.load(source, start: 0, limit: 3) }
        await provider.waitForCatalog()
        scope.invalidate()
        do { _ = try await request.value; XCTFail("An in-flight response cannot outlive its profile scope") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testConcurrentRecommendationsShareOneLibraryDiscoverySnapshot() async throws {
        let provider = MultiSourceProvider()
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        let sources = ["shelf", "second-shelf"].map {
            HomeContentSource(
                feed: .recommendation(sectionID: $0, kind: .movie),
                accountID: "account", serverUserID: "viewer", libraryID: "movies", title: "Recommended"
            )
        }
        let loader = HomeContentPageLoader.Session(accounts: [account], visibility: .default) { _ in [] }
        async let first = loader.load(sources[0], start: 0, limit: 3)
        async let second = loader.load(sources[1], start: 0, limit: 3)
        let pages = try await [first, second]
        XCTAssertEqual(pages.map { $0.items.count }, [3, 3])
        XCTAssertEqual(pages[0].items.first?.id, "recommendation-0")
        XCTAssertEqual(pages[1].items.first?.id, "second-0")
        let calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "catalog:movies" }.count, 1)
    }

    func testCancelledRecommendationDiscoveryDoesNotPoisonRetry() async throws {
        let provider = MultiSourceProvider(catalogDelay: .milliseconds(50))
        let account = ResolvedAccount(account: .init(id: "account", from: provider.session), provider: provider)
        let source = HomeContentSource(
            feed: .recommendation(sectionID: "shelf", kind: .movie),
            accountID: "account", serverUserID: "viewer", libraryID: "movies", title: "Recommended"
        )
        let loader = HomeContentPageLoader.Session(accounts: [account], visibility: .default) { _ in [] }
        let cancelled = Task { try await loader.load(source, start: 0, limit: 3) }
        await provider.waitForCatalog()
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled discovery must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        let retry = try await loader.load(source, start: 0, limit: 3)
        XCTAssertEqual(retry.items.count, 3)
        let calls = await provider.calls
        XCTAssertEqual(calls.filter { $0 == "catalog:movies" }.count, 2)
    }

    func testRecommendationDiscoveryDoesNotShareAcrossAccountsOrLibraries() async throws {
        let first = MultiSourceProvider()
        let second = MultiSourceProvider()
        let accounts = [
            ResolvedAccount(account: .init(id: "first", from: first.session), provider: first),
            ResolvedAccount(account: .init(id: "second", from: second.session), provider: second)
        ]
        let loader = HomeContentPageLoader.Session(accounts: accounts, visibility: .default) { _ in [] }
        for account in accounts {
            for library in ["movies", "other-movies"] {
                let source = HomeContentSource(
                    feed: .recommendation(sectionID: "shelf", kind: .movie),
                    accountID: account.account.id, serverUserID: "viewer", libraryID: library, title: "Recommended"
                )
                let page = try await loader.load(source, start: 0, limit: 3)
                XCTAssertEqual(page.items.count, 3)
                XCTAssertTrue(page.items.allSatisfy { $0.sourceAccountID == account.account.id })
            }
        }
        for provider in [first, second] {
            let calls = await provider.calls
            XCTAssertEqual(calls, ["catalog:movies", "catalog:other-movies"])
        }
    }

    func testPausedHomeSnapshotsRequireSeparateAuthorizationAndMatchingVisibility() throws {
        let saved = MediaItem(id: "saved", title: "Saved", kind: .movie)
        let store = InMemoryHomeContentStore(.init(watchlist: [saved]))
        var authorized = true
        var visibility = HomeLibraryVisibility.default
        let model = HomeViewModel(
            accounts: [], contentStore: store, currentVisibility: { visibility },
            isLoadingAllowed: { false }, isSnapshotAccessAllowed: { authorized }
        )
        XCTAssertEqual(try model.contentSnapshot(for: .watchlist, visibility: .default), [saved])
        authorized = false
        XCTAssertThrowsError(try model.contentSnapshot(for: .watchlist, visibility: .default))
        authorized = true
        visibility.setEnabled(false, for: "account:movies")
        XCTAssertThrowsError(try model.contentSnapshot(for: .watchlist, visibility: .default))
        visibility = .default
        model.invalidate()
        XCTAssertThrowsError(try model.contentSnapshot(for: .watchlist, visibility: .default))

        let defaultGuard = HomeViewModel(accounts: [], contentStore: store, isLoadingAllowed: { false })
        XCTAssertThrowsError(try defaultGuard.contentSnapshot(for: .watchlist, visibility: .default))
    }

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
    var discoveredScopes: [UUID?] = []
    let catalogDelay: Duration
    let memberCount: Int
    var catalogWaiters: [CheckedContinuation<Void, Never>] = []

    init(kind: ProviderKind = .jellyfin, catalogDelay: Duration = .zero, memberCount: Int = 8) {
        self.kind = kind
        self.catalogDelay = catalogDelay
        self.memberCount = memberCount
        session = .init(
            server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!, provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "device", accessToken: "fixture"
        )
    }
    private func items(_ prefix: String, count: Int? = nil) -> [MediaItem] {
        (0..<(count ?? memberCount)).map { MediaItem(id: "\(prefix)-\($0)", title: "\(prefix) \($0)", kind: .movie, libraryID: "movies") }
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
        calls.append("catalog:\(libraryID)")
        discoveredScopes.append(HomeRecommendationScope.current?.id)
        catalogWaiters.forEach { $0.resume() }
        catalogWaiters = []
        if catalogDelay > .zero { try await Task.sleep(for: catalogDelay) }
        return [
            .init(id: "shelf", title: "Recommended", items: Array(items("recommendation").prefix(limit)), browseID: "native-shelf"),
            .init(id: "second-shelf", title: "Other", items: Array(items("second").prefix(limit)), browseID: "native-second")
        ]
    }
    func waitForCatalog() async {
        if calls.contains(where: { $0.hasPrefix("catalog:") }) { return }
        await withCheckedContinuation { catalogWaiters.append($0) }
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
