import CoreModels
import XCTest
@testable import MetadataKit

final class MusicArtworkPolicyTests: XCTestCase {
    func testAlbumCacheRespectsCustomOrderAndDisabledProviders() async throws {
        let cache = MetadataDiskCache(directory: nil)
        let deezer = try XCTUnwrap(URL(string: "https://art.example.test/deezer.jpg"))
        let musicbrainz = try XCTUnwrap(URL(string: "https://art.example.test/musicbrainz.jpg"))
        await cache.store(deezer, for: "music|album|artist|album")
        await cache.store(deezer, for: "music|album|artist|album|provider:deezer")
        await cache.store(musicbrainz, for: "music|album|artist|album|provider:musicbrainz")
        for (settings, expected) in [
            (MetadataProviderSettings(orderMode: .custom, enabledOrder: ["musicbrainz", "deezer"]), musicbrainz),
            (MetadataProviderSettings(orderMode: .custom, enabledOrder: ["deezer", "musicbrainz"]), deezer),
            (MetadataProviderSettings(orderMode: .custom, disabledOrder: ["deezer"]), musicbrainz),
        ] {
            let router = makeRouter(settings: settings, cache: cache)
            let actual = await router.albumCoverURL(artist: "Artist", album: "Album")
            XCTAssertEqual(actual, expected)
        }
        let router = makeRouter(
            settings: .init(orderMode: .custom, disabledOrder: ["deezer", "musicbrainz"]), cache: cache
        )
        let disabled = await router.albumCoverURL(artist: "Artist", album: "Album")
        XCTAssertNil(disabled)
    }

    func testDisabledArtistProviderCannotReadItsPreviouslyCachedImage() async throws {
        let cache = MetadataDiskCache(directory: nil)
        let image = try XCTUnwrap(URL(string: "https://art.example.test/artist.jpg"))
        await cache.store(image, for: "music|artist|artist")
        await cache.store(image, for: "music|artist|artist|provider:deezer")
        let router = makeRouter(
            settings: .init(orderMode: .custom, disabledOrder: ["deezer"]), cache: cache
        )
        let actual = await router.artistImageURL(artist: "Artist")
        XCTAssertNil(actual)
    }

    private func makeRouter(settings: MetadataProviderSettings, cache: MetadataDiskCache) -> ArtworkRouter {
        ArtworkRouter(
            cache: cache, enrichmentBaseline: .init(order: [.deezer, .musicbrainz]),
            settingsStore: FixedSettings(settings: settings)
        )
    }
}

private struct FixedSettings: MetadataProviderSettingsStoring {
    let settings: MetadataProviderSettings
    func load() -> MetadataProviderSettings { settings }
    func save(_ settings: MetadataProviderSettings) { XCTFail("The artwork router must not mutate settings") }
}
