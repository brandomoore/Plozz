import CoreModels
import XCTest
@testable import CoreUI

final class CircularControlFocusStyleTests: XCTestCase {
    func testSystemUsesTheExistingCircularOutline() {
        XCTAssertEqual(CircularControlFocusStyle.resolve(.system), .outlined)
    }

    func testCustomSelectionsRemainUnchanged() {
        XCTAssertEqual(CircularControlFocusStyle.resolve(.highlight), .highlight)
        XCTAssertEqual(CircularControlFocusStyle.resolve(.outlined), .outlined)
    }
}
