import CoreModels
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinRecommendationRequestsTests: XCTestCase {
    func testExactRequestsReuseButScopesUsersLibrariesAndLimitsStaySeparate() async throws {
        let cache = JellyfinRecommendationRequests()
        let fixture = RecommendationCacheFixture()
        let scope = HomeRecommendationScope()
        for _ in 0..<2 { _ = try await read(cache, fixture, scope: scope) }
        for other in [HomeRecommendationScope(), HomeRecommendationScope()] {
            _ = try await read(cache, fixture, scope: other)
        }
        _ = try await read(cache, fixture, scope: scope, user: "other")
        _ = try await read(cache, fixture, scope: scope, library: "other")
        _ = try await read(cache, fixture, scope: scope, limit: 120)
        let original = try await read(cache, fixture, scope: scope)
        XCTAssertEqual(original.first?.Items?.first?.Id, "1-0")
        let count = await fixture.count
        XCTAssertEqual(count, 6)
    }

    func testRefreshAndRetirementFenceCachedGenerations() async throws {
        let cache = JellyfinRecommendationRequests()
        let fixture = RecommendationCacheFixture()
        let scope = HomeRecommendationScope()
        _ = try await read(cache, fixture, scope: scope)
        scope.refresh()
        let fresh = try await read(cache, fixture, scope: scope)
        XCTAssertEqual(fresh.first?.Items?.first?.Id, "2-0")
        let retry = try await cache.load(scope: scope, user: "viewer", library: "movies", limit: 20, refresh: true) {
            try await fixture.fetch()
        }
        XCTAssertEqual(retry.first?.Items?.first?.Id, "3-0")
        scope.invalidate()
        do { _ = try await read(cache, fixture, scope: scope); XCTFail("Retired scope must not read or fetch") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await fixture.count
        XCTAssertEqual(count, 3)
    }

    func testExpiryDoesNotReturnStaleResultsOnFailure() async throws {
        let clock = RecommendationCacheClock()
        let cache = JellyfinRecommendationRequests(now: { clock.read() })
        let fixture = RecommendationCacheFixture()
        let scope = HomeRecommendationScope()
        _ = try await read(cache, fixture, scope: scope)
        clock.advance(59)
        _ = try await read(cache, fixture, scope: scope)
        clock.advance(1)
        do {
            _ = try await cache.load(scope: scope, user: "viewer", library: "movies", limit: 20) {
                throw AppError.serverUnreachable
            }
            XCTFail("Expired data must not hide a failure")
        } catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        let retry = try await read(cache, fixture, scope: scope)
        XCTAssertEqual(retry.first?.Items?.first?.Id, "2-0")
    }

    func testEmptyAndOversizedResultsAreReturnedWithoutRetentionOrTruncation() async throws {
        let cache = JellyfinRecommendationRequests()
        let fixture = RecommendationCacheFixture()
        let scope = HomeRecommendationScope()
        for count in [0, 2_001] {
            for _ in 0..<2 {
                let rows = try await cache.load(scope: scope, user: "viewer", library: "movies", limit: count + 1) {
                    try await fixture.fetch(items: count)
                }
                XCTAssertEqual(rows.first?.Items?.count ?? 0, count)
            }
        }
        let count = await fixture.count
        XCTAssertEqual(count, 4)
    }

    func testEntryAndItemBudgetsEvictWithoutChangingResults() async throws {
        let cache = JellyfinRecommendationRequests()
        let fixture = RecommendationCacheFixture()
        let scope = HomeRecommendationScope()
        for library in 0..<17 { _ = try await read(cache, fixture, scope: scope, library: "\(library)") }
        _ = try await read(cache, fixture, scope: scope, library: "0")
        let count = await fixture.count
        XCTAssertEqual(count, 18)
        for library in ["large-a", "large-b", "large-a"] {
            let rows = try await cache.load(scope: scope, user: "viewer", library: library, limit: 1_001) {
                try await fixture.fetch(items: 1_001)
            }
            XCTAssertEqual(rows.first?.Items?.count, 1_001)
        }
        let finalCount = await fixture.count
        XCTAssertEqual(finalCount, 21)
    }

    private func read(
        _ cache: JellyfinRecommendationRequests, _ fixture: RecommendationCacheFixture,
        scope: HomeRecommendationScope, user: String = "viewer", library: String = "movies", limit: Int = 20
    ) async throws -> [MovieRecommendationDto] {
        try await cache.load(scope: scope, user: user, library: library, limit: limit) {
            try await fixture.fetch()
        }
    }
}

private actor RecommendationCacheFixture {
    private(set) var count = 0

    func fetch(items: Int = 1) throws -> [MovieRecommendationDto] {
        count += 1
        guard items > 0 else { return [] }
        let rows: [[String: Any]] = [[
            "RecommendationType": "SimilarToRecentlyPlayed", "CategoryId": "category",
            "Items": (0..<items).map { ["Id": "\(count)-\($0)", "Type": "Movie"] }
        ]]
        return try JSONDecoder().decode([MovieRecommendationDto].self, from: JSONSerialization.data(withJSONObject: rows))
    }
}

private final class RecommendationCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func read() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ seconds: Int) { lock.withLock { instant += .seconds(seconds) } }
}
