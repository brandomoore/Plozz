#if os(tvOS)
import XCTest
import UIKit
@testable import AppShell

@MainActor
final class NavigationContentFocusRequesterTests: XCTestCase {
    func testExpandedLaterCardDoesNotOutrankTheLeadingCard() {
        let frames = [
            CGRect(x: 80, y: 400, width: 240, height: 160),
            CGRect(x: 350, y: 390, width: 260, height: 180),
            CGRect(x: 640, y: 400, width: 240, height: 160),
            CGRect(x: 80, y: 650, width: 240, height: 160)
        ]
        XCTAssertEqual(NavigationContentFocusRequester.firstFrameIndex(frames, isRightToLeft: false), 0)
        XCTAssertEqual(NavigationContentFocusRequester.firstFrameIndex(frames, isRightToLeft: true), 2)
    }

    func testPageTopControlOutranksCardsBelowIt() {
        let frames = [
            CGRect(x: 80, y: 500, width: 240, height: 160),
            CGRect(x: 700, y: 150, width: 180, height: 70)
        ]
        XCTAssertEqual(NavigationContentFocusRequester.firstFrameIndex(frames, isRightToLeft: false), 1)
        XCTAssertNil(NavigationContentFocusRequester.firstFrameIndex([], isRightToLeft: false))
    }
}
#endif
