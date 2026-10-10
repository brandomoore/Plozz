import Foundation
import XCTest
import CoreModels
@testable import FeatureHome

@MainActor
final class SeasonEpisodeRosterLoadingTests: XCTestCase {
    func testRosterLoadCoalescesAndPublishesSuccess() async {
        let show = series("show", tmdbID: 101)
        let roster = makeRoster(tmdbID: 101, seasonNumber: 1, episodeIDs: [11, 12])
        let gate = RosterAsyncGate()
        let calls = RosterCallLog()
        let vm = makeViewModel(show: show) { item, seasonNumber in
            calls.record(itemID: item.id, seasonNumber: seasonNumber)
            await gate.wait()
            return .loaded(roster)
        }

        let first = Task { @MainActor in
            await vm.loadSeasonEpisodeRoster(for: 1)
        }
        await waitUntil { calls.count == 1 }
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 1), .loading)

        let second = Task { @MainActor in
            await vm.loadSeasonEpisodeRoster(for: 1)
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calls.count, 1)

        gate.open()
        await first.value
        await second.value

        XCTAssertEqual(calls.entries, [.init(itemID: "show", seasonNumber: 1)])
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 1), .loaded(roster))
        XCTAssertTrue(vm.seasonEpisodes.isEmpty)
    }

    func testAuthoritativeEmptyRosterStaysLoaded() async {
        let show = series("show", tmdbID: 101)
        let empty = makeRoster(tmdbID: 101, seasonNumber: 2)
        let vm = makeViewModel(show: show) { _, _ in .loaded(empty) }

        await vm.loadSeasonEpisodeRoster(for: 2)

        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 2), .loaded(empty))
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 2).roster?.episodes, [])
    }

    func testFailureAndUnavailableRequireExplicitRetry() async {
        let show = series("show", tmdbID: 101)
        let roster = makeRoster(tmdbID: 101, seasonNumber: 3, episodeIDs: [31])
        let responses = RosterResponseSequence([.failed, .unavailable, .loaded(roster)])
        let vm = makeViewModel(show: show) { _, _ in responses.next() }

        await vm.loadSeasonEpisodeRoster(for: 3)
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 3), .failed)
        await vm.loadSeasonEpisodeRoster(for: 3)
        XCTAssertEqual(responses.callCount, 1)

        await vm.loadSeasonEpisodeRoster(for: 3, forceRefresh: true)
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 3), .unavailable)
        await vm.loadSeasonEpisodeRoster(for: 3)
        XCTAssertEqual(responses.callCount, 2)

        await vm.loadSeasonEpisodeRoster(for: 3, forceRefresh: true)
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 3), .loaded(roster))
        XCTAssertEqual(responses.callCount, 3)
    }

    func testForcedRosterRefreshSupersedesInFlightSameSourceRequest() async {
        let show = series("show", tmdbID: 101)
        let staleRoster = makeRoster(tmdbID: 101, seasonNumber: 1, episodeIDs: [11])
        let freshRoster = makeRoster(tmdbID: 101, seasonNumber: 1, episodeIDs: [12])
        let staleGate = RosterAsyncGate()
        let calls = RosterCallLog()
        let vm = makeViewModel(show: show) { item, seasonNumber in
            let callNumber = calls.record(itemID: item.id, seasonNumber: seasonNumber)
            if callNumber == 1 {
                await staleGate.wait()
                return .loaded(staleRoster)
            }
            return .loaded(freshRoster)
        }

        let staleLoad = Task { @MainActor in
            await vm.loadSeasonEpisodeRoster(for: 1)
        }
        await waitUntil { calls.count == 1 }

        await vm.loadSeasonEpisodeRoster(for: 1, forceRefresh: true)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 1), .loaded(freshRoster))

        staleGate.open()
        await staleLoad.value
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 1), .loaded(freshRoster))
    }

    func testUnsupportedRosterRequestsBecomeUnavailableWithoutCallingLoader() async {
        let calls = RosterCallLog()
        let loader: @Sendable (MediaItem, Int) async -> SeasonEpisodeRosterResult = {
            item, seasonNumber in
            calls.record(itemID: item.id, seasonNumber: seasonNumber)
            return .failed
        }

        let noLoader = makeViewModel(show: series("no-loader", tmdbID: 1), loader: nil)
        await noLoader.loadSeasonEpisodeRoster(for: 1)
        XCTAssertEqual(noLoader.seasonEpisodeRosterState(for: 1), .unavailable)

        let noTMDb = makeViewModel(show: series("no-tmdb", tmdbID: nil), loader: loader)
        await noTMDb.loadSeasonEpisodeRoster(for: 1)
        XCTAssertEqual(noTMDb.seasonEpisodeRosterState(for: 1), .unavailable)

        let movie = MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "2"])
        let movieVM = makeViewModel(show: movie, loader: loader)
        await movieVM.loadSeasonEpisodeRoster(for: 1)
        XCTAssertEqual(movieVM.seasonEpisodeRosterState(for: 1), .unavailable)

        let invalidSeason = makeViewModel(show: series("invalid", tmdbID: 3), loader: loader)
        await invalidSeason.loadSeasonEpisodeRoster(for: -1)
        XCTAssertEqual(invalidSeason.seasonEpisodeRosterState(for: -1), .unavailable)
        XCTAssertEqual(calls.count, 0)
    }

    func testDetailOpenEnvironmentThreadsRosterLoaderIntoViewModel() async {
        let show = series("show", tmdbID: 101)
        let roster = makeRoster(tmdbID: 101, seasonNumber: 1, episodeIDs: [11])
        let provider = FakeMediaProvider(allItems: [show])
        let environment = DetailOpenEnvironment(
            resolveProvider: { _ in provider },
            resolveOptionalProvider: { _ in provider },
            identitySources: { _ in [] },
            crossServerSourceResolver: nil,
            loadSeasonEpisodeRoster: { _, _ in .loaded(roster) }
        )

        let vm = environment.makeViewModel(for: show, libraryOrigin: nil)
        await vm.loadSeasonEpisodeRoster(for: 1)

        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 1), .loaded(roster))
    }

    func testSourceSwitchRejectsLateRosterWithoutErasingNewerSameSeasonState() async {
        let firstShow = series("show-a", tmdbID: 101)
        let secondShow = series("show-b", tmdbID: 101)
        let firstProvider = FakeMediaProvider(allItems: [firstShow], accountID: "a")
        let secondProvider = FakeMediaProvider(allItems: [secondShow], accountID: "b")
        firstProvider.childrenByParent = ["show-a": []]
        secondProvider.childrenByParent = ["show-b": []]
        let oldGate = RosterAsyncGate()
        let calls = RosterCallLog()
        let oldRoster = makeRoster(tmdbID: 101, seasonNumber: 1, episodeIDs: [11])
        let newRoster = makeRoster(tmdbID: 101, seasonNumber: 1, episodeIDs: [21])
        let vm = ItemDetailViewModel(
            provider: firstProvider,
            itemID: firstShow.id,
            initialItem: firstShow,
            loadSeasonEpisodeRoster: { item, seasonNumber in
                calls.record(itemID: item.id, seasonNumber: seasonNumber)
                if item.id == firstShow.id {
                    await oldGate.wait()
                    return .loaded(oldRoster)
                }
                return .loaded(newRoster)
            },
            sourceAccountID: "a",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache(),
            initialSources: [
                MediaSourceRef(accountID: "a", itemID: firstShow.id),
                MediaSourceRef(accountID: "b", itemID: secondShow.id),
            ],
            alternateProviderResolver: { accountID in
                accountID == "b" ? secondProvider : firstProvider
            }
        )
        await vm.load()

        let staleLoad = Task { @MainActor in
            await vm.loadSeasonEpisodeRoster(for: 1)
        }
        await waitUntil { calls.count == 1 }

        await vm.switchToSource(accountID: "b")
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 1), .notLoaded)
        await vm.loadSeasonEpisodeRoster(for: 1)
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 1), .loaded(newRoster))

        oldGate.open()
        await staleLoad.value
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 1), .loaded(newRoster))
        XCTAssertEqual(calls.entries.map(\.itemID), ["show-a", "show-b"])
    }

    func testDisappearanceResetsStateAndRejectsLateResult() async {
        let show = series("show", tmdbID: 101)
        let roster = makeRoster(tmdbID: 101, seasonNumber: 1, episodeIDs: [11])
        let gate = RosterAsyncGate()
        let calls = RosterCallLog()
        let vm = makeViewModel(show: show) { item, seasonNumber in
            calls.record(itemID: item.id, seasonNumber: seasonNumber)
            await gate.wait()
            return .loaded(roster)
        }

        let load = Task { @MainActor in
            await vm.loadSeasonEpisodeRoster(for: 1)
        }
        await waitUntil { calls.count == 1 }
        vm.suspendEnrichment()
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 1), .notLoaded)

        gate.open()
        await load.value
        XCTAssertEqual(vm.seasonEpisodeRosterState(for: 1), .notLoaded)
    }

    func testForceRefreshReloadsPlayableLibraryEpisodes() async {
        let show = series("show", tmdbID: 101)
        let provider = FakeMediaProvider(allItems: [show])
        provider.childrenByParent = ["show": [
            MediaItem(id: "s1", title: "Season 1", kind: .season, seasonNumber: 1)
        ]]
        provider.childrenResponsesByParent = [
            "s1": [
                [MediaItem(id: "old", title: "Old", kind: .episode, episodeNumber: 1)],
                [MediaItem(id: "new", title: "New", kind: .episode, episodeNumber: 1)],
            ]
        ]
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: show.id,
            initialItem: show,
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
        await vm.load()

        await vm.loadEpisodes(for: "s1")
        XCTAssertEqual(vm.episodes(for: "s1")?.map(\.id), ["old"])
        await vm.loadEpisodes(for: "s1")
        XCTAssertEqual(provider.childrenCallCount["s1"], 1)

        await vm.loadEpisodes(for: "s1", forceRefresh: true)
        XCTAssertEqual(vm.episodes(for: "s1")?.map(\.id), ["new"])
        XCTAssertEqual(provider.childrenCallCount["s1"], 2)
    }

    func testLoadEpisodesSupportsLoadedSeriesAsFlatEpisodeContainer() async {
        let show = series("show", tmdbID: 101)
        let provider = FakeMediaProvider(allItems: [show])
        provider.childrenResponsesByParent = [
            "show": [
                [MediaItem(id: "old", title: "Old", kind: .episode, seasonNumber: 1)],
                [MediaItem(id: "new", title: "New", kind: .episode, seasonNumber: 1)],
            ]
        ]
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "season-entry",
            initialItem: show,
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.loadEpisodes(for: show.id)
        XCTAssertEqual(vm.episodes(for: show.id)?.map(\.id), ["old"])

        await vm.loadEpisodes(for: show.id, forceRefresh: true)
        XCTAssertEqual(vm.episodes(for: show.id)?.map(\.id), ["new"])
        XCTAssertEqual(provider.childrenCallCount[show.id], 2)
    }

    func testForcedLibraryRefreshSupersedesPendingLoadAndKeepsItsWaiters() async {
        let show = series("show", tmdbID: 101)
        let provider = FakeMediaProvider(allItems: [show])
        let staleGate = RosterAsyncGate()
        let freshGate = RosterAsyncGate()
        defer {
            staleGate.open()
            freshGate.open()
        }
        provider.childrenResponsesByParent = ["show": [
            [MediaItem(id: "old", title: "Old", kind: .episode, seasonNumber: 1)],
            [MediaItem(id: "new", title: "New", kind: .episode, seasonNumber: 1)],
        ]]
        provider.childrenGate = ["show": { call in
            if call == 1 { await staleGate.wait() }
            else { await freshGate.wait() }
        }]
        let vm = ItemDetailViewModel(
            provider: provider, itemID: show.id, initialItem: show,
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
        var firstReturned = false
        let first = Task { @MainActor in
            await vm.loadEpisodes(for: show.id)
            firstReturned = true
        }
        await waitUntil { provider.childrenCallCount[show.id] == 1 }
        let refresh = Task { @MainActor in
            await vm.loadEpisodes(for: show.id, forceRefresh: true)
        }
        await waitUntil { provider.childrenCallCount[show.id] == 2 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(firstReturned)

        freshGate.open()
        await refresh.value
        await first.value
        XCTAssertEqual(vm.episodes(for: show.id)?.map(\.id), ["new"])
        staleGate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(vm.episodes(for: show.id)?.map(\.id), ["new"])
        XCTAssertEqual(provider.childrenCallCount[show.id], 2)
    }

    func testMixedSeriesContainerKeepsSeasonObjectsOutOfEpisodeCache() async {
        let show = series("show", tmdbID: 101)
        let provider = FakeMediaProvider(allItems: [show])
        provider.childrenByParent = ["show": [
            MediaItem(id: "season1", title: "Season 1", kind: .season, seasonNumber: 1),
            MediaItem(id: "episode1", title: "Episode 1", kind: .episode, seasonNumber: 1, episodeNumber: 1),
        ]]
        let vm = ItemDetailViewModel(
            provider: provider, itemID: show.id, initialItem: show,
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
        await vm.load()
        await vm.loadEpisodes(for: show.id, forceRefresh: true)
        XCTAssertEqual(vm.episodes(for: show.id)?.map(\.id), ["episode1"])
    }

    func testVirtualSeasonMetadataIsNotLocalPresenceEvidence() async {
        let show = series("show", tmdbID: 101)
        let provider = FakeMediaProvider(allItems: [show])
        provider.childrenByParent = ["show": [
            MediaItem(
                id: "virtual", title: "Season 1", kind: .season,
                seasonNumber: 1, locallyValidatedPlayableSource: false
            ),
            MediaItem(id: "real", title: "Season 2", kind: .season, seasonNumber: 2),
        ]]
        let vm = ItemDetailViewModel(
            provider: provider, itemID: show.id, initialItem: show,
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
        await vm.load()
        let owned = await vm.ownedSeasonNumbersAcrossSources()
        XCTAssertEqual(owned, [2])
    }

    private func makeViewModel(
        show: MediaItem,
        loader: (@Sendable (MediaItem, Int) async -> SeasonEpisodeRosterResult)?
    ) -> ItemDetailViewModel {
        ItemDetailViewModel(
            provider: FakeMediaProvider(allItems: [show]),
            itemID: show.id,
            initialItem: show,
            loadSeasonEpisodeRoster: loader,
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )
    }

    private func series(_ id: String, tmdbID: Int?) -> MediaItem {
        MediaItem(
            id: id,
            title: "Series",
            kind: .series,
            providerIDs: tmdbID.map { ["Tmdb": String($0)] } ?? [:]
        )
    }

    private func makeRoster(
        tmdbID: Int,
        seasonNumber: Int,
        episodeIDs: [Int] = []
    ) -> SeasonEpisodeRoster {
        SeasonEpisodeRoster(
            seriesTMDbID: tmdbID,
            seasonNumber: seasonNumber,
            episodes: episodeIDs.enumerated().map { index, id in
                SeasonEpisodeMetadata(
                    id: id,
                    seasonNumber: seasonNumber,
                    episodeNumber: index + 1
                )
            }
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private final class RosterAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class RosterCallLog: @unchecked Sendable {
    struct Entry: Equatable {
        let itemID: String
        let seasonNumber: Int
    }

    private let lock = NSLock()
    private var storedEntries: [Entry] = []

    @discardableResult
    func record(itemID: String, seasonNumber: Int) -> Int {
        lock.lock()
        storedEntries.append(.init(itemID: itemID, seasonNumber: seasonNumber))
        let count = storedEntries.count
        lock.unlock()
        return count
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries
    }

    var count: Int { entries.count }
}

private final class RosterResponseSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [SeasonEpisodeRosterResult]
    private var calls = 0

    init(_ responses: [SeasonEpisodeRosterResult]) {
        self.responses = responses
    }

    func next() -> SeasonEpisodeRosterResult {
        lock.lock()
        defer { lock.unlock() }
        let response = responses[min(calls, responses.count - 1)]
        calls += 1
        return response
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
