#if canImport(UIKit)
import CoreModels
@testable import CoreUI
@testable import MetadataKit
import UIKit
import XCTest

final class LibraryCollageTests: XCTestCase {
    func testExternalOnlyCandidatesRetainTheirItemsAndRemainBoundedAndUnique() async throws {
        let items = (0..<18).map { index in
            let poster = URL(string: "https://art.example.test/poster/\(index / 2).jpg")!
            var item = MediaItem(id: "\(index)", title: "Title \(index)", kind: .movie, posterURL: poster)
            item.recordArtworkMetadataSource(.tvdb, for: poster)
            return item
        }
        let provider = CollageProvider(items: items)
        let candidates = try await source(provider).artworkCandidates()
        XCTAssertEqual(candidates.count, 6)
        XCTAssertTrue(candidates.allSatisfy { $0.references.isEmpty })
        XCTAssertEqual(candidates.map(\.item.id), ["0", "2", "4", "6", "8", "10"])
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.2.limit, 18)
    }

    func testExternalCollageCacheSeparatesLiveProviderOrderAndDisablement() async throws {
        let tvdb = try XCTUnwrap(URL(string: "https://art.example.test/tvdb.jpg"))
        let tmdb = try XCTUnwrap(URL(string: "https://art.example.test/tmdb.jpg"))
        var item = MediaItem(
            id: "movie", title: "Movie", kind: .movie, posterURL: tvdb, fallbackArtworkURL: tmdb
        )
        item.recordArtworkMetadataSource(.tvdb, for: tvdb)
        item.recordArtworkMetadataSource(.tmdb, for: tmdb)
        let initial = MetadataProviderSettings(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"])
        let settings = CollageArtworkSettings(initial)
        let router = await router(for: item, settings: settings)
        let provider = CollageProvider(items: [item])
        let source = source(provider)
        let loader = CollageArtworkLoader(images: [.remote(tvdb): Self.poster(.red), .remote(tmdb): Self.poster(.blue)])
        let cache = LibraryCollageCache(
            usesDiskCache: false, artworkRouter: router, imageLoader: { await loader.image(for: $0) }
        )
        let firstPolicy = ArtworkPresentationPolicy(settings: .init(preference: .library), providers: initial)
        let first = await cache.image(for: source, policy: firstPolicy)
        XCTAssertNotNil(first)
        XCTAssertTrue(cache.cachedImage(for: source, policy: firstPolicy) === first)

        settings.save(.init(orderMode: .custom, enabledOrder: ["tmdb", "tvdb"]))
        let reorderedPolicy = ArtworkPresentationPolicy(
            settings: .init(preference: .library), providers: settings.load()
        )
        XCTAssertNotEqual(
            LibraryCollageCache.identity(for: source, policy: firstPolicy),
            LibraryCollageCache.identity(for: source, policy: reorderedPolicy)
        )
        XCTAssertNil(cache.cachedImage(for: source, policy: reorderedPolicy))
        let reordered = await cache.image(for: source, policy: reorderedPolicy)
        XCTAssertNotNil(reordered)
        XCTAssertNotEqual(first?.pngData(), reordered?.pngData())

        settings.save(.init(orderMode: .custom, disabledOrder: ["tvdb", "tmdb"]))
        let disabledPolicy = ArtworkPresentationPolicy(
            settings: .init(preference: .library), providers: settings.load()
        )
        XCTAssertNil(cache.cachedImage(for: source, policy: disabledPolicy))
        let disabled = await cache.image(for: source, policy: disabledPolicy)
        let repeated = await cache.image(for: source, policy: disabledPolicy)
        XCTAssertNil(disabled)
        XCTAssertNil(repeated)
        let requests = await loader.requests
        XCTAssertEqual(requests, [.remote(tvdb), .remote(tmdb)])
        let providerCalls = await provider.calls
        XCTAssertEqual(providerCalls, 3, "An unchanged negative policy result must not create a retry storm.")

        settings.save(initial)
        let restored = await cache.image(for: source, policy: firstPolicy)
        XCTAssertTrue(restored === first, "Re-enabling a policy may reuse only its own source-qualified composite.")
        XCTAssertNotEqual(
            LibraryCollageCache.identity(for: source, policy: firstPolicy),
            LibraryCollageCache.identity(
                for: source, policy: .init(settings: .init(preference: .online), providers: initial)
            )
        )
    }

    func testLibraryCollagePaintsActualSidecarBeforeRetainedExternalPoster() async throws {
        let sidecar = ArtworkReference.networkFile(try NetworkArtworkReference(
            accountID: "share-account", credentialRevision: CredentialRevision(),
            catalogArtworkID: "local-poster",
            representation: RemoteFileRepresentation(
                size: 1_024, identity: .init(kind: .modificationTime, modifiedAt: .distantPast),
                consistency: .changeDetecting
            ),
            sourceRevision: "one", dimensions: .init(width: 100, height: 150)
        ))
        let external = try XCTUnwrap(URL(string: "https://art.example.test/external.jpg"))
        var item = MediaItem(
            id: "movie", title: "Movie", kind: .movie, posterURL: external,
            artworkSelections: [.init(placement: .poster, references: [sidecar])]
        )
        item.recordArtworkMetadataSource(.tvdb, for: external)
        let settings = CollageArtworkSettings(.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]))
        let router = await router(for: item, settings: settings)
        let loader = CollageArtworkLoader(images: [
            sidecar: Self.poster(.green), .remote(external): Self.poster(.red)
        ])
        let cache = LibraryCollageCache(
            usesDiskCache: false, artworkRouter: router, imageLoader: { await loader.image(for: $0) }
        )
        let result = await cache.image(
            for: source(CollageProvider(items: [item])),
            policy: .init(settings: .init(preference: .library), providers: settings.load())
        )
        XCTAssertNotNil(result)
        let requests = await loader.requests
        XCTAssertEqual(requests, [sidecar])
    }

    private func router(for item: MediaItem, settings: CollageArtworkSettings) async -> ArtworkRouter {
        let cache = MetadataDiskCache(directory: nil)
        for source in [MetadataSource.tvdb, .tmdb] {
            await cache.store(nil, for: ArtworkRouter.providerCacheKey(
                query: MetadataQuery(item), kind: .poster, source: source
            ))
        }
        return ArtworkRouter(
            cache: cache, enrichmentBaseline: .init(order: [.tvdb, .tmdb], priority: .init(rules: [])),
            settingsStore: settings
        )
    }

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

private actor CollageArtworkLoader {
    let images: [ArtworkReference: UIImage]
    private(set) var requests: [ArtworkReference] = []
    init(images: [ArtworkReference: UIImage]) { self.images = images }
    func image(for reference: ArtworkReference) -> UIImage? {
        requests.append(reference)
        return images[reference]
    }
}

private final class CollageArtworkSettings: MetadataProviderSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: MetadataProviderSettings
    init(_ value: MetadataProviderSettings) { self.value = value }
    func load() -> MetadataProviderSettings { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ value: MetadataProviderSettings) { lock.lock(); self.value = value; lock.unlock() }
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
