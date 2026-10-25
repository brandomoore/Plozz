import CoreModels
import CoreSecureStore
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

private let ratingResponse = #"{"items":[{"id":"rating-a","tmdb_id":550,"media_type":"movie","label":"Overall","score":85}],"total":1,"average":85}"#

@MainActor
final class PublicMetaDBRatingsTests: XCTestCase {
    private let movie = MediaItem(id: "movie", title: "Test", kind: .movie, providerIDs: ["Tmdb": "550"])

    private func withService(
        response: String = ratingResponse,
        _ body: (PublicMetaDBService, RecordingHTTPClient, UserDefaults) async throws -> Void
    ) async throws {
        let name = "PublicMetaDBRatingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: #"{"items":[],"total":0,"page":1,"perPage":1,"totalPages":0}"#)
        http.stub(pathSuffix: "/ratings", json: response)
        let service = PublicMetaDBService(
            credentials: RatingsCredentials(), http: http, defaults: defaults,
            watchlistReceiptStore: try DurableLocalStateStore(secureStore: InMemorySecureStore())
        )
        let key = "pm-" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(60)
        await service.connect(key: key)
        try await body(service, http, defaults)
    }

    func testConnectingDoesNotOptInToRatingLookups() async throws {
        try await withService { service, http, _ in
            XCTAssertFalse(service.communityRatingsEnabled)
            XCTAssertNil(service.cachedCommunityRatings(for: movie))
            let result = try await service.communityRatings(for: movie)
            XCTAssertTrue(result.isEmpty)
            XCTAssertEqual(http.sent.count, 1)
        }
    }

    func testServerCuratedRatingsDoNotTriggerOrReuseCommunityLookups() async throws {
        try await withService { service, http, _ in
            service.setCommunityRatingsEnabled(true)
            _ = try await service.communityRatings(for: movie)
            var curated = movie
            curated.usesProviderRatings = true
            let result = try await service.communityRatings(for: curated)
            XCTAssertTrue(result.isEmpty)
            XCTAssertNil(service.cachedCommunityRatings(for: curated))
            XCTAssertEqual(http.sent.count, 2)
        }
    }

    func testOverallAverageRetainsSourceScaleAndCountAlongsideOtherRatingKinds() async throws {
        try await withService { service, http, _ in
            service.setCommunityRatingsEnabled(true)
            XCTAssertNil(service.cachedCommunityRatings(for: movie))
            let result = try await service.communityRatings(for: movie)
            let rating = try XCTUnwrap(result.first)
            XCTAssertEqual(rating.id, "publicmetadb.overall")
            XCTAssertEqual(rating.displayName, "PublicMetaDB")
            XCTAssertEqual(rating.value, 85)
            XCTAssertEqual(rating.scale, .outOfHundred)
            XCTAssertEqual(rating.displayValue, "85/100")
            XCTAssertEqual(rating.ratingCount, 1)
            XCTAssertEqual(http.sent.last?.queryItems.first(where: { $0.name == "label" })?.value, "Overall")
            let cached = try await service.communityRatings(for: movie)
            XCTAssertEqual(cached, result)
            XCTAssertEqual(http.sent.count, 2)
        }
    }

    func testDisablingRatingsFencesAlreadyCapturedClientsAndClearsCache() async throws {
        try await withService { service, http, _ in
            service.setCommunityRatingsEnabled(true)
            _ = try await service.communityRatings(for: movie)
            let (client, _) = try service.communityRatingsClient()
            let count = http.sent.count
            service.setCommunityRatingsEnabled(false)
            service.setCommunityRatingsEnabled(true)
            XCTAssertNil(service.cachedCommunityRatings(for: movie))
            do {
                _ = try await client.ratings(for: .init(tmdbID: 550, mediaType: .movie))
                XCTFail("Old read admitted after consent changed")
            } catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .connectionChanged) }
            XCTAssertEqual(http.sent.count, count)
        }
    }

    func testPreferenceAndCacheAreProfileScoped() async throws {
        try await withService { service, _, _ in
            service.setCommunityRatingsEnabled(true)
            _ = try await service.communityRatings(for: movie)
            service.selectProfile(namespace: "other")
            XCTAssertFalse(service.communityRatingsEnabled)
            XCTAssertNil(service.cachedCommunityRatings(for: movie))
            service.selectProfile(namespace: nil)
            XCTAssertTrue(service.communityRatingsEnabled)
            XCTAssertNil(service.cachedCommunityRatings(for: movie))
            await service.refreshStatus()
            XCTAssertNil(service.cachedCommunityRatings(for: movie))
        }
    }

    func testInvalidAggregatesAreNotDisplayedOrCached() async throws {
        for response in [
            ratingResponse.replacingOccurrences(of: #""average":85"#, with: #""average":101"#),
            ratingResponse.replacingOccurrences(of: #""average":85"#, with: #""average":null"#),
            ratingResponse.replacingOccurrences(of: #""total":1"#, with: #""total":2"#),
            ratingResponse.replacingOccurrences(of: "550", with: "999"),
            ratingResponse.replacingOccurrences(of: "Overall", with: "Acting"),
        ] {
            try await withService(response: response) { service, _, _ in
                service.setCommunityRatingsEnabled(true)
                do { _ = try await service.communityRatings(for: movie); XCTFail("Invalid aggregate accepted") }
                catch { XCTAssertEqual(error as? PublicMetaDB.Failure, .incompleteResponse) }
                XCTAssertNil(service.cachedCommunityRatings(for: movie))
            }
        }
    }

    func testAuthoritativeEmptyIsCachedButMissingIdentityNeverTriggersSearch() async throws {
        try await withService(response: #"{"items":[],"total":0,"average":null}"#) { service, http, _ in
            service.setCommunityRatingsEnabled(true)
            let result = try await service.communityRatings(for: movie)
            XCTAssertTrue(result.isEmpty)
            XCTAssertEqual(service.cachedCommunityRatings(for: movie), [])
            let count = http.sent.count
            let unknown = try await service.communityRatings(for: .init(id: "unknown", title: "Test", kind: .movie))
            XCTAssertTrue(unknown.isEmpty)
            XCTAssertEqual(http.sent.count, count)
        }
    }

    func testExpiredCacheIsNotReportedAsCurrent() async throws {
        try await withService { service, _, _ in
            service.setCommunityRatingsEnabled(true)
            let content = try PublicMetaDB.Content(tmdbID: 550, mediaType: .movie)
            service.communityRatingsCache[content] = .init(expires: .distantPast, ratings: [])
            XCTAssertNil(service.cachedCommunityRatings(for: movie))
        }
    }

    func testOldMutationCannotInvalidateNewProfileRatingCache() async throws {
        try await withService { service, http, _ in
            let original = try XCTUnwrap(service.connectionID)
            service.selectProfile(namespace: "new-profile")
            let key = "pm-" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(60)
            await service.connect(key: key)
            service.setCommunityRatingsEnabled(true)
            _ = try await service.communityRatings(for: movie)
            let cached = service.cachedCommunityRatings(for: movie)
            XCTAssertNotNil(cached)
            let count = http.sent.count
            service.invalidateCommunityRatings(expectedConnectionID: original)
            XCTAssertEqual(service.cachedCommunityRatings(for: movie), cached)
            XCTAssertEqual(http.sent.count, count)
        }
    }

    func testEpisodeRequiresSeriesIdentityConfirmedOrderAndOneEpisode() throws {
        var episode = MediaItem(
            id: "episode", title: "Episode", kind: .episode, seasonNumber: 0, episodeNumber: 1,
            providerIDs: ["SeriesTmdb": "1396", "Tmdb": "999"]
        )
        XCTAssertNil(PublicMetaDBService.ratingContent(episode))
        episode.episodeOrdering = .tmdb
        let expected = try PublicMetaDB.Content(tmdbID: 1396, mediaType: .tv, season: 0, episode: 1)
        XCTAssertEqual(PublicMetaDBService.ratingContent(episode), expected)
        episode.episodeNumberEnd = 2
        XCTAssertNil(PublicMetaDBService.ratingContent(episode))
        episode.episodeNumberEnd = nil
        episode.providerIDs = ["Tmdb": "999"]
        XCTAssertNil(PublicMetaDBService.ratingContent(episode))
    }

    func testConflictingTMDBAliasesNeverChooseAnArbitraryTitle() throws {
        var item = movie
        item.providerIDs = ["Tmdb": "550", "TMDB": "999"]
        XCTAssertNil(PublicMetaDBService.ratingContent(item))
        let now = Date()
        let sample = try TrackerPlaybackSample(
            sessionID: UUID(), startedAt: now, capturedAt: now, item: item, position: 10, duration: 100, isFinal: false
        )
        XCTAssertThrowsError(try PublicMetaDBPlaybackReporter.content(sample))
        item.providerIDs = ["Tmdb": "550", "TheMovieDb": "invalid"]
        XCTAssertNil(PublicMetaDBService.ratingContent(item))
        item.providerIDs = ["Tmdb": "550", "TheMovieDb": "0550"]
        XCTAssertEqual(PublicMetaDBService.ratingContent(item)?.tmdbID, 550)
    }
}

private final class RatingsCredentials: PublicMetaDBCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: PublicMetaDBCredentials] = [:]
    func load(namespace: String?) -> PublicMetaDBCredentials? { lock.withLock { values[namespace ?? "default"] } }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws {
        lock.withLock { values[namespace ?? "default"] = credentials }
    }
    func clear(namespace: String?) throws { _ = lock.withLock { values.removeValue(forKey: namespace ?? "default") } }
}
