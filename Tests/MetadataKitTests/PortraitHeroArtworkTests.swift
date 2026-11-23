import CoreModels
import Foundation
import XCTest
@testable import MetadataKit

final class PortraitHeroArtworkTests: XCTestCase {
    private typealias Image = TMDbMetadataProvider.Image

    private func image(_ path: String?, language: String? = nil, votes: Double = 0) -> Image {
        Image(file_path: path, iso_639_1: language, vote_average: votes)
    }

    func testNeutralPortraitWinsWithoutChangingNormalPosterOrLandscapeRanking() {
        let posters = [
            image("/titled.jpg", language: "en", votes: 10),
            image("/clean.jpg", votes: 3),
            image("/clean-better.jpg", language: "", votes: 5)
        ]
        let backdrops = [image("/wide.jpg", votes: 10)]
        XCTAssertEqual(
            TMDbMetadataProvider.portraitHeroPath(posters: posters, backdrops: backdrops), "/clean-better.jpg"
        )
        XCTAssertEqual(TMDbMetadataProvider.bestImagePath(posters, preferNeutral: false), "/titled.jpg")
        XCTAssertEqual(TMDbMetadataProvider.bestImagePath(backdrops, preferNeutral: true), "/wide.jpg")
    }

    func testNeutralLandscapeBeatsEveryLanguageSpecificPortrait() {
        let posters = [
            image("/english.jpg", language: "en", votes: 10),
            image("/french.jpg", language: "fr", votes: 10),
            image("", votes: 10), image(nil, votes: 10)
        ]
        let backdrops = [image("/titled-wide.jpg", language: "en", votes: 10), image("/clean-wide.jpg")]
        XCTAssertEqual(
            TMDbMetadataProvider.portraitHeroPath(posters: posters, backdrops: backdrops), "/clean-wide.jpg"
        )
    }

    func testAnyUsableArtworkRemainsAvailableWhenNeutralArtworkIsMissing() {
        let poster = image("/poster.jpg", language: "en")
        let backdrop = image("/backdrop.jpg", language: "ja")
        XCTAssertEqual(
            TMDbMetadataProvider.portraitHeroPath(posters: [poster], backdrops: [backdrop]), "/poster.jpg"
        )
        XCTAssertEqual(
            TMDbMetadataProvider.portraitHeroPath(posters: [image("")], backdrops: [backdrop]), "/backdrop.jpg"
        )
        XCTAssertNil(TMDbMetadataProvider.portraitHeroPath(posters: nil, backdrops: nil))
        XCTAssertNil(TMDbMetadataProvider.portraitHeroPath(posters: [image(nil)], backdrops: [image("")]))
    }

    func testPortraitAndExistingLookupsEachReadExactlyOneImagesPayload() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in
            .init(json: """
                {"posters":[
                  {"file_path":"/clean.jpg","iso_639_1":null},
                  {"file_path":"/titled.jpg","iso_639_1":"en","vote_average":10}
                ],"backdrops":[{"file_path":"/wide.jpg","iso_639_1":null}]}
                """)
        }
        let provider = provider(fixture)
        let query = MetadataQuery(MediaItem(id: "movie", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "42"]))
            .forArtworkLanguage("en")
        let portrait = await provider.portraitHeroURL(for: query)
        var requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(portrait?.absoluteString, "https://image.tmdb.org/t/p/w500/clean.jpg")
        let landscape = await provider.artworkURL(.hero, for: query)
        requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(landscape?.absoluteString, "https://image.tmdb.org/t/p/original/wide.jpg")
        let poster = await provider.artworkURL(.poster, for: query)
        requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(poster?.absoluteString, "https://image.tmdb.org/t/p/w500/titled.jpg")
        XCTAssertEqual(Set(requests.compactMap { $0.url?.path }), ["/3/movie/42/images"])
    }

    func testRegularPostersPreferRequestedLanguageBeforeVotes() async {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in
            .init(json: """
                {"posters":[{"file_path":"/english.jpg","iso_639_1":"en","vote_average":10},
                            {"file_path":"/clean.jpg","iso_639_1":null},
                            {"file_path":"/spanish.jpg","iso_639_1":"es","vote_average":3},
                            {"file_path":"/german.jpg","iso_639_1":"de","vote_average":4}]}
                """)
        }
        let subject = MetadataQuery(MediaItem(id: "show", title: "Show", kind: .series, providerIDs: ["Tmdb": "42"]))
        let provider = provider(fixture)
        for (locale, expected) in [("es-ES", "spanish.jpg"), ("de-AT", "german.jpg"), ("ja-JP", "clean.jpg")] {
            let poster = await provider.artworkURL(.poster, for: subject.forArtworkLanguage(locale))
            XCTAssertEqual(poster?.lastPathComponent, expected)
        }
    }

    func testPortraitFallbackTiersDoNotAddRequests() async {
        for (json, expected) in [
            (#"{"posters":[{"file_path":"/titled.jpg","iso_639_1":"en"}],"backdrops":[{"file_path":"/wide.jpg"}]}"#,
             "https://image.tmdb.org/t/p/original/wide.jpg"),
            (#"{"posters":[{"file_path":"/titled.jpg","iso_639_1":"en"}],"backdrops":[]}"#,
             "https://image.tmdb.org/t/p/w500/titled.jpg"),
            (#"{"posters":[],"backdrops":[]}"#, nil)
        ] {
            let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: json) }
            let query = MetadataQuery(MediaItem(id: "show", title: "Show", kind: .series, providerIDs: ["Tmdb": "42"]))
            let result = await provider(fixture).portraitHeroURL(for: query)
            let requests = await fixture.recorded()
            XCTAssertEqual(result?.absoluteString, expected)
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url?.path, "/3/tv/42/images")
        }
    }

    func testTVDBUsesTheSamePortraitLandscapeFallbackOrder() {
        func art(_ name: String, width: Int, height: Int, language: String? = nil) -> TVDBClient.Artwork {
            .init(image: "/\(name).jpg", width: width, height: height, type: nil, language: language)
        }
        let portrait = art("clean", width: 500, height: 750)
        let titled = art("titled", width: 2_000, height: 3_000, language: "eng")
        let backdrop = art("wide", width: 1_920, height: 1_080)
        let invalid = TVDBClient.Artwork(image: "", width: 4_000, height: 2_000, type: nil)
        XCTAssertEqual(TVDBClient.bestPortraitHero([titled, backdrop, portrait])?.lastPathComponent, "clean.jpg")
        XCTAssertEqual(TVDBClient.bestPortraitHero([titled, backdrop, invalid])?.lastPathComponent, "wide.jpg")
        XCTAssertEqual(TVDBClient.bestPortraitHero([titled])?.lastPathComponent, "titled.jpg")
        XCTAssertEqual(TVDBClient.bestBackdrop([titled, backdrop, portrait])?.lastPathComponent, "wide.jpg")
        XCTAssertNil(TVDBClient.bestPortraitHero([invalid]))
    }

    private func provider(_ fixture: TMDbTVDBDiscoveryFixture) -> TMDbMetadataProvider {
        TMDbMetadataProvider(access: .proxy(baseURL: URL(string: "https://metadata.example.test")!)) { url, headers in
            var request = URLRequest(url: url)
            request.allHTTPHeaderFields = headers
            do {
                return try await fixture.http.decode(TMDbMetadataProvider.ImagesResponse.self, from: request)
            } catch {
                XCTFail("Images fixture failed: \(error)")
                return nil
            }
        }
    }
}
