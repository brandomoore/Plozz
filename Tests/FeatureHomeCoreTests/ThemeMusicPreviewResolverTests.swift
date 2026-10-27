import CoreModels
import XCTest
@testable import FeatureHomeCore

@MainActor
final class ThemeMusicPreviewResolverTests: XCTestCase {
    func testFindsThemeThroughEitherProviderAndUsesSeriesForEpisodes() async throws {
        for kind in [ProviderKind.plex, .jellyfin, .emby] {
            let provider = PreviewProvider(kind: kind, themeID: "series")
            let episode = MediaItem(id: "episode", title: "Episode", kind: .episode, seriesID: "series")
                .taggingSource("active")
            let result = try await ThemeMusicPreviewResolver.resolve(
                content: .init(continueWatching: [episode]), accounts: [account(provider)]
            )
            XCTAssertEqual(result?.itemID, "series")
            let requested = await provider.requested
            XCTAssertEqual(requested, ["series"])
        }
    }

    func testSkipsOtherAccountsAndDeduplicatesSeriesLookups() async throws {
        let provider = PreviewProvider(kind: .plex, themeID: "movie")
        let hidden = MediaItem(id: "private", title: "Private", kind: .movie).taggingSource("other")
        let series = MediaItem(id: "series", title: "Series", kind: .series).taggingSource("active")
        let episode = MediaItem(id: "episode", title: "Episode", kind: .episode, seriesID: "series")
            .taggingSource("active")
        let movie = MediaItem(id: "movie", title: "Movie", kind: .movie).taggingSource("active")
        let result = try await ThemeMusicPreviewResolver.resolve(
            content: .init(continueWatching: [hidden, series, episode], latest: [movie]),
            accounts: [account(provider)]
        )
        XCTAssertEqual(result?.itemID, "movie")
        let requested = await provider.requested
        XCTAssertEqual(requested, ["series", "movie"])
    }

    func testNoThemeLookupIsBoundedAndMissingContentNeedsNoProviderRequest() async throws {
        let provider = PreviewProvider(kind: .jellyfin)
        let items = (0..<20).map {
            MediaItem(id: "\($0)", title: "Movie", kind: .movie).taggingSource("active")
        }
        let result = try await ThemeMusicPreviewResolver.resolve(
            content: .init(latest: items), accounts: [account(provider)]
        )
        XCTAssertNil(result)
        let requested = await provider.requested
        XCTAssertEqual(requested.count, 8)
        let missing = try await ThemeMusicPreviewResolver.resolve(
            content: nil, accounts: [account(provider)]
        )
        XCTAssertNil(missing)
        let after = await provider.requested
        XCTAssertEqual(after, requested)
    }

    func testProviderFailureIsNotReportedAsNoAvailableTheme() async throws {
        let provider = PreviewProvider(kind: .plex, shouldFail: true)
        do {
            _ = try await ThemeMusicPreviewResolver.resolve(
                content: .init(latest: [MediaItem(id: "movie", title: "Movie", kind: .movie).taggingSource("active")]),
                accounts: [account(provider)]
            )
            XCTFail("A failed lookup must not silently become a generated preview.")
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
    }

    private func account(_ provider: PreviewProvider) -> ResolvedAccount {
        ResolvedAccount(
            account: Account(
                id: "active", server: provider.session.server, userID: "user", userName: "User", deviceID: "device"
            ),
            provider: provider
        )
    }
}

private actor PreviewProvider: MediaProvider {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    let themeID: String?
    let shouldFail: Bool
    private(set) var requested: [String] = []

    init(kind: ProviderKind, themeID: String? = nil, shouldFail: Bool = false) {
        self.kind = kind
        self.themeID = themeID
        self.shouldFail = shouldFail
        session = UserSession(
            server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://example.test")!, provider: kind),
            userID: "user", userName: "User", deviceID: "device", accessToken: ""
        )
    }

    func themeMusic(for itemID: String) async throws -> ThemeMusic? {
        requested.append(itemID)
        if shouldFail { throw AppError.serverUnreachable }
        guard itemID == themeID else { return nil }
        return ThemeMusic(
            itemID: itemID,
            playbackSource: .publicURL(try SecretFreeURLSource(url: URL(string: "https://example.test/theme.mp3")!))
        )
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
