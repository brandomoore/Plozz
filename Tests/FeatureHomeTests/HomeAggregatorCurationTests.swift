import XCTest
import CoreModels
@testable import FeatureHome

/// Every backend shares the unlimited Home default. Explicit policy overrides
/// remain consistent across merged and unmerged layouts.
@MainActor
final class HomeAggregatorCurationTests: XCTestCase {
    func testNormalHomeLoadingWarmsLibraryNamesWithoutCopyingProfileChoices() async {
        let source = resolved("warm-home-\(UUID())", provider: ResumeStub(continueWatching: []))
        XCTAssertNil(LibraryInventoryStore.shared.load(for: source))
        _ = await HomeAggregator().content(from: [source], visibility: merged)
        XCTAssertEqual(LibraryInventoryStore.shared.load(for: source)?.map(\.id), ["L1"])
        XCTAssertEqual(HomeAggregator.cachedLibraries(from: [source]).accountIDs, [source.account.id])
        XCTAssertTrue(HomeAggregator.cachedLibraries(from: []).libraries.isEmpty)
    }

    private func resolved(_ id: String, provider: any MediaProvider) -> ResolvedAccount {
        let server = MediaServer(
            id: "srv-\(id)", name: "S", baseURL: URL(string: "http://host")!, provider: .jellyfin
        )
        let account = Account(id: id, server: server, userID: "u-\(id)", userName: "U", deviceID: "d-\(id)")
        return ResolvedAccount(account: account, provider: provider)
    }

    private func suggestion(_ id: String, daysAgo: Double) -> MediaItem {
        var item = MediaItem(id: id, title: id, kind: .episode)
        item.lastPlayedAt = Date().addingTimeInterval(-daysAgo * 86_400)
        return item
    }

    private func inProgress(_ id: String, daysAgo: Double) -> MediaItem {
        var item = MediaItem(id: id, title: id, kind: .movie)
        item.resumePosition = 900
        item.lastPlayedAt = Date().addingTimeInterval(-daysAgo * 86_400)
        return item
    }

    private var merged: HomeLibraryVisibility { HomeLibraryVisibility(mergeLibrariesOnHome: true) }

    func testStaleSuggestionsAreRetiredButHalfWatchedTitlesSurvive() async {
        let stub = ResumeStub(continueWatching: [
            inProgress("halfway-but-ancient", daysAgo: 400),
            suggestion("suggested-recently", daysAgo: 3),
            suggestion("suggested-long-ago", daysAgo: 400)
        ])

        let content = await HomeAggregator().content(
            from: [resolved("acct", provider: stub)],
            policy: ContinueWatchingPolicy(nextUpCutoff: 90 * 86_400),
            visibility: merged
        )

        XCTAssertEqual(
            Set(content.continueWatching.map(\.id)),
            ["halfway-but-ancient", "suggested-recently"],
            "Only the abandoned suggestion goes; a title left halfway is where the viewer stopped"
        )
    }

    func testDefaultKeepsEveryTitleBeyondSixtyAndOrdersOldSuggestionsLast() async {
        let many = (1...150).map { inProgress("m\($0)", daysAgo: Double($0) / 24) }
        let stub = ResumeStub(continueWatching: many)
        let old = ResumeStub(continueWatching: [
            suggestion("old-next-up", daysAgo: 400),
            suggestion("recent-next-up", daysAgo: 1)
        ])

        let content = await HomeAggregator().content(
            from: [resolved("acct", provider: stub), resolved("other", provider: old)],
            visibility: merged
        )

        XCTAssertEqual(content.continueWatching.count, 152)
        XCTAssertEqual(content.continueWatching.last?.id, "old-next-up")
        XCTAssertEqual(Set(content.continueWatching.map(\.id)),
                       Set(many.map(\.id) + ["old-next-up", "recent-next-up"]))
    }

    func testDefaultUnmergedRowKeepsAllOldSuggestions() async {
        let many = (1...125).map { suggestion("e\($0)", daysAgo: Double($0) + 100) }
        let content = await HomeAggregator().unmergedContent(
            from: [resolved("acct", provider: ResumeStub(continueWatching: many))],
            visibility: HomeLibraryVisibility(mergeLibrariesOnHome: false)
        )
        XCTAssertEqual(content.continueWatching.map(\.id), many.map(\.id))
    }

    func testTheRowLimitIsStillHonoured() async {
        let many = (1...50).map { inProgress("m\($0)", daysAgo: Double($0) / 24) }
        let stub = ResumeStub(continueWatching: many)

        let content = await HomeAggregator().content(
            from: [resolved("acct", provider: stub)],
            policy: ContinueWatchingPolicy(rowLimit: 10),
            visibility: merged
        )

        XCTAssertEqual(content.continueWatching.count, 10)
    }

    func testWatchlistKeepsMoreThanTheOldTwentyItemPreview() async {
        let many = (1...250).map {
            MediaItem(id: "w\($0)", title: "Watchlist \($0)", kind: .movie)
        }
        let stub = ResumeStub(continueWatching: [], watchlist: many)

        let content = await HomeAggregator().content(
            from: [resolved("acct", provider: stub)],
            visibility: merged
        )

        XCTAssertEqual(content.watchlist.count, 250)
    }

    /// A backend that reports no recency must not have its row silently emptied.
    func testABackendThatReportsNoRecencyKeepsItsRow() async {
        let stub = ResumeStub(continueWatching: [
            MediaItem(id: "no-timestamp", title: "Untimed", kind: .movie)
        ])

        let content = await HomeAggregator().content(
            from: [resolved("acct", provider: stub)],
            policy: ContinueWatchingPolicy(nextUpCutoff: 1),
            visibility: merged
        )

        XCTAssertEqual(content.continueWatching.map(\.id), ["no-timestamp"])
    }

    /// Unmerged mode renders the same global row and must curate identically —
    /// otherwise flipping one display switch changes which titles exist.
    func testUnmergedModeCuratesTheSameWay() async {
        let stub = ResumeStub(continueWatching: [
            inProgress("halfway-but-ancient", daysAgo: 400),
            suggestion("suggested-long-ago", daysAgo: 400)
        ])

        let content = await HomeAggregator().unmergedContent(
            from: [resolved("acct", provider: stub)],
            policy: ContinueWatchingPolicy(nextUpCutoff: 90 * 86_400),
            visibility: HomeLibraryVisibility(mergeLibrariesOnHome: false)
        )

        XCTAssertEqual(content.continueWatching.map(\.id), ["halfway-but-ancient"])
    }
}

/// Minimal provider returning a fixed resume feed.
private final class ResumeStub: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    private let stubbedContinueWatching: [MediaItem]
    private let stubbedWatchlist: [MediaItem]

    init(continueWatching: [MediaItem], watchlist: [MediaItem] = []) {
        self.stubbedContinueWatching = continueWatching
        self.stubbedWatchlist = watchlist
    }

    var session: UserSession {
        UserSession(
            server: MediaServer(
                id: "srv", name: "S", baseURL: URL(string: "http://host")!, provider: .jellyfin
            ),
            userID: "u", userName: "User", deviceID: "d", accessToken: "TOKEN"
        )
    }

    func libraries() async throws -> [MediaLibrary] {
        [MediaLibrary(id: "L1", title: "Movies", kind: .movie)]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        Array(stubbedContinueWatching.prefix(limit))
    }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

extension ResumeStub: WatchlistProviding {
    func setWatchlisted(_ watchlisted: Bool, item: MediaItem) async throws {}
    func watchlist() async throws -> [MediaItem] { stubbedWatchlist }
}
