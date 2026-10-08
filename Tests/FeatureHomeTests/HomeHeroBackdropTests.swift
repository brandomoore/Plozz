#if canImport(UIKit)
import XCTest
import UIKit
import CoreModels
import CoreUI
@testable import FeatureHome
@testable import HeroUI
@testable import MetadataKit

@MainActor
final class HomeHeroBackdropTests: XCTestCase {
    func testCarouselRoutesPersistedExternalBackdropsThroughLiveProviderPolicy() async throws {
        let server = try XCTUnwrap(URL(string: "https://library.example.test/hero.jpg"))
        let tmdb = try XCTUnwrap(URL(string: "https://metadata.example.test/tmdb.jpg"))
        let tvdb = try XCTUnwrap(URL(string: "https://metadata.example.test/tvdb.jpg"))
        var item = MediaItem(
            id: "carousel", title: "Carousel", kind: .movie,
            backdropURL: server, heroBackdropURL: tmdb, fallbackArtworkURL: tvdb
        )
        item.artworkMetadataSourcesByURL = [tmdb.absoluteString: .tmdb, tvdb.absoluteString: .tvdb]
        let settings = CarouselArtworkProviderSettings(.init(orderMode: .custom, enabledOrder: ["tmdb", "tvdb"]))
        let cache = MetadataDiskCache(directory: nil)
        for provider in [MetadataSource.tmdb, .tvdb] {
            await cache.store(nil, for: ArtworkRouter.providerCacheKey(
                query: MetadataQuery(item), kind: .hero, source: provider
            ))
        }
        let router = ArtworkRouter(
            cache: cache,
            enrichmentBaseline: .init(order: [.tmdb, .tvdb], priority: .init(rules: [])),
            settingsStore: settings
        )
        let source = HomeCarouselArtworkSource(
            item: item, policy: .init(area: .home, settings: .init(preference: .online)),
            resolveOnline: { await router.heroArtworkURL(for: $0, placement: .homeHero) }
        )
        let cases: [(MetadataProviderSettings, URL)] = [
            (.init(orderMode: .custom, enabledOrder: ["tmdb", "tvdb"]), tmdb),
            (.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]), tvdb),
            (.init(orderMode: .custom, enabledOrder: ["tmdb"], disabledOrder: ["tvdb"]), tmdb),
            (.init(orderMode: .custom, disabledOrder: ["tmdb", "tvdb"]), server)
        ]
        for (providers, expected) in cases {
            settings.save(providers)
            let warmed = await source.warmURL()
            XCTAssertEqual(warmed, expected, "A previous warm result must not bypass live provider policy.")
            XCTAssertEqual(source.references, [.remote(server)],
                           "External warm results must never become library first-paint references.")
        }
        let library = HomeCarouselArtworkSource(
            item: item, policy: .init(area: .home, settings: .init(preference: .library)),
            resolveOnline: { _ in
                XCTFail("The real library hero must win without an online lookup.")
                return nil
            }
        )
        let warmedLibrary = await library.warmURL()
        XCTAssertEqual(warmedLibrary, server)
        XCTAssertEqual(item.heroBackdropURL, tmdb, "The original persisted item remains unchanged.")
    }

    func testCarouselExternalOnlyArtworkStillWarmsThroughItsFallback() async throws {
        let stored = try XCTUnwrap(URL(string: "https://metadata.example.test/old.jpg"))
        let current = try XCTUnwrap(URL(string: "https://metadata.example.test/current.jpg"))
        var item = MediaItem(id: "external", title: "External", kind: .movie, heroBackdropURL: stored)
        item.artworkMetadataSourcesByURL = [stored.absoluteString: .tmdb]
        for preference in [ArtworkPreference.library, .online] {
            let source = HomeCarouselArtworkSource(
                item: item, policy: .init(area: .home, settings: .init(preference: preference)),
                resolveOnline: { [item] snapshot in
                    XCTAssertEqual(snapshot, item)
                    return current
                }
            )
            XCTAssertTrue(source.references.isEmpty)
            XCTAssertTrue(source.canWarm, "An external-only slide must not be skipped by preview warming.")
            let warmed = await source.warmURL()
            XCTAssertEqual(warmed, current)
            XCTAssertTrue(source.references.isEmpty)
        }
        let disabled = HomeCarouselArtworkSource(
            item: item, policy: .init(area: .home, settings: .init(preference: .online)),
            resolveOnline: { _ in nil }
        )
        let unavailable = await disabled.warmURL()
        XCTAssertNil(unavailable, "Failed/disabled providers must not revive the persisted raw backdrop.")
    }

    func testCarouselLibrarySidecarRemainsAReferenceInsteadOfWarmingRawExternalURL() async throws {
        let native = try NetworkArtworkReference(
            accountID: "share", credentialRevision: CredentialRevision(),
            catalogArtworkID: "native-hero",
            representation: RemoteFileRepresentation(
                size: 1024,
                identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: .distantPast),
                consistency: .changeDetecting
            ),
            sourceRevision: "revision", dimensions: ArtworkDimensions(width: 16, height: 9)
        )
        let stored = try XCTUnwrap(URL(string: "https://metadata.example.test/saved.jpg"))
        var item = MediaItem(
            id: "sidecar", title: "Sidecar", kind: .movie, heroBackdropURL: stored,
            artworkSelections: [.init(placement: .homeHero, references: [.networkFile(native)])]
        )
        item.artworkMetadataSourcesByURL = [stored.absoluteString: .tmdb]
        let source = HomeCarouselArtworkSource(
            item: item, policy: .init(area: .home, settings: .init(preference: .library)),
            resolveOnline: { _ in
                XCTFail("Native artwork goes through reference warming, not the URL fallback.")
                return nil
            }
        )
        XCTAssertEqual(source.references, [.networkFile(native)])
        XCTAssertTrue(source.canWarm)
        let warmed = await source.warmURL()
        XCTAssertNil(warmed)
    }

    func testCancelledCarouselWarmDoesNotConsultTheRouter() async {
        let source = HomeCarouselArtworkSource(
            item: .init(id: "cancelled", title: "Cancelled", kind: .movie),
            policy: .init(area: .home, settings: .init(preference: .online)),
            resolveOnline: { _ in
                XCTFail("Cancelled warming must not start provider resolution.")
                return nil
            }
        )
        let task = Task { @MainActor in await source.warmURL() }
        task.cancel()
        let warmed = await task.value
        XCTAssertNil(warmed)
    }

    func testFullCachedHeroDoesNotRequestAMissingPreview() async throws {
        let reference = ArtworkReference.remote(URL(string: "https://example.test/hero.jpg")!)
        let full = image(.red)
        var resolverCalls = 0
        var variants: [String] = []
        let result = await HeroBackdropArtworkPolicy.firstPaint(
            references: [reference], allowsCachedLibraryArtwork: true,
            cachedImage: { candidate, variant in
                XCTAssertEqual(candidate, reference)
                variants.append(variant.rawValue)
                return variant == .heroBackdrop ? full : nil
            },
            resolve: { resolverCalls += 1; return nil }
        )
        XCTAssertTrue(result?.image === full)
        XCTAssertEqual(result?.variant, .heroBackdrop)
        XCTAssertEqual(variants, ["heroBackdrop"])
        XCTAssertEqual(resolverCalls, 0)
    }

    func testCachedFallbackCannotJumpAheadOfUnresolvedPrimary() async {
        let primary = ArtworkReference.remote(URL(string: "https://example.test/primary.jpg")!)
        let fallback = ArtworkReference.remote(URL(string: "https://example.test/fallback.jpg")!)
        var resolverCalls = 0
        let result = await HeroBackdropArtworkPolicy.firstPaint(
            references: [primary, fallback], allowsCachedLibraryArtwork: true,
            cachedImage: { candidate, _ in
                XCTAssertEqual(candidate, primary)
                return nil
            },
            resolve: { resolverCalls += 1; return nil }
        )
        XCTAssertNil(result)
        XCTAssertEqual(resolverCalls, 1)
    }

    func testOnlineOrSharedPolicyKeepsItsExistingResolver() async {
        var resolverCalls = 0
        _ = await HeroBackdropArtworkPolicy.firstPaint(
            references: [.remote(URL(string: "https://example.test/library.jpg")!)],
            allowsCachedLibraryArtwork: false,
            cachedImage: { _, _ in XCTFail("Do not bypass policy with cached library art"); return nil },
            resolve: { resolverCalls += 1; return nil }
        )
        XCTAssertEqual(resolverCalls, 1)
    }

    func testUnusableCachedHeroStillUsesTheResolver() async {
        let ultraWide = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 10)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 40, height: 10))
        }
        var resolverCalls = 0
        _ = await HeroBackdropArtworkPolicy.firstPaint(
            references: [.remote(URL(string: "https://example.test/banner.jpg")!)],
            allowsCachedLibraryArtwork: true,
            cachedImage: { _, _ in ultraWide },
            resolve: { resolverCalls += 1; return nil }
        )
        XCTAssertEqual(resolverCalls, 1)
    }

    func testCancelledFirstPaintDoesNotLoadOrPublishArtwork() async {
        let task = Task { @MainActor in
            await HeroBackdropArtworkPolicy.firstPaint(
                references: [.remote(URL(string: "https://example.test/hero.jpg")!)],
                allowsCachedLibraryArtwork: true,
                cachedImage: { _, _ in XCTFail("Cancelled request read the cache"); return nil },
                resolve: { XCTFail("Cancelled request started resolution"); return nil }
            )
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }

    func testRapidWipesRemainStackedUntilEachRevealFinishes() {
        let container = HeroWipeContainerView(
            bleed: 8,
            parallaxIn: 1_200,
            driftFraction: 0.625
        )
        container.slideSize = CGSize(width: 1_920, height: 1_080)

        let first = image(.red)
        let second = image(.green)
        let third = image(.blue)
        container.setInitialImage(first)

        let secondWipe = container.prepareWipe(incomingImage: second, forward: true)
        let thirdWipe = container.prepareWipe(incomingImage: third, forward: true)

        XCTAssertEqual(container.pageCount, 3)
        XCTAssertEqual(container.activeWipeCount, 2)
        XCTAssertTrue(container.frontImage === third)

        container.finishWipe(secondWipe.incoming)

        XCTAssertEqual(container.pageCount, 2)
        XCTAssertEqual(container.activeWipeCount, 1)
        XCTAssertTrue(container.frontImage === third)

        container.finishWipe(thirdWipe.incoming)

        XCTAssertEqual(container.pageCount, 1)
        XCTAssertEqual(container.activeWipeCount, 0)
        XCTAssertTrue(container.frontImage === third)
    }

    func testOppositeDirectionWipesAlsoStack() {
        let container = HeroWipeContainerView(
            bleed: 8,
            parallaxIn: 1_200,
            driftFraction: 0.625
        )
        container.slideSize = CGSize(width: 1_920, height: 1_080)
        container.setInitialImage(image(.red))

        let forward = container.prepareWipe(incomingImage: image(.green), forward: true)
        let backward = container.prepareWipe(incomingImage: image(.blue), forward: false)

        container.animateIncoming(forward.incoming)
        if let outgoing = forward.outgoing {
            container.animateOutgoing(outgoing, forward: true)
        }
        container.animateIncoming(backward.incoming)
        if let outgoing = backward.outgoing {
            container.animateOutgoing(outgoing, forward: false)
        }

        XCTAssertEqual(container.pageCount, 3)
        XCTAssertEqual(container.activeWipeCount, 2)
    }

    func testClearingArtworkRemovesEveryStackedPage() {
        let container = HeroWipeContainerView(
            bleed: 8,
            parallaxIn: 1_200,
            driftFraction: 0.625
        )
        container.slideSize = CGSize(width: 1_920, height: 1_080)
        container.setInitialImage(image(.red))
        _ = container.prepareWipe(incomingImage: image(.green), forward: true)
        _ = container.prepareWipe(incomingImage: image(.blue), forward: false)

        container.clear()

        XCTAssertEqual(container.pageCount, 0)
        XCTAssertEqual(container.activeWipeCount, 0)
        XCTAssertNil(container.frontImage)
    }

    func testProgressiveImageUpgradeKeepsWipeInFlight() {
        let container = HeroWipeContainerView(
            bleed: 8,
            parallaxIn: 1_200,
            driftFraction: 0.625
        )
        container.slideSize = CGSize(width: 1_920, height: 1_080)
        container.setInitialImage(image(.red))
        let preview = image(.green)
        let fullResolution = image(.blue)

        let wipe = container.prepareWipe(incomingImage: preview, forward: true)
        container.animateIncoming(wipe.incoming)
        container.frontImage = fullResolution

        XCTAssertEqual(container.pageCount, 2)
        XCTAssertEqual(container.activeWipeCount, 1)
        XCTAssertTrue(container.frontImage === fullResolution)

        container.finishWipe(wipe.incoming)
        XCTAssertEqual(container.pageCount, 1)
        XCTAssertEqual(container.activeWipeCount, 0)
        XCTAssertTrue(container.frontImage === fullResolution)
    }

    func testHeroBackdropPolicyRejectsUltraWideProviderJunk() {
        let usable = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        let ultraWide = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 10)).image {
            UIColor.red.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 40, height: 10))
        }

        XCTAssertTrue(HeroBackdropArtworkPolicy.isUsable(usable))
        XCTAssertFalse(HeroBackdropArtworkPolicy.isUsable(ultraWide))
    }

    private func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 9)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
    }
}

private final class CarouselArtworkProviderSettings: MetadataProviderSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: MetadataProviderSettings

    init(_ value: MetadataProviderSettings) { self.value = value }

    func load() -> MetadataProviderSettings {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func save(_ value: MetadataProviderSettings) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}
#endif
