import CoreModels
import Foundation
import XCTest

final class FamilyGuidanceTests: XCTestCase {
    func testMediaItemGuidanceRoundTripsAndOldSnapshotsRemainReadable() throws {
        let summary = FamilyGuidanceSummary(recommendedAge: 14, qualityRating: 0, overview: "Fixture")
        let item = MediaItem(id: "film", title: "Fixture", kind: .movie, officialRating: "PG-13",
                             familyGuidance: summary)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: data)
        XCTAssertEqual(decoded.familyGuidance, summary)
        XCTAssertEqual(decoded.officialRating, "PG-13")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "familyGuidance")
        XCTAssertNil(try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: old)).familyGuidance)
    }

    func testMissingAndZeroRatingsAreDifferent() {
        XCTAssertTrue(FamilyGuidanceSummary(recommendedAge: nil, qualityRating: 0).hasContent)
        XCTAssertFalse(FamilyGuidanceSummary(recommendedAge: nil, qualityRating: nil).hasContent)
    }

    func testCommunityRatingsCountAsAdditionalGuidance() {
        let summary = FamilyGuidanceSummary(recommendedAge: 14, qualityRating: 3)
        XCTAssertFalse(FamilyGuidance(summary: summary).hasDetails)
        XCTAssertTrue(FamilyGuidance(
            summary: summary,
            audienceRatings: [.init(audience: .parents, recommendedAge: 13, qualityRating: 4)]
        ).hasDetails)
    }
}
