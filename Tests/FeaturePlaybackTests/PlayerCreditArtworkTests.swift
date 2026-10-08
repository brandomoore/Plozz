#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import CoreUI
import XCTest
@testable import FeaturePlayback
@testable import MetadataKit

@MainActor
final class PlayerCreditArtworkTests: XCTestCase {
    func testExternalOnlyCreditPosterHonorsCachedProviderOrderAndDisablement() async {
        let saved = URL(string: "https://metadata.example.test/saved.jpg")!
        let tmdb = URL(string: "https://metadata.example.test/tmdb.jpg")!
        let tvdb = URL(string: "https://metadata.example.test/tvdb.jpg")!
        var item = MediaItem(id: "credit", title: "Credit", kind: .movie, posterURL: saved)
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
        let cache = MetadataDiskCache(directory: nil)
        let settings = CreditArtworkProviderSettings()
        let router = ArtworkRouter(
            cache: cache, enrichmentBaseline: .init(order: [.tmdb, .tvdb], priority: .init(rules: [])),
            settingsStore: settings
        )
        for source in [MetadataSource.tmdb, .tvdb] {
            await cache.store(
                source == .tmdb ? tmdb : tvdb,
                for: ArtworkRouter.providerCacheKey(query: MetadataQuery(item), kind: .poster, source: source)
            )
        }
        for (value, expected) in [
            (MetadataProviderSettings(orderMode: .custom, enabledOrder: ["tmdb", "tvdb"]), Optional(tmdb)),
            (.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]), Optional(tvdb)),
            (.init(orderMode: .custom, enabledOrder: ["tvdb"], disabledOrder: ["tmdb"]), Optional(tvdb)),
            (.init(orderMode: .custom, disabledOrder: ["tmdb", "tvdb"]), nil)
        ] {
            settings.save(value)
            let result = await CastPanelView.creditArtworkLookup(for: item, router: router)
            XCTAssertEqual(result, expected)
        }
        XCTAssertEqual(item.posterURL, saved)
    }

    func testExternalOnlyCreditKeepsAnOnlineLookupAndUsesPlaybackScope() {
        var item = MediaItem(
            id: "credit", title: "Credit", kind: .movie,
            posterURL: URL(string: "https://metadata.example.test/poster.jpg")
        )
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
        let source = CastPanelView.creditArtworkSource(
            for: item,
            policy: .init(area: .details, settings: .init(overrides: [.playback: .online, .details: .library]))
        )
        XCTAssertTrue(source.references.isEmpty)
        XCTAssertNotNil(source.fallbackURL)
        XCTAssertEqual(source.policy.area, .playback)
        XCTAssertTrue(source.policy.prefersOnlineArtwork)
        XCTAssertEqual(source.itemIdentity, item.stablePresentationID)
    }
}

private final class CreditArtworkProviderSettings: MetadataProviderSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings = MetadataProviderSettings.default
    func load() -> MetadataProviderSettings { lock.withLock { settings } }
    func save(_ settings: MetadataProviderSettings) { lock.withLock { self.settings = settings } }
}
#endif
