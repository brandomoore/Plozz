import XCTest
import CoreModels
@testable import FeatureHome

/// Verifies that a brand-new *in-progress* resume for a title not already on the
/// Continue Watching row triggers a silent re-aggregation so the just-started card
/// appears — the "I played something new and it never showed in Continue Watching
/// until I relaunched" gap. Completing an episode also refreshes the row to fetch
/// the next episode; movies and in-place progress do not need that refresh.
@MainActor
final class HomeViewModelNewResumeReloadTests: XCTestCase {
    private func makeViewModel(provider: FakeMediaProvider) -> HomeViewModel {
        let server = MediaServer(id: "srv-a", name: "Local", baseURL: URL(string: "http://host")!, provider: provider.kind)
        let account = Account(id: "a", server: server, userID: "u", userName: "Me", deviceID: "d")
        let resolved = ResolvedAccount(account: account, provider: provider)
        return HomeViewModel(
            accounts: [resolved],
            layoutStore: InMemoryHomeLayoutStore(),
            currentVisibility: { .default }
        )
    }

    /// Polls until `predicate` holds or a short budget elapses, letting the silent
    /// reload's detached `Task` run to completion.
    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        _ predicate: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Home did not reach the expected state", file: file, line: line)
    }

    private func cw(_ vm: HomeViewModel) -> [MediaItem] {
        vm.state.value?.continueWatching ?? []
    }

    func testSeasonWatchRemovesOnlyThatSeasonsContinueWatchingEpisodes() async {
        let earlier = MediaItem(
            id: "e1", title: "Earlier", kind: .episode, seasonID: "s1",
            resumePosition: 80, sourceAccountID: "a"
        )
        let selected = MediaItem(
            id: "e2", title: "Selected", kind: .episode, seasonID: "s2",
            resumePosition: 90, sourceAccountID: "a"
        )
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [earlier, selected]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        XCTAssertEqual(Set(cw(vm).map(\.id)), ["e1", "e2"])
        vm.applyWatchedState(MediaItemMutation(
            itemIDs: ["s2"], scopedItemIDs: ["a:s2"],
            cascadesToSeasonEpisodes: true, played: true, resumePosition: 0
        ))
        XCTAssertEqual(cw(vm).map(\.id), ["e1"])
        XCTAssertEqual(provider.librariesCallCount, 1)
    }

    func testNewResumeTriggersSilentReloadThatSurfacesTheCard() async {
        let provider = FakeMediaProvider(allItems: [])
        // Home already has one unrelated title on Continue Watching, so it loads to
        // `.loaded` (an empty Home renders a different state entirely).
        provider.continueWatchingItems = [MediaItem(id: "m0", title: "Old", kind: .movie)]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        XCTAssertEqual(provider.librariesCallCount, 1)
        XCTAssertEqual(cw(vm).count, 1)
        XCTAssertFalse(cw(vm).contains { $0.id == "m1" })

        // The user plays a brand-new title; its provider now reports it as
        // resumable (a media share persists this to disk before the mutation posts).
        provider.continueWatchingItems = [
            MediaItem(id: "m1", title: "Movie", kind: .movie),
            MediaItem(id: "m0", title: "Old", kind: .movie)
        ]
        vm.applyWatchedState(
            MediaItemMutation(
                itemIDs: ["m1"],
                scopedItemIDs: ["a:m1"],
                resumePosition: 120,
                playedPercentage: 0.1
            )
        )

        // The silent reload re-aggregates and the new card slots in — no user-visible
        // reload was needed.
        await waitUntil { self.cw(vm).contains { $0.id == "m1" } }
        XCTAssertEqual(provider.librariesCallCount, 2, "a new resume should trigger exactly one silent re-aggregation")
        XCTAssertTrue(cw(vm).contains { $0.id == "m1" })
    }

    func testPendingHeroMutationsApplyInCaptureOrder() async {
        let target = WatchMutationTarget(accountID: "a", itemID: "m1")
        let older = WatchMutation(
            capturedAt: Date(timeIntervalSince1970: 1_000),
            canonicalMediaID: "tmdb:1",
            played: true,
            targets: [target]
        )
        let newer = WatchMutation(
            capturedAt: Date(timeIntervalSince1970: 2_000),
            canonicalMediaID: "tmdb:1",
            played: false,
            targets: [target]
        )
        let viewModel = HomeViewModel(
            accounts: [],
            pendingWatchMutations: { [newer, older] }
        )

        let projected = await viewModel.pendingHeroWatchMutations()

        XCTAssertEqual(projected.map(\.played), [true, false],
                       "Newest durable intent must be reduced last regardless of queue slot order")
    }

    func testReWatchOfExistingCardDoesNotReload() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m1", title: "Movie", kind: .movie)]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        XCTAssertEqual(provider.librariesCallCount, 1)
        XCTAssertEqual(cw(vm).count, 1)

        // Progress on a title already on the row updates in place — no reload.
        vm.applyWatchedState(
            MediaItemMutation(itemIDs: ["m1"], scopedItemIDs: ["a:m1"], resumePosition: 240, playedPercentage: 0.2)
        )
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(provider.librariesCallCount, 1, "an in-place update must not re-aggregate")
    }

    func testMovieFinishDoesNotReload() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m0", title: "Old", kind: .movie)]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        XCTAssertEqual(provider.librariesCallCount, 1)

        // A completed play (played=true, resume cleared) for a title not on the row
        // must never force a reload to "insert" a finished title.
        vm.applyWatchedState(
            MediaItemMutation(
                itemIDs: ["m1"], scopedItemIDs: ["a:m1"], played: true, resumePosition: 0, playedPercentage: 1,
                item: MediaItem(id: "m1", title: "Movie", kind: .movie, sourceAccountID: "a")
            )
        )
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(provider.librariesCallCount, 1, "a finish must not re-aggregate")
    }

    func testCompletedEpisodeRefreshesNextUpWithoutWaitingForAnotherHomeAppearance() async {
        for kind in [ProviderKind.emby, .jellyfin, .plex] {
            for merged in [true, false] {
                let provider = FakeMediaProvider(allItems: [], kind: kind)
                let finished = MediaItem(
                    id: "e1", title: "Episode 1", kind: .episode,
                    seriesID: "show", resumePosition: 1_300, playedPercentage: 0.98
                )
                let next = MediaItem(id: "e2", title: "Episode 2", kind: .episode, seriesID: "show")
                let other = MediaItem(id: "movie", title: "Other title", kind: .movie, resumePosition: 100)
                provider.continueWatchingItems = [finished, other]
                let visibility = HomeLibraryVisibility(mergeLibrariesOnHome: merged)
                let account = Account(
                    id: "a", server: provider.session.server, userID: "u", userName: "Me", deviceID: "d"
                )
                let vm = HomeViewModel(
                    accounts: [.init(account: account, provider: provider)],
                    layoutStore: InMemoryHomeLayoutStore(), currentVisibility: { visibility }
                )
                await vm.load()
                let libraryCalls = provider.librariesCallCount
                provider.continueWatchingItems = [next, other]
                vm.applyWatchedState(MediaItemMutation(
                    itemIDs: [finished.id], scopedItemIDs: ["a:e1"],
                    played: true, resumePosition: 0, playedPercentage: 1,
                    item: finished.taggingSource("a")
                ))
                XCTAssertNotNil(vm.state.value, "No loading skeleton for \(kind), merged=\(merged)")
                XCTAssertEqual(cw(vm).map(\.id), [other.id])
                await waitUntil { self.cw(vm).contains { $0.id == next.id } && !vm.isRefreshing }
                XCTAssertEqual(provider.librariesCallCount, libraryCalls + 1)
                XCTAssertEqual(cw(vm).map(\.id), [next.id, other.id])
            }
        }
    }

    func testCompletionFromOutsideHomeRefreshesEvenWhenHomeWasEmpty() async {
        let provider = FakeMediaProvider(allItems: [], kind: .emby)
        let vm = makeViewModel(provider: provider)
        await vm.load()
        let next = MediaItem(id: "next", title: "Next", kind: .episode, seriesID: "show")
        provider.continueWatchingItems = [next]
        vm.applyWatchedState(MediaItemMutation(
            itemIDs: ["played"], scopedItemIDs: ["a:played"], played: true,
            resumePosition: 0, playedPercentage: 1,
            item: MediaItem(id: "played", title: "Played", kind: .episode, sourceAccountID: "a")
        ))
        await waitUntil { self.cw(vm).contains { $0.id == "next" } && !vm.isRefreshing }
        XCTAssertEqual(provider.librariesCallCount, 2)
    }

    func testCompletionWithoutItemPayloadRefreshesUsingTheLoadedEpisode() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [
            MediaItem(
                id: "episode",
                title: "Episode",
                kind: .episode,
                resumePosition: 420,
                playedPercentage: 0.2
            )
        ]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        XCTAssertEqual(cw(vm).map(\.id), ["episode"])
        provider.continueWatchingItems = [MediaItem(id: "next", title: "Next episode", kind: .episode)]

        vm.applyWatchedState(
            MediaItemMutation(
                itemIDs: ["episode"],
                scopedItemIDs: ["a:episode"],
                played: true,
                resumePosition: 0,
                playedPercentage: 1
            )
        )

        XCTAssertTrue(cw(vm).isEmpty)
        XCTAssertEqual(
            provider.librariesCallCount,
            1,
            "removing the old card must not wait for a refresh"
        )
        await waitUntil { self.cw(vm).map(\.id) == ["next"] && !vm.isRefreshing }
    }

    func testCompletionForAnotherAccountDoesNotRefreshOrRemoveMatchingBareID() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "e1", title: "Different show", kind: .episode)]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        vm.applyWatchedState(MediaItemMutation(
            itemIDs: ["e1"], scopedItemIDs: ["other:e1"], played: true, resumePosition: 0,
            item: MediaItem(id: "e1", title: "Finished show", kind: .episode, sourceAccountID: "other")
        ))
        await Task.yield()
        XCTAssertEqual(provider.librariesCallCount, 1)
        XCTAssertEqual(cw(vm).map(\.title), ["Different show"])
    }

    func testFinalEpisodeRefreshMayLeaveAnEmptyRowWithoutPolling() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "final", title: "Finale", kind: .episode)]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        provider.continueWatchingItems = []
        vm.applyWatchedState(MediaItemMutation(
            itemIDs: ["final"], scopedItemIDs: ["a:final"], played: true, resumePosition: 0
        ))
        await waitUntil { provider.librariesCallCount == 2 && !vm.isRefreshing }
        XCTAssertTrue(cw(vm).isEmpty)
    }

    func testEpisodeCompletionDuringRefreshQueuesAFreshPass() async {
        let provider = FakeMediaProvider(allItems: [])
        let finished = MediaItem(id: "e1", title: "Episode 1", kind: .episode, sourceAccountID: "a")
        provider.continueWatchingItems = [finished]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        let (blockedMetadata, releaseMetadata) = AsyncStream<Void>.makeStream()
        defer { releaseMetadata.finish() }
        provider.latestGate = { for await _ in blockedMetadata {} }
        let existingRefresh = Task { await vm.load(showLoadingState: false) }
        await waitUntil {
            provider.librariesCallCount == 2 && vm.isRefreshing
                && vm.continueWatchingForDetail.contains { $0.id == finished.id }
        }
        provider.continueWatchingItems = [MediaItem(id: "e2", title: "Episode 2", kind: .episode)]
        vm.applyWatchedState(MediaItemMutation(
            itemIDs: ["e1"], scopedItemIDs: ["a:e1"], played: true, resumePosition: 0,
            item: finished
        ))
        // Let the playback-driven request reach the active-load coalescer before
        // releasing the old request, whose feed was captured before completion.
        await Task.yield()
        releaseMetadata.finish()
        await existingRefresh.value
        await waitUntil { self.cw(vm).map(\.id) == ["e2"] && !vm.isRefreshing }
        XCTAssertEqual(provider.librariesCallCount, 3)
    }

    func testServerConfirmationFetchesNextUpAfterEarlyRefreshWasTooSoon() async throws {
        for kind in [ProviderKind.emby, .jellyfin, .plex] {
            let provider = FakeMediaProvider(allItems: [], kind: kind)
            let episode = MediaItem(id: "e3", title: "Episode 3", kind: .episode, sourceAccountID: "a")
            provider.continueWatchingItems = [episode]
            let vm = makeViewModel(provider: provider)
            await vm.load()
            provider.continueWatchingItems = []
            vm.applyWatchedState(MediaItemMutation(
                itemIDs: ["e3"], scopedItemIDs: ["a:e3"], played: true, resumePosition: 0, item: episode
            ))
            await waitUntil { provider.librariesCallCount == 2 && !vm.isRefreshing }
            XCTAssertTrue(cw(vm).isEmpty, "The first feed predates the completed write")

            provider.continueWatchingItems = [MediaItem(id: "e4", title: "Episode 4", kind: .episode)]
            let confirmation = WatchMutation(
                capturedAt: Date(), canonicalMediaID: "show/1/3", played: true, clearResume: true,
                targets: [.init(accountID: "a", itemID: "e3")], kind: .episode
            )
            vm.applyWatchedState(try XCTUnwrap(MediaItemMutation(confirmedWatchMutation: confirmation)))
            await waitUntil { self.cw(vm).map(\.id) == ["e4"] && !vm.isRefreshing }
            XCTAssertEqual(provider.librariesCallCount, 3)
        }
    }

    func testConfirmationFromInactiveAccountDoesNotRefreshHome() async throws {
        let provider = FakeMediaProvider(allItems: [])
        let vm = makeViewModel(provider: provider)
        await vm.load()
        let confirmation = WatchMutation(
            capturedAt: Date(), canonicalMediaID: "show/1/3", played: true,
            targets: [.init(accountID: "inactive", itemID: "e3")], kind: .episode
        )
        vm.applyWatchedState(try XCTUnwrap(MediaItemMutation(confirmedWatchMutation: confirmation)))
        await Task.yield()
        XCTAssertEqual(provider.librariesCallCount, 1)
    }

    func testCountConfirmationRefreshesHomeWithoutReplayingWatchState() async throws {
        for kind in [MediaItemKind.series, .season, .episode] {
            let provider = FakeMediaProvider(allItems: [])
            provider.continueWatchingItems = [
                MediaItem(id: "newer-play", title: "Newer play", kind: .episode, resumePosition: 120)
            ]
            let vm = makeViewModel(provider: provider)
            await vm.load()
            let confirmation = WatchMutation(
                capturedAt: Date(), canonicalMediaID: "show", played: false,
                targets: [.init(accountID: "a", itemID: "show")], kind: kind)
            let mutation = try XCTUnwrap(MediaItemMutation(confirmedWatchMutation: confirmation))
            XCTAssertFalse(mutation.refreshContinueWatching)
            vm.applyWatchedState(mutation)
            await waitUntil { provider.librariesCallCount == 2 && !vm.isRefreshing }
            XCTAssertEqual(cw(vm).first?.resumePosition, 120)
        }
    }

    func testOffscreenModelReceivesCompletionAndConfirmationWithoutAHomeView() async throws {
        let provider = FakeMediaProvider(allItems: [], kind: .emby)
        let episode = MediaItem(id: "e3", title: "Episode 3", kind: .episode, sourceAccountID: "a")
        provider.continueWatchingItems = [episode]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        provider.continueWatchingItems = []
        // No HomeView or .onReceive subscription exists: the persistent model
        // must keep observing while playback/detail navigation hides Home.
        MediaItemMutation(
            itemIDs: ["e3"], scopedItemIDs: ["a:e3"], played: true, resumePosition: 0, item: episode
        ).post()
        XCTAssertTrue(cw(vm).isEmpty)
        await waitUntil { provider.librariesCallCount == 2 && !vm.isRefreshing }

        provider.continueWatchingItems = [
            MediaItem(id: "e4", title: "Episode 4", kind: .episode, lastPlayedAt: Date())
        ]
        try XCTUnwrap(MediaItemMutation(confirmedWatchMutation: WatchMutation(
            capturedAt: Date(), canonicalMediaID: "show/1/3", played: true, clearResume: true,
            targets: [.init(accountID: "a", itemID: "e3")], kind: .episode
        ))).post()
        await waitUntil { self.cw(vm).map(\.id) == ["e4"] && !vm.isRefreshing }
        XCTAssertEqual(provider.librariesCallCount, 3)
    }

    func testNotificationObserverDoesNotRetainHomeModel() async {
        let provider = FakeMediaProvider(allItems: [])
        var vm: HomeViewModel? = makeViewModel(provider: provider)
        weak var retained = vm
        vm = nil
        XCTAssertNil(retained)
        MediaItemMutation(itemIDs: ["episode"], refreshContinueWatching: true).post()
        await Task.yield()
        XCTAssertEqual(provider.librariesCallCount, 0)
    }
}
