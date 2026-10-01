#if DEBUG && os(tvOS)
import CoreModels
import FeaturePlayback
import XCTest
@testable import AppShell

@MainActor
final class MarkerPreviewLibrarySourceTests: XCTestCase {
    private func resolved(_ provider: MarkerEpisodeProvider) -> ResolvedAccount {
        .init(account: Account(id: "account", from: provider.session), provider: provider)
    }

    func testLibraryPreviewUsesEnabledEpisodeAndNeverReportsWatchProgress() async throws {
        for kind in [ProviderKind.plex, .jellyfin] {
            let provider = MarkerEpisodeProvider(kind: kind)
            let source = try await MarkerPreviewLibrarySource.resolve(
                sources: [resolved(provider)],
                visibility: .init(disabledKeys: ["account:hidden"]), authorize: {}
            )
            XCTAssertEqual(source.request.item.id, "allowed-episode")
            XCTAssertEqual(source.startPosition, 60)
            let requestedLibraries = await provider.requestedLibraries
            XCTAssertEqual(requestedLibraries, ["allowed"])
            let options = await provider.options
            XCTAssertEqual(options?.quality, .original)
            XCTAssertEqual(options?.subtitlesOff, true)
            await source.release()
            let releases = await provider.releases
            XCTAssertEqual(releases, 1)
            let reports = await provider.watchReports
            XCTAssertEqual(reports, 0)
        }
    }

    func testDisablingAllLibrariesDoesNotResolveOrReadAnEpisode() async throws {
        let provider = MarkerEpisodeProvider(kind: .plex)
        do {
            _ = try await MarkerPreviewLibrarySource.resolve(
                sources: [resolved(provider)],
                visibility: .init(disabledKeys: ["account:allowed", "account:hidden"]), authorize: {}
            )
            XCTFail("The preview cannot use disabled libraries.")
        } catch let error as AppError {
            XCTAssertEqual(error, .notFound)
        }
        let requests = await provider.playbackRequests
        XCTAssertEqual(requests, 0)
        let libraries = await provider.requestedLibraries
        XCTAssertTrue(libraries.isEmpty)
    }

    func testAuthorizationChangeReleasesPreparedSessionBeforeAnyPlayback() async throws {
        let provider = MarkerEpisodeProvider(kind: .jellyfin)
        var checks = 0
        do {
            _ = try await MarkerPreviewLibrarySource.resolve(
                sources: [resolved(provider)], visibility: .init(disabledKeys: ["account:hidden"])
            ) {
                checks += 1
                if checks == 4 { throw CancellationError() }
            }
            XCTFail("A stale profile request must be discarded.")
        } catch is CancellationError {}
        let releases = await provider.releases
        let requests = await provider.playbackRequests
        let reports = await provider.watchReports
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(reports, 0)
    }

    func testUnauthenticatedPreviewCannotStartDiscovery() async throws {
        let provider = MarkerEpisodeProvider(kind: .plex)
        do {
            _ = try await MarkerPreviewLibrarySource.resolve(
                sources: [resolved(provider)], visibility: .default, authorize: { throw CancellationError() }
            )
            XCTFail("Normal profile gates must precede discovery.")
        } catch is CancellationError {}
        let reads = await provider.libraryReads
        XCTAssertEqual(reads, 0)
    }

    func testEmptyResumeFallsBackToATVLibraryWithoutBeingBlockedByMovieLibraries() async throws {
        let provider = MarkerEpisodeProvider(kind: .jellyfin, hasResume: false, movieLibrariesFirst: true)
        let source = try await MarkerPreviewLibrarySource.resolve(
            sources: [resolved(provider)], visibility: .init(disabledKeys: ["account:hidden"]), authorize: {}
        )
        XCTAssertEqual(source.request.item.id, "allowed-episode")
        let queried = await provider.requestedItemLibraries
        XCTAssertEqual(queried, ["allowed"])
        await source.release()
    }

    func testWrongPreparedItemIsReleasedAndNeverUsedAsTheBackground() async throws {
        let provider = MarkerEpisodeProvider(kind: .plex, wrongPreparedItem: true)
        do {
            _ = try await MarkerPreviewLibrarySource.resolve(
                sources: [resolved(provider)], visibility: .init(disabledKeys: ["account:hidden"]), authorize: {}
            )
            XCTFail("The selected episode must own the prepared stream.")
        } catch let error as AppError {
            XCTAssertEqual(error, .invalidResponse)
        }
        let releases = await provider.releases
        XCTAssertEqual(releases, 1)
    }
}

private actor MarkerEpisodeProvider: StreamingQualityProviding {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    private(set) var requestedLibraries: Set<String> = []
    private(set) var playbackRequests = 0
    private(set) var releases = 0
    private(set) var watchReports = 0
    private(set) var libraryReads = 0
    private(set) var options: StreamingPlaybackOptions?
    private(set) var requestedItemLibraries: [String] = []
    private let hasResume: Bool
    private let movieLibrariesFirst: Bool
    private let wrongPreparedItem: Bool

    init(kind: ProviderKind, hasResume: Bool = true, movieLibrariesFirst: Bool = false, wrongPreparedItem: Bool = false) {
        self.kind = kind
        self.hasResume = hasResume
        self.movieLibrariesFirst = movieLibrariesFirst
        self.wrongPreparedItem = wrongPreparedItem
        session = .init(
            server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!, provider: kind),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
    }

    func libraries() async throws -> [MediaLibrary] {
        libraryReads += 1
        let movies: [MediaLibrary] = movieLibrariesFirst
            ? (1...3).map { .init(id: "movies-\($0)", title: "Movies", kind: .movie) } : []
        return movies + [.init(id: "allowed", title: "Allowed", kind: .series),
                         .init(id: "hidden", title: "Hidden", kind: .series)]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { try await continueWatching(limit: limit, inLibraries: nil) }
    func continueWatching(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        requestedLibraries = Set(libraryIDs ?? [])
        guard hasResume else { return [] }
        return [
            MediaItem(id: "hidden-episode", title: "Hidden", kind: .episode, libraryID: "hidden"),
            MediaItem(id: "allowed-episode", title: "Allowed", kind: .episode, runtime: 1_440, libraryID: "allowed")
        ]
    }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { .init(id: id, title: "Fixture", kind: .episode, runtime: 1_440) }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        requestedItemLibraries.append(containerID)
        return .init(items: [.init(id: "allowed-episode", title: "Allowed", kind: .episode, runtime: 1_440)],
                     startIndex: 0, totalCount: 1)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        playbackRequests += 1
        return .init(item: try await item(id: wrongPreparedItem ? "wrong" : itemID),
                     streamURL: URL(string: "https://fixture.invalid/video.mp4")!)
    }
    func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
                      streaming: StreamingPlaybackOptions) async throws -> PlaybackRequest {
        options = streaming
        return try await playbackInfo(for: itemID)
    }
    func releaseStreamingSession(_ request: PlaybackRequest) async { releases += 1 }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws { watchReports += 1 }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
