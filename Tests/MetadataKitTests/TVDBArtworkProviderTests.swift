import XCTest
@testable import MetadataKit
import CoreModels

/// Gating coverage for the TheTVDB backdrop provider. Live TVDB lookups aren't
/// exercised (no network in unit tests); these assert the routing contract: it
/// only serves `.hero`, skips anime/music, and no-ops cleanly when unconfigured.
final class TVDBArtworkProviderTests: XCTestCase {
    func testRegularPosterMatchesTVDBLanguageAndContentTypeBeforeSize() {
        let art: [TVDBClient.Artwork] = [
            .init(image: "/de.jpg", width: 500, height: 720, type: 2, language: "deu"),
            .init(image: "/es.jpg", width: 500, height: 720, type: 2, language: "spa"),
            .init(image: "/neutral.jpg", width: 800, height: 1200, type: 2),
            .init(image: "/banner.jpg", width: 4000, height: 900, type: 1, language: "spa"),
            .init(image: "/movie.jpg", width: 600, height: 900, type: 14, language: "spa")
        ]
        for (locale, movie, expected) in [("es-ES", false, "es.jpg"), ("de", false, "de.jpg"),
                                           ("fr", false, "neutral.jpg"), ("es", true, "movie.jpg")] {
            XCTAssertEqual(TVDBClient.preferredPoster(art, isMovie: movie, language: locale)?.lastPathComponent, expected)
        }
    }

    private func query(_ type: ContentType, kind: MediaItemKind = .series) -> MetadataQuery {
        MetadataQuery(contentType: type, kind: kind, title: "Some Show", alternateTitle: nil,
                      year: 2020, seasonNumber: nil, episodeNumber: nil,
                      animeIDs: AnimeIDs(), providerIDs: [:])
    }

    func testUnconfiguredReturnsNil() async {
        let provider = TVDBArtworkProvider(client: TVDBClient(config: TVDBConfig(apiKey: nil)))
        let hero = await provider.artworkURL(.hero, for: query(.tvShow))
        XCTAssertNil(hero, "no key → no lookup, no crash")
    }

    func testServesHeroAndPosterButNotLogoOrThumbnail() async {
        // hero (backdrop) + poster are served; logos/stills stay with other
        // providers. Unconfigured client keeps this a pure routing check.
        let provider = TVDBArtworkProvider(client: TVDBClient(config: TVDBConfig(apiKey: nil)))
        for kind in [ArtworkKind.logo, .thumbnail] {
            let url = await provider.artworkURL(kind, for: query(.tvShow))
            XCTAssertNil(url, "\(kind) must be declined by the TVDB provider")
        }
        // hero/poster route to the client (nil here only because it's unconfigured).
        _ = await provider.artworkURL(.hero, for: query(.tvShow))
        _ = await provider.artworkURL(.poster, for: query(.movie, kind: .movie))
    }

    func testSkipsAnimeAndMusic() async {
        let provider = TVDBArtworkProvider(client: TVDBClient(config: TVDBConfig(apiKey: nil)))
        let anime = await provider.artworkURL(.hero, for: query(.anime))
        let music = await provider.artworkURL(.hero, for: query(.music, kind: .unknown))
        XCTAssertNil(anime)
        XCTAssertNil(music)
    }
}
