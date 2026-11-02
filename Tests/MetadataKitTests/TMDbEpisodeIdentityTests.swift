import CoreModels
import Foundation
import XCTest
@testable import MetadataKit

private let episodeIdentityJSON = #"{"id":123,"season_number":1,"episode_number":2,"external_ids":{"imdb_id":"tt1234567","tvdb_id":456}}"#
private let parentIdentityJSON = #"{"id":42,"imdb_id":"tt7654321","tvdb_id":789}"#

final class TMDbEpisodeIdentityTests: XCTestCase {
    func testExactEpisodeAndParentIDsDoNotCreateAPlayableServerItem() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, count in
            XCTAssertEqual(request.url?.host, "api.themoviedb.org")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            if count == 1 {
                XCTAssertEqual(request.url?.path, "/3/tv/42/season/1/episode/2")
                XCTAssertEqual(request.url?.query, "append_to_response=external_ids")
                return .init(json: episodeIdentityJSON)
            }
            XCTAssertEqual(count, 2)
            XCTAssertEqual(request.url?.path, "/3/tv/42/external_ids")
            return .init(json: parentIdentityJSON)
        }
        let provider = TMDbMetadataProvider(access: .directToken("fixture"), detailHTTP: fixture.http)
        let value = try await provider.episodeIdentity(seriesID: 42, season: 1, episode: 2)
        let item = try XCTUnwrap(value)
        XCTAssertEqual(item.kind, .episode)
        XCTAssertEqual(item.episodeOrdering, .tmdb)
        XCTAssertEqual(item.providerIDs, [
            "Tmdb": "123", "SeriesTmdb": "42", "Imdb": "tt1234567",
            "SeriesImdb": "tt7654321", "Tvdb": "456", "SeriesTvdb": "789"
        ])
        XCTAssertFalse(item.locallyValidatedPlayableSource)
        XCTAssertNil(item.sourceAccountID)
    }

    func testMismatchedCoordinatesAndParentAreRejected() async throws {
        for mismatch in ["season", "episode", "parent"] {
            let fixture = TMDbTVDBDiscoveryFixture { _, count in
                if count == 1 {
                    var response = episodeIdentityJSON
                    if mismatch == "season" { response = response.replacingOccurrences(of: #""season_number":1"#, with: #""season_number":9"#) }
                    if mismatch == "episode" { response = response.replacingOccurrences(of: #""episode_number":2"#, with: #""episode_number":3"#) }
                    return .init(json: response)
                }
                return .init(json: parentIdentityJSON.replacingOccurrences(of: #""id":42"#, with: #""id":99"#))
            }
            let provider = TMDbMetadataProvider(access: .directToken("fixture"), detailHTTP: fixture.http)
            do {
                _ = try await provider.episodeIdentity(seriesID: 42, season: 1, episode: 2)
                XCTFail("Unrelated \(mismatch) accepted")
            } catch {
                XCTAssertEqual(error as? MetadataDiscoveryHTTPError, .invalidResponse)
            }
        }
    }

    func testSpecialsKeepSeasonZero() async throws {
        let fixture = TMDbTVDBDiscoveryFixture { request, count in
            if count == 1 {
                XCTAssertEqual(request.url?.path, "/3/tv/42/season/0/episode/2")
                return .init(json: episodeIdentityJSON.replacingOccurrences(of: #""season_number":1"#, with: #""season_number":0"#))
            }
            return .init(json: parentIdentityJSON)
        }
        let provider = TMDbMetadataProvider(access: .directToken("fixture"), detailHTTP: fixture.http)
        let item = try await provider.episodeIdentity(seriesID: 42, season: 0, episode: 2)
        XCTAssertEqual(item?.seasonNumber, 0)
    }

    func testUnavailableIsDistinctFromRejectedCredentials() async throws {
        for status in [404, 401, 429, 500] {
            let fixture = TMDbTVDBDiscoveryFixture { _, _ in .init(json: "{}", status: status) }
            let provider = TMDbMetadataProvider(access: .directToken("fixture"), detailHTTP: fixture.http)
            do {
                let item = try await provider.episodeIdentity(seriesID: 42, season: 1, episode: 2)
                XCTAssertEqual(status, 404)
                XCTAssertNil(item)
            } catch {
                XCTAssertNotEqual(status, 404)
                XCTAssertEqual(error as? MetadataDiscoveryHTTPError, .status(status, retryAfter: nil))
            }
        }
        let disabled = TMDbMetadataProvider(access: .disabled)
        let item = try await disabled.episodeIdentity(seriesID: 42, season: 1, episode: 2)
        XCTAssertNil(item)
    }
}
