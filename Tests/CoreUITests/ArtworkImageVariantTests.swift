import XCTest
import CoreModels
#if canImport(UIKit)
import UIKit
#endif
@testable import CoreUI

final class ArtworkImageVariantTests: XCTestCase {
    private let url = URL(string: "https://media.example.com/Items/abc/Images/Primary?maxWidth=1280")!

    func testMaxPixelSizeBoundsPerVariant() {
        // Cards are aggressively bounded; the hero is high-fidelity but still capped;
        // only `.original` decodes at native source size.
        XCTAssertNil(ArtworkImageVariant.original.maxPixelSize)
        XCTAssertEqual(ArtworkImageVariant.musicThumbnail.maxPixelSize, 256)
        XCTAssertEqual(ArtworkImageVariant.posterPreview.maxPixelSize, 320)
        XCTAssertEqual(ArtworkImageVariant.posterCard.maxPixelSize, 960)
        XCTAssertEqual(ArtworkImageVariant.landscapeCard.maxPixelSize, 1_200)
        XCTAssertEqual(ArtworkImageVariant.heroPreview.maxPixelSize, 768)
        XCTAssertEqual(ArtworkImageVariant.heroBackdrop.maxPixelSize, 2_000)
    }

    func testCardVariantsAreSmallerThanHero() {
        // Sanity-check the size ordering the whole optimization rests on: cards must
        // never decode larger than the hero, and every bounded variant must be
        // smaller than an unbounded `.original`.
        let poster = ArtworkImageVariant.posterCard.maxPixelSize!
        let posterPreview = ArtworkImageVariant.posterPreview.maxPixelSize!
        let landscape = ArtworkImageVariant.landscapeCard.maxPixelSize!
        let preview = ArtworkImageVariant.heroPreview.maxPixelSize!
        let hero = ArtworkImageVariant.heroBackdrop.maxPixelSize!
        XCTAssertLessThan(poster, hero)
        XCTAssertLessThan(posterPreview, poster)
        XCTAssertLessThan(landscape, hero)
        XCTAssertLessThan(preview, hero)
        XCTAssertLessThanOrEqual(poster, landscape)
    }

    func testVariantsProduceDistinctCacheKeysForSameURL() {
        // The same source URL must be cacheable at every variant at once (an episode
        // card's small backdrop and the detail hero's large one) without collision.
        let keys = ArtworkImageVariant.allCases.map { $0.cacheKey(for: url) }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testCacheKeyIsStableAndContainsURL() {
        let key = ArtworkImageVariant.posterCard.cacheKey(for: url)
        XCTAssertEqual(key, ArtworkImageVariant.posterCard.cacheKey(for: url))
        XCTAssertTrue(key.contains(url.absoluteString))
    }

    func testDifferentURLsProduceDifferentKeysWithinAVariant() {
        let other = URL(string: "https://media.example.com/Items/xyz/Images/Primary")!
        XCTAssertNotEqual(
            ArtworkImageVariant.landscapeCard.cacheKey(for: url),
            ArtworkImageVariant.landscapeCard.cacheKey(for: other)
        )
    }

    func testHeroPreviewRightSizesJellyfinTransferWithoutChangingCacheIdentity() {
        let source = URL(string: "https://jellyfin.example/Items/abc/Images/Backdrop?maxWidth=3840&tag=rev")!
        let request = ArtworkImageVariant.heroPreview.requestURL(for: source)

        XCTAssertEqual(
            request.absoluteString,
            "https://jellyfin.example/Items/abc/Images/Backdrop?maxWidth=768&tag=rev"
        )
        XCTAssertEqual(
            ArtworkImageVariant.heroPreview.cacheKey(for: source),
            "heroPreview|\(source.absoluteString)"
        )
    }

    func testHeroBackdropNeverUpscalesSmallerJellyfinTransfer() {
        let source = URL(string: "https://jellyfin.example/Items/abc/Images/Backdrop?maxWidth=1280")!
        XCTAssertEqual(ArtworkImageVariant.heroBackdrop.requestURL(for: source), source)
    }

    func testHeroPreviewRightSizesPlexTransferAndPreservesNestedToken() {
        let source = URL(
            string: "https://plex.example/photo/:/transcode?width=3840&height=5760&minSize=1&url=%2Flibrary%2Fmetadata%2F1%2Fart%2F2%3FX-Plex-Token%3DSECRET&X-Plex-Token=SECRET"
        )!
        let request = ArtworkImageVariant.heroPreview.requestURL(for: source)
        let components = URLComponents(url: request, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) }
        )

        XCTAssertEqual(query["width"]!, "768")
        XCTAssertEqual(query["height"]!, "768")
        XCTAssertEqual(query["minSize"]!, "0")
        XCTAssertEqual(query["upscale"]!, "0")
        XCTAssertEqual(query["url"]!, "/library/metadata/1/art/2?X-Plex-Token=SECRET")
        XCTAssertEqual(query["X-Plex-Token"]!, "SECRET")
        XCTAssertEqual(
            components?.percentEncodedQueryItems?.first(where: { $0.name == "url" })?.value,
            URLComponents(url: source, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems?
                .first(where: { $0.name == "url" })?.value
        )
    }

    func testEveryPlexVariantBoundsBothAxesWithoutUpscalingOrChangingAspectRatio() throws {
        for variant in ArtworkImageVariant.allCases {
            guard let cap = variant.maxPixelSize else { continue }
            for bounds in [(3840, 5760), (500, 750), (300, 4000)] {
                let source = try XCTUnwrap(URL(string:
                    "https://plex.example/photo/:/transcode?width=\(bounds.0)&height=\(bounds.1)&minSize=1&upscale=1"
                ))
                let query = try XCTUnwrap(URLComponents(url: variant.requestURL(for: source), resolvingAgainstBaseURL: false)?.queryItems)
                let width = try XCTUnwrap(query.first { $0.name == "width" }?.value.flatMap(Double.init))
                let height = try XCTUnwrap(query.first { $0.name == "height" }?.value.flatMap(Double.init))
                XCTAssertEqual(width, Double(min(bounds.0, cap)))
                XCTAssertEqual(height, Double(min(bounds.1, cap)))
                XCTAssertEqual(query.first { $0.name == "minSize" }?.value, "0")
                XCTAssertEqual(query.first { $0.name == "upscale" }?.value, "0")
                // Plex's fit-without-upscale contract, for landscape, portrait and small originals.
                for original in [(5333.0, 3000.0), (3000.0, 4500.0), (120.0, 80.0)] {
                    let scale = min(1, width / original.0, height / original.1)
                    XCTAssertLessThanOrEqual(max(original.0 * scale, original.1 * scale).rounded(), Double(cap))
                    XCTAssertLessThanOrEqual(scale, 1)
                    XCTAssertEqual((original.0 * scale) / (original.1 * scale), original.0 / original.1, accuracy: 0.0001)
                }
            }
        }
    }

    func testPlexWidthOnlyGetsHeightBoundAndOriginalRemainsUntouched() throws {
        let source = try XCTUnwrap(URL(string: "https://plex.example/photo/:/transcode?width=400&url=%2Fposter"))
        let query = try XCTUnwrap(URLComponents(url: ArtworkImageVariant.heroPreview.requestURL(for: source), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "width" }?.value, "400")
        XCTAssertEqual(query.first { $0.name == "height" }?.value, "768")
        XCTAssertEqual(ArtworkImageVariant.original.requestURL(for: source), source)
    }

    func testHeroPreviewUsesNearestTMDbBucket() {
        let source = URL(string: "https://image.tmdb.org/t/p/w1280/backdrop.jpg")!
        XCTAssertEqual(
            ArtworkImageVariant.heroPreview.requestURL(for: source).absoluteString,
            "https://image.tmdb.org/t/p/w780/backdrop.jpg"
        )
        XCTAssertEqual(ArtworkImageVariant.heroBackdrop.requestURL(for: source), source)
    }

    func testUnknownArtworkEndpointIsNotRewritten() {
        let source = URL(string: "https://images.example.com/backdrop.jpg?width=3840")!
        XCTAssertEqual(ArtworkImageVariant.heroPreview.requestURL(for: source), source)
    }

    func testPreviewIsNotDistinctForUnresizableArtworkEndpoint() {
        let source = URL(string: "https://images.example.com/poster.jpg")!

        XCTAssertFalse(
            ArtworkImageVariant.posterPreview.hasDistinctRequestURL(
                from: .posterCard,
                for: source
            )
        )
    }

    func testPreviewIsDistinctForResizablePlexArtworkEndpoint() {
        let source = URL(
            string: "https://plex.example/photo/:/transcode?width=1280&height=1920"
        )!

        XCTAssertTrue(
            ArtworkImageVariant.posterPreview.hasDistinctRequestURL(
                from: .posterCard,
                for: source
            )
        )
    }

    #if canImport(UIKit)
    private struct ImmediateArtworkLoader: ArtworkNetworkFileLoading {
        let data: Data

        func loadArtwork(
            _ reference: NetworkArtworkReference,
            maximumBytes: Int
        ) async throws -> Data {
            data
        }
    }

    private actor BlockingArtworkLoader: ArtworkNetworkFileLoading {
        let data: Data
        private var started = false
        private var released = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        init(data: Data) {
            self.data = data
        }

        func loadArtwork(
            _ reference: NetworkArtworkReference,
            maximumBytes: Int
        ) async throws -> Data {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
            return data
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private actor CountingArtworkLoader: ArtworkNetworkFileLoading {
        let data: Data
        private(set) var loadCount = 0

        init(data: Data) {
            self.data = data
        }

        func loadArtwork(
            _ reference: NetworkArtworkReference,
            maximumBytes: Int
        ) async throws -> Data {
            loadCount += 1
            return data
        }
    }

    private func networkReference(
        accountID: String = "art-cache-account",
        revision: CredentialRevision = CredentialRevision(),
        sourceRevision: String = UUID().uuidString
    ) throws -> NetworkArtworkReference {
        try NetworkArtworkReference(
            accountID: accountID,
            credentialRevision: revision,
            catalogArtworkID: "art-\(sourceRevision)",
            representation: RemoteFileRepresentation(
                size: 1_024,
                identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: .distantPast),
                consistency: .changeDetecting
            ),
            sourceRevision: sourceRevision
        )
    }

    private func jpegFixture() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    private func transparentLogoFixture() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 64, height: 32),
            format: format
        ).image {
            UIColor.clear.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            UIColor.white.setFill()
            $0.fill(CGRect(x: 8, y: 8, width: 48, height: 16))
        }
        return try XCTUnwrap(image.pngData())
    }

    func testSuspensionBlocksNewPrefetchesAndRejectsStalePhaseChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkImageCache(derivedCache: LocalArtworkDerivedCache(directory: directory))
        let loader = CountingArtworkLoader(data: try jpegFixture())
        cache.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        let reference = try networkReference(accountID: UUID().uuidString)

        await cache.setBackgroundWorkAllowed(false, revision: 1)
        let blocked = await cache.image(for: .networkFile(reference), background: true)
        XCTAssertNil(blocked)
        let blockedCount = await loader.loadCount
        XCTAssertEqual(blockedCount, 0)

        await cache.setBackgroundWorkAllowed(true, revision: 2)
        await cache.setBackgroundWorkAllowed(false, revision: 1)
        await cache.setBackgroundWorkAllowed(false, revision: 2)
        let loaded = await cache.image(for: .networkFile(reference), background: true)
        XCTAssertNotNil(loaded)
        let resumedCount = await loader.loadCount
        XCTAssertEqual(resumedCount, 1)
    }

    func testStaleSuspensionDoesNotCancelResumedInFlightPrefetch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkImageCache(derivedCache: LocalArtworkDerivedCache(directory: directory))
        let loader = BlockingArtworkLoader(data: try jpegFixture())
        cache.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        let reference = try networkReference(accountID: UUID().uuidString)
        await cache.setBackgroundWorkAllowed(false, revision: 1)
        await cache.setBackgroundWorkAllowed(true, revision: 2)
        let load = Task { await cache.image(for: .networkFile(reference), background: true) }
        await loader.waitUntilStarted()
        await cache.setBackgroundWorkAllowed(false, revision: 1)
        await loader.release()
        let image = await load.value
        XCTAssertNotNil(image)
    }

    func testSuspensionFinishesBackgroundCallerBeforeUncooperativeLoaderReturns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkImageCache(derivedCache: LocalArtworkDerivedCache(directory: directory))
        let loader = BlockingArtworkLoader(data: try jpegFixture())
        cache.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        let reference = try networkReference(accountID: UUID().uuidString)
        let returned = expectation(description: "background caller released without waiting for I/O")
        let load = Task {
            let image = await cache.image(for: .networkFile(reference), background: true)
            returned.fulfill()
            return image
        }
        await loader.waitUntilStarted()
        await cache.setBackgroundWorkAllowed(false, revision: 1)
        await fulfillment(of: [returned], timeout: 2)
        await loader.release()
        let result = await load.value
        XCTAssertNil(result)
        XCTAssertNil(cache.cachedImage(for: .networkFile(reference)))
    }

    func testQueuedPrefetchCannotCrossSuspensionGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let limiter = ConcurrencyLimiter(limit: 1)
        let cache = ArtworkImageCache(
            derivedCache: LocalArtworkDerivedCache(directory: directory),
            warmLimiter: limiter
        )
        let reference = try networkReference(accountID: UUID().uuidString)
        let blocker = BlockingArtworkLoader(data: try jpegFixture())
        let loader = CountingArtworkLoader(data: try jpegFixture())
        cache.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        let occupied = Task {
            await limiter.run { try? await blocker.loadArtwork(reference, maximumBytes: 1_024) }
        }
        await blocker.waitUntilStarted()
        let pending = try XCTUnwrap(cache.prefetch(.networkFile(reference)))
        await cache.setBackgroundWorkAllowed(false, revision: 1)
        await cache.setBackgroundWorkAllowed(true, revision: 2)
        await blocker.release()
        _ = await occupied.value
        await pending.value
        let count = await loader.loadCount
        XCTAssertEqual(count, 0)
    }

    func testSharedDownsamplerBoundsLongestEdge() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 900)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 1_600, height: 900))
        }
        let data = try XCTUnwrap(source.jpegData(compressionQuality: 0.9))
        let downsampled = try XCTUnwrap(ArtworkImageCache.downsample(data, maxPixelSize: 768))

        XCTAssertEqual(max(downsampled.size.width, downsampled.size.height), 768, accuracy: 1)
        XCTAssertEqual(downsampled.size.width / downsampled.size.height, 16.0 / 9.0, accuracy: 0.01)
    }

    func testCredentialPurgeRemovesDecodedNetworkArtwork() async throws {
        let cache = ArtworkImageCache.shared
        let revision = CredentialRevision()
        let reference = try networkReference(revision: revision)
        cache.configure(
            networkFileService: ArtworkNetworkFileService(
                loader: ImmediateArtworkLoader(data: try jpegFixture())
            )
        )
        defer { cache.configure(networkFileService: nil) }

        let loaded = await cache.image(for: .networkFile(reference))
        XCTAssertNotNil(loaded)
        XCTAssertNotNil(cache.cachedImage(for: .networkFile(reference)))

        await cache.purgeNetworkArtwork(
            accountID: reference.accountID,
            credentialRevision: revision
        )

        XCTAssertNil(cache.cachedImage(for: .networkFile(reference)))
    }

    func testAccountPurgeFencesLateInFlightNetworkArtworkCompletion() async throws {
        let cache = ArtworkImageCache.shared
        let reference = try networkReference()
        let loader = BlockingArtworkLoader(data: try jpegFixture())
        cache.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        defer { cache.configure(networkFileService: nil) }

        let request = Task {
            await cache.image(for: .networkFile(reference))
        }
        await loader.waitUntilStarted()
        let purge = Task {
            await cache.purgeNetworkArtwork(accountID: reference.accountID)
        }
        let result = await request.value
        XCTAssertNil(result)
        let blockedDuringPurge = await cache.image(for: .networkFile(reference))
        XCTAssertNil(blockedDuringPurge)

        await loader.release()
        await purge.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(cache.cachedImage(for: .networkFile(reference)))
    }

    func testCredentialPurgeAlsoEvictsPreparedHeroLogo() async throws {
        let cache = ArtworkImageCache.shared
        let revision = CredentialRevision()
        let reference = try networkReference(
            revision: revision,
            sourceRevision: "hero-logo-\(UUID().uuidString)"
        )
        let artworkReference = ArtworkReference.networkFile(reference)
        let loader = CountingArtworkLoader(data: try transparentLogoFixture())
        cache.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        defer { cache.configure(networkFileService: nil) }

        let first = await HeroLogoPipeline.shared.preparedLogo(for: artworkReference)
        let second = await HeroLogoPipeline.shared.preparedLogo(for: artworkReference)
        let initialLoads = await loader.loadCount
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(initialLoads, 1)

        await cache.purgeNetworkArtwork(
            accountID: reference.accountID,
            credentialRevision: revision
        )

        let reloaded = await HeroLogoPipeline.shared.preparedLogo(for: artworkReference)
        let finalLoads = await loader.loadCount
        XCTAssertNotNil(reloaded)
        XCTAssertEqual(finalLoads, 2)
    }
    #endif
}
