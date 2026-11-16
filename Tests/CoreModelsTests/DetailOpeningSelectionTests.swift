import XCTest
@testable import CoreModels

/// One rule decides which child every detail page loads first. It used to be a
/// series-only helper, which is why a season page and a collection each waited for
/// a view pass before fetching what they were going to show anyway.
final class DetailOpeningSelectionTests: XCTestCase {
    private func item(_ id: String, _ kind: MediaItemKind) -> MediaItem {
        MediaItem(id: id, title: id, kind: kind)
    }

    func testPrefersReportedResumeSeason() {
        let children = [item("s1", .season), item("s2", .season), item("s3", .season)]
        XCTAssertEqual(
            DetailOpeningSelection.openingSeasonID(children: children, resumeSeasonID: "s2"),
            "s2"
        )
    }

    func testFallsBackToFirstSeasonWhenNoResume() {
        let children = [item("s1", .season), item("s2", .season)]
        XCTAssertEqual(
            DetailOpeningSelection.openingSeasonID(children: children, resumeSeasonID: nil),
            "s1"
        )
    }

    func testIgnoresResumeSeasonTheServerNoLongerLists() {
        let children = [item("s1", .season), item("s2", .season)]
        XCTAssertEqual(
            DetailOpeningSelection.openingSeasonID(children: children, resumeSeasonID: "s9"),
            "s1"
        )
    }

    func testSeasonPageHasNoOpeningSeason() {
        // A season page's children are the episodes the rail shows directly.
        let children = [item("e1", .episode), item("e2", .episode)]
        XCTAssertNil(
            DetailOpeningSelection.openingSeasonID(children: children, resumeSeasonID: nil)
        )
    }

    func testLeafPageHasNoOpeningSeason() {
        XCTAssertNil(
            DetailOpeningSelection.openingSeasonID(children: [], resumeSeasonID: nil)
        )
    }

    func testCollectionWithoutSeasonsHasNoOpeningSeason() {
        let children = [item("m1", .movie), item("m2", .movie)]
        XCTAssertNil(
            DetailOpeningSelection.openingSeasonID(children: children, resumeSeasonID: nil)
        )
    }
}
