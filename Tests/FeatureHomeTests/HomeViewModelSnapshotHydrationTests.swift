import XCTest
import CoreModels
import CoreNetworking
@testable import FeatureHome

/// Verifies the instant-launch behaviour: `HomeViewModel` hydrates the last
/// content snapshot synchronously at construction (so the hero + rows paint with
/// no network), then the first appearance refreshes SILENTLY (never flashing a
/// loading skeleton), persists fresh content, and never lets a transient empty
/// aggregate blank out good content already on screen.
@MainActor
final class HomeViewModelSnapshotHydrationTests: XCTestCase {
    private func resolved(_ provider: FakeMediaProvider, accountID: String) -> ResolvedAccount {
        ResolvedAccount(
            account: Account(
                id: accountID, server: provider.session.server,
                userID: provider.session.userID, userName: provider.session.userName,
                deviceID: provider.session.deviceID
            ),
            provider: provider
        )
    }

    private func waitForResume(_ vm: HomeViewModel, id: String) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !vm.continueWatchingForDetail.contains(where: { $0.id == id }) {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func testLatestPublishesBeforeSlowContinueWatchingCompletes() async {
        let resumeGate = HomeRefreshGate()
        defer { resumeGate.open() }
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "resume", title: "Resume", kind: .movie)]
        provider.continueWatchingGate = { await resumeGate.wait() }
        provider.latestItems = [MediaItem(id: "latest", title: "Latest", kind: .movie)]
        let store = InMemoryHomeContentStore()
        let home = makeViewModel(provider: provider, contentStore: store)

        let load = Task { await home.load() }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, home.state.value?.latest.first?.id != "latest" {
            await Task.yield()
        }

        XCTAssertEqual(home.state.value?.latest.first?.id, "latest",
                       "A ready row must not wait for Continue Watching.")
        XCTAssertTrue(home.isRefreshing)
        XCTAssertTrue(home.loadingRows.contains(.continueWatching))
        XCTAssertFalse(home.loadingRows.contains(.recentlyAdded))
        XCTAssertNil(store.load(), "An incomplete Home must not replace the durable snapshot.")
        await home.loadIfNeeded(for: .default)
        resumeGate.open()
        await load.value
        XCTAssertEqual(home.state.value?.continueWatching.first?.id, "resume")
        XCTAssertEqual(provider.librariesCallCount, 1, "Publishing a row must not restart the launch load.")
    }

    func testUnmergedRowsPublishBeforeSlowResumeAndRemainingLibraryRequests() async {
        let resumeGate = HomeRefreshGate()
        let libraryGate = HomeRefreshGate()
        defer {
            resumeGate.open()
            libraryGate.open()
        }
        let provider = FakeMediaProvider(allItems: [
            MediaItem(id: "recent", title: "Recent", kind: .movie)
        ])
        provider.continueWatchingGate = { await resumeGate.wait() }
        provider.libraryItems = (0..<20).map {
            MediaLibrary(id: "library-\($0)", title: "Library \($0)", kind: .movie)
        }
        for library in provider.libraryItems.dropFirst() {
            provider.containerGates[library.id] = { await libraryGate.wait() }
        }
        var visibility = HomeLibraryVisibility(mergeLibrariesOnHome: false)
        for library in provider.libraryItems {
            visibility.setLibraryRowEnabled(true, libraryKey: "a:\(library.id)", kind: .recentlyAdded)
        }
        let home = HomeViewModel(
            accounts: [resolved(provider, accountID: "a")],
            layoutStore: InMemoryHomeLayoutStore(),
            contentStore: InMemoryHomeContentStore(),
            currentVisibility: { visibility }
        )

        let load = Task { await home.load() }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, home.state.value?.librarySections.first?.cardCount != 1 {
            await Task.yield()
        }

        XCTAssertEqual(home.state.value?.librarySections.first?.library.key, "a:library-0",
                       "The first ready library row must appear with nineteen other libraries still loading.")
        XCTAssertTrue(home.isRefreshing)
        XCTAssertLessThanOrEqual(provider.maximumActivePageRequests, 5,
                                 "Additional rows must stay queued instead of launching twenty requests at once.")
        XCTAssertLessThan(provider.requestedPages.count, 20)
        resumeGate.open()
        libraryGate.open()
        await load.value
        XCTAssertEqual(home.state.value?.librarySections.count, 20)
        XCTAssertEqual(provider.librariesCallCount, 1)
        XCTAssertEqual(provider.requestedPages.count, 20)
    }

    func testSlowResumeFeedsCannotOccupyEverySlotNeededByOtherRows() async {
        for merged in [true, false] {
            let gate = HomeRefreshGate()
            defer { gate.open() }
            var visibility = HomeLibraryVisibility(mergeLibrariesOnHome: merged)
            let accounts = (0..<5).map { index -> ResolvedAccount in
                let id = "source-\(index)"
                let movie = MediaItem(id: "movie-\(index)", title: "Movie \(index)", kind: .movie)
                let provider = FakeMediaProvider(allItems: [movie])
                provider.continueWatchingGate = { await gate.wait() }
                provider.latestItems = [movie]
                provider.libraryItems = [MediaLibrary(id: "movies", title: "Movies", kind: .movie)]
                visibility.setLibraryRowEnabled(true, libraryKey: "\(id):movies", kind: .recentlyAdded)
                return resolved(provider, accountID: id)
            }
            let home = HomeViewModel(
                accounts: accounts, layoutStore: InMemoryHomeLayoutStore(),
                currentVisibility: { visibility }
            )
            let load = Task { await home.load() }
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                let content = home.state.value
                if content?.latest.count == 5,
                   merged || content?.librarySections.filter({ $0.cardCount == 1 }).count == 5 {
                    break
                }
                await Task.yield()
            }
            XCTAssertEqual(home.state.value?.latest.count, 5,
                           "Five stalled resume feeds must not consume the queue for other global rows.")
            if !merged {
                XCTAssertEqual(home.state.value?.librarySections.filter { $0.cardCount == 1 }.count, 5,
                               "The library-row queue must remain independent of stalled global feeds.")
            }
            XCTAssertTrue(home.loadingRows.contains(.continueWatching))
            gate.open()
            await load.value
        }
    }

    func testMergedRowsKeepAccountOrderAndUserActionsWhileAnotherRowLoads() async {
        let gate = HomeRefreshGate()
        defer { gate.open() }
        let first = FakeMediaProvider(allItems: [], kind: .plex)
        first.latestItems = [MediaItem(id: "first-latest", title: "First latest", kind: .movie)]
        first.continueWatchingItems = [MediaItem(id: "first-resume", title: "First resume", kind: .movie)]
        let second = FakeMediaProvider(allItems: [], kind: .emby)
        second.latestItems = [MediaItem(id: "second-latest", title: "Second latest", kind: .movie)]
        second.continueWatchingItems = [MediaItem(id: "second-resume", title: "Second resume", kind: .movie)]
        second.continueWatchingGate = { await gate.wait() }
        let home = HomeViewModel(
            accounts: [resolved(first, accountID: "first"), resolved(second, accountID: "second")],
            layoutStore: InMemoryHomeLayoutStore(), contentStore: InMemoryHomeContentStore()
        )
        let load = Task { await home.load() }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, home.state.value?.latest.count != 2 {
            await Task.yield()
        }
        XCTAssertEqual(home.state.value?.latest.map(\.id), ["first-latest", "second-latest"])
        XCTAssertTrue(home.loadingRows.contains(.continueWatching))
        XCTAssertTrue(home.state.value?.continueWatching.isEmpty ?? true,
                      "A merged row arrives once, not as a succession of differently sorted partial feeds.")
        home.applyWatchedState(MediaItemMutation(
            itemIDs: ["first-latest"], scopedItemIDs: ["first:first-latest"], played: true
        ))
        gate.open()
        await load.value
        XCTAssertEqual(home.state.value?.latest.map(\.id), ["first-latest", "second-latest"])
        XCTAssertEqual(home.state.value?.latest.first?.isPlayed, true,
                       "Finishing another row must not undo an action on an already usable card.")
        XCTAssertEqual(home.state.value?.continueWatching.map(\.id), ["first-resume", "second-resume"])
    }

    func testLibraryFailureIsExplicitAndDoesNotHideOtherRows() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "movie", title: "Movie", kind: .movie)])
        provider.latestItems = [MediaItem(id: "latest", title: "Latest", kind: .movie)]
        provider.libraryItems = [
            MediaLibrary(id: "ready", title: "Ready", kind: .movie),
            MediaLibrary(id: "offline", title: "Offline", kind: .movie)
        ]
        provider.containerErrors["offline"] = .serverUnreachable
        var visibility = HomeLibraryVisibility(mergeLibrariesOnHome: false)
        for library in provider.libraryItems {
            visibility.setLibraryRowEnabled(true, libraryKey: "a:\(library.id)", kind: .recentlyAdded)
        }
        let home = HomeViewModel(
            accounts: [resolved(provider, accountID: "a")],
            layoutStore: InMemoryHomeLayoutStore(),
            currentVisibility: { visibility }
        )
        await home.load()
        XCTAssertEqual(home.state.value?.latest.first?.id, "latest")
        XCTAssertEqual(home.state.value?.librarySections.first?.cardCount, 1)
        XCTAssertEqual(home.state.value?.librarySections.last?.failures[.recentlyAdded], .serverUnreachable)
        XCTAssertTrue(home.state.value?.librarySections.last?.loadingRows.isEmpty ?? false)
        XCTAssertFalse(home.isRefreshing)

        provider.containerErrors = [:]
        await home.load(showLoadingState: false)
        XCTAssertEqual(home.state.value?.librarySections.map(\.cardCount), [1, 1])
        XCTAssertTrue(home.state.value?.librarySections.allSatisfy { $0.failures.isEmpty } ?? false)
    }

    func testGlobalFailureLeavesUsableRowsAndNoPermanentLoadingState() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "resume", title: "Resume", kind: .movie)]
        provider.latestError = .serverUnreachable
        let home = makeViewModel(provider: provider, contentStore: InMemoryHomeContentStore())
        await home.load()
        XCTAssertEqual(home.state.value?.continueWatching.first?.id, "resume")
        XCTAssertEqual(home.rowFailures[.recentlyAdded], .serverUnreachable)
        XCTAssertTrue(home.loadingRows.isEmpty)
        XCTAssertFalse(home.isRefreshing)
    }

    func testContinueWatchingDetailsFollowFailureAndClearAfterRecovery() async throws {
        for kind in [ProviderKind.plex, .jellyfin, .emby] {
            for merged in [true, false] {
                let provider = FakeMediaProvider(allItems: [], kind: kind)
                provider.continueWatchingError = .invalidResponse
                provider.continueWatchingGate = {
                    HTTPResponseDiagnostics.recordHTTPFailure(status: 503)
                }
                let visibility = HomeLibraryVisibility(mergeLibrariesOnHome: merged)
                let home = HomeViewModel(
                    accounts: [resolved(provider, accountID: "private-account")],
                    layoutStore: InMemoryHomeLayoutStore(), currentVisibility: { visibility }
                )
                await home.load()
                let diagnostic = try XCTUnwrap(home.continueWatchingDiagnostic)
                XCTAssertEqual(diagnostic.provider, kind)
                XCTAssertEqual(diagnostic.operation, .homeContinueWatching)
                XCTAssertEqual(diagnostic.failures.first?.error, home.rowFailures[.continueWatching])
                XCTAssertEqual(diagnostic.failures.first?.http, [.init(route: .continueWatching, httpStatus: 503)])
                XCTAssertFalse(diagnostic.supportText.contains("private-account"))

                provider.continueWatchingError = nil
                await home.load(showLoadingState: false)
                XCTAssertNil(home.continueWatchingDiagnostic)
                XCTAssertNil(home.rowFailures[.continueWatching])
            }
        }
    }

    func testContinueWatchingDetailsMatchFirstFailedAccountNotFirstAccount() async throws {
        let healthy = FakeMediaProvider(allItems: [], kind: .jellyfin)
        let failed = FakeMediaProvider(allItems: [], kind: .plex)
        failed.continueWatchingError = .decoding
        let later = FakeMediaProvider(allItems: [], kind: .emby)
        later.continueWatchingError = .unauthorized
        let home = HomeViewModel(
            accounts: [resolved(healthy, accountID: "healthy"), resolved(failed, accountID: "failed"),
                       resolved(later, accountID: "later")],
            layoutStore: InMemoryHomeLayoutStore()
        )
        await home.load()
        XCTAssertEqual(home.rowFailures[.continueWatching], .decoding)
        XCTAssertEqual(home.continueWatchingDiagnostic?.provider, .plex)
        XCTAssertEqual(home.continueWatchingDiagnostic?.failures.first?.error, .decoding)
        failed.continueWatchingError = .cancelled
        later.continueWatchingError = nil
        await home.load(showLoadingState: false)
        XCTAssertNil(home.continueWatchingDiagnostic, "Cancellation must not create a shareable failure report.")
    }

    func testResumeFailureWaitsForReconciledContentBeforePublication() async throws {
        for merged in [true, false] {
            for healthyCount in [0, 4] {
                let pause = HomeResumePublicationPause(detailReads: healthyCount)
                defer { pause.release.open() }
                var accounts = (0..<healthyCount).map { index in
                    let provider = FakeMediaProvider(allItems: [], kind: .plex)
                    provider.continueWatchingItems = [
                        MediaItem(id: "resume-\(index)", title: "Resume \(index)", kind: .movie)
                    ]
                    return resolved(provider, accountID: "healthy-\(index)")
                }
                let offline = FakeMediaProvider(allItems: [], kind: .jellyfin)
                offline.continueWatchingError = .serverUnreachable
                accounts.append(resolved(offline, accountID: "offline"))
                let visibility = HomeLibraryVisibility(mergeLibrariesOnHome: merged)
                let home = HomeViewModel(
                    accounts: accounts, layoutStore: InMemoryHomeLayoutStore(),
                    contentStore: InMemoryHomeContentStore(),
                    currentVisibility: { visibility },
                    recentlyAppliedRecency: {
                        await pause.waitForPublication()
                        return [:]
                    }
                )
                let load = Task { await home.load() }
                let deadline = ContinuousClock.now + .seconds(2)
                while !(await pause.isWaiting), ContinuousClock.now < deadline { await Task.yield() }
                let isWaiting = await pause.isWaiting
                XCTAssertTrue(isWaiting, "Hold the publication after every server has settled.")
                XCTAssertTrue(home.loadingRows.contains(.continueWatching))
                XCTAssertNil(home.rowFailures[.continueWatching],
                             "Publishing a failure before its usable cards tears down the loading focus target.")
                XCTAssertNil(home.continueWatchingDiagnostic)
                let row = try XCTUnwrap(HomeRow.rows(
                    for: try XCTUnwrap(home.state.value), isLibraryVisible: { _ in true },
                    loadingRows: home.loadingRows, failures: home.rowFailures
                ).first { $0.kind == .continueWatching })
                XCTAssertNil(row.failure)
                XCTAssertGreaterThan(row.loadingPlaceholderCount, 0)

                pause.release.open()
                await load.value
                XCTAssertEqual(home.state.value?.continueWatching.map(\.id),
                               (0..<healthyCount).map { "resume-\($0)" })
                XCTAssertEqual(home.rowFailures[.continueWatching], .serverUnreachable,
                               "Retain the source failure; only an empty settled row presents its error.")
                XCTAssertEqual(home.continueWatchingDiagnostic?.provider, .jellyfin)
                XCTAssertEqual(home.continueWatchingDiagnostic?.failures.first?.error, .serverUnreachable)
                XCTAssertTrue(home.loadingRows.isEmpty)
                let settledRow = try XCTUnwrap(HomeRow.rows(
                    for: try XCTUnwrap(home.state.value), isLibraryVisible: { _ in true },
                    loadingRows: home.loadingRows, failures: home.rowFailures
                ).first { $0.kind == .continueWatching })
                XCTAssertEqual(settledRow.items.count, healthyCount)
                XCTAssertEqual(settledRow.loadingPlaceholderCount, 0)
                XCTAssertEqual(settledRow.failure, .serverUnreachable)
            }
        }
    }

    func testVisibilityChangeDuringCachedLaunchCancelsAndReplacesTheOldLoad() async {
        let gate = HomeRefreshGate()
        defer { gate.open() }
        let provider = FakeMediaProvider(allItems: [])
        provider.libraryItems = [
            MediaLibrary(id: "old-library", title: "Old", kind: .movie),
            MediaLibrary(id: "new-library", title: "New", kind: .movie)
        ]
        provider.latestItems = [
            MediaItem(id: "old", title: "Old", kind: .movie, libraryID: "old-library")
        ]
        provider.continueWatchingGate = { await gate.wait() }
        var visibility = HomeLibraryVisibility.default
        let home = HomeViewModel(
            accounts: [resolved(provider, accountID: "a")],
            layoutStore: InMemoryHomeLayoutStore(),
            contentStore: InMemoryHomeContentStore(snapshot(cwIDs: ["cached"])),
            currentVisibility: { visibility }
        )
        let first = Task { await home.loadIfNeeded(for: visibility) }
        let startedDeadline = Date().addingTimeInterval(1)
        while Date() < startedDeadline, home.state.value?.latest.first?.id != "old" {
            await Task.yield()
        }
        XCTAssertEqual(home.state.value?.latest.first?.id, "old")
        visibility.setEnabled(false, for: "a:old-library")
        provider.latestItems = [
            MediaItem(id: "new", title: "New", kind: .movie, libraryID: "new-library")
        ]
        await home.loadIfNeeded(for: visibility)
        gate.open()
        await first.value
        let finishedDeadline = Date().addingTimeInterval(2)
        while Date() < finishedDeadline, home.isRefreshing || provider.librariesCallCount < 2 {
            await Task.yield()
        }
        XCTAssertFalse(home.isRefreshing)
        XCTAssertEqual(provider.librariesCallCount, 2)
        XCTAssertEqual(home.state.value?.latest.map(\.id), ["new"])
        XCTAssertTrue(home.loadingRows.isEmpty)
    }

    func testVisibilityChangeWithoutAnotherViewTaskCannotStrandLoadingRows() async {
        for merged in [true, false] {
            let gate = HomeRefreshGate()
            defer { gate.open() }
            let provider = FakeMediaProvider(allItems: [])
            provider.latestItems = [MediaItem(id: "latest", title: "Latest", kind: .movie)]
            provider.continueWatchingItems = [MediaItem(id: "resume", title: "Resume", kind: .movie)]
            provider.continueWatchingGate = { await gate.wait() }
            var visibility = HomeLibraryVisibility(mergeLibrariesOnHome: merged)
            let home = HomeViewModel(
                accounts: [resolved(provider, accountID: "a")],
                layoutStore: InMemoryHomeLayoutStore(),
                currentVisibility: { visibility }
            )

            let load = Task { await home.loadIfNeeded(for: visibility) }
            let startedDeadline = Date().addingTimeInterval(1)
            while Date() < startedDeadline, home.state.value?.latest.first?.id != "latest" {
                await Task.yield()
            }
            XCTAssertEqual(home.state.value?.latest.first?.id, "latest")
            XCTAssertTrue(home.loadingRows.contains(.continueWatching))

            // Settings can change while Home's view-owned task is absent.
            visibility.setGlobalRowEnabled(false, for: .watchlist)
            gate.open()
            await load.value
            let finishedDeadline = Date().addingTimeInterval(2)
            while Date() < finishedDeadline, home.isRefreshing || provider.librariesCallCount < 2 {
                await Task.yield()
            }

            XCTAssertEqual(provider.librariesCallCount, 2, "The model must replace its obsolete load.")
            XCTAssertFalse(home.isRefreshing)
            XCTAssertTrue(home.loadingRows.isEmpty, "A discarded result must not leave permanent skeletons.")
            XCTAssertEqual(home.state.value?.continueWatching.map(\.id), ["resume"])
        }
    }

    func testVisibilityChangeDuringFinalReconciliationDoesNotCompleteObsoleteLoad() async {
        for merged in [true, false] {
            let pause = HomeResumePublicationPause(detailReads: 2)
            let replacementGate = HomeRefreshGate()
            defer {
                pause.release.open()
                replacementGate.open()
            }
            let provider = FakeMediaProvider(allItems: [])
            provider.continueWatchingItems = [MediaItem(id: "resume", title: "Resume", kind: .movie)]
            var visibility = HomeLibraryVisibility(mergeLibrariesOnHome: merged)
            let home = HomeViewModel(
                accounts: [resolved(provider, accountID: "a")],
                layoutStore: InMemoryHomeLayoutStore(),
                currentVisibility: { visibility },
                recentlyAppliedRecency: {
                    await pause.waitForPublication()
                    return [:]
                }
            )
            let load = Task { await home.load() }
            let deadline = ContinuousClock.now + .seconds(2)
            while !(await pause.isWaiting), ContinuousClock.now < deadline { await Task.yield() }
            let isWaiting = await pause.isWaiting
            XCTAssertTrue(isWaiting, "Pause final reconciliation after detail and progressive publication.")
            XCTAssertFalse(home.loadingRows.contains(.continueWatching))

            visibility.setGlobalRowEnabled(false, for: .watchlist)
            provider.continueWatchingGate = { await replacementGate.wait() }
            pause.release.open()
            await load.value
            let restartedDeadline = ContinuousClock.now + .seconds(2)
            while provider.librariesCallCount < 2, ContinuousClock.now < restartedDeadline { await Task.yield() }
            XCTAssertEqual(provider.librariesCallCount, 2)
            XCTAssertTrue(home.loadingRows.contains(.continueWatching),
                          "The obsolete final result must not mark the cold load complete.")

            replacementGate.open()
            let finishedDeadline = ContinuousClock.now + .seconds(2)
            while home.isRefreshing, ContinuousClock.now < finishedDeadline { await Task.yield() }
            XCTAssertFalse(home.isRefreshing)
            XCTAssertTrue(home.loadingRows.isEmpty)
        }
    }

    func testRestartedColdLoadStillPublishesRowsAfterResumeHadArrived() async {
        let latestGate = HomeRefreshGate()
        let secondResumeGate = HomeRefreshGate()
        defer {
            latestGate.open()
            secondResumeGate.open()
        }
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "resume", title: "Resume", kind: .movie)]
        provider.latestItems = [MediaItem(id: "latest", title: "Latest", kind: .movie)]
        provider.latestGate = { await latestGate.wait() }
        var visibility = HomeLibraryVisibility.default
        let home = HomeViewModel(
            accounts: [resolved(provider, accountID: "a")],
            layoutStore: InMemoryHomeLayoutStore(), currentVisibility: { visibility }
        )
        let first = Task { await home.loadIfNeeded(for: visibility) }
        let firstDeadline = Date().addingTimeInterval(1)
        while Date() < firstDeadline, !home.hasLiveContinueWatching { await Task.yield() }
        XCTAssertTrue(home.hasLiveContinueWatching)
        visibility.setGlobalRowEnabled(false, for: .watchlist)
        provider.continueWatchingGate = { await secondResumeGate.wait() }
        await home.loadIfNeeded(for: visibility)
        latestGate.open()
        await first.value
        let rowDeadline = Date().addingTimeInterval(1)
        while Date() < rowDeadline, home.state.value?.latest.first?.id != "latest" { await Task.yield() }
        XCTAssertEqual(provider.librariesCallCount, 2)
        XCTAssertEqual(home.state.value?.latest.first?.id, "latest")
        XCTAssertTrue(home.isRefreshing)
        XCTAssertTrue(home.loadingRows.contains(.continueWatching))
        secondResumeGate.open()
        let finishDeadline = Date().addingTimeInterval(2)
        while Date() < finishDeadline, home.isRefreshing { await Task.yield() }
        XCTAssertFalse(home.isRefreshing)
    }

    func testCancellationDoesNotStartQueuedLibraryRequestsOrPublishMoreRows() async {
        let gate = HomeRefreshGate()
        defer { gate.open() }
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "movie", title: "Movie", kind: .movie)])
        provider.libraryItems = (0..<20).map {
            MediaLibrary(id: "library-\($0)", title: "Library \($0)", kind: .movie)
        }
        var visibility = HomeLibraryVisibility(mergeLibrariesOnHome: false)
        for library in provider.libraryItems {
            visibility.setLibraryRowEnabled(true, libraryKey: "a:\(library.id)", kind: .recentlyAdded)
            provider.containerGates[library.id] = { await gate.wait() }
        }
        let accounts = [resolved(provider, accountID: "a")]
        let progress = HomeProgressCounter()
        let load = Task {
            await HomeAggregator().unmergedContent(
                from: accounts, visibility: visibility,
                onProgress: { _ in await progress.record() }
            )
        }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            let published = await progress.count
            if provider.requestedPages.count == 5, published == 4 { break }
            await Task.yield()
        }
        XCTAssertEqual(provider.requestedPages.count, 5)
        let beforeCancellation = await progress.count
        XCTAssertEqual(beforeCancellation, 4, "All initial feed callbacks must settle before cancellation.")
        load.cancel()
        gate.open()
        _ = await load.value
        let afterCancellation = await progress.count
        XCTAssertEqual(provider.requestedPages.count, 5)
        XCTAssertEqual(afterCancellation, beforeCancellation)
    }

    func testFirstDetailCanResumeBeforeOtherServersAndHomeMetadataFinish() async throws {
        for merged in [true, false] {
            let show = MediaItem(id: "show", title: "Show", kind: .series, sourceAccountID: "fast")
            let episode = MediaItem(
                id: "s4e1", title: "Resume", kind: .episode,
                seasonNumber: 4, episodeNumber: 1,
                seriesID: show.id, resumePosition: 867
            )
            let fast = FakeMediaProvider(allItems: [show], kind: .plex)
            fast.continueWatchingItems = [episode]
            let metadataGate = HomeRefreshGate()
            fast.latestGate = { await metadataGate.wait() }
            let slow = FakeMediaProvider(allItems: [], kind: .jellyfin)
            let slowGate = HomeRefreshGate()
            slow.continueWatchingGate = { await slowGate.wait() }
            let visibility = HomeLibraryVisibility(mergeLibrariesOnHome: merged)
            let home = HomeViewModel(
                accounts: [resolved(fast, accountID: "fast"), resolved(slow, accountID: "slow")],
                layoutStore: InMemoryHomeLayoutStore(),
                contentStore: InMemoryHomeContentStore(),
                currentVisibility: { visibility }
            )
            let load = Task { await home.load() }
            await waitForResume(home, id: episode.id)
            XCTAssertTrue(home.isRefreshing, "The slow server and metadata are still blocked")
            XCTAssertTrue(home.loadingRows.contains(.continueWatching),
                          "The merged resume row still waits for its other source, not unrelated rows.")
            XCTAssertTrue(home.state.value?.continueWatching.isEmpty ?? true)
            let environment = DetailOpenEnvironment(
                resolveProvider: { _ in fast },
                resolveOptionalProvider: { _ in fast },
                identitySources: { _ in [] },
                crossServerSourceResolver: nil,
                continueWatchingSnapshot: { home.continueWatchingForDetail }
            )
            let detail = try environment.makeViewModel(for: show, libraryOrigin: nil)
            XCTAssertEqual(detail.serverResumeEpisode?.id, episode.id, "merged=\(merged)")
            XCTAssertEqual(detail.serverResumeEpisode?.resumePosition, 867)
            home.applyWatchedState(MediaItemMutation(
                itemIDs: [episode.id], scopedItemIDs: ["fast:\(episode.id)"], played: true
            ))
            XCTAssertTrue(home.continueWatchingForDetail.isEmpty, "Completed native hints must be removed too")

            metadataGate.open()
            slowGate.open()
            await load.value
        }
    }

    func testMergedHomeKeepsEachServersNativeResumeEpisodeForDetail() async {
        let plexShow = MediaItem(
            id: "plex-show", title: "Show", kind: .series,
            providerIDs: ["Tmdb": "10"], sourceAccountID: "plex"
        )
        let jellyShow = MediaItem(
            id: "jelly-show", title: "Show", kind: .series,
            providerIDs: ["Tmdb": "10"], sourceAccountID: "jelly"
        )
        let plexEpisode = MediaItem(
            id: "plex-e1", title: "Episode", kind: .episode,
            seasonNumber: 4, episodeNumber: 1, seriesID: plexShow.id,
            resumePosition: 867, providerIDs: ["SeriesTmdb": "10"]
        )
        var jellyEpisode = plexEpisode
        jellyEpisode.id = "jelly-e1"
        jellyEpisode.seriesID = jellyShow.id
        let plex = FakeMediaProvider(allItems: [plexShow], kind: .plex)
        plex.continueWatchingItems = [plexEpisode]
        let jelly = FakeMediaProvider(allItems: [jellyShow], kind: .jellyfin)
        jelly.continueWatchingItems = [jellyEpisode]
        let home = HomeViewModel(
            accounts: [resolved(plex, accountID: "plex"), resolved(jelly, accountID: "jelly")],
            layoutStore: InMemoryHomeLayoutStore(),
            contentStore: InMemoryHomeContentStore()
        )
        await home.load()

        XCTAssertEqual(home.state.value?.continueWatching.count, 1)
        for (show, expectedID) in [(plexShow, "plex-e1"), (jellyShow, "jelly-e1")] {
            let resume = DetailPlaybackSelection.resumeItem(for: show, in: home.continueWatchingForDetail)
            XCTAssertEqual(resume?.id, expectedID)
            XCTAssertEqual(resume?.seriesID, show.id)
            XCTAssertEqual(resume?.sourceAccountID, show.sourceAccountID)
        }
    }

    private func makeViewModel(
        provider: FakeMediaProvider,
        contentStore: HomeContentStoring
    ) -> HomeViewModel {
        let server = MediaServer(id: "srv", name: "Home", baseURL: URL(string: "http://host")!, provider: .jellyfin)
        let account = Account(id: "a", server: server, userID: "u", userName: "Me", deviceID: "d")
        let resolved = ResolvedAccount(account: account, provider: provider)
        return HomeViewModel(
            accounts: [resolved],
            layoutStore: InMemoryHomeLayoutStore(),
            contentStore: contentStore
        )
    }

    /// A view model for a profile that watches NO servers.
    private func makeSourcelessViewModel(contentStore: HomeContentStoring) -> HomeViewModel {
        HomeViewModel(
            accounts: [],
            layoutStore: InMemoryHomeLayoutStore(),
            contentStore: contentStore
        )
    }

    private func snapshot(cwIDs: [String]) -> HomeViewModel.Content {
        HomeViewModel.Content(
            continueWatching: cwIDs.map { MediaItem(id: $0, title: "Cached \($0)", kind: .movie) }
        )
    }

    private func loadedContent(_ vm: HomeViewModel) -> HomeViewModel.Content? {
        if case let .loaded(content) = vm.state { return content }
        return nil
    }

    func testHydratesCachedSnapshotSynchronouslyAtInit() {
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA", "cachedB"]))
        let vm = makeViewModel(provider: FakeMediaProvider(allItems: []), contentStore: store)
        // Painted from cache BEFORE any load — no network, no skeleton.
        XCTAssertEqual(loadedContent(vm)?.continueWatching.map(\.id), ["cachedA", "cachedB"])
        XCTAssertTrue(vm.continueWatchingForDetail.isEmpty, "A launch cache is not a current resume answer")
    }

    func testNoCacheLeavesIdleForNormalLoadingState() {
        let vm = makeViewModel(provider: FakeMediaProvider(allItems: []), contentStore: InMemoryHomeContentStore())
        guard case .idle = vm.state else {
            return XCTFail("With no snapshot the VM must stay .idle so a normal loading state shows")
        }
    }

    func testFirstAppearanceRefreshesSilentlyAndSwapsFreshContentIn() async {
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA"]))
        let provider = FakeMediaProvider(allItems: [])
        // Fresh server content differs from the cache.
        provider.continueWatchingItems = [
            MediaItem(id: "freshA", title: "Fresh A", kind: .movie),
            MediaItem(id: "freshB", title: "Fresh B", kind: .movie)
        ]
        let vm = makeViewModel(provider: provider, contentStore: store)
        XCTAssertEqual(loadedContent(vm)?.continueWatching.map(\.id), ["cachedA"], "Starts on the cached snapshot")

        await vm.loadIfNeeded(for: .default)

        XCTAssertEqual(provider.librariesCallCount, 1, "The silent refresh actually re-aggregated")
        XCTAssertEqual(loadedContent(vm)?.continueWatching.map(\.id), ["freshA", "freshB"], "Fresh content swapped in")
        XCTAssertEqual(vm.continueWatchingForDetail.map(\.id), ["freshA", "freshB"])
    }

    func testSilentRefreshNeverEntersLoadingState() async {
        // Observe the state the moment loadIfNeeded runs: it must never become
        // `.loading` (which would render the skeleton over the instant cached hero).
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA"]))
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "freshA", title: "Fresh", kind: .movie)]
        let vm = makeViewModel(provider: provider, contentStore: store)

        await vm.loadIfNeeded(for: .default)
        // Ends loaded (not empty/loading) with the fresh content.
        XCTAssertEqual(loadedContent(vm)?.continueWatching.map(\.id), ["freshA"])
    }

    func testRefreshingCoversTheFullSilentRefreshLifetime() async {
        let gate = HomeRefreshGate()
        let provider = FakeMediaProvider(allItems: [])
        provider.librariesGate = { await gate.wait() }
        let vm = makeViewModel(
            provider: provider,
            contentStore: InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA"]))
        )

        let load = Task { await vm.loadIfNeeded(for: .default) }
        while provider.librariesCallCount == 0 {
            await Task.yield()
        }

        XCTAssertTrue(vm.isRefreshing, "Cached content should disclose that its live replacement is still loading")
        gate.open()
        await load.value
        XCTAssertFalse(vm.isRefreshing, "The loading disclosure must clear when aggregation finishes")
    }

    func testTransientEmptyRefreshKeepsCachedContent() async {
        // Cached snapshot present, but the fresh aggregate comes back empty (server
        // momentarily unreachable). The instant content must stay on screen.
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA", "cachedB"]))
        let provider = FakeMediaProvider(allItems: []) // returns empty rows
        let vm = makeViewModel(provider: provider, contentStore: store)

        await vm.loadIfNeeded(for: .default)
        XCTAssertTrue(vm.continueWatchingForDetail.isEmpty, "Revealing a fallback row is not a live resume answer")

        XCTAssertEqual(
            loadedContent(vm)?.continueWatching.map(\.id), ["cachedA", "cachedB"],
            "A silent refresh that came back empty must not blank out the cached content"
        )

        // Regression: a SECOND appearance with unchanged visibility (tvOS restarts
        // the `.task` on every reappearance) must stay a no-op and keep the cached
        // content — NOT run a loud load that flashes the skeleton and then drops to
        // `.empty` while the server is still down.
        await vm.loadIfNeeded(for: .default)
        XCTAssertEqual(
            loadedContent(vm)?.continueWatching.map(\.id), ["cachedA", "cachedB"],
            "Reappearance before the first successful refresh must keep the cached content, not reload loudly"
        )
    }

    func testViewTaskCancellationKeepsCompletedModelOwnedRefresh() async {
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA"]))
        let provider = FakeMediaProvider(allItems: [])
        provider.librariesGate = {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let vm = makeViewModel(provider: provider, contentStore: store)

        let first = Task { await vm.loadIfNeeded(for: .default) }
        while provider.librariesCallCount == 0 {
            await Task.yield()
        }
        first.cancel()
        await first.value

        XCTAssertFalse(
            vm.isShowingCachedSnapshot,
            "View-task cancellation must not discard a completed model-owned refresh"
        )
        await vm.loadIfNeeded(for: .default)
        XCTAssertEqual(
            provider.librariesCallCount,
            1,
            "Reappearance must not repeat the already-completed fan-out"
        )
    }

    func testCoveredHomeDefersLoadsUntilItsOwnerAllowsThem() async {
        let provider = FakeMediaProvider(allItems: [])
        var allowed = false
        let home = HomeViewModel(
            accounts: [resolved(provider, accountID: "a")],
            layoutStore: InMemoryHomeLayoutStore(),
            isLoadingAllowed: { allowed }
        )
        await home.load()
        await home.loadIfNeeded(for: .default)
        XCTAssertEqual(provider.librariesCallCount, 0)
        allowed = true
        await home.loadIfNeeded(for: .default)
        XCTAssertEqual(provider.librariesCallCount, 1)
    }

    func testPauseResumptionKeepsLiveGlobalLibraryAndCollectionCards() async throws {
        for kind in [ProviderKind.jellyfin, .plex] {
            for becomesEmpty in [false, true] {
                let pending = HomeRefreshGate()
                let refresh = HomeRefreshGate()
                defer { pending.open(); refresh.open() }
                let old = MediaItem(id: "old", title: "Old", kind: .movie)
                let provider = FakeMediaProvider(allItems: [old], kind: kind)
                provider.libraryItems = [
                    MediaLibrary(id: "ready", title: "Ready", kind: .movie),
                    MediaLibrary(id: "pending", title: "Pending", kind: .movie)
                ]
                provider.latestItems = [old]
                provider.continueWatchingItems = [old]
                provider.containerGates["pending"] = { await pending.wait() }
                let collection = CollectionSection(source: .init(
                    accountID: "a", collectionID: "collection", title: "Collection",
                    serverUserID: provider.session.userID
                ))
                var visibility = HomeLibraryVisibility(
                    mergeLibrariesOnHome: false,
                    rowCustomization: .init(defaults: .legacy, shown: [collection.rowID]),
                    collectionSections: [collection]
                )
                for id in ["ready", "pending"] {
                    visibility.setLibraryRowEnabled(true, libraryKey: "a:\(id)", kind: .recentlyAdded)
                }
                var allowed = true
                let home = HomeViewModel(
                    accounts: [resolved(provider, accountID: "a")],
                    layoutStore: InMemoryHomeLayoutStore(), contentStore: InMemoryHomeContentStore(),
                    currentVisibility: { visibility }, isLoadingAllowed: { allowed }
                )
                defer { home.invalidate() }
                let initial = Task { await home.load() }
                let deadline = ContinuousClock.now + .seconds(3)
                while (home.state.value?.librarySections.first?.cardCount != 1
                       || home.state.value?.collectionRows.first?.items.isEmpty != false
                       || home.loadingRows.contains(.continueWatching)
                       || home.loadingRows.contains(.recentlyAdded)), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let shown = try XCTUnwrap(home.state.value)
                XCTAssertEqual(shown.librarySections.first?.sections.first?.items.first?.id, "old")
                XCTAssertEqual(shown.collectionRows.first?.items.first?.id, "old")
                XCTAssertEqual(shown.latest.first?.id, "old")
                XCTAssertEqual(shown.continueWatching.first?.id, "old")
                XCTAssertTrue(home.isRefreshing)
                allowed = false
                home.cancelPendingLoad()
                pending.open()
                await initial.value
                let pages = provider.requestedPages.count
                provider.containerGates = ["ready": { await refresh.wait() }, "pending": { await refresh.wait() }]
                provider.latestGate = { await refresh.wait() }
                provider.continueWatchingGate = { await refresh.wait() }
                provider.childrenGate = ["collection": { _ in await refresh.wait() }]
                allowed = true
                let resumed = Task { await home.loadIfNeeded(for: visibility) }
                let resumedDeadline = ContinuousClock.now + .seconds(3)
                while provider.requestedPages.count == pages, ContinuousClock.now < resumedDeadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                XCTAssertGreaterThan(provider.requestedPages.count, pages)
                for _ in 0..<20 {
                    let current = try XCTUnwrap(home.state.value)
                    XCTAssertEqual(current.librarySections.first?.sections, shown.librarySections.first?.sections)
                    XCTAssertEqual(current.collectionRows.first?.items, shown.collectionRows.first?.items)
                    XCTAssertEqual(current.collectionRows.first?.row.isLoading, false)
                    XCTAssertEqual(current.latest, shown.latest)
                    XCTAssertEqual(current.continueWatching, shown.continueWatching)
                    XCTAssertFalse(home.loadingRows.contains(.recentlyAdded))
                    XCTAssertFalse(home.loadingRows.contains(.continueWatching))
                    try await Task.sleep(for: .milliseconds(5))
                }
                let fresh = becomesEmpty ? [] : [MediaItem(id: "new", title: "New", kind: .movie)]
                provider.allItems = fresh
                provider.latestItems = fresh
                provider.continueWatchingItems = fresh
                refresh.open()
                await resumed.value
                let finished = try XCTUnwrap(home.state.value)
                XCTAssertEqual(finished.librarySections.flatMap(\.sections).flatMap(\.items).map(\.id),
                               becomesEmpty ? [] : ["new", "new"])
                XCTAssertEqual(finished.collectionRows.first?.items.map(\.id), fresh.map(\.id))
                XCTAssertEqual(finished.latest.map(\.id), fresh.map(\.id))
                XCTAssertEqual(finished.continueWatching.map(\.id), fresh.map(\.id))
                XCTAssertFalse(home.isRefreshing)
            }
        }
    }

    func testRetryReservesFailedEmptyGlobalRowsButNotConfirmedEmptyRows() async throws {
        for merged in [true, false] {
            for interrupted in [true, false] {
                for failed in [true, false] {
                    let pending = HomeRefreshGate()
                    let retryGate = HomeRefreshGate()
                    defer { pending.open(); retryGate.open() }
                    let provider = FakeMediaProvider(allItems: [])
                    provider.latestItems = [MediaItem(id: "latest", title: "Latest", kind: .movie)]
                    provider.continueWatchingError = failed ? .serverUnreachable : nil
                    if interrupted { provider.latestGate = { await pending.wait() } }
                    let visibility = HomeLibraryVisibility(mergeLibrariesOnHome: merged)
                    var allowed = true
                    let home = HomeViewModel(
                        accounts: [resolved(provider, accountID: "a")],
                        layoutStore: InMemoryHomeLayoutStore(), contentStore: InMemoryHomeContentStore(),
                        currentVisibility: { visibility }, isLoadingAllowed: { allowed }
                    )
                    defer { home.invalidate() }
                    func resumeRow() -> HomeRow? {
                        guard let content = home.state.value else { return nil }
                        return HomeRow.rows(
                            for: content, isLibraryVisible: { _ in true },
                            loadingRows: home.loadingRows, failures: home.rowFailures
                        ).first { $0.kind == .continueWatching }
                    }
                    let initial = Task { await home.load() }
                    if interrupted {
                        let deadline = ContinuousClock.now + .seconds(3)
                        while (provider.librariesCallCount == 0 || home.loadingRows.contains(.continueWatching)),
                              ContinuousClock.now < deadline {
                            try await Task.sleep(for: .milliseconds(5))
                        }
                        XCTAssertTrue(home.isRefreshing)
                    } else {
                        await initial.value
                    }
                    XCTAssertFalse(home.loadingRows.contains(.continueWatching))
                    XCTAssertEqual(home.rowFailures[.continueWatching], failed ? .serverUnreachable : nil)
                    XCTAssertEqual(resumeRow() != nil, failed)
                    allowed = false
                    home.cancelPendingLoad()
                    pending.open()
                    await initial.value
                    provider.continueWatchingError = nil
                    let started = expectation(description: "Replacement Continue Watching request")
                    provider.continueWatchingGate = { started.fulfill(); await retryGate.wait() }
                    allowed = true
                    let retry = Task {
                        if interrupted {
                            await home.loadIfNeeded(for: visibility)
                        } else {
                            await home.load()
                        }
                    }
                    await fulfillment(of: [started], timeout: 3)
                    for _ in 0..<10 {
                        XCTAssertNil(home.rowFailures[.continueWatching])
                        XCTAssertEqual(home.loadingRows.contains(.continueWatching), failed)
                        XCTAssertEqual(resumeRow() != nil, failed)
                        if failed { XCTAssertGreaterThan(resumeRow()?.loadingPlaceholderCount ?? 0, 0) }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    retryGate.open()
                    await retry.value
                    XCTAssertNil(home.rowFailures[.continueWatching])
                    XCTAssertNil(resumeRow(), "Only a successful empty retry can remove the failed row")
                    XCTAssertFalse(home.isRefreshing)
                }
            }
        }
    }

    func testPauseResumptionKeepsGlobalCardsWhenAnotherSourceFailed() async throws {
        let pending = HomeRefreshGate()
        let retryGate = HomeRefreshGate()
        defer { pending.open(); retryGate.open() }
        let good = FakeMediaProvider(allItems: [])
        let bad = FakeMediaProvider(allItems: [])
        good.continueWatchingItems = [MediaItem(id: "resume", title: "Resume", kind: .movie)]
        bad.continueWatchingError = .serverUnreachable
        good.latestGate = { await pending.wait() }
        var allowed = true
        let home = HomeViewModel(
            accounts: [resolved(good, accountID: "good"), resolved(bad, accountID: "bad")],
            layoutStore: InMemoryHomeLayoutStore(), contentStore: InMemoryHomeContentStore(),
            isLoadingAllowed: { allowed }
        )
        defer { home.invalidate() }
        let initial = Task { await home.load() }
        let deadline = ContinuousClock.now + .seconds(3)
        while (home.rowFailures[.continueWatching] == nil || home.state.value?.continueWatching.isEmpty != false),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(home.rowFailures[.continueWatching], .serverUnreachable)
        let cards = try XCTUnwrap(home.state.value?.continueWatching)
        XCTAssertFalse(cards.isEmpty)
        allowed = false
        home.cancelPendingLoad()
        pending.open()
        await initial.value
        let started = expectation(description: "Populated row refresh started")
        good.continueWatchingGate = { started.fulfill(); await retryGate.wait() }
        bad.continueWatchingGate = { await retryGate.wait() }
        allowed = true
        let retry = Task { await home.loadIfNeeded(for: .default) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertFalse(home.loadingRows.contains(.continueWatching))
        XCTAssertEqual(home.state.value?.continueWatching, cards)
        retryGate.open()
        await retry.value
        XCTAssertEqual(home.state.value?.continueWatching, cards)
    }

    func testRetryReservesGlobalRowsWhoseOnlyContentIsFilteredOut() async throws {
        for (kind, collection, hideWatched): (HomeRowKind, Bool, Bool) in [
            (.libraries, false, false), (.libraries, true, false),
            (.recentlyAdded, false, false), (.recentlyAdded, false, true)
        ] {
            for interrupted in [true, false] {
                let pending = HomeRefreshGate()
                let retryGate = HomeRefreshGate()
                defer { pending.open(); retryGate.open() }
                let good = FakeMediaProvider(allItems: [])
                let bad = FakeMediaProvider(allItems: [])
                good.libraryItems = [MediaLibrary(
                    id: "hidden", title: "Hidden", kind: collection ? .collection : .movie,
                    hasCollections: collection ? false : nil
                )]
                var latest = MediaItem(id: "latest", title: "Latest", kind: .movie)
                latest.libraryID = "hidden"
                latest.isPlayed = hideWatched
                good.latestItems = [latest]
                if kind == .libraries {
                    bad.librariesError = .serverUnreachable
                } else {
                    bad.latestError = .serverUnreachable
                }
                if interrupted { good.continueWatchingGate = { await pending.wait() } }
                var visibility = HomeLibraryVisibility(hideWatchedRecentlyAdded: hideWatched)
                if !collection && !hideWatched {
                    visibility.setEnabled(false, for: "good:hidden")
                }
                var allowed = true
                let home = HomeViewModel(
                    accounts: [resolved(good, accountID: "good"), resolved(bad, accountID: "bad")],
                    layoutStore: InMemoryHomeLayoutStore(), contentStore: InMemoryHomeContentStore(),
                    currentVisibility: { visibility }, isLoadingAllowed: { allowed }
                )
                defer { home.invalidate() }
                let rowID: HomeRowID = kind == .libraries ? .libraries : .global(.recentlyAdded)
                func visibleRow() -> HomePresentationRow? {
                    guard let content = home.state.value else { return nil }
                    let rows = HomeRow.rows(
                        for: content, isLibraryVisible: visibility.isEnabled,
                        isLibraryTileVisible: visibility.isVisibleOnHome,
                        loadingRows: home.loadingRows, failures: home.rowFailures
                    )
                    return HomePresentationRow.resolve(rows: rows, content: content, visibility: visibility)
                        .first { $0.id == rowID }
                }
                let initial = Task { await home.load() }
                if interrupted {
                    let deadline = ContinuousClock.now + .seconds(3)
                    while (home.rowFailures[kind] == nil || home.loadingRows.contains(kind)),
                          ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    XCTAssertTrue(home.isRefreshing)
                } else {
                    await initial.value
                }
                XCTAssertEqual(home.rowFailures[kind], .serverUnreachable)
                let content = try XCTUnwrap(home.state.value)
                if kind == .libraries {
                    XCTAssertFalse(content.libraries.isEmpty)
                } else {
                    XCTAssertFalse((content.recentlyAddedCandidates ?? content.latest).isEmpty)
                }
                switch try XCTUnwrap(visibleRow()).source {
                case let .home(row):
                    XCTAssertTrue(row.items.isEmpty && row.libraries.isEmpty)
                    XCTAssertEqual(row.failure, .serverUnreachable)
                case let .library(row):
                    XCTAssertTrue(row.section.items.isEmpty)
                    XCTAssertNotNil(row.issue)
                case .liveTV:
                    XCTFail("Unexpected Live TV row")
                }
                allowed = false
                home.cancelPendingLoad()
                pending.open()
                await initial.value
                bad.librariesError = nil
                bad.latestError = nil
                let started = expectation(description: "Filtered row retry started")
                if kind == .libraries {
                    bad.librariesGate = { started.fulfill(); await retryGate.wait() }
                } else {
                    bad.latestGate = { started.fulfill(); await retryGate.wait() }
                }
                allowed = true
                let retry = Task {
                    if interrupted {
                        await home.loadIfNeeded(for: visibility)
                    } else {
                        await home.load()
                    }
                }
                await fulfillment(of: [started], timeout: 3)
                for _ in 0..<10 {
                    XCTAssertNil(home.rowFailures[kind])
                    XCTAssertTrue(home.loadingRows.contains(kind))
                    if case let .home(row)? = visibleRow()?.source {
                        XCTAssertGreaterThan(row.loadingPlaceholderCount, 0)
                    } else {
                        XCTFail("A failed row without visible cards must reserve its retry footprint")
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                retryGate.open()
                await retry.value
                XCTAssertNil(home.rowFailures[kind])
                XCTAssertNil(visibleRow())
            }
        }
    }

    func testPauseResumptionBeforeCancelledWorkReturnsKeepsFinalVisibility() async {
        for merged in [true, false] {
            let gate = HomeRefreshGate()
            defer { gate.open() }
            let provider = FakeMediaProvider(allItems: [])
            provider.librariesGate = { await gate.wait() }
            var allowed = true
            var visibility = HomeLibraryVisibility(mergeLibrariesOnHome: merged)
            let home = HomeViewModel(
                accounts: [resolved(provider, accountID: "a")],
                layoutStore: InMemoryHomeLayoutStore(),
                currentVisibility: { visibility },
                isLoadingAllowed: { allowed }
            )
            let first = Task { await home.loadIfNeeded(for: visibility) }
            let deadline = ContinuousClock.now + .seconds(2)
            while provider.librariesCallCount == 0, ContinuousClock.now < deadline {
                await Task.yield()
            }
            XCTAssertEqual(provider.librariesCallCount, 1)
            allowed = false
            home.cancelPendingLoad()
            visibility.setGlobalRowEnabled(false, for: .watchlist)
            await home.loadIfNeeded(for: visibility)
            XCTAssertEqual(provider.librariesCallCount, 1)
            let pausedContent = home.state.value
            allowed = true
            await home.loadIfNeeded(for: visibility)
            XCTAssertEqual(home.state.value, pausedContent)
            gate.open()
            await first.value
            let resumedDeadline = ContinuousClock.now + .seconds(2)
            while (provider.librariesCallCount < 2 || home.isRefreshing),
                  ContinuousClock.now < resumedDeadline {
                await Task.yield()
            }
            XCTAssertEqual(provider.librariesCallCount, 2)
            XCTAssertFalse(home.isRefreshing)
            await home.loadIfNeeded(for: visibility)
            XCTAssertEqual(provider.librariesCallCount, 2, "The resumed load must use the final choices.")
        }
    }

    func testCoveringOrRetiringHomeDuringPreparationDoesNotStartRequests() async {
        for retiring in [false, true] {
            let gate = HomeRefreshGate()
            defer { gate.open() }
            let preparing = expectation(description: "Home is preparing visibility")
            var preparations = 0
            var allowed = true
            let provider = FakeMediaProvider(allItems: [])
            let home = HomeViewModel(
                accounts: [resolved(provider, accountID: "a")],
                layoutStore: InMemoryHomeLayoutStore(),
                prepareVisibility: {
                    preparations += 1
                    if preparations == 1 { preparing.fulfill() }
                    await gate.wait()
                },
                isLoadingAllowed: { allowed }
            )
            let first = Task { await home.load() }
            await fulfillment(of: [preparing], timeout: 2)
            allowed = false
            if retiring { home.invalidate() } else { home.cancelPendingLoad() }
            gate.open()
            await first.value
            await home.loadIfNeeded(for: .default)
            XCTAssertEqual(provider.librariesCallCount, 0)
            XCTAssertFalse(home.isRefreshing)
            allowed = true
            await home.loadIfNeeded(for: .default)
            XCTAssertEqual(provider.librariesCallCount, retiring ? 0 : 1)
        }
    }

    func testInvalidatedHomeCannotPublishLateResultsOrRestart() async {
        for merged in [true, false] {
            let gate = HomeRefreshGate()
            defer { gate.open() }
            let provider = FakeMediaProvider(allItems: [])
            provider.librariesGate = { await gate.wait() }
            let visibility = HomeLibraryVisibility(mergeLibrariesOnHome: merged)
            let home = HomeViewModel(
                accounts: [resolved(provider, accountID: "a")],
                layoutStore: InMemoryHomeLayoutStore(),
                currentVisibility: { visibility }
            )
            let load = Task { await home.load() }
            let deadline = ContinuousClock.now + .seconds(2)
            while provider.librariesCallCount == 0, ContinuousClock.now < deadline {
                await Task.yield()
            }
            home.invalidate()
            let retiredContent = home.state.value
            gate.open()
            await load.value
            await home.load()
            await home.loadIfNeeded(for: visibility)
            XCTAssertEqual(home.state.value, retiredContent)
            XCTAssertEqual(provider.librariesCallCount, 1)
            XCTAssertFalse(home.isRefreshing)
        }
    }

    func testViewTaskReplacementDuringPreparationStillLoadsRowsWithoutAnotherAppearance() async {
        for cached in [false, true] {
            for merged in [false, true] {
                let gate = HomeRefreshGate()
                defer { gate.open() }
                let enteredPreparation = expectation(description: "Home is preparing visibility")
                var preparations = 0
                let visibility = HomeLibraryVisibility(mergeLibrariesOnHome: merged)
                let provider = FakeMediaProvider(allItems: [])
                provider.continueWatchingItems = [MediaItem(id: "resume", title: "Resume", kind: .movie)]
                provider.latestItems = [MediaItem(id: "latest", title: "Latest", kind: .movie)]
                let store = InMemoryHomeContentStore(cached ? snapshot(cwIDs: ["cached"]) : nil)
                let vm = HomeViewModel(
                    accounts: [resolved(provider, accountID: "a")],
                    layoutStore: InMemoryHomeLayoutStore(),
                    contentStore: store,
                    currentVisibility: { visibility },
                    prepareVisibility: {
                        preparations += 1
                        if preparations == 1 { enteredPreparation.fulfill() }
                        await gate.wait()
                    }
                )
                let first = Task { await vm.loadIfNeeded(for: visibility) }
                await fulfillment(of: [enteredPreparation], timeout: 2)
                first.cancel()
                await vm.loadIfNeeded(for: visibility)
                gate.open()
                await first.value

                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline,
                      vm.isRefreshing || vm.state.value?.continueWatching.first?.id != "resume" {
                    await Task.yield()
                }
                XCTAssertEqual(preparations, 2, "Retry the dropped preparation once for the waiting appearance.")
                XCTAssertEqual(vm.state.value?.continueWatching.map(\.id), ["resume"],
                               "Continue Watching must load without leaving Home and returning.")
                XCTAssertEqual(vm.state.value?.latest.map(\.id), ["latest"])
                XCTAssertFalse(vm.isShowingCachedSnapshot)
                XCTAssertFalse(vm.isRefreshing)
                XCTAssertTrue(vm.loadingRows.isEmpty)
                XCTAssertEqual(provider.librariesCallCount, 1)
                await vm.loadIfNeeded(for: visibility)
                XCTAssertEqual(provider.librariesCallCount, 1, "Reappearance must not duplicate the completed load.")
            }
        }
    }

    func testCancelledPreparationWithoutReplacementDoesNotStartBackgroundLoad() async {
        let gate = HomeRefreshGate()
        defer { gate.open() }
        let enteredPreparation = expectation(description: "Home is preparing visibility")
        let provider = FakeMediaProvider(allItems: [])
        var preparations = 0
        let vm = HomeViewModel(
            accounts: [resolved(provider, accountID: "a")],
            layoutStore: InMemoryHomeLayoutStore(),
            contentStore: InMemoryHomeContentStore(),
            prepareVisibility: {
                preparations += 1
                if preparations == 1 { enteredPreparation.fulfill() }
                await gate.wait()
            }
        )
        let first = Task { await vm.loadIfNeeded(for: .default) }
        await fulfillment(of: [enteredPreparation], timeout: 2)
        first.cancel()
        gate.open()
        await first.value

        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(provider.librariesCallCount, 0)
        await vm.loadIfNeeded(for: .default)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(provider.librariesCallCount, 1)
    }

    func testSuccessfulLoadPersistsSnapshotForNextLaunch() async {
        let store = InMemoryHomeContentStore()
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "freshA", title: "Fresh", kind: .movie)]
        let vm = makeViewModel(provider: provider, contentStore: store)

        // No cache ⇒ a normal (loud) load; it should persist the fresh content.
        await vm.loadIfNeeded(for: .default)
        for _ in 0..<100 where store.load() == nil {
            await Task.yield()
        }

        XCTAssertEqual(store.load()?.continueWatching.map(\.id), ["freshA"], "Fresh content is cached for next launch")
    }

    // MARK: Watching nothing

    /// Turning every server off left the previous library on screen: the cached
    /// snapshot was hydrated at init regardless of whether the profile still had
    /// anything to aggregate, and it survived relaunches because `save` refuses
    /// to overwrite good content with an empty one.
    func testAProfileWithNoServersDoesNotPaintTheCachedSnapshot() async {
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA"]))
        let vm = makeSourcelessViewModel(contentStore: store)

        XCTAssertNil(loadedContent(vm), "A profile watching nothing must not repaint an old library")
        await vm.waitForHeroPersistence()
        XCTAssertNil(store.load(), "and the stale snapshot must not survive to the next launch")
    }

    /// The other half: an empty aggregate from a profile with no sources is the
    /// ANSWER, not a failed fetch, so the keep-cached rule must stand aside.
    func testLoadingWithNoServersEndsEmptyRatherThanKeepingContent() async {
        let store = InMemoryHomeContentStore()
        let vm = makeSourcelessViewModel(contentStore: store)
        await vm.load(showLoadingState: false)

        guard case .empty = vm.state else {
            return XCTFail("Expected .empty for a profile that watches nothing, got \(vm.state)")
        }
        XCTAssertNil(store.load())
    }

    /// The fix strips SERVER-derived rows, not everything: the universal
    /// watchlist is the user's own and isn't a server's to take away.
    func testAProfileWithNoServersKeepsItsUniversalWatchlist() {
        var snapshot = self.snapshot(cwIDs: ["cachedA"])
        snapshot.watchlist = [MediaItem(id: "wl", title: "Watchlisted", kind: .movie)]
        let vm = makeSourcelessViewModel(contentStore: InMemoryHomeContentStore(snapshot))

        XCTAssertEqual(loadedContent(vm)?.watchlist.map(\.id), ["wl"])
        XCTAssertEqual(
            loadedContent(vm)?.continueWatching, [],
            "but the switched-off server's rows must be gone"
        )
    }

    /// Guards the fix from over-reaching: a profile that DOES have a server and
    /// gets a transient empty (server briefly unreachable) must still keep what
    /// is on screen, which is what the cached snapshot exists for.
    func testATransientEmptyStillKeepsCachedContentWhenAServerExists() async {
        let store = InMemoryHomeContentStore(snapshot(cwIDs: ["cachedA"]))
        let vm = makeViewModel(provider: FakeMediaProvider(allItems: []), contentStore: store)
        await vm.load(showLoadingState: false)

        XCTAssertEqual(
            loadedContent(vm)?.continueWatching.map(\.id), ["cachedA"],
            "An unreachable server must not blank a good snapshot"
        )
    }
}

private actor HomeProgressCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor HomeResumePublicationPause {
    nonisolated let release = HomeRefreshGate()
    private let detailReads: Int
    private var reads = 0
    private(set) var isWaiting = false

    init(detailReads: Int) { self.detailReads = detailReads }

    func waitForPublication() async {
        reads += 1
        guard reads > detailReads else { return }
        isWaiting = true
        await release.wait()
    }
}

private final class HomeRefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
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
