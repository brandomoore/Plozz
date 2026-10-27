import CoreModels
import Foundation
import XCTest
@testable import MetadataKit

final class TMDbTrailerTests: XCTestCase {
    func testExactMovieAndSeriesUseDocumentedMetadataEndpointOnly() async throws {
        for kind in [MediaItemKind.movie, .series] {
            let fixture = TMDbTVDBDiscoveryFixture { request, count in
                XCTAssertEqual(count, 1)
                XCTAssertEqual(request.url?.host, "api.themoviedb.org")
                XCTAssertEqual(request.url?.path, "/3/\(kind == .series ? "tv" : "movie")/42/videos")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
                return .init(json: #"{"results":[{"key":"dQw4w9WgXcQ","site":"YouTube","type":"Trailer","official":true}]}"#)
            }
            let provider = TMDbMetadataProvider(access: .directToken("fixture-key"), detailHTTP: fixture.http)
            let item = MediaItem(id: "server", title: "Title", kind: kind, providerIDs: ["Tmdb": "42"])
            let ids = try await provider.trailerVideoIDs(for: MetadataQuery(item))
            XCTAssertEqual(ids, ["dQw4w9WgXcQ"])
            let requests = await fixture.recorded()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testOfficialTrailerPriorityDeduplicationAndStrictLinkValidation() throws {
        let response = try JSONDecoder().decode(TMDbMetadataProvider.TrailerVideos.self, from: Data(#"""
        {"results":[
          {"key":"aqz-KE-bpKQ","site":"YouTube","type":"Teaser","official":true},
          {"key":"M7lc1UVf-VE","site":"YouTube","type":"Trailer","official":false},
          {"key":"dQw4w9WgXcQ","site":"YouTube","type":"Trailer","official":true},
          {"key":"dQw4w9WgXcQ","site":"YouTube","type":"Trailer","official":true},
          {"key":"invalid","site":"YouTube","type":"Trailer","official":true},
          {"key":"https://youtube.com/watch?v=aqz-KE-bpKQ","site":"YouTube","type":"Trailer"},
          {"key":"dQw4w9WgXcQ","site":"Vimeo","type":"Trailer"},
          {"key":"aqz-KE-bpKQ","site":"YouTube","type":"Clip"}
        ]}
        """#.utf8))
        XCTAssertEqual(TMDbMetadataProvider.trailerVideoIDs(from: response, limit: 6),
                       ["dQw4w9WgXcQ", "M7lc1UVf-VE", "aqz-KE-bpKQ"])
        XCTAssertEqual(TMDbMetadataProvider.trailerVideoIDs(from: response, limit: 1), ["dQw4w9WgXcQ"])
        XCTAssertTrue(TMDbMetadataProvider.trailerVideoIDs(from: response, limit: 0).isEmpty)
    }

    func testNoLookupForDisabledServiceUnsupportedKindOrInvalidKnownID() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in
            XCTFail("No request should be sent")
            return .init(json: #"{"results":[]}"#)
        }
        let disabled = TMDbMetadataProvider(access: .disabled, detailHTTP: fixture.http)
        let enabled = TMDbMetadataProvider(access: .directToken("fixture-key"), detailHTTP: fixture.http)
        let movie = MediaItem(id: "m", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "-1"])
        let episode = MediaItem(id: "e", title: "Episode", kind: .episode)
        let disabledIDs = try await disabled.trailerVideoIDs(for: MetadataQuery(movie))
        let malformedIDs = try await enabled.trailerVideoIDs(for: MetadataQuery(movie))
        let episodeIDs = try await enabled.trailerVideoIDs(for: MetadataQuery(episode))
        XCTAssertTrue(disabledIDs.isEmpty)
        XCTAssertTrue(malformedIDs.isEmpty)
        XCTAssertTrue(episodeIDs.isEmpty)
    }

    func testUnauthorizedAndCancellationRemainFailures() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: "{}", status: 401) }
        let provider = TMDbMetadataProvider(access: .directToken("fixture-key"), detailHTTP: fixture.http)
        let query = MetadataQuery(MediaItem(id: "m", title: "Movie", kind: .movie, providerIDs: ["Tmdb": "42"]))
        do {
            _ = try await provider.trailerVideoIDs(for: query)
            XCTFail("A rejected credential is not an empty result")
        } catch {
            XCTAssertEqual(error as? MetadataDiscoveryHTTPError, .status(401, retryAfter: nil))
        }
        let cancelled = Task { () throws -> [String] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.trailerVideoIDs(for: query)
        }
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled lookup must not succeed")
        } catch is CancellationError {
        }
    }
}
