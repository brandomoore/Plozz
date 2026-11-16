import CoreModels
import FeatureHomeCore
import Foundation
import XCTest

@testable import AppRuntime

@MainActor
final class UpcomingFeedTests: XCTestCase {
    private static let day = Date(timeIntervalSince1970: 1_900_000_000)
    private static let interval = DateInterval(start: day.addingTimeInterval(-86_400), duration: 10 * 86_400)

    private static func episode() -> UpcomingEpisode {
        .init(
            seriesIdentity: .external(source: "tvmaze", value: "42"),
            seasonNumber: 2, episodeNumber: 1, airDate: day,
            datePrecision: .dateOnly, source: .tvmaze, refreshedAt: day
        )
    }

    func testBothBackendsIncludeCaughtUpShowsBeyondFirstPageButNotUnwatchedLibrary() async throws {
        for kind: ProviderKind in [.jellyfin, .plex] {
            var watched = MediaItem(id: "returning", title: "Returning", kind: .series, providerIDs: ["Tvmaze": "42"])
            watched.hasBeenPlayed = true
            let unwatched = (0..<200).map { MediaItem(id: "unwatched-\($0)", title: "Unwatched", kind: .series) }
            let provider = UpcomingFixtureProvider(kind: kind, items: unwatched + [watched])
            let account = ResolvedAccount(account: Account(id: "account", from: provider.session), provider: provider)
            let episode = Self.episode()
            let result = try await UpcomingFeedLoader.load(
                accounts: [account], watchlist: [], regionCode: "US", interval: Self.interval,
                requestedTitles: { [] }, isCurrent: { true },
                schedule: { _, _ in [episode] },
                movieAvailability: { _, region in .init(regionCode: region) }
            )
            XCTAssertEqual(result.releases.map(\.item.id), ["returning"])
            XCTAssertEqual(result.releases.first?.item.sourceAccountID, "account")
            let pages = await provider.pages
            let playbackReads = await provider.playbackReads
            XCTAssertEqual(pages, [0, 200])
            XCTAssertEqual(playbackReads, 0)
            XCTAssertEqual(result.failedSourceCount, 0)
        }
    }

    func testWatchlistedAndRequestedShowsAndMoviesCarryTheirInterests() async throws {
        let film = MediaItem(id: "saved", title: "Film", kind: .movie, providerIDs: ["Tmdb": "17"])
        let request = MediaItem(id: "request", title: "Film", kind: .movie, providerIDs: ["Tmdb": "17"])
        let show = MediaItem(id: "unwatched", title: "Unwatched", kind: .series, providerIDs: ["Tvmaze": "42"])
        let date = Self.day
        let episode = Self.episode()
        let result = try await UpcomingFeedLoader.load(
            accounts: [], watchlist: [film, show], regionCode: "US", interval: Self.interval,
            requestedTitles: { [request, show] }, isCurrent: { true },
            schedule: { _, _ in [episode] },
            movieAvailability: { _, region in
                .init(regionCode: region, releaseEvents: [.init(kind: .digital, date: date, regionCode: region)])
            }
        )
        XCTAssertEqual(result.releases.count, 2)
        XCTAssertEqual(Set(result.releases.map(\.item.kind)), [.movie, .series])
        XCTAssertTrue(result.releases.allSatisfy { $0.interests == [.watchlist, .requested] })
        XCTAssertTrue(result.releases.allSatisfy { !$0.interests.contains(.watching) })
        var filters = UpcomingFilters()
        filters.interests = [.watching]
        XCTAssertTrue(result.releases.filter(filters.includes).isEmpty)
        for interest in [UpcomingInterest.watchlist, .requested] {
            filters.interests = [interest]
            XCTAssertEqual(result.releases.filter(filters.includes).count, 2)
        }
    }

    func testWatchedShowAndInProgressMovieMergeWithSavedAndRequestedInterests() async throws {
        var show = MediaItem(id: "watching", title: "Show", kind: .series, providerIDs: ["Tmdb": "42"])
        show.hasBeenPlayed = true
        let savedShow = MediaItem(id: "saved-show", title: "Show", kind: .series, providerIDs: ["Tmdb": "42"])
        var movie = MediaItem(id: "watching-film", title: "Film", kind: .movie, providerIDs: ["Tmdb": "17"])
        movie.resumePosition = 60
        let savedMovie = movie
        let episode = Self.episode()
        let day = Self.day
        for kind in [ProviderKind.jellyfin, .plex] {
            let provider = UpcomingFixtureProvider(kind: kind, items: [show], continuing: [movie])
            let result = try await UpcomingFeedLoader.load(
                accounts: [.init(account: Account(id: "account", from: provider.session), provider: provider)],
                watchlist: [savedShow, savedMovie], regionCode: "US", interval: Self.interval,
                requestedTitles: { [savedShow, savedMovie] }, isCurrent: { true },
                schedule: { _, _ in [episode] },
                movieAvailability: { _, region in
                    .init(regionCode: region, releaseEvents: [.init(kind: .digital, date: day, regionCode: region)])
                }
            )
            XCTAssertEqual(result.releases.count, 2)
            XCTAssertTrue(result.releases.allSatisfy { $0.interests == [.watching, .watchlist, .requested] })
            XCTAssertTrue(result.releases.allSatisfy { $0.item.sourceAccountID == "account" })
            XCTAssertEqual(result.failedSourceCount, 0)
        }
    }

    func testUnstartedShowQualifiesFromEitherWatchlistOrPersonalRequestAlone() async throws {
        let show = MediaItem(id: "unstarted", title: "Show", kind: .series, providerIDs: ["Tmdb": "42"])
        let episode = Self.episode()
        for requested in [false, true] {
            let snapshot = try await UpcomingFeedLoader.load(
                accounts: [], watchlist: requested ? [] : [show], regionCode: nil, interval: Self.interval,
                requestedTitles: { requested ? [show] : [] }, isCurrent: { true },
                schedule: { _, _ in [episode] }
            )
            XCTAssertEqual(snapshot.releases.count, 1)
            XCTAssertEqual(snapshot.releases.first?.interests, requested ? [.requested] : [.watchlist])
            var filters = UpcomingFilters()
            filters.interests.remove(requested ? .requested : .watchlist)
            XCTAssertTrue(snapshot.releases.filter(filters.includes).isEmpty)
        }
    }

    func testInvalidatedIdentityDoesNotReadProviders() async {
        let provider = UpcomingFixtureProvider(kind: .plex, items: [])
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        do {
            _ = try await UpcomingFeedLoader.load(
                accounts: [account], watchlist: [], regionCode: "US", interval: Self.interval,
                requestedTitles: {
                    XCTFail("Requests must remain fenced")
                    return []
                },
                isCurrent: { false }
            )
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let reads = await provider.libraryReads
        XCTAssertEqual(reads, 0)
    }

    func testDateOutageIsReportedButSuccessfulEmptyReleaseListIsNot() async throws {
        let film = MediaItem(id: "film", title: "Film", kind: .movie, providerIDs: ["Tmdb": "17"])
        for available in [false, true] {
            let result = try await UpcomingFeedLoader.load(
                accounts: [], watchlist: [film], regionCode: "US", interval: Self.interval,
                requestedTitles: { [] }, isCurrent: { true },
                movieAvailability: { _, region in .init(regionCode: region, releaseDatesAvailable: available) }
            )
            XCTAssertEqual(result.failedSourceCount, available ? 0 : 1)
            XCTAssertEqual(
                result.failedTitleInterests,
                available ? [:] : [UpcomingRelease.titleKey(for: film): [.watchlist]]
            )
        }
    }

    func testLaterDigitalDateDoesNotReintroduceAnAlreadyReleasedMovie() async throws {
        let film = MediaItem(id: "film", title: "Film", kind: .movie, providerIDs: ["Tmdb": "17"])
        let date = Self.day
        let snapshot = try await UpcomingFeedLoader.load(
            accounts: [], watchlist: [film], regionCode: "US", interval: Self.interval,
            requestedTitles: { [] }, isCurrent: { true },
            movieAvailability: { _, region in
                .init(
                    regionCode: region,
                    releaseEvents: [
                        .init(kind: .digital, date: date.addingTimeInterval(-90 * 86_400), regionCode: region),
                        .init(kind: .digital, date: date, regionCode: region),
                    ])
            }
        )
        XCTAssertTrue(snapshot.releases.isEmpty)
        XCTAssertEqual(snapshot.failedSourceCount, 0)
    }

    func testContinueWatchingFailureDoesNotDiscardConfirmedWatchedSeries() async throws {
        var series = MediaItem(id: "watched", title: "Watched", kind: .series)
        series.hasBeenPlayed = true
        let provider = UpcomingFixtureProvider(kind: .jellyfin, items: [series], failsContinuing: true)
        let episode = Self.episode()
        let snapshot = try await UpcomingFeedLoader.load(
            accounts: [.init(account: Account(id: "account", from: provider.session), provider: provider)],
            watchlist: [], regionCode: "US", interval: Self.interval,
            requestedTitles: { [] }, isCurrent: { true }, schedule: { _, _ in [episode] }
        )
        XCTAssertEqual(snapshot.releases.map(\.item.id), ["watched"])
        XCTAssertEqual(snapshot.failedAccountIDs, ["account"])
        XCTAssertEqual(snapshot.failedSourceCount, 1)
    }

    func testFirstUnfinishedEpisodeEnrollsItsPreviouslyUnplayedSeries() async throws {
        let series = MediaItem(id: "first-show", title: "First", kind: .series)
        var inProgress = MediaItem(id: "episode", title: "Episode", kind: .episode)
        inProgress.seriesID = series.id
        let provider = UpcomingFixtureProvider(kind: .plex, items: [series], continuing: [inProgress])
        let episode = Self.episode()
        let snapshot = try await UpcomingFeedLoader.load(
            accounts: [.init(account: Account(from: provider.session), provider: provider)],
            watchlist: [], regionCode: "US", interval: Self.interval,
            requestedTitles: { [] }, isCurrent: { true }, schedule: { _, _ in [episode] }
        )
        XCTAssertEqual(snapshot.releases.map(\.item.id), ["first-show"])
        let playbackReads = await provider.playbackReads
        XCTAssertEqual(playbackReads, 0)
    }

    func testUpcomingOnlyHomeIsLoadedUnlessTheRowIsExplicitlyHidden() {
        var visibility = HomeLibraryVisibility()
        let release = Self.release("show")
        let state = HomePresentationRow.displayState(
            .empty, liveTV: .empty, visibility: visibility, upcoming: [release])
        guard case .loaded = state else { return XCTFail("Upcoming alone is usable Home content") }
        visibility.rowCustomization = .init(defaults: .combined, hidden: [.global(.comingSoon)])
        let hidden = HomePresentationRow.displayState(
            .empty, liveTV: .empty, visibility: visibility, upcoming: [release])
        guard case .empty = hidden else { return XCTFail("A hidden Upcoming row does not replace the empty state") }
    }

    func testScopeChangeRejectsOldCompletionEvenWhenLoaderIgnoresCancellation() async {
        let model = UpcomingFeedModel()
        let gate = UpcomingTestGate()
        let started = expectation(description: "Old load entered")
        let oldRelease = Self.release("old")
        let newRelease = Self.release("new")
        var current = "old"
        let old = Task {
            await model.refresh(scope: "old", namespace: "old", isCurrent: { current == "old" }) { progress in
                started.fulfill()
                await gate.wait()
                await progress([oldRelease])
                return .init(releases: [oldRelease])
            }
        }
        await fulfillment(of: [started], timeout: 2)
        current = "new"
        await model.refresh(scope: "new", namespace: "new", isCurrent: { current == "new" }) {
            .init(releases: [newRelease])
        }
        await gate.open()
        await old.value
        XCTAssertEqual(model.releases.map(\.item.id), ["new"])
        XCTAssertFalse(model.isLoading)
    }

    func testEpisodesPublishWhilePersonalRequestsAreStillLoading() async throws {
        var series = MediaItem(id: "show", title: "Show", kind: .series)
        series.hasBeenPlayed = true
        series.seriesStatus = .returning
        let ended = (0..<4).map {
            var show = MediaItem(id: "ended-\($0)", title: "Ended", seriesStatus: .ended, kind: .series)
            show.hasBeenPlayed = true
            return show
        }
        let provider = UpcomingFixtureProvider(kind: .jellyfin, items: ended + [series])
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        let model = UpcomingFeedModel()
        let requests = UpcomingTestGate()
        let visible = expectation(description: "Episode visible before requests finish")
        let episode = Self.episode()
        let task = Task {
            await model.refresh(scope: "viewer", namespace: nil, isCurrent: { true }) { progress in
                try await UpcomingFeedLoader.load(
                    accounts: [account], watchlist: [], regionCode: "US", interval: Self.interval,
                    requestedTitles: {
                        await requests.wait()
                        return []
                    }, isCurrent: { true },
                    onProgress: {
                        progress($0)
                        visible.fulfill()
                    },
                    schedule: { item, _ in
                        if item.seriesStatus == .ended {
                            await requests.wait()
                            return []
                        }
                        return [episode]
                    }
                )
            }
        }
        await fulfillment(of: [visible], timeout: 2)
        XCTAssertEqual(model.releases.map(\.item.id), ["show"])
        XCTAssertTrue(model.isLoading, "Progress is not a completed refresh")
        await requests.open()
        await task.value
        XCTAssertEqual(model.releases.count, 1)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.failedSourceCount, 0)
    }

    func testSameScopeInvalidationFinishesUsefulWorkThenLoadsLatestInputs() async {
        let model = UpcomingFeedModel()
        let gate = UpcomingTestGate()
        let started = expectation(description: "Original refresh entered")
        let old = Self.release("old")
        let fresh = Self.release("fresh")
        let original = Task {
            await model.refresh(scope: "scope", namespace: nil, isCurrent: { true }) {
                started.fulfill()
                await gate.wait()
                XCTAssertFalse(Task.isCancelled, "A same-viewer change must not restart the full scan")
                return .init(releases: [old])
            }
        }
        await fulfillment(of: [started], timeout: 2)
        model.refreshRevision += 1
        XCTAssertTrue(model.isLoading)
        let latest = Task {
            await model.refresh(scope: "scope", namespace: nil, isCurrent: { true }) {
                .init(releases: [fresh])
            }
        }
        await gate.open()
        await original.value
        await latest.value
        XCTAssertEqual(model.releases.map(\.item.id), ["fresh"])
        XCTAssertFalse(model.isLoading)
    }

    func testPartialFailureDoesNotRescanOnImmediateRevisitButExplicitRetryRecovers() async {
        let model = UpcomingFeedModel()
        let release = Self.release("show")
        await model.refresh(scope: "scope", namespace: nil, isCurrent: { true }) {
            .init(releases: [release], failedSourceCount: 1, failedTitleInterests: ["unavailable": [.watching]])
        }
        await model.refresh(scope: "scope", namespace: nil, isCurrent: { true }) {
            XCTFail("One unavailable title must not repeatedly rescan all viewing history")
            return .init()
        }
        XCTAssertEqual(model.releases.count, 1)
        XCTAssertEqual(model.failedSourceCount, 1)
        model.refreshRevision += 1
        await model.refresh(scope: "scope", namespace: nil, isCurrent: { true }) {
            .init(releases: [release])
        }
        XCTAssertEqual(model.failedSourceCount, 0)
    }

    func testPersonalInterestChangesInvalidateTheRetainedFeedWithoutAMountedTab() async {
        let model = UpcomingFeedModel()
        let saved = Self.release("saved")
        await model.refresh(scope: "scope", namespace: nil, isCurrent: { true }) {
            .init(releases: [saved])
        }
        for notification in [
            Notification.Name.universalWatchlistDidChange, .universalWatchlistCacheDidLoad,
            .personalRequestsDidChange
        ] {
            await model.refresh(scope: "scope", namespace: nil, isCurrent: { true }) {
                XCTFail("A revisit without a mutation should reuse the fresh feed")
                return .init()
            }
            let revision = model.refreshRevision
            NotificationCenter.default.post(name: notification, object: nil)
            XCTAssertGreaterThan(model.refreshRevision, revision)
            let updated = model.releases.isEmpty ? [saved] : []
            await model.refresh(scope: "scope", namespace: nil, isCurrent: { true }) {
                .init(releases: updated)
            }
            XCTAssertEqual(model.releases, updated)
        }
    }

    func testPartialRefreshRetainsOnlyFailedSourcesAndHideIsProfileScoped() async throws {
        let suite = "upcoming-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UpcomingFeedModel(defaults: defaults)
        let old = Self.release("old", accountID: "failed")
        let removed = Self.release("removed", accountID: "healthy")
        let fresh = Self.release("fresh", accountID: "healthy")
        await model.refresh(scope: "scope", namespace: "alice", isCurrent: { true }) {
            .init(releases: [old, removed])
        }
        await model.refresh(scope: "scope", namespace: "alice", force: true, isCurrent: { true }) {
            .init(releases: [fresh], failedSourceCount: 1, failedAccountIDs: ["failed"])
        }
        XCTAssertEqual(Set(model.releases.map(\.item.id)), ["old", "fresh"])
        model.hide(old)
        XCTAssertEqual(model.visibleReleases.map(\.item.id), ["fresh"])
        model.undoHide()
        XCTAssertEqual(model.visibleReleases.count, 2)
        model.hide(old)
        await model.refresh(scope: "other", namespace: "bob", isCurrent: { true }) { .init(releases: [old]) }
        XCTAssertEqual(model.visibleReleases.count, 1)
        await model.refresh(scope: "scope", namespace: "alice", isCurrent: { true }) { .init(releases: [old]) }
        XCTAssertTrue(model.visibleReleases.isEmpty)
    }

    func testRequestFailureRetainsShowInterestWithoutRestoringRemovedWatchlistMembership() async {
        let model = UpcomingFeedModel()
        var original = Self.release("requested")
        original.interests = [.requested, .watchlist]
        let saved = original
        await model.refresh(scope: "scope", namespace: nil, isCurrent: { true }) { .init(releases: [saved]) }
        await model.refresh(scope: "scope", namespace: nil, force: true, isCurrent: { true }) {
            .init(failedSourceCount: 1, requestsFailed: true)
        }
        XCTAssertEqual(model.releases.first?.interests, [.requested])
        var fresh = original
        fresh.interests = [.watching]
        let watching = fresh
        await model.refresh(scope: "scope", namespace: nil, force: true, isCurrent: { true }) {
            .init(releases: [watching], failedSourceCount: 1, requestsFailed: true)
        }
        XCTAssertEqual(model.releases.count, 1)
        XCTAssertEqual(model.releases.first?.interests, [.watching, .requested])
        await model.refresh(scope: "scope", namespace: nil, force: true, isCurrent: { true }) {
            .init(releases: [watching])
        }
        XCTAssertEqual(model.releases.first?.interests, [.watching])
    }

    func testHistoryFailureRetainsInProgressMovieButSuccessfulEmptyClearsIt() async {
        let model = UpcomingFeedModel()
        var movie = MediaItem(id: "film", title: "Film", kind: .movie)
        movie.sourceAccountID = "offline"
        let release = UpcomingReleaseBuilder.movies(
            [.init(kind: .digital, date: Self.day, regionCode: "US")],
            for: movie, interests: [.watching], regionCode: "US"
        )
        await model.refresh(scope: "scope", namespace: nil, isCurrent: { true }) { .init(releases: release) }
        await model.refresh(scope: "scope", namespace: nil, force: true, isCurrent: { true }) {
            .init(failedSourceCount: 1, failedAccountIDs: ["offline"])
        }
        XCTAssertEqual(model.releases, release)
        await model.refresh(scope: "scope", namespace: nil, force: true, isCurrent: { true }) { .init() }
        XCTAssertTrue(model.releases.isEmpty)
    }

    func testMetadataFailureKeepsOnlyCurrentInterestsForRetainedShow() async {
        let model = UpcomingFeedModel()
        var original = Self.release("series")
        original.interests = [.watching, .watchlist, .requested]
        let release = original
        await model.refresh(scope: "scope", namespace: nil, isCurrent: { true }) { .init(releases: [release]) }
        await model.refresh(scope: "scope", namespace: nil, force: true, isCurrent: { true }) {
            .init(failedSourceCount: 1, failedTitleInterests: [release.titleKey: [.requested]])
        }
        XCTAssertEqual(model.releases.count, 1)
        XCTAssertEqual(model.releases.first?.interests, [.requested])
    }

    func testRepeatedHistoryFailuresPreserveSourceWhenRequestMetadataRefreshes() async {
        let model = UpcomingFeedModel()
        let native = Self.release("offline", accountID: "offline")
        var external = native
        external.item.sourceAccountID = nil
        external.interests = [.requested]
        let requested = external
        await model.refresh(scope: "scope", namespace: nil, isCurrent: { true }) { .init(releases: [native]) }
        for _ in 0..<2 {
            await model.refresh(scope: "scope", namespace: nil, force: true, isCurrent: { true }) {
                .init(releases: [requested], failedSourceCount: 1, failedAccountIDs: ["offline"])
            }
            XCTAssertEqual(model.releases.count, 1)
            XCTAssertEqual(model.releases.first?.interests, [.watching, .requested])
            XCTAssertEqual(model.releases.first?.item.sourceAccountID, "offline")
        }
    }

    private static func release(_ id: String, accountID: String? = nil) -> UpcomingRelease {
        var item = MediaItem(id: id, title: id, kind: .series)
        item.sourceAccountID = accountID
        return UpcomingReleaseBuilder.episodes([episode()], for: item)[0]
    }

    func testRecreatedModelRestoresScopedCacheWithoutNetworkAndWithoutPersistingCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = UpcomingFeedCache(directory: directory)
        var release = Self.release("cached", accountID: "account")
        release.item.posterURL = URL(string: "https://example.invalid/art?api_key=secret-fixture")
        let saved = release
        let original = UpcomingFeedModel(cache: cache)
        await original.refresh(scope: "runtime-1", namespace: "alice", cacheScope: "alice-account", isCurrent: { true }) {
            .init(releases: [saved])
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let data = try Data(contentsOf: XCTUnwrap(files.first))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret-fixture"))

        let restored = UpcomingFeedModel(cache: UpcomingFeedCache(directory: directory))
        await restored.refresh(
            scope: "runtime-2", namespace: "alice", cacheScope: "alice-account",
            rehydrate: { items in
                items.map { item in
                    var item = item
                    item.posterURL = URL(string: "https://example.invalid/art?api_key=current-fixture")
                    return item
                }
            },
            isCurrent: { true }
        ) {
            XCTFail("A fresh disk snapshot must not repeat the server scan")
            return .init()
        }
        XCTAssertEqual(restored.releases.map(\.item.id), ["cached"])
        XCTAssertTrue(try XCTUnwrap(restored.releases.first?.item.posterURL?.absoluteString).contains("current-fixture"))
        restored.refreshIfStale()
        XCTAssertEqual(restored.refreshRevision, 0, "Foreground must retain a fresh cache")
        restored.refreshIfStale(now: Date().addingTimeInterval(7 * 60 * 60))
        XCTAssertEqual(restored.refreshRevision, 1)

        let unauthorized = UpcomingFeedModel(cache: cache)
        await unauthorized.refresh(
            scope: "runtime-3", namespace: "alice", cacheScope: "alice-account", isCurrent: { false }
        ) {
            XCTFail("Locked profiles must neither hydrate nor load")
            return .init()
        }
        XCTAssertTrue(unauthorized.releases.isEmpty)
        let otherScope = await cache.load(scope: "alice-other-account", namespace: "alice")
        let otherProfile = await cache.load(scope: "alice-account", namespace: "bob")
        XCTAssertNil(otherScope)
        XCTAssertNil(otherProfile)
    }

    func testStaleCachePublishesBeforeRefreshAndSuccessfulEmptyReplacesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = UpcomingFeedCache(directory: directory)
        await cache.save(
            releases: [Self.release("cached")], failedSourceCount: 0, scope: "scope", namespace: nil,
            savedAt: Date().addingTimeInterval(-7 * 60 * 60)
        )
        let model = UpcomingFeedModel(cache: cache)
        let gate = UpcomingTestGate()
        let entered = expectation(description: "Stale snapshot rendered before network")
        let refresh = Task {
            await model.refresh(scope: "runtime", namespace: nil, cacheScope: "scope", isCurrent: { true }) {
                entered.fulfill()
                await gate.wait()
                return .init()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(model.releases.map(\.item.id), ["cached"])
        XCTAssertTrue(model.isLoading)
        await gate.open()
        await refresh.value
        XCTAssertTrue(model.releases.isEmpty)
        let restored = UpcomingFeedModel(cache: cache)
        await restored.refresh(scope: "runtime", namespace: nil, cacheScope: "scope", isCurrent: { true }) {
            XCTFail("A completed empty result must replace the old cache")
            return .init()
        }
        XCTAssertTrue(restored.releases.isEmpty)
    }

    func testExplicitInvalidationCannotBeSatisfiedByFreshDiskCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = UpcomingFeedCache(directory: directory)
        await cache.save(
            releases: [Self.release("old")], failedSourceCount: 0,
            scope: "scope", namespace: nil, savedAt: Date()
        )
        let model = UpcomingFeedModel(cache: cache)
        model.refreshRevision += 1
        let fresh = Self.release("fresh")
        await model.refresh(scope: "runtime", namespace: nil, cacheScope: "scope", isCurrent: { true }) {
            .init(releases: [fresh])
        }
        XCTAssertEqual(model.releases.map(\.item.id), ["fresh"])
    }
}

private actor UpcomingTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        isOpen = true
        for continuation in continuations { continuation.resume() }
        continuations = []
    }
}

private actor UpcomingFixtureProvider: MediaProvider {
    nonisolated let session: UserSession
    nonisolated let kind: ProviderKind
    nonisolated let connectionLocality: SourceLocality = .remote
    private let catalog: [MediaItem]
    private let continuing: [MediaItem]
    private let failsContinuing: Bool
    private(set) var pages: [Int] = []
    private(set) var libraryReads = 0
    private(set) var playbackReads = 0

    init(kind: ProviderKind, items: [MediaItem], continuing: [MediaItem] = [], failsContinuing: Bool = false) {
        self.kind = kind
        catalog = items
        self.continuing = continuing
        self.failsContinuing = failsContinuing
        session = UserSession(
            server: .init(
                id: "server", name: "Fixture", baseURL: URL(string: "https://example.invalid")!, provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
    }
    func libraries() async throws -> [MediaLibrary] {
        libraryReads += 1
        return [.init(id: "shows", title: "Shows", kind: .series)]
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        pages.append(page.startIndex)
        return .init(
            items: Array(catalog.dropFirst(page.startIndex).prefix(page.limit)),
            startIndex: page.startIndex, totalCount: catalog.count
        )
    }
    func item(id: String) async throws -> MediaItem {
        guard let item = catalog.first(where: { $0.id == id }) else { throw AppError.notFound }
        return item
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        if failsContinuing { throw AppError.invalidResponse }
        return continuing
    }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        playbackReads += 1
        throw AppError.notFound
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
