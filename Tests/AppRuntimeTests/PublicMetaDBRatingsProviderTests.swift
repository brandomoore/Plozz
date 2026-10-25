import AppRuntime
import CoreModels
import CoreSecureStore
import Foundation
import PublicMetaDBService
import RatingsService
import XCTest
@testable import TestSupportNetworking

@MainActor
final class PublicMetaDBRatingsProviderTests: XCTestCase {
    func testDisconnectedOptionalSourcePreservesBaseRatingsAndCacheOnlySemantics() async throws {
        let name = "PublicMetaDBRatingsProviderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = PublicMetaDBService(
            credentials: NoRatingsCredentials(), defaults: defaults,
            watchlistReceiptStore: try DurableLocalStateStore(secureStore: InMemorySecureStore())
        )
        let expected = [ExternalRating(source: .imdb, value: 8.5, scale: .outOfTen)]
        let item = MediaItem(id: "movie", title: "Test", kind: .movie, providerIDs: ["Tmdb": "550"])
        let provider = PublicMetaDBRatingsProvider(base: CachedRatingFixture(ratings: expected), service: service)
        let fresh = await provider.ratings(for: item)
        let cached = await provider.cachedRatings(for: item)
        XCTAssertEqual(fresh, expected)
        XCTAssertEqual(cached, expected)
        let uncached = PublicMetaDBRatingsProvider(base: DisabledRatingsProvider(), service: service)
        let missing = await uncached.cachedRatings(for: item)
        XCTAssertNil(missing)
    }

    private func withConnectedService(
        ratingStatus: Int = 200,
        _ body: (PublicMetaDBService, RecordingHTTPClient, MediaItem) async throws -> Void
    ) async throws {
        let name = "PublicMetaDBRatingsProviderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/lists", json: #"{"items":[],"total":0,"page":1,"perPage":1,"totalPages":0}"#)
        http.stub(
            pathSuffix: "/ratings",
            json: #"{"items":[{"id":"rating-a","tmdb_id":550,"media_type":"movie","label":"Overall","score":85}],"total":1,"average":85}"#,
            status: ratingStatus
        )
        let service = PublicMetaDBService(
            credentials: RuntimeRatingsCredentials(), http: http, defaults: defaults,
            watchlistReceiptStore: try DurableLocalStateStore(secureStore: InMemorySecureStore())
        )
        let key = "pm-" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(60)
        await service.connect(key: key)
        service.setCommunityRatingsEnabled(true)
        XCTAssertEqual(service.phase, .connected)
        let item = MediaItem(id: "movie", title: "Test", kind: .movie, providerIDs: ["Tmdb": "550"])
        try await body(service, http, item)
    }

    func testConnectedSourceAddsAttributedRatingWithoutReplacingOtherSources() async throws {
        try await withConnectedService { service, http, item in
            let expected = [ExternalRating(source: .imdb, value: 8.5, scale: .outOfTen)]
            let provider = PublicMetaDBRatingsProvider(base: CachedRatingFixture(ratings: expected), service: service)
            let cold = await provider.cachedRatings(for: item)
            XCTAssertEqual(cold, expected)
            XCTAssertEqual(http.sentPaths.count, 1)
            let result = await provider.ratings(for: item)
            XCTAssertEqual(result.first(where: { $0.source == .imdb }), expected.first)
            XCTAssertEqual(result.first(where: { $0.id == "publicmetadb.overall" })?.value, 85)
            XCTAssertEqual(result.count, 2)
            let warm = await provider.cachedRatings(for: item)
            XCTAssertEqual(warm, result)
            XCTAssertEqual(http.sentPaths.count, 2)
            service.setCommunityRatingsEnabled(false)
            let disabled = await provider.cachedRatings(for: item)
            XCTAssertEqual(disabled, expected)
            XCTAssertEqual(http.sentPaths.count, 2)
        }
    }

    func testRejectedOptionalLookupKeepsExistingRatingsWithoutRetrying() async throws {
        for status in [401, 403, 429, 503] {
            try await withConnectedService(ratingStatus: status) { service, http, item in
                let expected = [ExternalRating(source: .tmdb, value: 7.5, scale: .outOfTen)]
                let provider = PublicMetaDBRatingsProvider(base: CachedRatingFixture(ratings: expected), service: service)
                let result = await provider.ratings(for: item)
                XCTAssertEqual(result, expected)
                XCTAssertNil(service.cachedCommunityRatings(for: item))
                XCTAssertEqual(http.sentPaths.count, 2)
            }
        }
    }
}

private struct CachedRatingFixture: CachedExternalRatingsProviding {
    let ratings: [ExternalRating]
    func ratings(for item: MediaItem) async -> [ExternalRating] { ratings }
    func cachedRatings(for item: MediaItem) async -> [ExternalRating]? { ratings }
}

private struct NoRatingsCredentials: PublicMetaDBCredentialStoring {
    func load(namespace: String?) -> PublicMetaDBCredentials? { nil }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws { throw PublicMetaDB.Failure.invalidInput }
    func clear(namespace: String?) throws {}
}

private final class RuntimeRatingsCredentials: PublicMetaDBCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PublicMetaDBCredentials?
    func load(namespace: String?) -> PublicMetaDBCredentials? { lock.withLock { value } }
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws {
        lock.withLock { value = credentials }
    }
    func clear(namespace: String?) throws { lock.withLock { value = nil } }
}
