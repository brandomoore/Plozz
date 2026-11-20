import CoreModels
import XCTest
@testable import FeatureHomeCore

@MainActor
final class FastHeroTrailerResolverTests: XCTestCase {
    func testFailedOrCancelledResolveReleasesExactNegotiationBeforeReturning() async {
        for failure in [Failure.afterNegotiation, .url, .duration, .afterDuration] {
            let provider = TrailerProvider(cancelNegotiation: failure == .afterNegotiation)
            let result = await Task {
                await resolve(provider, failure: failure)
            }.value
            XCTAssertNil(result)
            let releases = await provider.releases
            XCTAssertEqual(releases, ["clip:grant"], "\(failure)")
        }
    }

    func testDroppingUnusedSourceReleasesGrantButReportingIDAloneIsCacheable() async {
        let released = expectation(description: "unused source released")
        let provider = TrailerProvider(onRelease: { released.fulfill() })
        var source = await resolve(provider)
        XCTAssertEqual(source?.isCacheable, false)
        source = nil
        await fulfillment(of: [released], timeout: 2)

        let direct = TrailerProvider(kind: .plex, hasGrant: false, onRelease: { XCTFail("No grant to release") })
        let reusable = await resolve(direct)
        XCTAssertEqual(reusable?.isCacheable, true)
    }

    private enum Failure: Equatable { case afterNegotiation, url, duration, afterDuration }

    private func resolve(_ provider: TrailerProvider, failure: Failure? = nil) async -> HeroTrailerSource? {
        await FastHeroTrailerResolver.resolve(
            item: MediaItem(id: "movie", title: "Movie", kind: .movie).taggingSource("account"),
            identitySources: [], providerForAccountID: { _ in provider },
            authenticatedHTTPResolver: TrailerURLResolver { _ in
                XCTAssertNotEqual(failure, .afterNegotiation, "Do not resolve credentials after cancellation")
                if failure == .url { throw AppError.unauthorized }
                return URL(fileURLWithPath: "/unused-trailer.mov")
            },
            resolveDuration: { _ in
                if failure == .afterDuration { withUnsafeCurrentTask { $0?.cancel() } }
                return failure == .duration ? nil : 30
            }
        )
    }
}

private struct TrailerURLResolver: AuthenticatedHTTPResourceResolving {
    let url: @MainActor @Sendable (AuthenticatedHTTPPlaybackLocator) throws -> URL
    func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL { try url(locator) }
}

private actor TrailerProvider: StreamingQualityProviding {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    let hasGrant: Bool
    let cancelNegotiation: Bool
    let onRelease: @Sendable () -> Void
    private(set) var releases: [String] = []

    init(kind: ProviderKind = .silo, hasGrant: Bool = true, cancelNegotiation: Bool = false,
         onRelease: @escaping @Sendable () -> Void = {}) {
        self.kind = kind
        session = UserSession(
            server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://example.test")!, provider: kind),
            userID: "user", userName: "User", deviceID: "device", accessToken: ""
        )
        self.hasGrant = hasGrant
        self.cancelNegotiation = cancelNegotiation
        self.onRelease = onRelease
    }

    func trailers(for itemID: String) async throws -> [MediaItem] {
        [MediaItem(id: "clip", title: "Trailer", kind: .video)]
    }

    func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
                      streaming: StreamingPlaybackOptions) async throws -> PlaybackRequest {
        try makeRequest(itemID)
    }

    private func makeRequest(_ itemID: String) throws -> PlaybackRequest {
        let locator = try AuthenticatedHTTPPlaybackLocator(
            provider: kind, accountID: "account", credentialRevision: .init(), itemID: itemID,
            deliveryMode: .directFile, resource: AuthenticatedHTTPResource(pathBase: .serverRoot, path: "/clip"),
            playSessionID: hasGrant ? "grant" : nil
        )
        var request = PlaybackRequest(item: .init(id: itemID, title: "Trailer", kind: .video),
                                      playbackSource: .authenticatedHTTP(locator), playSessionID: "grant")
        request.streamingSessionID = hasGrant ? request.playSessionID : nil
        if cancelNegotiation { withUnsafeCurrentTask { $0?.cancel() } }
        return request
    }

    func releaseStreamingSession(_ request: PlaybackRequest) async {
        XCTAssertFalse(Task.isCancelled)
        XCTAssertEqual(request.streamingSessionID, request.playSessionID)
        releases.append("\(request.item.id):\(request.streamingSessionID ?? "missing")")
        onRelease()
    }

    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        XCTAssertEqual(kind, .plex, "Silo ordinary playbackInfo does not opt into watch-neutral release")
        return try makeRequest(itemID)
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        XCTFail("Ambient trailers must not report watch activity")
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
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
