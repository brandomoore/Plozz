#if canImport(SwiftUI) && canImport(UIKit)
import CoreModels
import CoreUI
import XCTest
@testable import FeaturePlayback
@testable import MetadataKit

@MainActor
final class PlayerInfoArtworkTests: XCTestCase {
    func testExternalOnlyPosterLookupHonorsCurrentProviderOrderAndDisablement() async {
        let saved = URL(string: "https://metadata.example.test/saved.jpg")!
        let tmdb = URL(string: "https://metadata.example.test/tmdb.jpg")!
        let tvdb = URL(string: "https://metadata.example.test/tvdb.jpg")!
        var item = MediaItem(id: "movie", title: "Movie", kind: .movie, posterURL: saved)
        item.metadataProvenance[.posterURL] = MetadataAttribution(source: .tmdb)
        let cache = MetadataDiskCache(directory: nil)
        let settings = PlayerArtworkProviderSettings()
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
        XCTAssertTrue(InfoPanelView.artworkReferences(for: item, policy: .init(area: .playback)).isEmpty)
        for (value, expected) in [
            (MetadataProviderSettings(orderMode: .custom, enabledOrder: ["tmdb", "tvdb"]), Optional(tmdb)),
            (.init(orderMode: .custom, enabledOrder: ["tvdb", "tmdb"]), Optional(tvdb)),
            (.init(orderMode: .custom, enabledOrder: ["tvdb"], disabledOrder: ["tmdb"]), Optional(tvdb)),
            (.init(orderMode: .custom, disabledOrder: ["tmdb", "tvdb"]), nil)
        ] {
            settings.save(value)
            let result = await InfoPanelView.artworkLookup(for: item, router: router)
            XCTAssertEqual(result, expected)
        }
        XCTAssertEqual(item.posterURL, saved)
    }

    func testStillOnlyEpisodeAndPosterOnlyMovieRemainUsable() {
        let image = URL(string: "https://library.example.test/image.jpg")!
        for kind in [MediaItemKind.episode, .movie] {
            let item = MediaItem(id: "item", title: "Title", kind: kind, posterURL: image)
            let policy = ArtworkPresentationPolicy(area: .playback)

            XCTAssertEqual(InfoPanelView.artworkReferences(for: item, policy: policy), [.remote(image)])
            XCTAssertTrue(policy.references(for: item, placement: .detailBackdrop).isEmpty,
                          "The consumer fallback must not broaden detail-backdrop selection.")
        }
    }

    func testBackdropsAreFollowedByExplicitStillAndPosterWithoutDuplicates() {
        let backdrop = URL(string: "https://library.example.test/backdrop.jpg")!
        let still = URL(string: "https://library.example.test/still.jpg")!
        let poster = URL(string: "https://library.example.test/poster.jpg")!
        let item = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            posterURL: poster, backdropURL: backdrop,
            artworkSelections: [.init(placement: .episodeThumbnail, references: [.remote(still), .remote(backdrop)])]
        )

        XCTAssertEqual(
            InfoPanelView.artworkReferences(for: item, policy: .init(area: .playback)),
            [.remote(backdrop), .remote(still), .remote(poster)]
        )
    }

    func testPlaybackChoiceControlsReferenceOrderIndependentlyOfEpisodeBrowser() {
        let selected = URL(string: "https://library.example.test/selected.jpg")!
        let alternate = URL(string: "https://library.example.test/alternate.jpg")!
        let still = URL(string: "https://library.example.test/still.jpg")!
        let item = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            posterURL: still, heroBackdropURL: selected,
            artworkSelections: [.init(placement: .detailBackdrop, references: [.remote(alternate)])]
        )
        for preference in [ArtworkPreference.recommended, .library, .online] {
            let settings = ArtworkSettings(
                preference: preference,
                overrides: [.episodes: preference == .online ? .library : .online]
            )
            let references = InfoPanelView.artworkReferences(
                for: item, policy: .init(area: .episodes, settings: settings)
            )
            XCTAssertEqual(
                references,
                preference == .online
                    ? [.remote(alternate), .remote(selected), .remote(still)]
                    : [.remote(selected), .remote(alternate), .remote(still)]
            )
        }
    }
}

private final class PlayerArtworkProviderSettings: MetadataProviderSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings = MetadataProviderSettings.default
    func load() -> MetadataProviderSettings { lock.withLock { settings } }
    func save(_ settings: MetadataProviderSettings) { lock.withLock { self.settings = settings } }
}
#endif
