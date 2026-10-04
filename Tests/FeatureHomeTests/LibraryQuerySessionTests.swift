import CoreModels
import Foundation
import XCTest
@testable import FeatureHomeCore
@testable import FeatureHome

@MainActor
final class LibraryQuerySessionTests: XCTestCase {
    func testEmptySuccessfulFacetsAreCachedUntilExplicitRetry() async {
        let source = QueryInventoryProvider(items: [], facets: .init())
        let model = LibraryBrowseViewModel(provider: source, containerID: "lib", containerKind: .movie,
                                           initialContentMode: .titles)
        await model.loadQueryFacetsIfNeeded()
        await model.loadQueryFacetsIfNeeded()
        let requests = await source.facetRequests
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(model.queryFacets, .init())
        XCTAssertNil(model.facetsError)
        XCTAssertFalse(model.facetsLoading)
        await model.loadQueryFacetsIfNeeded(retry: true)
        let retried = await source.facetRequests
        XCTAssertEqual(retried, 2)
    }

    func testFacetRetryClearsARealFailureWithoutChangingTheSelectedFilter() async throws {
        let name = "LibraryFacetRetry.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let source = QueryInventoryProvider(items: queryItems(3))
        await source.setFacetError(.decoding)
        let model = LibraryBrowseViewModel(provider: source, containerID: "lib", containerKind: .movie,
                                           defaults: defaults, initialContentMode: .titles)
        await model.setFilters(.init(filter: .unwatched))
        await model.loadQueryFacetsIfNeeded()
        XCTAssertEqual(model.facetsError, .decoding)
        XCTAssertEqual(model.filters.filter, .unwatched)
        await source.setFacetError(nil)
        await model.loadQueryFacetsIfNeeded(retry: true)
        XCTAssertNil(model.facetsError)
        XCTAssertEqual(model.queryFacets, .init(genres: ["Drama"], years: [2024]))
        XCTAssertEqual(model.filters.filter, .unwatched)
    }

    func testCancelledFacetRequestDoesNotDisplayARetryErrorAndCanLoadAgain() async {
        let source = QueryInventoryProvider(items: [])
        await source.setFacetError(.cancelled)
        let model = LibraryBrowseViewModel(provider: source, containerID: "lib", containerKind: .movie,
                                           initialContentMode: .titles)
        await model.loadQueryFacetsIfNeeded()
        XCTAssertNil(model.facetsError)
        XCTAssertFalse(model.facetsLoading)
        await source.setFacetError(nil)
        await model.loadQueryFacetsIfNeeded()
        XCTAssertEqual(model.queryFacets.genres, ["Drama"])
        let requests = await source.facetRequests
        XCTAssertEqual(requests, 2)
    }

    func testQuickFiltersWithoutGenreOrYearCapabilitiesDoNotRequestFacets() async {
        let source = QueryInventoryProvider(items: [], supportsFacets: false)
        let model = LibraryBrowseViewModel(provider: source, containerID: "lib", containerKind: .movie,
                                           initialContentMode: .titles)
        await model.loadQueryFacetsIfNeeded()
        let requests = await source.facetRequests
        XCTAssertEqual(requests, 0)
        XCTAssertNil(model.facetsError)
    }

    func testNormalBrowseAndFacetsNeverInventory() async throws {
        let source = QueryInventoryProvider(items: queryItems(300))
        let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .movie)
        let page = try await session.page(.init(limit: 10), progress: { _, _ in })
        _ = try await source.libraryQueryFacets(in: "lib", kind: .movie)
        XCTAssertEqual(page.totalCount, 300)
        XCTAssertEqual(page.items.count, 10)
        let count = await source.inventoryRequests
        XCTAssertEqual(count, 0)
    }

    func testFallbackFiltersEntireLibraryNotOnlyFirstPageAndCachesFacts() async throws {
        let source = QueryInventoryProvider(items: queryItems(300))
        let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .movie)
        let filtered = PageRequest(limit: 11, filters: .init(filter: .atmos, genre: "Drama", year: 2024))
        let first = try await session.page(filtered, progress: { _, _ in })
        XCTAssertEqual(first.totalCount, 100)
        XCTAssertEqual(first.items.map(\.id), stride(from: 0, to: 33, by: 3).map { "i\($0)" })
        let last = try await session.page(.init(startIndex: 99, limit: 11, filters: filtered.filters), progress: { _, _ in })
        XCTAssertEqual(last.items.map(\.id), ["i297"])
        let requests = await source.inventoryRequests
        XCTAssertEqual(requests, 3)
        let changedSort = try await session.page(.init(limit: 10, sort: .init(field: .runtime, direction: .descending)),
                                                progress: { _, _ in })
        XCTAssertEqual(changedSort.totalCount, 300)
        let after = await source.inventoryRequests
        XCTAssertEqual(after, requests, "Richer cached file facts also cover simpler sorts")
    }

    func testRepeatedIdentityAndIncompleteTraversalFailRatherThanReturnPartialResults() async {
        for broken: QueryInventoryProvider.Broken in [.emptyTail, .repeatedIdentity, .changedTotal] {
            let source = QueryInventoryProvider(items: queryItems(300), broken: broken)
            let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .movie)
            do {
                _ = try await session.page(.init(filters: .init(filter: .atmos)), progress: { _, _ in })
                XCTFail("Incomplete inventories must not look successful")
            } catch {
                XCTAssertTrue(error is AppError || error is LibraryQueryFailure)
            }
        }
    }

    func testMetricChangesReuseFileFactsWithoutReusingWatchHistory() async throws {
        let source = QueryInventoryProvider(items: queryItems(12))
        let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .movie)
        let filters = LibraryFilters(filter: .atmos)
        _ = try await session.page(.init(filters: filters), progress: { _, _ in })
        await source.setPlayCount(5, for: "i9")
        let page = try await session.page(
            .init(sort: .init(field: .plays, direction: .descending), filters: filters),
            progress: { _, _ in })
        XCTAssertEqual(page.totalCount, 4)
        XCTAssertEqual(page.items.first?.id, "i9")
        let inventories = await source.inventoryRequests
        let technical = await source.technicalRequests
        XCTAssertEqual(inventories, 2, "The new metric must come from a fresh inventory")
        XCTAssertEqual(technical, 1, "Switching metrics must not repeat file hydration")

        await source.markWatched("i9")
        await session.invalidate(preservingFileFacts: true)
        let refreshed = try await session.page(.init(filters: filters), progress: { _, _ in })
        XCTAssertTrue(try XCTUnwrap(refreshed.items.first { $0.id == "i9" }).isPlayed)
        let afterWatch = await source.technicalRequests
        XCTAssertEqual(afterWatch, technical)
        await session.invalidate()
        _ = try await session.page(.init(filters: filters), progress: { _, _ in })
        let afterCatalog = await source.technicalRequests
        XCTAssertEqual(afterCatalog, technical + 1, "Catalog changes must discard cached file facts")
    }

    func testCompletedSeriesRewatchRetainsHistoricalWatchAndCurrentProgress() async throws {
        let parent = MediaItem(id: "s", title: "Series", kind: .series)
        let episode = MediaItem(
            id: "e", title: "Episode", kind: .episode, seasonNumber: 1, episodeNumber: 1,
            seriesID: "s", runtime: 100, resumePosition: 25, isPlayed: false,
            librarySortValues: .init(playCount: 2, watched: true))
        let source = QueryInventoryProvider(items: [parent], episodes: [episode])
        let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .series)
        let page = try await session.page(
            .init(sort: .init(field: .progress, direction: .descending), filters: .init(filter: .inProgress)),
            progress: { _, _ in })
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.playedPercentage, 0.25)
        XCTAssertFalse(item.isPlayed)
        XCTAssertTrue(item.hasBeenPlayed)
        XCTAssertEqual(item.librarySortValues?.watched, true)
        let unwatched = try await session.page(.init(filters: .init(filter: .unwatched)), progress: { _, _ in })
        XCTAssertTrue(unwatched.items.isEmpty)
    }

    func testCancellationStopsInventoryAndNextNativeQueryWorks() async throws {
        let source = QueryInventoryProvider(items: queryItems(300), delay: 50_000_000)
        let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .movie)
        let task = Task { try await session.page(.init(filters: .init(filter: .atmos)), progress: { _, _ in }) }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled query returned results") }
        catch { XCTAssertTrue(error is CancellationError) }
        let page = try await session.page(.init(limit: 10), progress: { _, _ in })
        XCTAssertEqual(page.items.count, 10)
        let count = await source.inventoryRequests
        XCTAssertLessThanOrEqual(count, 1)
    }

    func testConcurrentPagesShareOneInventoryAndGlobalMaterializationBound() async throws {
        let source = QueryInventoryProvider(items: queryItems(300), delay: 10_000_000)
        let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .movie)
        async let first = session.page(.init(limit: 9, filters: .init(filter: .atmos)), progress: { _, _ in })
        async let next = session.page(.init(startIndex: 9, limit: 9, filters: .init(filter: .atmos)), progress: { _, _ in })
        let pages = try await (first, next)
        XCTAssertEqual(pages.0.totalCount, 100)
        XCTAssertEqual(pages.1.totalCount, 100)
        let count = await source.inventoryRequests
        let maximum = await source.maximumMaterialization
        XCTAssertEqual(count, 3)
        XCTAssertLessThanOrEqual(maximum, 3)
    }

    func testSeriesRollupDeduplicatesFilesAndStampsMaterializedCard() async throws {
        let parent = MediaItem(id: "s", title: "Series", kind: .series)
        let episodes = [
            MediaItem(id: "e1a", title: "E1", kind: .episode, seasonNumber: 1, episodeNumber: 1,
                      seriesID: "s", isPlayed: true, librarySortValues: .init(playCount: 2)),
            MediaItem(id: "e1b", title: "E1 alternative", kind: .episode, seasonNumber: 1, episodeNumber: 1,
                      seriesID: "s", librarySortValues: .init(playCount: 1)),
            MediaItem(id: "e2", title: "E2", kind: .episode, seasonNumber: 1, episodeNumber: 2,
                      seriesID: "s", playedPercentage: 0.5, librarySortValues: .init(playCount: 0))
        ]
        let source = QueryInventoryProvider(items: [parent], episodes: episodes)
        let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .series)
        let page = try await session.page(.init(sort: .init(field: .progress, direction: .descending),
                                               filters: .init(filter: .inProgress)), progress: { _, _ in })
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.playedPercentage, 0.75)
        XCTAssertEqual(item.librarySortValues?.playCount, 2)
        XCTAssertFalse(item.isPlayed)
        XCTAssertTrue(item.hasBeenPlayed)
    }

    func testMixedMovieInventoryDoesNotTraverseEpisodesWhenThereAreNoSeries() async throws {
        let source = QueryInventoryProvider(items: queryItems(50))
        let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .unknown)
        _ = try await session.page(.init(filters: .init(filter: .atmos)), progress: { _, _ in })
        let count = await source.episodeRequests
        XCTAssertEqual(count, 0)
    }

    func testMemoryGuardRejectsOversizeInventory() async {
        let items = (0..<40).map { MediaItem(id: "\($0)", title: String(repeating: "x", count: 1_000_000), kind: .movie) }
        let source = QueryInventoryProvider(items: items)
        let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .movie)
        do {
            _ = try await session.page(.init(filters: .init(filter: .atmos)), progress: { _, _ in })
            XCTFail("Unbounded memory consumption")
        } catch LibraryQueryFailure.memoryBudget {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testWatchChangeInvalidatesOnlyWhenLibraryReturns() async throws {
        let name = "LibraryQuerySessionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let source = QueryInventoryProvider(items: queryItems(12))
        let model = LibraryBrowseViewModel(provider: source, containerID: "lib", containerKind: .movie,
                                           defaults: defaults, initialContentMode: .titles)
        await model.loadFirstPageIfNeeded()
        await model.setFilters(.init(filter: .unwatched))
        XCTAssertEqual(model.totalCount, 12)
        model.cancelPendingQuery()
        await source.markWatched("i0")
        model.applyWatchedState(.init(itemIDs: ["i0"], played: true))
        let before = await source.inventoryRequests
        await Task.yield()
        let unchanged = await source.inventoryRequests
        XCTAssertEqual(before, unchanged, "Covered libraries do not start a watch-change scan")
        await model.loadFirstPageIfNeeded()
        XCTAssertEqual(model.totalCount, 11)
    }

    func testNewProfileDoesNotInheritLegacySort() throws {
        let name = "LibraryQuerySessionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try JSONEncoder().encode(SortDescriptor(field: .runtime, direction: .descending)),
                     forKey: "LibraryBrowse.sort.movie")
        let source = QueryInventoryProvider(items: queryItems(12))
        let model = LibraryBrowseViewModel(provider: source, containerID: "lib", containerKind: .movie,
                                           defaults: defaults, initialContentMode: .titles, settingsNamespace: "new-profile")
        XCTAssertEqual(model.sort, .default)
    }

    func testLargeInventoryRunsOffMainAndKeepsNativePageSmall() async throws {
        let source = QueryInventoryProvider(items: queryItems(20_000))
        let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .movie)
        let start = Date()
        let page = try await session.page(.init(limit: 10, filters: .init(filter: .atmos)), progress: { _, _ in })
        XCTAssertEqual(page.totalCount, 6_667)
        XCTAssertEqual(page.items.count, 10)
        let onMain = await source.inventoryOnMain
        XCTAssertFalse(onMain)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "Compact linear inventory must not become quadratic")
    }
}

private func queryItems(_ count: Int) -> [MediaItem] {
    (0..<count).map {
        MediaItem(id: "i\($0)", title: "Title \(String(format: "%05d", $0))", kind: .movie,
                  productionYear: 2024, genres: ["Drama"], runtime: Double($0 + 1),
                  librarySortValues: .init(hasAtmos: $0 % 3 == 0))
    }
}

private actor QueryInventoryProvider: MediaLibraryQueryProviding {
    enum Broken { case emptyTail, repeatedIdentity, changedTotal }
    nonisolated let kind: ProviderKind = .mediaShare
    nonisolated let session = UserSession(
        server: MediaServer(id: "query-server", name: "Query", baseURL: URL(string: "https://query.test")!, provider: .mediaShare),
        userID: "user", userName: "User", deviceID: "device", accessToken: "test"
    )
    private var allItems: [MediaItem]
    private let episodes: [MediaItem]
    private let broken: Broken?
    private let delay: UInt64
    private let facets: LibraryQueryFacets
    private let supportsFacets: Bool
    private var facetError: AppError?
    private(set) var facetRequests = 0
    private(set) var inventoryRequests = 0
    private(set) var technicalRequests = 0
    private(set) var episodeRequests = 0
    private(set) var inventoryOnMain = false
    private var materializing = 0
    private(set) var maximumMaterialization = 0

    init(items: [MediaItem], episodes: [MediaItem] = [], broken: Broken? = nil, delay: UInt64 = 0,
         facets: LibraryQueryFacets = .init(genres: ["Drama"], years: [2024]), supportsFacets: Bool = true) {
        allItems = items
        self.episodes = episodes
        self.broken = broken
        self.delay = delay
        self.facets = facets
        self.supportsFacets = supportsFacets
    }

    nonisolated func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] { SortField.allCases }
    nonisolated func libraryQueryCapabilities(in containerID: String, kind: MediaItemKind) -> LibraryQueryCapabilities {
        .init(filters: LibraryFilter.allCases, nativeSortFields: [.name],
              supportsGenres: supportsFacets, supportsYears: supportsFacets)
    }
    nonisolated func libraryQueryInventorySortKey(_ field: SortField) -> SortField {
        [.plays, .lastPlayed].contains(field) ? field : .name
    }
    func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws -> LibraryQueryFacets {
        facetRequests += 1
        if let facetError { throw facetError }
        return facets
    }
    func setFacetError(_ value: AppError?) { facetError = value }
    func libraryQueryInventory(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        inventoryRequests += 1
        inventoryOnMain = inventoryOnMain || Thread.isMainThread
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        var result = slice(allItems, page)
        if page.filters.filter.needsFileMetadata {
            technicalRequests += 1
        } else {
            result.items = result.items.map { item in
                var copy = item
                copy.librarySortValues?.hasAtmos = nil
                return copy
            }
        }
        if page.startIndex > 0 {
            switch broken {
            case .emptyTail: result = .init(items: [], startIndex: page.startIndex, totalCount: allItems.count)
            case .repeatedIdentity: result.items = Array(allItems.prefix(result.items.count))
            case .changedTotal: result.totalCount += 1
            case nil: break
            }
        }
        return result
    }
    func libraryQueryEpisodeInventory(in containerID: String, page: PageRequest) async throws -> MediaPage {
        episodeRequests += 1
        return slice(episodes, page)
    }
    func markWatched(_ id: String) {
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return }
        allItems[index].isPlayed = true
        allItems[index].librarySortValues?.watched = true
    }
    func setPlayCount(_ count: Int, for id: String) {
        guard let index = allItems.firstIndex(where: { $0.id == id }) else { return }
        allItems[index].librarySortValues?.playCount = count
    }
    private func slice(_ items: [MediaItem], _ page: PageRequest) -> MediaPage {
        .init(items: Array(items.dropFirst(page.startIndex).prefix(page.limit)), startIndex: page.startIndex, totalCount: items.count)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        materializing += 1
        maximumMaterialization = max(maximumMaterialization, materializing)
        defer { materializing -= 1 }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        guard let item = allItems.first(where: { $0.id == id }) else { throw AppError.notFound }
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { slice(allItems, page) }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
