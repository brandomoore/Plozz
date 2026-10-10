import XCTest
@testable import CoreModels

final class UnwatchedEpisodeCountTests: XCTestCase {
    private func series(_ count: Int?, account: String = "a") -> MediaItem {
        MediaItem(
            id: "show", title: "Show", kind: .series, unwatchedEpisodeCount: count,
            sourceAccountID: account)
    }

    func testCountSurvivesCacheAndInventoryRoundTrips() throws {
        let item = series(8)
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: data).unwatchedEpisodeCount, 8)
        let record = LibraryQueryRecord(item, includeFormats: false)
        XCTAssertEqual(record.identityItem.unwatchedEpisodeCount, 8)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "unwatchedEpisodeCount")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(MediaItem.self, from: legacyData).unwatchedEpisodeCount)
    }

    func testSourceCountSurvivesLegacyAndCurrentCache() throws {
        let source = MediaSourceRef(accountID: "a", itemID: "show", kind: .series, unwatchedEpisodeCount: 8)
        let data = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(MediaSourceRef.self, from: data).unwatchedEpisodeCount, 8)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "unwatchedEpisodeCount")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(MediaSourceRef.self, from: legacyData).unwatchedEpisodeCount)
    }

    func testSourceAuthorityNeverAddsDuplicateServersOrBorrowsUnknownCount() {
        let older = MediaSourceRef(
            accountID: "a", itemID: "show", kind: .series, unwatchedEpisodeCount: 8,
            lastPlayedAt: Date(timeIntervalSince1970: 10))
        var newer = MediaSourceRef(
            accountID: "b", itemID: "other-show", kind: .series, unwatchedEpisodeCount: 3,
            lastPlayedAt: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(MediaItemMerger.unifiedWatchState(from: [older, newer]).unwatchedEpisodeCount, 3)
        newer.unwatchedEpisodeCount = nil
        XCTAssertNil(MediaItemMerger.unifiedWatchState(from: [older, newer]).unwatchedEpisodeCount)
        var first = series(8)
        first.providerIDs = ["tvdb": "1"]
        var second = series(8, account: "b")
        second.providerIDs = first.providerIDs
        let merged = MediaItemMerger.merge([first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.sources.map(\.unwatchedEpisodeCount), [8, 8])
        XCTAssertEqual(merged.first?.unwatchedEpisodeCount, 8)
    }

    func testMarkContainerWatchedClearsRemainingAndUnwatchedInvalidatesUnknownTotal() {
        var item = series(8)
        item.sources = [MediaSourceRef(accountID: "a", itemID: "show", kind: .series, unwatchedEpisodeCount: 8)]
        let watched = MediaItemMutation(itemIDs: ["show"], scopedItemIDs: ["a:show"], played: true).applied(to: item)
        XCTAssertEqual(watched.unwatchedEpisodeCount, 0)
        XCTAssertEqual(watched.sources.first?.unwatchedEpisodeCount, 0)
        let unwatched = MediaItemMutation(itemIDs: ["show"], scopedItemIDs: ["a:show"], played: false).applied(to: watched)
        XCTAssertNil(unwatched.unwatchedEpisodeCount)
        XCTAssertNil(unwatched.sources.first?.unwatchedEpisodeCount)
    }

    func testChildCompletionInvalidatesOnlyItsParentAndDoesNotDoubleSubtract() {
        let episode = MediaItem(id: "episode", title: "Episode", kind: .episode, seriesID: "show", sourceAccountID: "a")
        let mutation = MediaItemMutation(itemIDs: ["episode"], scopedItemIDs: ["a:episode"], played: true, item: episode)
        let updated = mutation.applied(to: series(8))
        XCTAssertNil(updated.unwatchedEpisodeCount)
        XCTAssertEqual(mutation.applied(to: updated), updated)
        XCTAssertEqual(mutation.applied(to: series(8, account: "b")).unwatchedEpisodeCount, 8)
        var unrelated = series(12)
        unrelated.id = "another-show"
        XCTAssertEqual(mutation.applied(to: unrelated).unwatchedEpisodeCount, 12)
    }

    func testProgressAndFavoriteChangesDoNotInvalidateCounts() {
        for mutation in [
            MediaItemMutation(itemIDs: ["episode"], favorite: true),
            MediaItemMutation(itemIDs: ["episode"], resumePosition: 30, playedPercentage: 0.2)
        ] {
            XCTAssertEqual(mutation.applied(to: series(8)).unwatchedEpisodeCount, 8)
        }
    }
}
