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
                requestedMovies: { [] }, isCurrent: { true },
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

    func testWatchlistedAndRequestedMoviesMergeWithoutIncludingUnwatchedShows() async throws {
        let film = MediaItem(id: "saved", title: "Film", kind: .movie, providerIDs: ["Tmdb": "17"])
        let request = MediaItem(id: "request", title: "Film", kind: .movie, providerIDs: ["Tmdb": "17"])
        let show = MediaItem(id: "unwatched", title: "Unwatched", kind: .series, providerIDs: ["Tvmaze": "42"])
        let date = Self.day
        let result = try await UpcomingFeedLoader.load(
            accounts: [], watchlist: [film, show], regionCode: "US", interval: Self.interval,
            requestedMovies: { [request, show] }, isCurrent: { true },
            schedule: { _, _ in
                XCTFail("Saved/requested unwatched shows are not viewing history")
                return []
            },
            movieAvailability: { _, region in
                .init(regionCode: region, releaseEvents: [.init(kind: .digital, date: date, regionCode: region)])
            }
        )
        XCTAssertEqual(result.releases.count, 1)
        XCTAssertEqual(result.releases.first?.interests, [.watchlist, .requested])
    }

    func testInvalidatedIdentityDoesNotReadProviders() async {
        let provider = UpcomingFixtureProvider(kind: .plex, items: [])
        let account = ResolvedAccount(account: Account(from: provider.session), provider: provider)
        do {
            _ = try await UpcomingFeedLoader.load(
                accounts: [account], watchlist: [], regionCode: "US", interval: Self.interval,
                requestedMovies: {
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
                requestedMovies: { [] }, isCurrent: { true },
                movieAvailability: { _, region in .init(regionCode: region, releaseDatesAvailable: available) }
            )
            XCTAssertEqual(result.failedSourceCount, available ? 0 : 1)
            XCTAssertEqual(result.failedTitleKeys, available ? [] : [UpcomingRelease.titleKey(for: film)])
        }
    }

    func testContinueWatchingFailureDoesNotDiscardConfirmedWatchedSeries() async throws {
        var series = MediaItem(id: "watched", title: "Watched", kind: .series)
        series.hasBeenPlayed = true
        let provider = UpcomingFixtureProvider(kind: .jellyfin, items: [series], failsContinuing: true)
        let episode = Self.episode()
        let snapshot = try await UpcomingFeedLoader.load(
            accounts: [.init(account: Account(id: "account", from: provider.session), provider: provider)],
            watchlist: [], regionCode: "US", interval: Self.interval,
            requestedMovies: { [] }, isCurrent: { true }, schedule: { _, _ in [episode] }
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
            requestedMovies: { [] }, isCurrent: { true }, schedule: { _, _ in [episode] }
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
            await model.refresh(scope: "old", namespace: "old", isCurrent: { current == "old" }) {
                started.fulfill()
                await gate.wait()
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

    private static func release(_ id: String, accountID: String? = nil) -> UpcomingRelease {
        var item = MediaItem(id: id, title: id, kind: .series)
        item.sourceAccountID = accountID
        return UpcomingReleaseBuilder.episodes([episode()], for: item)[0]
    }
}

private actor UpcomingTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
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
