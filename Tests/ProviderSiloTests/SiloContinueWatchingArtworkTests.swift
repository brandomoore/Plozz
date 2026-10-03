import CoreModels
import Foundation
import XCTest
@testable import ProviderSilo

extension SiloProviderTests {
    private func logoResponses(
        progress: Bool = false, differentSeries: Bool = false, childLogo: Bool = false
    ) -> [String: String] {
        let episodeID = differentSeries ? "episode-tmdb-99-1-2" : "episode-tmdb-42-1-2"
        let parentID = differentSeries ? "series-tmdb-99" : "series-tmdb-42"
        let series = """
        {"content_id":"series-tmdb-42","type":"series","title":"The Show",
         "tmdb_id":"42","imdb_id":"ttShow","logo_url":"https://silo.test/base/show-logo.png",
         "play_content_id":"\(episodeID)"}
        """
        return [
            "/api/v2/progress": progress
                ? """
                  {"items":[{"media_item_id":"\(episodeID)","position_seconds":120,"duration_seconds":1800,
                    "completed":false,"updated_at":"2026-10-02T12:00:00Z"}]}
                  """
                : #"{"items":[]}"#,
            "/api/v2/home/sections": """
            {"sections":[{"id":"next","section_type":"next_up","items":[\(series)]}]}
            """,
            "/api/v2/catalog/items/series-tmdb-42": series,
            "/api/v2/catalog/items/\(episodeID)": """
            {"content_id":"\(episodeID)","type":"episode","title":"Episode 2","series_title":"The Show",
             "series_id":"\(parentID)","tmdb_id":"episode-222","duration_seconds":1800,"position_seconds":25,
             "logo_url":\(childLogo ? "\"https://silo.test/base/curated-episode-logo.png\"" : "null")}
            """
        ]
    }

    func testNextUpRetainsTheParentLogoWhenResolvingThePlayableEpisode() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(logoResponses())
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 10)
        let episode = try XCTUnwrap(items.first)
        XCTAssertEqual(episode.id, "episode-tmdb-42-1-2")
        XCTAssertEqual(episode.providerID(.tmdb), "episode-222")
        XCTAssertEqual(episode.providerID(.seriesTmdb), "42")
        XCTAssertEqual(episode.providerID(.seriesImdb), "ttShow")
        XCTAssertEqual(episode.logoURL?.path, "/base/show-logo.png")
        XCTAssertEqual(provider.imageURL(itemID: episode.id, kind: .logo, maxWidth: nil), episode.logoURL)
        let requests = await http.requests
        XCTAssertEqual(requests.map(\.path), [
            "/api/v2/progress", "/api/v2/home/sections", "/api/v2/catalog/items/episode-tmdb-42-1-2"
        ], "Parent artwork is already in the Home response; no extra request is needed.")
    }

    func testProgressEntryUsesKnownParentArtworkWithoutRefetchingOrLosingResume() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(logoResponses(progress: true))
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 10)
        let episode = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(episode.resumePosition, 120)
        XCTAssertEqual(episode.providerID(.seriesImdb), "ttShow")
        XCTAssertEqual(episode.logoURL?.path, "/base/show-logo.png")
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path.contains("/catalog/items/") }.count, 1)
    }

    func testUnrelatedHomeSeriesCannotSupplyAnotherEpisodesLogo() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(logoResponses(differentSeries: true))
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 10)
        let episode = try XCTUnwrap(items.first)
        XCTAssertEqual(episode.id, "episode-tmdb-99-1-2")
        XCTAssertEqual(episode.providerID(.seriesTmdb), "99")
        XCTAssertNil(episode.providerID(.seriesImdb))
        XCTAssertNil(episode.logoURL)
    }

    func testExistingEpisodeLogoIsNotReplacedByHomeSeriesArtwork() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(logoResponses(childLogo: true))
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 10)
        let episode = try XCTUnwrap(items.first)
        XCTAssertEqual(episode.logoURL?.path, "/base/curated-episode-logo.png")
        XCTAssertEqual(episode.providerID(.seriesImdb), "ttShow")
    }

    func testDifferentProgressAndNextUpEpisodesShareTheKnownSeriesLogo() async throws {
        let raw = try credential().encoded()
        var responses = logoResponses()
        responses["/api/v2/progress"] = """
        {"items":[{"media_item_id":"episode-tmdb-42-1-1","position_seconds":120,"duration_seconds":1800,
          "completed":false,"updated_at":"2026-10-02T12:00:00Z"}]}
        """
        responses["/api/v2/catalog/items/episode-tmdb-42-1-1"] = """
        {"content_id":"episode-tmdb-42-1-1","type":"episode","title":"Episode 1",
         "series_title":"The Show","series_id":"series-tmdb-42","tmdb_id":"episode-111"}
        """
        let http = SiloHTTPStub(responses)
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let items = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.logoURL?.path == "/base/show-logo.png" })
        XCTAssertTrue(items.allSatisfy { $0.providerID(.seriesImdb) == "ttShow" })
        let requests = await http.requests
        XCTAssertEqual(requests.filter { $0.path.contains("/catalog/items/") }.count, 2)
        XCTAssertFalse(requests.contains { $0.path == "/api/v2/catalog/items/series-tmdb-42" })
    }

    func testSeriesResumeKeepsTheSameParentLogoAsContinueWatching() async throws {
        let raw = try credential().encoded()
        let http = SiloHTTPStub(logoResponses())
        let provider = try SiloProvider(context: context(raw), credentials: SiloCredentialStub(raw), http: http)
        let episode = try await provider.resumeEpisode(inSeries: "series-tmdb-42")
        XCTAssertEqual(episode?.logoURL?.path, "/base/show-logo.png")
        XCTAssertEqual(episode?.providerID(.seriesImdb), "ttShow")
    }
}
