import CoreModels
import CoreNetworking
import FeatureHomeCore
import XCTest

@MainActor
final class LibraryCollectionModeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsName: String!

    private func submittedLibraryRecords(scope: DiagnosticExportScope) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(LibraryDiagnosticJournal.shared.export(scope: scope))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(body["entries"] as? [[String: Any]])
    }

    func testSharedTabArrangementReconcilesSelectionWithoutChangingProviderCapabilities() async {
        for providerKind: ProviderKind in [.plex, .jellyfin, .emby, .silo] {
            let settings = LibraryPresentationSettingsModel(
                store: LibraryPresentationSettingsStore(defaults: defaults, namespace: providerKind.rawValue)
            )
            settings.settings.navigation = .init(
                order: ["collections", "recommended", "titles", "playlists"], hidden: ["playlists"]
            )
            let provider = LibraryModeProvider(kind: providerKind, supportsPlaylists: true)
            let model = LibraryBrowseViewModel(
                provider: provider, containerID: "real-library", containerKind: .movie,
                defaults: defaults, sourceAccountID: "owning-account", presentation: settings
            )
            XCTAssertEqual(model.contentMode, .collections)
            XCTAssertEqual(model.availableContentModes, [.collections, .recommended, .titles])
            XCTAssertTrue(model.supportsPlaylists)
            settings.settings.navigation.hidden.insert("collections")
            await model.reconcileContentMode()
            XCTAssertEqual(model.contentMode, .recommended)
            settings.settings.navigation.hidden.insert("recommended")
            settings.settings.navigation.hidden.insert("titles")
            await model.reconcileContentMode()
            XCTAssertEqual(model.availableContentModes, [.titles])
            XCTAssertEqual(model.contentMode, .titles)
            let member = LibraryBrowseViewModel(
                provider: provider, containerID: "collection", containerKind: .collection,
                defaults: defaults, browseScope: .collectionMembers, presentation: settings
            )
            XCTAssertEqual(member.availableContentModes, [.titles])
            XCTAssertEqual(member.contentMode, .titles)
        }
    }

    func testRecommendedArrangementIsLocalOnlyAndPreservesHiddenRowsForRestoration() async throws {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        let provider = LibraryModeProvider(nativeSections: [
            .init(id: "discovery", title: "Discovery", items: [item])
        ])
        let model = model(provider)
        await model.loadRecommendationsIfNeeded()
        let rows = try XCTUnwrap(model.recommendationState.value)
        let hub = try XCTUnwrap(rows.first { $0.id.hasPrefix("hub:") })
        let requests = await provider.requestedHubLibraries.count
        model.presentation.settings.recommendedRows[model.recommendedRowsAddress] = .init(
            order: ["recentlyAdded", hub.id], hidden: [hub.id]
        )
        XCTAssertEqual(model.visibleRecommendedRows(rows).map(\.id), ["recentlyAdded"])
        XCTAssertEqual(model.recommendationState.value, rows)
        model.presentation.settings.recommendedRows[model.recommendedRowsAddress]?.hidden.remove(hub.id)
        XCTAssertEqual(model.visibleRecommendedRows(rows).map(\.id), ["recentlyAdded", hub.id])
        let remainingRequests = await provider.requestedHubLibraries.count
        XCTAssertEqual(remainingRequests, requests, "Reordering must not refetch recommendations.")
        let other = LibraryBrowseViewModel(
            provider: provider, containerID: "another-library", containerKind: .movie,
            defaults: defaults, sourceAccountID: "owning-account", presentation: model.presentation
        )
        XCTAssertEqual(other.visibleRecommendedRows(rows), rows)
    }

    override func setUp() async throws {
        try await super.setUp()
        defaultsName = "LibraryCollectionModeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsName)
        defaults = nil
        try await super.tearDown()
    }

    func testOnlyCapableMovieAndSeriesLibrariesOfferCollections() async {
        for kind: MediaItemKind in [.movie, .series, .collection, .folder, .unknown, .season] {
            for supported in [false, true] {
                let provider = LibraryModeProvider(supportsCollections: supported)
                let model = model(provider, kind: kind)
                let expected = supported && (kind == .movie || kind == .series)
                XCTAssertEqual(model.supportsCollections, expected)
                let initial: LibraryContentMode = kind == .movie || kind == .series ? .recommended : .titles
                XCTAssertEqual(model.contentMode, initial)
                await model.setContentMode(.collections)
                XCTAssertEqual(model.contentMode, expected ? .collections : initial)
                let requests = await provider.requests
                XCTAssertEqual(requests.count, expected ? 1 : 0)
            }
        }
    }

    func testEveryBackendUsesLibraryScopedCollectionsAndStartsInRecommended() async {
        for kind: ProviderKind in [.plex, .jellyfin, .emby, .silo] {
            let provider = LibraryModeProvider(kind: kind)
            let model = model(provider)
            XCTAssertEqual(model.contentMode, .recommended)
            XCTAssertEqual(model.availableContentModes.first, .recommended)
            await model.setContentMode(.titles)
            XCTAssertEqual(model.item(at: 0)?.kind, .movie)
            await model.setContentMode(.collections)
            XCTAssertEqual(model.item(at: 0)?.kind, .collection)
            XCTAssertEqual(model.item(at: 0)?.sourceAccountID, "owning-account")
            let requests = await provider.requests
            XCTAssertEqual(requests.map(\.mode), [.titles, .collections])
            XCTAssertEqual(requests.map(\.containerID), ["real-library", "real-library"])
            XCTAssertEqual(requests.map(\.kind), [.movie, .collection])
            XCTAssertEqual(requests.map(\.page.startIndex), [0, 0])
        }
    }

    func testRecommendedRowsStayScopedAndHaveDistinctPresentationIDs() async {
        let watching = MediaItem(id: "watching", title: "Watching", kind: .movie)
            .taggingLibrary("real-library")
        let hubItem = MediaItem(id: "suggested", title: "Suggested", kind: .movie)
        let provider = LibraryModeProvider(
            watchingItems: [watching, watching.taggingLibrary("other-library")],
            nativeSections: [
                LibrarySection(id: "recentlyAdded", title: "For You", localizedTitle: "Recommended",
                               localizedTitleSuffix: " · Cinema", items: [hubItem]),
                LibrarySection(id: "recentlyAdded", title: "More For You", items: [hubItem])
            ]
        )
        let model = model(provider)
        await model.loadFirstPageIfNeeded()

        guard case .loaded(let sections) = model.recommendationState else {
            return XCTFail("Expected scoped recommendation rows")
        }
        XCTAssertEqual(sections.map(\.title), ["Continue Watching", "For You", "More For You", "Recently Added"])
        XCTAssertEqual(sections[0].localizedTitle, LocalizedStringResource("Continue Watching"))
        XCTAssertEqual(sections[1].localizedTitle, LocalizedStringResource("Recommended"))
        XCTAssertEqual(sections[1].localizedTitleSuffix, " · Cinema")
        XCTAssertNil(sections[2].localizedTitle)
        XCTAssertEqual(sections[3].localizedTitle, LocalizedStringResource("Recently Added"))
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
        XCTAssertEqual(sections.first?.items.map(\.id), ["watching"])
        XCTAssertTrue(sections.flatMap(\.items).allSatisfy { $0.sourceAccountID == "owning-account" })
        XCTAssertEqual(sections[1].items.first?.libraryID, "real-library")
        let requestedLibraries = await provider.requestedWatchingLibraries
        let requestedHubs = await provider.requestedHubLibraries
        let firstRequest = await provider.requests.first
        XCTAssertEqual(requestedLibraries, [["real-library"]])
        XCTAssertEqual(requestedHubs, ["real-library"])
        XCTAssertEqual(firstRequest?.page.sort.field, .dateAdded)
    }

    func testRepeatedHubIdentifiersRemainStableWhenAnEarlierHubDisappears() async throws {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        let earlier = LibrarySection(id: "shared", title: "Earlier", items: [item])
        let remaining = LibrarySection(id: "shared", title: "Remaining", items: [item])
        let provider = LibraryModeProvider(nativeSections: [earlier, remaining, remaining])
        let model = model(provider)
        await model.loadRecommendationsIfNeeded()
        let sections = try XCTUnwrap(model.recommendationState.value)
        let original = sections.filter { $0.title == "Remaining" }.map(\.id)
        XCTAssertEqual(original.count, 2)
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
        await provider.setNativeSections([remaining, remaining])
        await model.loadRecommendations()
        XCTAssertEqual(model.recommendationState.value?.filter { $0.title == "Remaining" }.map(\.id), original)
    }

    func testLocalizedHubPresentationDoesNotChangeItsIdentity() async throws {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        var resource: LocalizedStringResource = "Recommended"
        resource.locale = Locale(identifier: "de")
        let provider = LibraryModeProvider(nativeSections: [
            LibrarySection(id: "stable", title: "Recommended", localizedTitle: resource, items: [item])
        ])
        let model = model(provider)
        await model.loadRecommendationsIfNeeded()
        let original = try XCTUnwrap(model.recommendationState.value?.first { $0.title == "Recommended" })
        resource.locale = Locale(identifier: "fr")
        await provider.setNativeSections([
            LibrarySection(id: "stable", title: "Recommended", localizedTitle: resource, items: [item])
        ])
        await model.loadRecommendations()
        let updated = try XCTUnwrap(model.recommendationState.value?.first { $0.title == "Recommended" })
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.localizedTitle, resource)
    }

    func testRecommendationFailurePreservesOtherRowsAndCanRetry() async {
        let provider = LibraryModeProvider(failHubs: true)
        let model = model(provider)
        await model.loadFirstPageIfNeeded()
        XCTAssertEqual(model.recommendationError, .serverUnreachable)
        guard case .loaded(let sections) = model.recommendationState else {
            return XCTFail("Recent titles should survive a hub failure")
        }
        XCTAssertEqual(sections.map(\.id), ["recentlyAdded"])

        await provider.setFailHubs(false)
        await model.loadRecommendations()
        XCTAssertNil(model.recommendationError)
        XCTAssertNotNil(model.recommendationState.value)
    }

    func testRecommendationDecodingFailureIdentifiesTheFailedSectionForEveryProvider() async throws {
        for kind: ProviderKind in [.jellyfin, .emby, .plex, .silo] {
            let watching = MediaItem(id: "watching", title: "Watching", kind: .movie, libraryID: "real-library")
            let provider = LibraryModeProvider(kind: kind, watchingItems: [watching])
            await provider.setHubError(.decoding)
            let model = model(provider)
            let scope = DiagnosticExportScope()
            let previous = Set(try submittedLibraryRecords(scope: scope).compactMap { $0["record"] as? String })
            await model.loadFirstPageIfNeeded()
            XCTAssertEqual(model.recommendationState.value?.map(\.id), ["continueWatching", "recentlyAdded"])
            XCTAssertEqual(model.recommendationError, .decoding)
            let diagnostic = try XCTUnwrap(model.recommendationDiagnostic)
            XCTAssertEqual(diagnostic.provider, kind)
            XCTAssertEqual(diagnostic.failures.map(\.section), [.recommendations])
            XCTAssertEqual(diagnostic.failures.map(\.error), [.decoding])
            XCTAssertEqual(model.errorServers, [provider.session.server])
            let submitted = try submittedLibraryRecords(scope: scope).filter {
                !previous.contains($0["record"] as? String ?? "")
            }
            XCTAssertTrue(submitted.contains {
                let facts = $0["facts"] as? [String: Any]
                let failure = (facts?["failures"] as? [[String: Any]])?.first
                return facts?["provider"] as? String == kind.rawValue
                    && failure?["section"] as? String == "recommendations"
                    && failure?["reason"] as? String == "decoding"
            }, "Send to Developer must retain the actual producer's typed recommendation failure.")

            await provider.setHubError(nil)
            await model.loadRecommendations()
            XCTAssertNil(model.recommendationDiagnostic)
            XCTAssertNil(model.recommendationError)
            XCTAssertTrue(model.errorServers.isEmpty)
        }
    }

    func testRecommendationRetryPreservesFailedFamiliesUntilAnAuthoritativeSuccess() async throws {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, libraryID: "real-library")
        let provider = LibraryModeProvider(
            watchingItems: [item], nativeSections: [LibrarySection(id: "suggested", title: "Suggested", items: [item])]
        )
        let model = model(provider)
        await model.loadRecommendations()
        let original = try XCTUnwrap(model.recommendationState.value)
        await provider.setHubError(.decoding)
        await model.loadRecommendations()
        XCTAssertEqual(model.recommendationState.value?.map(\.id), original.map(\.id),
                       "Successful recent/resume requests must not erase the failed hub's existing content.")
        await provider.setWatchingError(.serverUnreachable)
        await provider.fail(.titles, at: 0)
        await model.loadRecommendations()
        XCTAssertEqual(model.recommendationState.value?.map(\.id), original.map(\.id))
        XCTAssertEqual(model.recommendationDiagnostic?.failures.map(\.section),
                       [.continueWatching, .recommendations, .recentlyAdded])

        await provider.setHubError(nil)
        await provider.setNativeSections([])
        await provider.setWatchingError(nil)
        await provider.clearFailures()
        await model.loadRecommendations()
        XCTAssertEqual(model.recommendationState.value?.map(\.id), ["continueWatching", "recentlyAdded"])
        XCTAssertNil(model.recommendationDiagnostic)
    }

    func testAllRecommendationFailuresHaveDetailsAndProviderCancellationDoesNotPublishPartialSuccess() async throws {
        let provider = LibraryModeProvider()
        await provider.setHubError(.decoding)
        await provider.setWatchingError(.unauthorized)
        await provider.fail(.titles, at: 0)
        let model = model(provider)
        await model.loadRecommendations()
        XCTAssertEqual(model.recommendationState, .failed(.unauthorized))
        let diagnostic = try XCTUnwrap(model.recommendationDiagnostic)
        XCTAssertEqual(diagnostic.failures.count, 3)

        await provider.clearFailures()
        await provider.setWatchingError(nil)
        await provider.setHubError(.cancelled)
        await model.loadRecommendations()
        XCTAssertEqual(model.recommendationState, .failed(.unauthorized))
        XCTAssertEqual(model.recommendationDiagnostic, diagnostic, "Cancellation must retain the last completed failure.")

        let fresh = self.model(provider)
        await fresh.loadRecommendations()
        XCTAssertEqual(fresh.recommendationState, .idle)
        XCTAssertNil(fresh.recommendationDiagnostic)
    }

    func testCancelledRecommendationsCanRetryOnReappear() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await provider.hold(.titles, at: 0)
        let loading = Task { await model.loadFirstPageIfNeeded() }
        await provider.waitForHeldRequest(.titles, at: 0)
        loading.cancel()
        await provider.release(.titles, at: 0)
        await loading.value
        XCTAssertEqual(model.recommendationState, .idle)

        await model.loadFirstPageIfNeeded()
        XCTAssertNotNil(model.recommendationState.value)
    }

    func testReturningAfterPlaybackReplacesCompletedEpisodeWithNextUp() async throws {
        let first = MediaItem(id: "e1", title: "First", kind: .episode, libraryID: "real-library")
        let next = MediaItem(id: "e2", title: "Next", kind: .episode, libraryID: "real-library")
        let provider = LibraryModeProvider(watchingItems: [first])
        let model = model(provider, kind: .series)
        await model.loadFirstPageIfNeeded()
        model.cancelPendingQuery()
        await provider.setWatchingItems([next])
        model.applyWatchedState(.init(itemIDs: ["e1"], played: true))
        await model.loadFirstPageIfNeeded()
        let sections = try XCTUnwrap(model.recommendationState.value)
        XCTAssertEqual(sections.first { $0.id == "continueWatching" }?.items.map(\.id), ["e2"])
        let requests = await provider.requestedWatchingLibraries
        XCTAssertEqual(requests.count, 2)
        await model.loadFirstPageIfNeeded()
        let unchanged = await provider.requestedWatchingLibraries
        XCTAssertEqual(unchanged.count, requests.count, "Clean returns must preserve the cached presentation.")
    }

    func testRecommendationRefreshPreservesRowsAndRetriesMutationDuringRequest() async throws {
        let first = MediaItem(id: "e1", title: "First", kind: .episode, libraryID: "real-library")
        let next = MediaItem(id: "e2", title: "Next", kind: .episode, libraryID: "real-library")
        let provider = LibraryModeProvider(watchingItems: [first])
        let model = model(provider, kind: .series)
        await model.loadFirstPageIfNeeded()
        await provider.hold(.titles, at: 0)
        let refreshing = Task { await model.loadRecommendations() }
        await provider.waitForHeldRequest(.titles, at: 0)
        XCTAssertNotNil(model.recommendationState.value, "Refreshing must not replace focused rows with a spinner.")
        await provider.setWatchingItems([next])
        model.applyWatchedState(.init(itemIDs: ["e1"], played: true))
        await provider.release(.titles, at: 0)
        await refreshing.value
        let sections = try XCTUnwrap(model.recommendationState.value)
        XCTAssertEqual(sections.first { $0.id == "continueWatching" }?.items.map(\.id), ["e2"])
        let requests = await provider.requestedWatchingLibraries
        XCTAssertEqual(requests.count, 3, "An older in-flight snapshot cannot overwrite a watch mutation.")
    }

    func testVisibleRecommendationWatchMutationRefreshesWithoutAViewReentry() async throws {
        let first = MediaItem(id: "e1", title: "First", kind: .episode, libraryID: "real-library")
        let next = MediaItem(id: "e2", title: "Next", kind: .episode, libraryID: "real-library")
        let provider = LibraryModeProvider(watchingItems: [first])
        let model = model(provider, kind: .series)
        await model.loadFirstPageIfNeeded()
        await provider.hold(.titles, at: 0)
        await provider.setWatchingItems([next])
        model.applyWatchedState(.init(itemIDs: ["e1"], played: true))
        await provider.waitForHeldRequest(.titles, at: 0)
        XCTAssertNotNil(model.recommendationState.value)
        await provider.release(.titles, at: 0)
        await model.loadRecommendationsIfNeeded()
        let sections = try XCTUnwrap(model.recommendationState.value)
        XCTAssertEqual(sections.first { $0.id == "continueWatching" }?.items.map(\.id), ["e2"])
    }

    func testLeavingDuringRecommendationRefreshDoesNotRestartHiddenWork() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await model.loadFirstPageIfNeeded()
        await provider.hold(.titles, at: 0)
        let refreshing = Task { await model.loadRecommendations() }
        await provider.waitForHeldRequest(.titles, at: 0)
        model.cancelPendingQuery()
        await provider.release(.titles, at: 0)
        await refreshing.value
        let requests = await provider.requestedWatchingLibraries
        XCTAssertEqual(requests.count, 2, "A covered destination must not restart its cancelled refresh.")
        XCTAssertNotNil(model.recommendationState.value)
        await model.loadFirstPageIfNeeded()
        let returned = await provider.requestedWatchingLibraries
        XCTAssertEqual(returned.count, 3)
    }

    func testLeavingBeforeScheduledRecommendationRefreshDoesNotStartHiddenWork() async throws {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await model.loadFirstPageIfNeeded()
        model.applyWatchedState(.init(itemIDs: ["title-0"], played: true))
        model.cancelPendingQuery()
        try await Task.sleep(for: .milliseconds(100))
        let requests = await provider.requestedWatchingLibraries
        XCTAssertEqual(requests.count, 1)
        await model.loadFirstPageIfNeeded()
        let returned = await provider.requestedWatchingLibraries
        XCTAssertEqual(returned.count, 2, "Returning must still refresh the invalidated recommendations.")
    }

    func testVideoPlaylistModeIsCapabilityGatedAndKeepsAccountAndSortSeparate() async {
        let unsupported = model(LibraryModeProvider(supportsPlaylists: false))
        XCTAssertEqual(unsupported.availableContentModes, [.recommended, .titles, .collections])
        await unsupported.setContentMode(.playlists)
        XCTAssertEqual(unsupported.contentMode, .recommended)

        let provider = LibraryModeProvider(supportsPlaylists: true)
        let model = model(provider)
        XCTAssertEqual(model.availableContentModes, [.recommended, .titles, .collections, .playlists])
        await model.setContentMode(.playlists)
        XCTAssertEqual(model.item(at: 0)?.kind, .playlist)
        XCTAssertEqual(model.item(at: 0)?.sourceAccountID, "owning-account")
        XCTAssertEqual(model.availableSortFields, [.name])
        XCTAssertEqual(CollectionBrowseRoute(item: model.item(at: 0)!)?.kind, .playlist)
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.mode), [.playlists])
        XCTAssertEqual(requests.map(\.containerID), ["real-library"])
        await model.setContentMode(.titles)
        XCTAssertEqual(model.item(at: 0)?.kind, .movie)
    }

    func testPlaylistMemberGridPreservesOrderAcrossShortPagesAndHidesSort() async {
        let provider = LibraryModeProvider(supportsPlaylists: true)
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "playlist-0", containerKind: .playlist,
            pageSize: 2, defaults: defaults, sourceAccountID: "owning-account",
            browseScope: .playlistMembers
        )
        XCTAssertEqual(model.availableContentModes, [.titles])
        XCTAssertTrue(model.availableSortFields.isEmpty)
        await model.loadFirstPage()
        XCTAssertEqual(model.totalCount, 3)
        XCTAssertEqual(model.item(at: 0)?.id, "first")
        XCTAssertEqual(model.item(at: 1)?.id, "second")
        XCTAssertEqual(model.item(at: 1)?.sourceAccountID, "owning-account")
        await model.itemAppeared(at: 2)
        XCTAssertEqual(model.item(at: 2)?.id, "third")
        await model.setContentMode(.playlists)
        XCTAssertEqual(model.contentMode, .titles)
    }

    func testNativeCollectionRootKeepsExistingItemsBrowseAndNeverAddsAnotherMode() async {
        let provider = LibraryModeProvider()
        let model = model(provider, kind: .collection)
        await model.loadFirstPage()
        await model.setContentMode(.collections)
        XCTAssertFalse(model.supportsCollections)
        XCTAssertEqual(model.availableSortFields, [.name, .dateAdded])
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.mode, .titles)
        XCTAssertEqual(requests.first?.kind, .collection)
    }

    func testSwitchClearsCountSlotsScrollAndLatePagesBeforeResponse() async {
        let provider = LibraryModeProvider(titleCount: 40, collectionCount: 12)
        let model = model(provider)
        await model.setContentMode(.titles)
        await model.itemAppeared(at: 8)
        XCTAssertNotNil(model.item(at: 8))
        XCTAssertEqual(model.topVisibleIndex, 8)
        let oldGeneration = model.contentGeneration

        await provider.hold(.collections, at: 0)
        let switching = Task { await model.setContentMode(.collections) }
        await provider.waitForHeldRequest(.collections, at: 0)
        XCTAssertEqual(model.state, .loading)
        XCTAssertEqual(model.totalCount, 0)
        XCTAssertTrue(model.loaded.isEmpty)
        XCTAssertNil(model.pageError)
        XCTAssertNil(model.topVisibleIndex)
        XCTAssertTrue(model.letterEntries.isEmpty)
        XCTAssertNotEqual(model.contentGeneration, oldGeneration)
        await provider.release(.collections, at: 0)
        await switching.value

        XCTAssertEqual(model.totalCount, 12)
        XCTAssertEqual(model.loadedCount, 2)
        XCTAssertNil(model.item(at: 8))
        await model.itemAppeared(at: 4, generation: oldGeneration)
        XCTAssertNil(model.item(at: 4), "A retired title cell must not page collections.")
        await model.itemAppeared(at: 4)
        model.itemDisappeared(at: 4, generation: oldGeneration)
        XCTAssertEqual(model.topVisibleIndex, 4)
        XCTAssertEqual(model.item(at: 4)?.id, "collection-4")

        await model.setContentMode(.titles)
        XCTAssertEqual(model.totalCount, 40)
        XCTAssertEqual(model.loadedCount, 2)
        XCTAssertNil(model.item(at: 4), "Collection slots never become cached title slots.")
        XCTAssertNil(model.topVisibleIndex)
    }

    func testTitleAndCollectionSortsRestoreIndependently() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await model.setContentMode(.titles)
        let titleSort = CoreModels.SortDescriptor(field: .communityRating, direction: .descending)
        let collectionSort = CoreModels.SortDescriptor(field: .dateAdded, direction: .descending)
        await model.setSort(titleSort)
        await model.setContentMode(.collections)
        XCTAssertEqual(model.sort, .default)
        XCTAssertEqual(model.availableSortFields, [.name, .dateAdded])
        await model.setSort(collectionSort)
        let beforeUnsupportedSort = await provider.requests.count
        await model.setSort(titleSort)
        let afterUnsupportedSort = await provider.requests.count
        XCTAssertEqual(afterUnsupportedSort, beforeUnsupportedSort)
        XCTAssertEqual(model.sort, collectionSort)
        await model.setContentMode(.titles)
        XCTAssertEqual(model.sort, titleSort)
        await model.setContentMode(.collections)
        XCTAssertEqual(model.sort, collectionSort)
        let lastRequest = await provider.requests.last
        XCTAssertEqual(lastRequest?.page.sort, collectionSort)
    }

    func testReturningFromCollectionDetailRetainsModePagesAndScroll() async {
        let provider = LibraryModeProvider(collectionCount: 20)
        let model = model(provider)
        await model.setContentMode(.collections)
        await model.itemAppeared(at: 8)
        let requestsBefore = await provider.requests.count
        let slotBefore = model.slot(at: 8)
        await model.loadFirstPageIfNeeded()
        let requestsAfter = await provider.requests.count
        XCTAssertEqual(requestsAfter, requestsBefore)
        XCTAssertEqual(model.contentMode, .collections)
        XCTAssertEqual(model.topVisibleIndex, 8)
        XCTAssertTrue(model.slot(at: 8) === slotBefore)
        XCTAssertEqual(model.item(at: 8)?.id, "collection-8")
    }

    func testCollectionShapeIsStableAcrossPagingAndOverridesDoNotRefetchOrAffectMembers() async {
        for kind: ProviderKind in [.jellyfin, .emby, .plex] {
            let provider = LibraryModeProvider(
                kind: kind, collectionCount: 30, collectionCoverRatios: [16.0 / 9, 16.0 / 9, 16.0 / 9, 16.0 / 9]
            )
            let model = model(provider)
            await model.setContentMode(.collections)
            XCTAssertTrue(model.showsCollectionCoverLayout)
            XCTAssertEqual(model.gridStyle, .landscape)
            await model.itemAppeared(at: 15)
            XCTAssertEqual(model.gridStyle, .landscape, "Later portrait pages cannot relayout the initial group.")
            let firstPageRequests = await provider.requests.filter { $0.page.startIndex == 0 }.count
            let generation = model.contentGeneration
            let slot = model.slot(at: 0)
            model.collectionCoverLayout = .poster
            XCTAssertEqual(model.gridStyle, .poster)
            XCTAssertTrue(model.slot(at: 0) === slot)
            model.collectionCoverLayout = .landscape
            XCTAssertEqual(model.gridStyle, .landscape)
            let after = await provider.requests.filter { $0.page.startIndex == 0 }.count
            XCTAssertEqual(after, firstPageRequests, "Presentation changes must not restart pagination.")
            XCTAssertEqual(model.contentGeneration, generation)
            let reopened = self.model(provider)
            await reopened.setContentMode(.collections)
            XCTAssertEqual(reopened.collectionCoverLayout, .landscape)
            let other = self.model(provider, accountID: "another-account")
            XCTAssertEqual(other.collectionCoverLayout, .auto)
            let members = LibraryBrowseViewModel(
                provider: provider, containerID: "collection", containerKind: .collection,
                defaults: defaults, browseScope: .collectionMembers, presentation: model.presentation
            )
            XCTAssertFalse(members.showsCollectionCoverLayout)
            XCTAssertEqual(members.gridStyle, .poster)
        }
    }

    func testRecommendedCollectionShapeAndOverrideLeaveMovieRowsUnchanged() async throws {
        let cover = MediaItem(
            id: "cover", title: "Collection", kind: .collection, primaryImageAspectRatio: 16.0 / 9
        )
        let movie = MediaItem(id: "movie", title: "Movie", kind: .movie)
        let provider = LibraryModeProvider(nativeSections: [
            .init(id: "collections", title: "Collections", items: [cover]),
            .init(id: "movies", title: "Movies", items: [movie])
        ])
        let model = model(provider)
        await model.loadRecommendationsIfNeeded()
        let sections = try XCTUnwrap(model.recommendationState.value)
        let collection = try XCTUnwrap(sections.first { $0.title == "Collections" })
        XCTAssertEqual(model.visibleRecommendedRows(sections).first { $0.id == collection.id }?.style, .landscape)
        model.presentation.settings.collectionCoverLayouts[model.collectionCoverAddress(rowID: collection.id)] = .poster
        XCTAssertEqual(model.visibleRecommendedRows(sections).first { $0.id == collection.id }?.style, .poster)
        XCTAssertEqual(model.visibleRecommendedRows(sections).first { $0.title == "Movies" }?.style, .poster)
    }

    func testNewLibraryOrAccountStartsInRecommendedAndRetainsItsOwnSource() async {
        let firstProvider = LibraryModeProvider(accountID: "server-a")
        let first = model(firstProvider, accountID: "account-a")
        await first.setContentMode(.collections)
        XCTAssertEqual(first.item(at: 0)?.sourceAccountID, "account-a")

        let secondProvider = LibraryModeProvider(accountID: "server-b")
        let second = model(secondProvider, accountID: "account-b")
        XCTAssertEqual(second.contentMode, .recommended)
        await second.setContentMode(.titles)
        XCTAssertEqual(second.item(at: 0)?.sourceAccountID, "account-b")
        await second.setContentMode(.collections)
        XCTAssertEqual(second.item(at: 0)?.sourceAccountID, "account-b")
        XCTAssertEqual(first.item(at: 0)?.sourceAccountID, "account-a")
        XCTAssertEqual(first.sourceServerID, "server-a")
        XCTAssertEqual(second.sourceServerID, "server-b")

        let anotherLibrary = model(firstProvider, libraryID: "other-library", accountID: "account-a")
        XCTAssertEqual(anotherLibrary.contentMode, .recommended)
        await anotherLibrary.setContentMode(.collections)
        let request = await firstProvider.requests.last
        XCTAssertEqual(request?.containerID, "other-library")
    }

    func testEmptyCollectionsAreNotTheMovieCountAndCanSwitchBack() async {
        let provider = LibraryModeProvider(titleCount: 40, collectionCount: 0)
        let model = model(provider)
        await model.setContentMode(.titles)
        await model.setContentMode(.collections)
        XCTAssertEqual(model.state, .empty)
        XCTAssertEqual(model.totalCount, 0)
        XCTAssertTrue(model.loaded.isEmpty)
        XCTAssertTrue(model.supportsCollections)
        await model.setContentMode(.titles)
        XCTAssertEqual(model.state, .loaded(40))
    }

    func testFailedCollectionsRemainRetryableAndDoNotLookEmpty() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await provider.fail(.collections, at: 0)
        await model.setContentMode(.collections)
        XCTAssertEqual(model.state, .failed(.serverUnreachable))
        XCTAssertEqual(model.totalCount, 0)
        XCTAssertTrue(model.loaded.isEmpty)
        XCTAssertEqual(model.contentMode, .collections)
        XCTAssertEqual(model.browseDiagnostic?.operation, .libraryBrowse)
        XCTAssertEqual(model.browseDiagnostic?.failures.first?.section, .collections)
        XCTAssertEqual(model.browseDiagnostic?.failures.first?.error, .serverUnreachable)
        await provider.clearFailures()
        await model.loadFirstPage()
        XCTAssertEqual(model.state, .loaded(12))
        XCTAssertNil(model.browseDiagnostic)
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.mode), [.collections, .collections])
    }

    func testSlowFirstPageCannotOverwriteNewMode() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await model.setContentMode(.titles)
        await provider.hold(.titles, at: 0)
        let titleLoad = Task { await model.loadFirstPage() }
        await provider.waitForHeldRequest(.titles, at: 0)
        await model.setContentMode(.collections)
        await provider.release(.titles, at: 0)
        await titleLoad.value
        XCTAssertEqual(model.contentMode, .collections)
        XCTAssertEqual(model.totalCount, 12)
        XCTAssertEqual(model.item(at: 0)?.id, "collection-0")
    }

    func testBrowseFailuresOfferDetailsAcrossProvidersAndClearOnModeChanges() async throws {
        for kind: ProviderKind in [.jellyfin, .emby, .plex, .silo] {
            let provider = LibraryModeProvider(kind: kind, supportsPlaylists: true)
            let model = model(provider)
            for (mode, section) in [
                (LibraryContentMode.titles, LibraryLoadDiagnostic.Section.browse),
                (.collections, .collections), (.playlists, .playlists)
            ] {
                let scope = DiagnosticExportScope()
                let previous = Set(try submittedLibraryRecords(scope: scope).compactMap { $0["record"] as? String })
                await provider.fail(mode, at: 0)
                await model.setContentMode(mode)
                XCTAssertEqual(model.browseDiagnostic?.provider, kind)
                XCTAssertEqual(model.browseDiagnostic?.failures.first?.section, section)
                let submitted = try submittedLibraryRecords(scope: scope).filter {
                    !previous.contains($0["record"] as? String ?? "")
                }
                XCTAssertTrue(submitted.contains {
                    let facts = $0["facts"] as? [String: Any]
                    let failure = (facts?["failures"] as? [[String: Any]])?.first
                    return facts?["provider"] as? String == kind.rawValue
                        && facts?["operation"] as? String == "libraryBrowse"
                        && failure?["section"] as? String == section.rawValue
                }, "Send to Developer must retain the actual producer's typed browse failure.")
                await provider.clearFailures()
                await model.loadFirstPage()
                XCTAssertNil(model.browseDiagnostic)
            }
        }
    }

    func testCollectionPageFailureRetriesWithoutReplacingLoadedGrid() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await model.setContentMode(.collections)
        let firstSlot = model.slot(at: 0)
        await provider.fail(.collections, at: 4)
        await model.itemAppeared(at: 4)
        XCTAssertEqual(model.pageError, .serverUnreachable)
        XCTAssertEqual(model.browseDiagnostic?.failures.first?.section, .collections)
        XCTAssertEqual(model.state, .loaded(12))
        XCTAssertNil(model.item(at: 4))

        await model.itemAppeared(at: 6)
        XCTAssertEqual(model.pageError, .serverUnreachable,
                       "Another successful page must not hide an outstanding failure.")
        await provider.clearFailures()
        await model.retryFailedPages()
        XCTAssertNil(model.pageError)
        XCTAssertNil(model.browseDiagnostic)
        XCTAssertTrue(firstSlot === model.slot(at: 0))
        XCTAssertEqual(model.item(at: 4)?.id, "collection-4")
    }

    func testSlowCollectionFirstPageCannotOverwriteReturnedTitlesOrSort() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await model.setContentMode(.titles)
        let chosen = CoreModels.SortDescriptor(field: .dateAdded, direction: .descending)
        await model.setSort(chosen)
        await provider.hold(.collections, at: 0)
        let collectionLoad = Task { await model.setContentMode(.collections) }
        await provider.waitForHeldRequest(.collections, at: 0)
        await model.setContentMode(.titles)
        await provider.release(.collections, at: 0)
        await collectionLoad.value
        XCTAssertEqual(model.contentMode, .titles)
        XCTAssertEqual(model.sort, chosen)
        XCTAssertEqual(model.totalCount, 40)
        XCTAssertEqual(model.item(at: 0)?.id, "title-0")
    }

    func testRetiredPageErrorCannotContaminateNewMode() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await model.loadFirstPage()
        await provider.fail(.titles, at: 4)
        await provider.hold(.titles, at: 4)
        let oldPage = Task { await model.itemAppeared(at: 4) }
        await provider.waitForHeldRequest(.titles, at: 4)
        await model.setContentMode(.collections)
        await provider.release(.titles, at: 4)
        await oldPage.value
        XCTAssertNil(model.pageError)
        XCTAssertNil(model.browseDiagnostic)
        XCTAssertEqual(model.state, .loaded(12))
        XCTAssertNil(model.item(at: 4))
    }

    func testRetiredPageCompletionCannotRemoveNewModesInFlightPage() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await model.loadFirstPage()
        await provider.hold(.titles, at: 4)
        let oldPage = Task { await model.itemAppeared(at: 4) }
        await provider.waitForHeldRequest(.titles, at: 4)
        await model.setContentMode(.collections)
        await provider.hold(.collections, at: 4)
        let newPage = Task { await model.itemAppeared(at: 4) }
        await provider.waitForHeldRequest(.collections, at: 4)

        await provider.release(.titles, at: 4)
        await oldPage.value
        let adjacentCell = Task { await model.itemAppeared(at: 5) }
        // Yield while the adjacent cell joins the existing page task.
        for _ in 0..<10 { await Task.yield() }
        let requests = await provider.requests
        XCTAssertEqual(requests.filter { $0.mode == .collections && $0.page.startIndex == 4 }.count, 1)
        XCTAssertNil(model.item(at: 4), "An old title page must never fill collection slots.")
        await provider.release(.collections, at: 4)
        await newPage.value
        await adjacentCell.value
        XCTAssertEqual(model.item(at: 4)?.id, "collection-4")
        XCTAssertEqual(model.totalCount, 12)
    }

    func testCollectionModeClearsAndDoesNotRequestTitleLetterIndex() async {
        let provider = LibraryModeProvider(collectionCount: 40)
        let model = model(provider)
        await model.setContentMode(.titles)
        let deadline = Date().addingTimeInterval(1)
        while model.letterEntries.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(model.showsLetterRail)
        await model.setContentMode(.collections)
        XCTAssertFalse(model.showsLetterRail)
        XCTAssertTrue(model.letterEntries.isEmpty)
        let requests = await provider.letterRequests
        XCTAssertEqual(requests, [.movie])
    }

    func testReappearingWhileLoadingDoesNotRestartTheFirstPage() async {
        let provider = LibraryModeProvider()
        let model = model(provider)
        await provider.hold(.collections, at: 0)
        let initial = Task { await model.setContentMode(.collections) }
        await provider.waitForHeldRequest(.collections, at: 0)
        await model.loadFirstPageIfNeeded()
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(model.state, .loading)
        await provider.release(.collections, at: 0)
        await initial.value
        XCTAssertEqual(model.state, .loaded(12))
    }

    func testProgressiveCollectionsKeepSlotsAndDoNotStartSparsePageRequests() async {
        let provider = LibraryModeProvider()
        await provider.enableCollectionProgress()
        let model = model(provider)
        await provider.hold(.collections, at: 0)
        let initial = Task { await model.setContentMode(.collections) }
        await provider.waitForHeldRequest(.collections, at: 0)
        XCTAssertEqual(model.state, .loaded(4))
        XCTAssertEqual(model.collectionProgress?.checked, 4)
        XCTAssertTrue(model.collectionScanIncomplete)
        let slot = model.slot(at: 0)
        XCTAssertEqual(model.item(at: 0)?.sourceAccountID, "owning-account")
        await model.itemAppeared(at: 3)
        await model.loadFirstPageIfNeeded()
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1, "Progress must not start another refresh or sparse-page consumer.")
        await provider.release(.collections, at: 0)
        await initial.value
        XCTAssertTrue(slot === model.slot(at: 0))
        XCTAssertEqual(model.state, .loaded(12))
        XCTAssertEqual(model.item(at: 11)?.id, "collection-11", "Final page zero must not erase streamed later slots.")
        XCTAssertFalse(model.collectionScanIncomplete)
        XCTAssertNil(model.collectionProgress)
    }

    func testProgressiveCollectionShapeIsFrozenBeforeItsFirstVisibleCards() async {
        let provider = LibraryModeProvider(
            collectionCount: 12, collectionCoverRatios: Array(repeating: 16.0 / 9, count: 4)
        )
        await provider.enableCollectionProgress()
        await provider.hold(.collections, at: 0)
        let model = model(provider)
        let initial = Task { await model.setContentMode(.collections) }
        await provider.waitForHeldRequest(.collections, at: 0)
        XCTAssertEqual(model.loadedCount, 4)
        XCTAssertEqual(model.gridStyle, .landscape)
        await provider.release(.collections, at: 0)
        await initial.value
        XCTAssertEqual(model.loadedCount, 12)
        XCTAssertEqual(model.gridStyle, .landscape, "Completing discovery must not change the visible cover shape.")
    }

    func testPartialCollectionFailureKeepsCardsAndTransportDetailsThenRetries() async {
        let provider = LibraryModeProvider()
        await provider.enableCollectionProgress()
        await provider.fail(.collections, at: 0)
        let model = model(provider)
        await model.setContentMode(.collections)
        XCTAssertEqual(model.state, .loaded(4))
        XCTAssertEqual(model.pageError, .serverUnreachable)
        XCTAssertTrue(model.collectionScanIncomplete)
        XCTAssertNil(model.collectionProgress)
        let failure = model.browseDiagnostic?.failures.first
        XCTAssertEqual(failure?.paging.first?.stage, .collectionMembers)
        XCTAssertEqual(failure?.transport.first?.urlErrorCode, URLError.timedOut.rawValue)
        XCTAssertEqual(failure?.transport.first?.route, .collectionMembers)
        XCTAssertEqual(model.queryMessage, "Couldn't connect to the server. Check your connection and try again.")
        await provider.clearFailures()
        await model.retryFailedPages()
        XCTAssertEqual(model.state, .loaded(12))
        XCTAssertFalse(model.collectionScanIncomplete)
        XCTAssertNil(model.pageError)
        XCTAssertNil(model.browseDiagnostic)
    }

    func testInterruptedPartialScanRestartsOnReturnButCompletedScanDoesNot() async {
        let provider = LibraryModeProvider()
        await provider.enableCollectionProgress()
        let model = model(provider)
        await provider.hold(.collections, at: 0)
        let initial = Task { await model.setContentMode(.collections) }
        await provider.waitForHeldRequest(.collections, at: 0)
        model.cancelPendingQuery()
        await provider.release(.collections, at: 0)
        await initial.value
        XCTAssertEqual(model.loadedCount, 4, "Late progress from a cancelled request must be rejected.")
        XCTAssertTrue(model.collectionScanIncomplete)
        await model.loadFirstPageIfNeeded()
        XCTAssertEqual(model.loadedCount, 12)
        XCTAssertFalse(model.collectionScanIncomplete)
        await model.loadFirstPageIfNeeded()
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testRetiredCollectionProgressCannotReplaceAnotherMode() async {
        let provider = LibraryModeProvider()
        await provider.enableCollectionProgress()
        let model = model(provider)
        await provider.hold(.collections, at: 0)
        let initial = Task { await model.setContentMode(.collections) }
        await provider.waitForHeldRequest(.collections, at: 0)
        await model.setContentMode(.titles)
        await provider.release(.collections, at: 0)
        await initial.value
        XCTAssertEqual(model.state, .loaded(40))
        XCTAssertEqual(model.item(at: 0)?.id, "title-0")
        XCTAssertFalse(model.collectionScanIncomplete)
        XCTAssertNil(model.collectionProgress)
    }

    private func model(
        _ provider: LibraryModeProvider,
        kind: MediaItemKind = .movie,
        libraryID: String = "real-library",
        accountID: String = "owning-account"
    ) -> LibraryBrowseViewModel {
        LibraryBrowseViewModel(
            provider: provider, containerID: libraryID, containerKind: kind,
            pageSize: 2, defaults: defaults, sourceAccountID: accountID
        )
    }
}

private actor LibraryModeProvider: MediaProvider, CapabilityReporting {
    struct Request: Sendable {
        let mode: LibraryContentMode
        let containerID: String
        let kind: MediaItemKind
        let page: PageRequest
    }

    private struct Key: Hashable {
        let mode: LibraryContentMode
        let index: Int
    }

    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    nonisolated let capabilities: ProviderCapability
    private let titleCount: Int
    private let collectionCount: Int
    private let collectionCoverRatios: [Double]
    private let supportsPlaylists: Bool
    private var watchingItems: [MediaItem]
    private var nativeSections: [LibrarySection]
    private var failHubs: Bool
    private var hubError: AppError?
    private var watchingError: AppError?
    private var holds: Set<Key> = []
    private var held: [Key: CheckedContinuation<Void, Never>] = [:]
    private var heldObservers: [Key: CheckedContinuation<Void, Never>] = [:]
    private var failures: Set<Key> = []
    private var progressiveCollections = false
    private(set) var requests: [Request] = []
    private(set) var letterRequests: [MediaItemKind] = []
    private(set) var requestedWatchingLibraries: [[String]?] = []
    private(set) var requestedHubLibraries: [String] = []

    init(
        kind: ProviderKind = .jellyfin,
        accountID: String = "server",
        supportsCollections: Bool = true,
        supportsPlaylists: Bool = false,
        titleCount: Int = 40,
        collectionCount: Int = 12,
        collectionCoverRatios: [Double] = [],
        watchingItems: [MediaItem] = [],
        nativeSections: [LibrarySection] = [],
        failHubs: Bool = false
    ) {
        self.kind = kind
        self.titleCount = titleCount
        self.collectionCount = collectionCount
        self.collectionCoverRatios = collectionCoverRatios
        self.supportsPlaylists = supportsPlaylists
        self.watchingItems = watchingItems
        self.nativeSections = nativeSections
        self.failHubs = failHubs
        let base: ProviderCapability = supportsCollections ? [.video, .libraryCollections] : [.video]
        capabilities = supportsPlaylists ? base.union(.videoPlaylists) : base
        session = UserSession(
            server: MediaServer(
                id: accountID, name: "Server",
                baseURL: URL(string: "https://media.example")!, provider: kind
            ),
            userID: "user", userName: "Viewer", deviceID: "device", accessToken: "test-token"
        )
    }

    func hold(_ mode: LibraryContentMode, at index: Int) {
        holds.insert(Key(mode: mode, index: index))
    }

    func waitForHeldRequest(_ mode: LibraryContentMode, at index: Int) async {
        let key = Key(mode: mode, index: index)
        guard held[key] == nil else { return }
        await withCheckedContinuation { heldObservers[key] = $0 }
    }

    func release(_ mode: LibraryContentMode, at index: Int) {
        held.removeValue(forKey: Key(mode: mode, index: index))?.resume()
    }

    func fail(_ mode: LibraryContentMode, at index: Int) {
        failures.insert(Key(mode: mode, index: index))
    }

    func clearFailures() { failures = [] }
    func setFailHubs(_ value: Bool) { failHubs = value }
    func setHubError(_ value: AppError?) { hubError = value }
    func setWatchingError(_ value: AppError?) { watchingError = value }
    func setWatchingItems(_ items: [MediaItem]) { watchingItems = items }
    func setNativeSections(_ sections: [LibrarySection]) { nativeSections = sections }
    func enableCollectionProgress() { progressiveCollections = true }

    func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        try await response(.collections, containerID: libraryID, kind: .collection, page: page)
    }

    func collections(
        in libraryID: String, page: PageRequest,
        progress: @escaping @Sendable (LibraryCollectionProgress) async -> Void
    ) async throws -> MediaPage {
        func update(_ count: Int, checked: Int) -> LibraryCollectionProgress {
            .init(items: (0..<count).map {
                MediaItem(
                    id: "collection-\($0)", title: "collection \($0)", kind: .collection,
                    primaryImageAspectRatio: $0 < collectionCoverRatios.count ? collectionCoverRatios[$0] : 2.0 / 3
                )
            }, checked: checked, total: 20)
        }
        if progressiveCollections { await progress(update(4, checked: 4)) }
        let result = try await collections(in: libraryID, page: page)
        if progressiveCollections { await progress(update(collectionCount, checked: 20)) }
        return result
    }

    func videoPlaylists(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        try await response(.playlists, containerID: libraryID, kind: .playlist, page: page)
    }

    func videoPlaylistMembers(of playlistID: String, page: PageRequest) async throws -> MediaPage {
        let ids = ["first", "second", "third"]
        let index = min(page.startIndex, ids.count)
        return MediaPage(
            items: Array(ids.dropFirst(index).prefix(1)).map {
                MediaItem(id: $0, title: $0, kind: .movie)
            },
            startIndex: page.startIndex, totalCount: ids.count
        )
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        try await response(.titles, containerID: containerID, kind: kind, page: page)
    }

    private func response(
        _ mode: LibraryContentMode, containerID: String,
        kind: MediaItemKind, page: PageRequest
    ) async throws -> MediaPage {
        requests.append(Request(mode: mode, containerID: containerID, kind: kind, page: page))
        let key = Key(mode: mode, index: page.startIndex)
        let fails = failures.contains(key)
        if holds.remove(key) != nil {
            // Intentionally cancellation-insensitive to exercise stale replies.
            await withCheckedContinuation { continuation in
                held[key] = continuation
                heldObservers.removeValue(forKey: key)?.resume()
            }
        }
        if fails {
            if mode == .collections {
                HTTPResponseDiagnostics.recordPagingFailure(.init(
                    stage: .collectionMembers, reason: .nonAdvancing, start: 4, rows: 2, total: 20
                ))
                HTTPResponseDiagnostics.$route.withValue(.collectionMembers) {
                    HTTPResponseDiagnostics.recordTransportFailure(URLError(.timedOut))
                }
            }
            throw AppError.serverUnreachable
        }
        let total = mode == .collections ? collectionCount : mode == .playlists ? 3 : titleCount
        let prefix = mode == .collections ? "collection" : mode == .playlists ? "playlist" : "title"
        let start = min(page.startIndex, total)
        let end = min(start + page.limit, total)
        return MediaPage(
            items: (start..<end).map {
                MediaItem(
                    id: "\(prefix)-\($0)", title: "\(prefix) \($0)", kind: kind,
                    primaryImageAspectRatio: mode == .collections
                        ? ($0 < collectionCoverRatios.count ? collectionCoverRatios[$0] : 2.0 / 3) : nil
                )
            },
            startIndex: page.startIndex, totalCount: total
        )
    }

    func letterIndex(
        in containerID: String, kind: MediaItemKind, sort: CoreModels.SortDescriptor
    ) async throws -> [LibraryLetterIndexEntry] {
        letterRequests.append(kind)
        return [
            LibraryLetterIndexEntry(letter: "A", startIndex: 0),
            LibraryLetterIndexEntry(letter: "B", startIndex: 20)
        ]
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func continueWatching(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        requestedWatchingLibraries.append(libraryIDs)
        if let watchingError { throw watchingError }
        return Array(watchingItems.prefix(limit))
    }
    func libraryHubs(libraryID: String, kind: MediaItemKind, limit: Int) async throws -> [LibrarySection] {
        requestedHubLibraries.append(libraryID)
        if let hubError { throw hubError }
        if failHubs { throw AppError.serverUnreachable }
        return nativeSections
    }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
