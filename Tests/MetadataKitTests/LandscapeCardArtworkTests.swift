import CoreModels
import Foundation
import XCTest
@testable import MetadataKit

final class LandscapeCardArtworkTests: XCTestCase {
    private func image(_ path: String?, _ language: String?, _ votes: Double = 0) -> TMDbMetadataProvider.Image {
        .init(file_path: path, iso_639_1: language, vote_average: votes)
    }

    func testLanguageThenVotesSelectsTitledArtWithoutChangingHeroRanking() {
        let images = [
            image("/clean.jpg", nil, 10), image("/english.jpg", "en", 9),
            image("/french.jpg", "fr", 2), image("/french-best.jpg", "fr", 5),
            image("/tie.jpg", "fr", 5), image("/japanese.jpg", "ja", 10)
        ]
        XCTAssertEqual(
            TMDbMetadataProvider.landscapeCardPath(images, preferredLanguage: "fr-CA"), "/french-best.jpg"
        )
        XCTAssertEqual(TMDbMetadataProvider.landscapeCardPath(images, preferredLanguage: "de"), "/english.jpg")
        XCTAssertEqual(TMDbMetadataProvider.bestImagePath(images, preferNeutral: true), "/clean.jpg")
    }

    func testNeutralInvalidAndUnrelatedLanguageImagesAreNotTitledFallbacks() {
        XCTAssertNil(TMDbMetadataProvider.landscapeCardPath(
            [image(nil, "en"), image("", "en"), image("/neutral.jpg", nil),
             image("/empty-language.jpg", ""), image("/foreign.jpg", "ja")],
            preferredLanguage: "fr"
        ))
        XCTAssertNil(TMDbMetadataProvider.landscapeCardPath(nil, preferredLanguage: "en"))
    }

    func testKnownMovieAndSeriesIDsUseOneImagesRequest() async {
        for kind in [MediaItemKind.movie, .series] {
            let fixture = TMDbTVDBDiscoveryFixture { _, _ in
                .init(json: """
                    {"backdrops":[{"file_path":"/clean.jpg","iso_639_1":null},
                                  {"file_path":"/titled.jpg","iso_639_1":"en"}]}
                    """)
            }
            let provider = TMDbMetadataProvider(
                access: .proxy(baseURL: URL(string: "https://metadata.example.test")!)
            ) { url, headers in
                var request = URLRequest(url: url)
                request.allHTTPHeaderFields = headers
                do {
                    return try await fixture.http.decode(TMDbMetadataProvider.ImagesResponse.self, from: request)
                } catch {
                    XCTFail("Images fixture failed: \(error)")
                    return nil
                }
            }
            let query = MetadataQuery(
                MediaItem(id: "item", title: "Title", kind: kind, providerIDs: ["Tmdb": "42"])
            ).forArtworkLanguage("en")
            let result = await provider.landscapeCardURL(for: query)
            XCTAssertEqual(result?.absoluteString, "https://image.tmdb.org/t/p/w1280/titled.jpg")
            let requests = await fixture.recorded()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url?.path, kind == .movie ? "/3/movie/42/images" : "/3/tv/42/images")
        }
    }
}
