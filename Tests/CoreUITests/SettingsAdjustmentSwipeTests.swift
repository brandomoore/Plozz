import XCTest
@testable import CoreUI

final class SettingsAdjustmentSwipeTests: XCTestCase {
    func testShortSwipesStayFineAndLongSwipesCrossMultipleSteps() {
        for sign in [-1, 1] {
            let short = SettingsAdjustmentSwipe(translation: Double(sign * 8), forward: sign > 0)
            let long = SettingsAdjustmentSwipe(translation: Double(sign * 400), forward: sign > 0)
            XCTAssertEqual(short.initialSteps, sign)
            XCTAssertEqual(long.initialSteps, sign * 20)
        }
    }

    func testCoalescedFlickAndFrequentSamplesReachTheSameValue() {
        for sign in [-1.0, 1.0] {
            var flick = SettingsAdjustmentSwipe(translation: 8 * sign, forward: sign > 0)
            var sampled = flick
            let total = flick.initialSteps + flick.advance(to: 408 * sign)
            var sampledTotal = sampled.initialSteps
            for point in stride(from: 9, through: 408, by: 1) {
                sampledTotal += sampled.advance(to: Double(point) * sign)
            }
            XCTAssertEqual(total, Int(sign) * 21)
            XCTAssertEqual(sampledTotal, total)
            XCTAssertEqual(flick.advance(to: 408 * sign), 0, "A stationary finger adds no steps.")
        }
    }

    func testReversalUsesNewTravelAndAnotherGestureStartsFresh() {
        var swipe = SettingsAdjustmentSwipe(translation: 8, forward: true)
        XCTAssertEqual(swipe.advance(to: 208), 10)
        XCTAssertEqual(swipe.advance(to: 188), -1)
        XCTAssertEqual(swipe.advance(to: 178), 0)
        XCTAssertEqual(swipe.advance(to: 168), -1)
        let fresh = SettingsAdjustmentSwipe(translation: -8, forward: false)
        XCTAssertEqual(fresh.initialSteps, -1)
    }
}
