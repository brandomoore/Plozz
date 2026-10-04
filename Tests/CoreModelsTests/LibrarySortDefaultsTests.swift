import CoreModels
import XCTest

final class LibrarySortDefaultsTests: XCTestCase {
    func testNameDefaultsAscending() {
        XCTAssertEqual(SortField.name.defaultDirection, .ascending)
    }

    func testContentRatingDefaultsAscending() {
        XCTAssertEqual(SortField.contentRating.defaultDirection, .ascending)
    }

    func testNumericAndDateFieldsDefaultDescending() {
        for field in SortField.allCases where field != .name && field != .contentRating {
            XCTAssertEqual(
                field.defaultDirection,
                .descending,
                "\(field) should put its highest/newest values first"
            )
        }
    }
}
