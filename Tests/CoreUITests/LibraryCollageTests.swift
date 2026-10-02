#if canImport(UIKit)
import CoreModels
@testable import CoreUI
import UIKit
import XCTest

final class LibraryCollageTests: XCTestCase {
    func testServerCoverDoesNotRequestCollageCandidates() async throws {
        let provider = CollageProvider()
        let source = source(provider, cover: URL(string: "https://example.invalid/custom.jpg"))
        let candidates = try await source.candidates()
        let calls = await provider.calls
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertEqual(calls, 0)
    }

    func testCandidatesAreLibraryScopedBoundedUniqueAndStable() async throws {
        let provider = CollageProvider()
        let source = source(provider)
        let first = try await source.candidates()
        let second = try await source.candidates()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 6)
        XCTAssertEqual(Set(first.compactMap(\.first)).count, 6)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.0, "movies")
        XCTAssertEqual(requests.first?.1, .movie)
        XCTAssertEqual(requests.first?.2.limit, 18)
        XCTAssertEqual(requests.first?.2.sort, .init(field: .name, direction: .ascending))
    }

    func testCacheIdentitySeparatesProfileAccountLibraryAndCredential() {
        let provider = CollageProvider()
        let baseline = source(provider)
        XCTAssertEqual(baseline.cacheIdentity, source(provider).cacheIdentity)
        XCTAssertNotEqual(baseline.cacheIdentity, source(provider, scope: "child").cacheIdentity)
        XCTAssertNotEqual(baseline.cacheIdentity, source(provider, accountID: "other").cacheIdentity)
        XCTAssertNotEqual(baseline.cacheIdentity, source(provider, libraryID: "series").cacheIdentity)
        XCTAssertNotEqual(
            baseline.cacheIdentity,
            source(provider, revision: CredentialRevision()).cacheIdentity
        )
        XCTAssertNotEqual(
            baseline.cacheIdentity,
            source(CollageProvider(userID: "managed-user")).cacheIdentity
        )
        XCTAssertFalse(baseline.cacheIdentity.contains(provider.session.accessToken))
    }

    func testRawFileRootUsesOnlyItsProvidersIndexedPostersWithoutWalkingFolders() async throws {
        let provider = CollageProvider()
        let source = source(provider, libraryID: "files")
        let candidates = try await source.candidates()
        let directoryRequests = await provider.calls
        let catalogRequests = await provider.latestCalls
        XCTAssertEqual(candidates.count, 6)
        XCTAssertEqual(directoryRequests, 0, "Generating a Browse Files cover must not enumerate the filesystem.")
        XCTAssertEqual(catalogRequests, 1)
    }

    func testConcurrentLoadsComposeOnceAndFreshCacheUsesDiskWithoutProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = CollageProvider()
        let image = Self.poster(.red)
        let cache = LibraryCollageCache(directory: directory, imageLoader: { _ in image })
        let source = source(provider)
        async let first = cache.image(for: source)
        async let second = cache.image(for: source)
        let loaded = await (first, second)
        XCTAssertNotNil(loaded.0)
        XCTAssertTrue(loaded.0 === loaded.1)
        XCTAssertEqual(loaded.0?.size, CGSize(width: 720, height: 405))
        XCTAssertTrue(cache.cachedImage(for: source) === loaded.0,
                      "Returning cards must obtain the same decoded bitmap synchronously.")
        XCTAssertNil(cache.cachedImage(for: self.source(provider, scope: "child")))
        let repeated = await cache.image(for: source)
        XCTAssertTrue(repeated === loaded.0)
        var calls = await provider.calls
        XCTAssertEqual(calls, 1)

        let restored = LibraryCollageCache(directory: directory, imageLoader: { _ in nil })
        let diskImage = await restored.image(for: source)
        XCTAssertNotNil(diskImage)
        XCTAssertEqual(diskImage?.size, CGSize(width: 720, height: 405))
        XCTAssertTrue(restored.cachedImage(for: source) === diskImage)
        calls = await provider.calls
        XCTAssertEqual(calls, 1, "A persisted collage must not refetch posters or enumerate the library.")
    }

    func testMissingPostersAndUnavailableProviderKeepFallbackWithoutRetryStorm() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = CollageProvider(fails: true)
        let cache = LibraryCollageCache(directory: directory, imageLoader: { _ in nil })
        let source = source(provider)
        let first = await cache.image(for: source)
        let second = await cache.image(for: source)
        XCTAssertNil(first)
        XCTAssertNil(second)
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)

        let empty = CollageProvider(items: [])
        let emptyImage = await cache.image(for: self.source(empty, accountID: "empty"))
        XCTAssertNil(emptyImage)
    }

    func testCompositionIsDeterministicOpaqueAndHandlesOnePoster() throws {
        let posters = [Self.poster(.red), Self.poster(.green), Self.poster(.blue)]
        let first = LibraryCollageCache.render(posters)
        let second = LibraryCollageCache.render(posters)
        XCTAssertEqual(first.pngData(), second.pngData())
        XCTAssertEqual(first.scale, 1)
        XCTAssertEqual(first.cgImage?.width, 720)
        XCTAssertEqual(first.cgImage?.height, 405)
        XCTAssertEqual(LibraryCollageCache.render([posters[0]]).size, first.size)
        XCTAssertNotEqual(first.pngData(), LibraryCollageCache.render([]).pngData())
        let alpha = try XCTUnwrap(first.cgImage).alphaInfo
        XCTAssertTrue([.none, .noneSkipFirst, .noneSkipLast].contains(alpha))
    }

    private func source(
        _ provider: CollageProvider,
        cover: URL? = nil,
        scope: String = "adult",
        accountID: String = "account",
        libraryID: String = "movies",
        revision: CredentialRevision = CredentialRevision(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
    ) -> LibraryArtworkSource {
        let account = Account(
            id: accountID, server: provider.session.server, userID: "user", userName: "Viewer",
            deviceID: "device", credentialRevision: revision
        )
        return LibraryArtworkSource(
            library: AggregatedLibrary(
                accountID: accountID, accountName: "Viewer", serverName: "Server",
                providerKind: .jellyfin,
                library: MediaLibrary(id: libraryID, title: "Movies", kind: .movie, imageURL: cover)
            ),
            account: ResolvedAccount(account: account, provider: provider), scope: scope
        )
    }

    private static func poster(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 100, height: 150), format: format).image {
            color.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 100, height: 150))
        }
    }
}

private actor CollageProvider: MediaProvider, MediaFileBrowsing {
    nonisolated let kind: ProviderKind = .jellyfin
    nonisolated let session: UserSession
    private let items: [MediaItem]
    private let fails: Bool
    private(set) var calls = 0
    private(set) var latestCalls = 0
    private(set) var requests: [(String, MediaItemKind, PageRequest)] = []
    nonisolated var fileBrowserLibrary: MediaLibrary {
        MediaLibrary(id: "files", title: "Browse Files", kind: .folder)
    }

    init(userID: String = "user", fails: Bool = false, items: [MediaItem]? = nil) {
        self.session = UserSession(
            server: MediaServer(
                id: "server", name: "Server",
                baseURL: URL(string: "https://example.invalid")!, provider: .jellyfin
            ),
            userID: userID, userName: "Viewer", deviceID: "device", accessToken: "private-fixture-token"
        )
        self.fails = fails
        self.items = items ?? (0..<18).map {
            MediaItem(
                id: "\($0)", title: "Movie \($0)", kind: .movie,
                posterURL: URL(string: "https://example.invalid/poster/\($0 / 2).jpg")
            )
        }
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        calls += 1
        requests.append((containerID, kind, page))
        if fails { throw AppError.notFound }
        return MediaPage(items: items, startIndex: 0, totalCount: items.count)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] {
        latestCalls += 1
        return Array(items.prefix(limit))
    }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
