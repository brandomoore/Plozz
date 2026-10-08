#if os(iOS)
import CoreModels
import CoreUI
import UIKit
import XCTest
@testable import AppShelliOS
@testable import MetadataKit

@MainActor
final class DownloadArtworkPresentationTests: XCTestCase {
    func testDownloadRepairLoaderHonorsItsScopeAndCurrentProviderOrder() async throws {
        let library = URL(string: "https://library.example.test/\(UUID()).png")!
        let tmdb = URL(string: "https://metadata.example.test/\(UUID()).png")!
        let tvdb = URL(string: "https://metadata.example.test/\(UUID()).png")!
        let imageCache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        for (url, color) in [(library, UIColor.red), (tmdb, .green), (tvdb, .blue)] {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 24)).pngData { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 24))
            }
            let request = URLRequest(url: url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"]
            ))
            imageCache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
            addTeardownBlock { imageCache.removeCachedResponse(for: request) }
        }
        var item = MediaItem(
            id: UUID().uuidString, title: "Download artwork repair", kind: .movie,
            posterURL: tmdb, backdropURL: library
        )
        item.metadataProvenance[.posterURL] = .init(source: .tmdb)
        let cache = MetadataDiskCache(directory: nil)
        let store = DownloadArtworkProviderSettings()
        let router = ArtworkRouter(
            cache: cache, enrichmentBaseline: .init(order: [.tmdb, .tvdb], priority: .init(rules: [])),
            settingsStore: store
        )
        for source in [MetadataSource.tmdb, .tvdb] {
            for kind in [ArtworkKind.hero, .thumbnail, .poster] {
                await cache.store(
                    source == .tmdb ? tmdb : tvdb,
                    for: ArtworkRouter.providerCacheKey(query: MetadataQuery(item), kind: kind, source: source)
                )
            }
        }
        for (providers, choice, expectedChannel) in [
            (MetadataProviderSettings(orderMode: .custom, enabledOrder: ["tmdb", "tvdb"]), ArtworkOverride.online, 1),
            (.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]), .online, 2),
            (.init(orderMode: .custom, enabledOrder: ["tvdb"], disabledOrder: ["tmdb"]), .online, 2),
            (.init(orderMode: .custom, disabledOrder: ["tmdb", "tvdb"]), .online, 0),
            (.init(orderMode: .custom, enabledOrder: ["tmdb", "tvdb"]), .library, 0)
        ] {
            store.save(providers)
            var settings = ArtworkSettings(preference: choice == .online ? .library : .online)
            settings.setOverride(choice, for: .downloads)
            let data = try await PlozziOSDownloadArtwork.load(
                for: item, policy: .init(area: .details, settings: settings, providers: providers), router: router
            )
            let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
            let pixel = try XCTUnwrap(CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            pixel.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let channels = try XCTUnwrap(pixel.data).assumingMemoryBound(to: UInt8.self)
            for channel in 0..<3 {
                XCTAssertEqual(Int(channels[channel]), channel == expectedChannel ? 255 : 0, accuracy: 8)
            }
        }
    }

    func testEpisodeRepairRetainsSeriesPosterAsTheLastLibraryFallback() {
        let poster = URL(string: "https://library.example.test/series.jpg")!
        let item = MediaItem(id: "episode", title: "Episode", kind: .episode, seriesPosterURL: poster)
        XCTAssertEqual(
            PlozziOSDownloadArtwork.references(for: item, policy: .init(area: .downloads)),
            [.remote(poster)]
        )
    }

    func testNewDownloadFindsCachedExternalPosterWithoutBypassingDisabledProviders() async {
        let saved = URL(string: "https://metadata.example.test/saved.jpg")!
        let tmdb = URL(string: "https://metadata.example.test/tmdb.jpg")!
        let tvdb = URL(string: "https://metadata.example.test/tvdb.jpg")!
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie, posterURL: saved)
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
        let cache = MetadataDiskCache(directory: nil)
        let settings = DownloadArtworkProviderSettings()
        let router = ArtworkRouter(
            cache: cache, enrichmentBaseline: .init(order: [.tmdb, .tvdb], priority: .init(rules: [])),
            settingsStore: settings
        )
        for source in [MetadataSource.tmdb, .tvdb] {
            for kind in [ArtworkKind.hero, .thumbnail, .poster] {
                await cache.store(
                    kind == .poster ? (source == .tmdb ? tmdb : tvdb) : nil,
                    for: ArtworkRouter.providerCacheKey(query: MetadataQuery(item), kind: kind, source: source)
                )
            }
        }
        XCTAssertTrue(PlozziOSDownloadsModel.artworkReferences(for: item, policy: .init(area: .downloads)).isEmpty)
        for (value, expected) in [
            (MetadataProviderSettings(orderMode: .custom, enabledOrder: ["tmdb", "tvdb"]), Optional(tmdb)),
            (.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]), Optional(tvdb)),
            (.init(orderMode: .custom, enabledOrder: ["tvdb"], disabledOrder: ["tmdb"]), Optional(tvdb)),
            (.init(orderMode: .custom, disabledOrder: ["tmdb", "tvdb"]), nil)
        ] {
            settings.save(value)
            let result = await PlozziOSDownloadsModel.artworkLookup(for: item, router: router)
            XCTAssertEqual(result, expected)
        }
        XCTAssertEqual(item.posterURL, saved)
    }

    func testNewDownloadCanCaptureStillOnlyEpisodesAndPosterOnlyMovies() {
        let image = URL(string: "https://library.example.test/image.jpg")!
        for kind in [MediaItemKind.episode, .movie] {
            let item = MediaItem(id: "item", title: "Title", kind: kind, posterURL: image)
            let policy = ArtworkPresentationPolicy(area: .downloads)

            XCTAssertEqual(
                PlozziOSDownloadsModel.artworkReferences(for: item, policy: policy),
                [.remote(image)]
            )
            XCTAssertTrue(policy.references(for: item, placement: .detailBackdrop).isEmpty,
                          "Download fallbacks must not change the detail-page backdrop policy.")
        }
    }

    func testNewDownloadKeepsOrderedStillAndPosterFallbacksAfterBackdrops() {
        let backdrop = URL(string: "https://library.example.test/backdrop.jpg")!
        let still = URL(string: "https://library.example.test/still.jpg")!
        let poster = URL(string: "https://library.example.test/poster.jpg")!
        let item = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            posterURL: poster, backdropURL: backdrop,
            artworkSelections: [.init(placement: .episodeThumbnail, references: [.remote(still), .remote(backdrop)])]
        )

        XCTAssertEqual(
            PlozziOSDownloadsModel.artworkReferences(for: item, policy: .init(area: .downloads)),
            [.remote(backdrop), .remote(still), .remote(poster)]
        )
    }

    func testDownloadPreferenceDoesNotInheritTheDetailPageOverride() {
        let selected = URL(string: "https://library.example.test/selected.jpg")!
        let alternate = URL(string: "https://library.example.test/alternate.jpg")!
        let poster = URL(string: "https://library.example.test/poster.jpg")!
        let item = MediaItem(
            id: "movie", title: "Movie", kind: .movie,
            posterURL: poster, heroBackdropURL: selected,
            artworkSelections: [.init(placement: .detailBackdrop, references: [.remote(alternate)])]
        )
        for preference in [ArtworkPreference.recommended, .library, .online] {
            let settings = ArtworkSettings(
                preference: preference,
                overrides: [.details: preference == .online ? .library : .online]
            )
            let references = PlozziOSDownloadsModel.artworkReferences(
                for: item, policy: .init(area: .details, settings: settings)
            )
            XCTAssertEqual(
                references,
                preference == .online
                    ? [.remote(alternate), .remote(selected), .remote(poster)]
                    : [.remote(selected), .remote(alternate), .remote(poster)]
            )
        }
    }
}

private final class DownloadArtworkProviderSettings: MetadataProviderSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings = MetadataProviderSettings.default
    func load() -> MetadataProviderSettings { lock.withLock { settings } }
    func save(_ settings: MetadataProviderSettings) { lock.withLock { self.settings = settings } }
}
#endif
