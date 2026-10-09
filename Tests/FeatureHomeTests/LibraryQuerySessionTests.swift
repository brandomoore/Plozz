import CoreModels
import Foundation
import XCTest
@testable import FeatureHomeCore
@testable import FeatureHome

@MainActor
final class LibraryQuerySessionTests: XCTestCase {
    func testConcurrentFirstPagesShareOfflineRecovery() async throws {
        let lost = QueryInventoryProvider(items: queryItems(1), delay: 5_000_000)
        let healthy = QueryInventoryProvider(items: queryItems(10))
        await lost.failInventoryAfter(1)
        let provider = AggregatedLibraryProvider(sources: [
            .init(accountID: "lost", containerID: "movies", provider: lost, kind: .movie),
            .init(accountID: "healthy", containerID: "movies", provider: healthy, kind: .movie)
        ])
        let session = LibraryQuerySession(provider: provider, containerID: "all", kind: .unknown)
        let request = PageRequest(sort: .init(field: .year, direction: .ascending))
        async let first = session.page(request, progress: { _, _ in })
        async let second = session.page(request, progress: { _, _ in })
        let results = try await [first, second]
        XCTAssertEqual(results.map(\.totalCount), [10, 10])
        XCTAssertTrue(results.flatMap(\.items).allSatisfy { $0.sourceAccountID == "healthy" })
        let requests = await lost.inventoryRequests
        XCTAssertEqual(requests, 2)
    }

    func testUnpublishedAggregateQueryRestartsWithoutMidInventoryOrHydrationOutage() async throws {
        for outageDuringHydration in [false, true] {
            let lost = QueryInventoryProvider(items: [
                MediaItem(id: "lost", title: "Lost", kind: .movie, productionYear: 2000)
            ], serverID: "lost", serverName: "Unavailable")
            let healthy = QueryInventoryProvider(items: queryItems(125))
            if outageDuringHydration {
                await lost.setHydrationFailure(.serverUnreachable)
            } else {
                await lost.failInventoryAfter(1)
            }
            // Two libraries on one account must remain independent.
            let provider = AggregatedLibraryProvider(sources: [
                .init(accountID: "same", containerID: "lost", provider: lost, kind: .movie),
                .init(accountID: "same", containerID: "healthy", provider: healthy, kind: .movie)
            ])
            let session = LibraryQuerySession(provider: provider, containerID: "all", kind: .unknown)
            let sort = CoreModels.SortDescriptor(field: .year, direction: .ascending)
            let first = try await session.page(.init(limit: 20, sort: sort), progress: { _, _ in })
            XCTAssertEqual(first.totalCount, 125)
            XCTAssertEqual(first.items.count, 20)
            XCTAssertFalse(first.items.contains { $0.id == "lost" })
            let last = try await session.page(.init(startIndex: 120, limit: 20, sort: sort), progress: { _, _ in })
            XCTAssertEqual(last.items.count, 5)
            XCTAssertEqual(last.totalCount, 125)
            let requests = await lost.inventoryRequests
            XCTAssertLessThanOrEqual(requests, 2)
            await lost.failInventoryAfter(nil)
            await lost.setHydrationFailure(nil)
            await session.invalidate()
            let recovered = try await session.page(.init(limit: 20, sort: sort), progress: { _, _ in })
            XCTAssertEqual(recovered.totalCount, 126)
            XCTAssertEqual(recovered.items.first?.id, "lost")
        }
    }

    func testAllOfflineDuringHydrationRemainsRetryableAndPreservesSourceAttribution() async throws {
        let first = QueryInventoryProvider(items: queryItems(1), serverID: "first", serverName: "First")
        let second = QueryInventoryProvider(items: queryItems(1), serverID: "second", serverName: "Second")
        await first.setHydrationFailure(.serverUnreachable)
        await second.setHydrationFailure(.serverUnreachable)
        let provider = AggregatedLibraryProvider(sources: [
            .init(accountID: "a", containerID: "movies", provider: first, kind: .movie),
            .init(accountID: "b", containerID: "movies", provider: second, kind: .movie)
        ])
        let session = LibraryQuerySession(provider: provider, containerID: "all", kind: .unknown)
        do {
            _ = try await session.page(.init(sort: .init(field: .year, direction: .ascending)), progress: { _, _ in })
            XCTFail("No healthy source cannot be an empty success")
        } catch {
            let failure = try XCTUnwrap(error as? LibrarySourceFailure)
            XCTAssertEqual(failure.underlyingError as? AppError, .serverUnreachable)
            XCTAssertFalse(failure.servers.isEmpty)
        }
    }

    func testFailedLibraryIdentifiesItsServerAndClearsTheChipOnRetry() async {
        let source = QueryInventoryProvider(items: queryItems(1), serverID: "plex", serverName: "Living Room")
        await source.setFailure(.serverUnreachable)
        let model = LibraryBrowseViewModel(
            provider: source, containerID: "movies", containerKind: .movie, initialContentMode: .titles)
        await model.loadFirstPage()
        XCTAssertEqual(model.state, .failed(.serverUnreachable))
        XCTAssertEqual(model.errorServers.map(\.name), ["Living Room"])
        await source.setFailure(nil)
        await model.loadFirstPage()
        XCTAssertTrue(model.errorServers.isEmpty)
    }

    func testAllOfflineIdentifiesEveryFailedServerInsteadOfOnlyTheFirstProvider() async {
        let first = QueryInventoryProvider(items: [], serverID: "first", serverName: "Living Room")
        let second = QueryInventoryProvider(items: [], serverID: "second", serverName: "Bedroom")
        await first.setFailure(.serverUnreachable)
        await second.setFailure(.serverUnreachable)
        let provider = AggregatedLibraryProvider(sources: [
            .init(accountID: "a", containerID: "movies", provider: first, kind: .movie),
            .init(accountID: "a", containerID: "shows", provider: first, kind: .series),
            .init(accountID: "b", containerID: "movies", provider: second, kind: .movie)
        ])
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "all", containerKind: .unknown, initialContentMode: .titles)
        await model.loadFirstPage()
        XCTAssertEqual(model.state, .failed(.serverUnreachable))
        XCTAssertEqual(model.errorServers.map(\.name), ["Living Room", "Bedroom"])
    }

    func testAggregateKeepsHealthyQueriesWhenAnotherSourceIsOfflineAndRecovers() async throws {
        let offline = QueryInventoryProvider(items: [
            MediaItem(id: "offline", title: "Offline", kind: .movie, productionYear: 2025)
        ])
        let healthy = QueryInventoryProvider(items: queryItems(125))
        await offline.setFailure(.serverUnreachable)
        let provider = AggregatedLibraryProvider(sources: [
            .init(accountID: "offline", containerID: "movies", provider: offline, kind: .movie),
            .init(accountID: "healthy", containerID: "movies", provider: healthy, kind: .movie)
        ])
        try await provider.prepareLibraryQueryCapabilities()
        let facets = try await provider.libraryQueryFacets(in: "all", kind: .unknown)
        XCTAssertEqual(facets.genres, ["Drama"])
        let session = LibraryQuerySession(provider: provider, containerID: "all", kind: .unknown)
        let request = PageRequest(limit: 20, sort: .init(field: .year, direction: .ascending))
        let first = try await session.page(request, progress: { _, _ in })
        XCTAssertEqual(first.totalCount, 125)
        XCTAssertEqual(first.items.count, 20)
        XCTAssertTrue(first.items.allSatisfy { $0.sourceAccountID == "healthy" })
        let last = try await session.page(
            .init(startIndex: 120, limit: 20, sort: request.sort), progress: { _, _ in })
        XCTAssertEqual(last.items.count, 5)
        await offline.setFailure(nil)
        await session.invalidate()
        let recovered = try await session.page(request, progress: { _, _ in })
        XCTAssertEqual(recovered.totalCount, 126)
    }

    func testAggregateAllOfflineIsRetryableInsteadOfEmptyAndCancellationPropagates() async throws {
        let source = QueryInventoryProvider(items: queryItems(1))
        let provider = AggregatedLibraryProvider(sources: [
            .init(accountID: "owner", containerID: "movies", provider: source, kind: .movie)
        ])
        for failure in [AppError.serverUnreachable, .cancelled] {
            await source.setFailure(failure)
            for operation in 0..<3 {
                do {
                    switch operation {
                    case 0: try await provider.prepareLibraryQueryCapabilities()
                    case 1: _ = try await provider.libraryQueryFacets(in: "all", kind: .unknown)
                    default: _ = try await provider.libraryQueryInventory(
                        in: "all", kind: .unknown, page: .init())
                    }
                    XCTFail("A failed source is not an empty library")
                } catch {
                    if failure == .cancelled { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertEqual(LibrarySourceFailure.underlying(error) as? AppError, failure) }
                }
            }
        }
        await source.setFailure(nil)
        let recovered = try await provider.libraryQueryInventory(in: "all", kind: .unknown, page: .init())
        XCTAssertEqual(recovered.totalCount, 1)
    }

    func testAggregateHydratesReachableDuplicateWhenOtherCopyIsOffline() async throws {
        let source = QueryInventoryProvider(items: queryItems(1))
        let offline = QueryInventoryProvider(items: [])
        await offline.setFailure(.serverUnreachable)
        let provider = AggregatedLibraryProvider(sources: [
            .init(accountID: "offline", containerID: "movies", provider: offline),
            .init(accountID: "healthy", containerID: "movies", provider: source)
        ])
        let item = try await provider.libraryQueryItem(.init(id: "i0", sources: [
            .init(accountID: "offline", itemID: "i0"),
            .init(accountID: "healthy", itemID: "i0")
        ]))
        XCTAssertEqual(item.sourceAccountID, "healthy")
        XCTAssertFalse(item.sources.contains { $0.accountID == "offline" })
    }

    func testDuplicatesIgnoreOutOfScopeSourcesButRetainActualVersions() async throws {
        for otherAccount in ["active", "excluded"] {
            for versions: [MediaVersion] in [[], [.init(id: "1080p"), .init(id: "2160p")]] {
                let item = MediaItem(id: "movie", title: "Movie", kind: .movie,
                                     providerIDs: ["Tmdb": "1"], versions: versions)
                let source = QueryInventoryProvider(items: [item])
                let provider = AggregatedLibraryProvider(
                    sources: [.init(accountID: "active", containerID: "library", provider: source, kind: .movie)],
                    identitySources: { _ in [
                        MediaSourceRef(accountID: "active", itemID: "movie", kind: .movie),
                        MediaSourceRef(accountID: otherAccount, itemID: "other-copy", kind: .movie)
                    ] }
                )
                let records = provider.libraryQueryMergeInventory([LibraryQueryRecord(item.taggingSource("active"))])
                XCTAssertEqual(records.count, 1)
                XCTAssertEqual(records.first?.reference.sources.count, 1)
                let session = LibraryQuerySession(provider: provider, containerID: "library", kind: .movie)
                let page = try await session.page(.init(filters: .init(filter: .duplicates)), progress: { _, _ in })
                XCTAssertEqual(page.items.count, versions.count > 1 ? 1 : 0)
            }
        }
    }

    func testDuplicatesIncludeSeparateFilesOnlyForTheSameLogicalEpisode() async throws {
        for secondSeason in [1, 2] {
            let series = MediaItem(id: "s", title: "Series", kind: .series)
            let episodes = [
                MediaItem(id: "f:Show/S01E01.1080p.mkv", title: "Episode", kind: .episode,
                          seasonNumber: 1, episodeNumber: 1, seriesID: "s"),
                MediaItem(id: "f:Show/S0\(secondSeason)E01.2160p.mkv", title: "Episode", kind: .episode,
                          seasonNumber: secondSeason, episodeNumber: 1, seriesID: "s")
            ]
            let source = QueryInventoryProvider(items: [series], episodes: episodes)
            let session = LibraryQuerySession(provider: source, containerID: "tv", kind: .series)
            let page = try await session.page(.init(filters: .init(filter: .duplicates)), progress: { _, _ in })
            let episodeRequests = await source.episodeRequests
            XCTAssertEqual(episodeRequests, 1)
            XCTAssertEqual(page.items.map(\.id), secondSeason == 1 ? ["s"] : [])
        }
    }

    func testCatalogRefreshReloadsCachedFacetsAndSurfacesFailures() async throws {
        let source = QueryInventoryProvider(items: queryItems(2), facets: .init())
        let model = LibraryBrowseViewModel(
            provider: source, containerID: "facet-refresh", containerKind: .movie, initialContentMode: .titles)
        await model.loadFirstPageIfNeeded()
        await model.loadQueryFacetsIfNeeded()
        XCTAssertEqual(model.queryFacets, .init())
        await source.setFacets(.init(genres: ["Drama"], years: [2024]))
        await model.refreshAfterCatalogChange()
        XCTAssertEqual(model.queryFacets, .init(genres: ["Drama"], years: [2024]))
        await source.setFacetError(.serverUnreachable)
        await model.refreshAfterCatalogChange()
        XCTAssertEqual(model.facetsError, .serverUnreachable)
        XCTAssertEqual(model.queryFacets.genres, ["Drama"])
        await source.setFacetError(nil)
        await model.loadQueryFacetsIfNeeded(retry: true)
        XCTAssertNil(model.facetsError)
    }

    func testWatchRefreshKeepsCachedFacets() async {
        let source = QueryInventoryProvider(items: queryItems(2))
        let model = LibraryBrowseViewModel(
            provider: source, containerID: "facet-watch-refresh", containerKind: .movie, initialContentMode: .titles)
        await model.loadFirstPageIfNeeded()
        await model.loadQueryFacetsIfNeeded()
        await source.setFacetError(.serverUnreachable)
        await model.refreshAfterCatalogChange(preservingFileFacts: true)
        await model.loadQueryFacetsIfNeeded()
        let requests = await source.facetRequests
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(model.queryFacets, .init(genres: ["Drama"], years: [2024]))
        XCTAssertNil(model.facetsError)
    }

    func testFacetCallersShareResultsAfterTheOriginalCallerIsCancelled() async {
        for error: AppError? in [nil, .serverUnreachable] {
            let source = QueryInventoryProvider(items: [])
            let model = LibraryBrowseViewModel(
                provider: source, containerID: "facet-reentry", containerKind: .movie, initialContentMode: .titles)
            await source.setFacetError(error)
            await source.holdNextFacetRequest()
            let previous = Task { await model.loadQueryFacetsIfNeeded() }
            await source.waitForHeldFacetRequest()
            previous.cancel()
            let release = Task { await source.releaseFacetRequest() }
            await model.loadQueryFacetsIfNeeded()
            await release.value
            await previous.value
            let requests = await source.facetRequests
            XCTAssertEqual(requests, 1)
            XCTAssertFalse(model.facetsLoading)
            XCTAssertEqual(model.facetsError, error)
            if error == nil {
                XCTAssertEqual(model.queryFacets, .init(genres: ["Drama"], years: [2024]))
            } else {
                await source.setFacetError(nil)
                await model.loadQueryFacetsIfNeeded(retry: true)
                XCTAssertNil(model.facetsError)
                XCTAssertEqual(model.queryFacets, .init(genres: ["Drama"], years: [2024]))
                let retried = await source.facetRequests
                XCTAssertEqual(retried, 2)
            }
        }
    }

    func testPreRefreshFacetResponsesCannotOverwriteNewerOptionsOrErrors() async {
        for oldError: AppError? in [nil, .serverUnreachable] {
            let source = QueryInventoryProvider(items: queryItems(2), facets: .init())
            let model = LibraryBrowseViewModel(
                provider: source, containerID: "facet-race", containerKind: .movie, initialContentMode: .titles)
            await model.loadFirstPageIfNeeded()
            await source.setFacetError(oldError)
            await source.holdNextFacetRequest()
            let pending = Task { await model.loadQueryFacetsIfNeeded() }
            await source.waitForHeldFacetRequest()
            await source.setFacetError(nil)
            await source.setFacets(.init(genres: ["Drama"], years: [2024]))
            await model.refreshAfterCatalogChange()
            XCTAssertEqual(model.queryFacets, .init(genres: ["Drama"], years: [2024]))
            await source.releaseFacetRequest()
            await pending.value
            XCTAssertEqual(model.queryFacets, .init(genres: ["Drama"], years: [2024]))
            XCTAssertNil(model.facetsError)
            XCTAssertFalse(model.facetsLoading)
        }
    }

    func testFilteredAlphabetOffsetsMatchActualOrderingInBothDirections() async throws {
        let source = QueryInventoryProvider(items: ["Alpha", "Bravo", "中文", "2 Fast", "Éclair", "Zulu"].map {
            MediaItem(id: $0, title: $0, kind: .movie)
        })
        let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .movie)
        for direction: SortDirection in [.ascending, .descending] {
            let request = PageRequest(sort: .init(field: .name, direction: direction), filters: .init(filter: .unwatched))
            let page = try await session.page(request, progress: { _, _ in })
            let entries = try await session.letterIndex(page: request)
            XCTAssertEqual(entries.count, 5)
            XCTAssertEqual(entries.compactMap(\.startIndex), entries.compactMap(\.startIndex).sorted())
            for entry in entries {
                let actual = try XCTUnwrap(page.items.firstIndex { MediaItemSortOrder.alphabetBucket(for: $0) == entry.letter })
                XCTAssertEqual(entry.startIndex, actual)
                let resolved = try await session.letterPosition(entry.letter, page: request)
                XCTAssertEqual(resolved, actual)
            }
        }
    }

    func testMaterializesIdentityIndexMergedTitleWithoutAddingUnscopedSources() async throws {
        let a = MediaItem(id: "a", title: "Dune", kind: .movie, productionYear: 2021,
                          providerIDs: ["Tmdb": "438631"], librarySortValues: .init(hasAtmos: true))
        let b = MediaItem(id: "b", title: "Dune", kind: .movie, productionYear: 2021,
                          librarySortValues: .init(hasAtmos: true))
        let first = QueryInventoryProvider(items: [a])
        let second = QueryInventoryProvider(items: [b])
        let refs = [MediaSourceRef(accountID: "a", itemID: "a", kind: .movie),
                    MediaSourceRef(accountID: "b", itemID: "b", kind: .movie),
                    MediaSourceRef(accountID: "foreign", itemID: "outside", kind: .movie)]
        let provider = AggregatedLibraryProvider(sources: [
            .init(accountID: "a", containerID: "first", provider: first, kind: .movie),
            .init(accountID: "b", containerID: "second", provider: second, kind: .movie)
        ], identitySources: { _ in refs })
        let records = provider.libraryQueryMergeInventory([
            LibraryQueryRecord(a.taggingSource("a")), LibraryQueryRecord(b.taggingSource("b"))
        ])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.reference.sources.count, 2)
        let session = LibraryQuerySession(provider: provider, containerID: "all", kind: .movie)
        let page = try await session.page(.init(filters: .init(filter: .atmos)), progress: { _, _ in })
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.sources.count, 2)
        XCTAssertEqual(Set(try XCTUnwrap(page.items.first).allSourceAccountIDs), ["a", "b"])
    }

    func testDuplicatesIncludesSameAccountCopies() async throws {
        let a = MediaItem(id: "a", title: "Dune", kind: .movie, productionYear: 2021,
                          providerIDs: ["Tmdb": "438631"])
        let b = MediaItem(id: "b", title: "Dune", kind: .movie, productionYear: 2021,
                          providerIDs: ["Tmdb": "438631"])
        let source = QueryInventoryProvider(items: [a, b])
        let provider = AggregatedLibraryProvider(sources: [
            .init(accountID: "account", containerID: "library", provider: source, kind: .movie)
        ])
        let records = provider.libraryQueryMergeInventory([
            LibraryQueryRecord(a.taggingSource("account")), LibraryQueryRecord(b.taggingSource("account"))
        ])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.reference.sources.count, 2)
        let session = LibraryQuerySession(provider: provider, containerID: "all", kind: .movie)
        let page = try await session.page(.init(filters: .init(filter: .duplicates)), progress: { _, _ in })
        XCTAssertEqual(page.items.count, 1)
    }

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

    func testRandomFallbackRemainsStableAndCompleteAcrossMultiplePages() async throws {
        let source = QueryInventoryProvider(items: queryItems(300))
        let session = LibraryQuerySession(provider: source, containerID: "lib", kind: .movie)
        let sort = SortDescriptor(field: .random, direction: .descending)
        let filters = LibraryFilters(filter: .atmos)
        var ids: [String] = []
        for start in stride(from: 0, to: 100, by: 17) {
            let page = try await session.page(
                .init(startIndex: start, limit: 17, sort: sort, filters: filters), progress: { _, _ in })
            XCTAssertEqual(page.totalCount, 100)
            ids += page.items.map(\.id)
        }
        XCTAssertEqual(ids.count, 100)
        XCTAssertEqual(Set(ids), Set(stride(from: 0, to: 300, by: 3).map { "i\($0)" }))
        let again = try await session.page(.init(limit: 17, sort: sort, filters: filters), progress: { _, _ in })
        XCTAssertEqual(again.items.map(\.id), Array(ids.prefix(17)))
        let requests = await source.inventoryRequests
        XCTAssertEqual(requests, 3)
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
    nonisolated let session: UserSession
    private var allItems: [MediaItem]
    private let episodes: [MediaItem]
    private let broken: Broken?
    private let delay: UInt64
    private var facets: LibraryQueryFacets
    private let supportsFacets: Bool
    private var facetError: AppError?
    private var failure: AppError?
    private var hydrationFailure: AppError?
    private var maximumInventoryRequests: Int?
    private var holdsNextFacetRequest = false
    private var heldFacetRequest: CheckedContinuation<Void, Never>?
    private var heldFacetObserver: CheckedContinuation<Void, Never>?
    private(set) var facetRequests = 0
    private(set) var inventoryRequests = 0
    private(set) var technicalRequests = 0
    private(set) var episodeRequests = 0
    private(set) var inventoryOnMain = false
    private var materializing = 0
    private(set) var maximumMaterialization = 0

    init(items: [MediaItem], episodes: [MediaItem] = [], broken: Broken? = nil, delay: UInt64 = 0,
         facets: LibraryQueryFacets = .init(genres: ["Drama"], years: [2024]), supportsFacets: Bool = true,
         serverID: String = "query-server", serverName: String = "Query") {
        session = UserSession(
            server: MediaServer(id: serverID, name: serverName, baseURL: URL(string: "https://query.test")!, provider: .mediaShare),
            userID: "user", userName: "User", deviceID: "device", accessToken: "test")
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
    func setFailure(_ value: AppError?) { failure = value }
    func setHydrationFailure(_ value: AppError?) { hydrationFailure = value }
    func failInventoryAfter(_ value: Int?) { maximumInventoryRequests = value }
    func prepareLibraryQueryCapabilities() async throws {
        if let failure { throw failure }
    }
    func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws -> LibraryQueryFacets {
        if let failure { throw failure }
        facetRequests += 1
        let snapshot = facets
        let error = facetError
        if holdsNextFacetRequest {
            holdsNextFacetRequest = false
            await withCheckedContinuation {
                heldFacetRequest = $0
                heldFacetObserver?.resume()
                heldFacetObserver = nil
            }
        }
        if let error { throw error }
        return snapshot
    }
    func setFacetError(_ value: AppError?) { facetError = value }
    func setFacets(_ value: LibraryQueryFacets) { facets = value }
    func holdNextFacetRequest() { holdsNextFacetRequest = true }
    func waitForHeldFacetRequest() async {
        guard heldFacetRequest == nil else { return }
        await withCheckedContinuation { heldFacetObserver = $0 }
    }
    func releaseFacetRequest() {
        heldFacetRequest?.resume()
        heldFacetRequest = nil
    }
    func libraryQueryInventory(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        if let failure { throw failure }
        inventoryRequests += 1
        if let maximumInventoryRequests, inventoryRequests > maximumInventoryRequests {
            throw AppError.serverUnreachable
        }
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
        if let failure { throw failure }
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
        if let failure { throw failure }
        if let hydrationFailure { throw hydrationFailure }
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
