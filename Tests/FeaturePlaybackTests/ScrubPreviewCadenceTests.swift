import XCTest
@testable import FeaturePlayback

final class ScrubPreviewCadenceTests: XCTestCase {
    func testCadenceScalesFromPrecisionToTraversalInEitherDirection() {
        for direction in [-1.0, 1.0] {
            var cadence = ScrubPreviewCadence()
            cadence.update(speed: 400 * direction, delta: direction)
            XCTAssertEqual(cadence.interval, 1.0 / 30, accuracy: 0.000001)
            cadence.update(speed: 1_500 * direction, delta: direction)
            XCTAssertEqual(cadence.interval, (1.0 / 30 + 0.25) / 2, accuracy: 0.000001)
            cadence.update(speed: 2_500 * direction, delta: direction)
            XCTAssertEqual(cadence.interval, 0.25)
            cadence.update(speed: 10_000 * direction, delta: direction)
            XCTAssertEqual(cadence.interval, 0.25)
        }
    }

    func testRepeatedInputsCannotPostponeTheTrailingFrame() {
        var cadence = ScrubPreviewCadence()
        cadence.update(speed: 3_000, delta: 1)
        XCTAssertEqual(cadence.remainingDelay(at: 100), 0)
        cadence.didRequest(at: 100)
        for elapsed in [0.05, 0.1, 0.15, 0.2] {
            cadence.update(speed: 3_000, delta: 1)
            XCTAssertEqual(cadence.remainingDelay(at: 100 + elapsed), 0.25 - elapsed, accuracy: 0.000001)
        }
        XCTAssertEqual(cadence.remainingDelay(at: 100.25), 0)
    }

    func testSlowingDownDoesNotWaitForTheFastSwipeDeadline() {
        var cadence = ScrubPreviewCadence()
        cadence.update(speed: 3_000, delta: 1)
        cadence.didRequest(at: 10)
        XCTAssertEqual(cadence.remainingDelay(at: 10.05), 0.2, accuracy: 0.000001)
        cadence.update(speed: 200, delta: 1)
        XCTAssertEqual(cadence.remainingDelay(at: 10.05), 0)
    }

    func testReversalRequestsANewDirectionalPreviewImmediately() {
        var cadence = ScrubPreviewCadence()
        cadence.update(speed: 3_000, delta: 1)
        cadence.didRequest(at: 10)
        cadence.update(speed: 3_000, delta: -1)
        XCTAssertEqual(cadence.remainingDelay(at: 10.01), 0)
    }

    func testSixtyHzInputHasFewerPreviewRequestsDuringTraversal() {
        func requests(speed: Double) -> Int {
            var cadence = ScrubPreviewCadence()
            var count = 0
            for sample in 0..<60 {
                let time = Double(sample) / 60
                cadence.update(speed: speed, delta: 1)
                if cadence.remainingDelay(at: time) == 0 {
                    count += 1
                    cadence.didRequest(at: time)
                }
            }
            return count
        }
        let fast = requests(speed: 3_000)
        let slow = requests(speed: 200)
        XCTAssertEqual(fast, 4)
        XCTAssertGreaterThanOrEqual(slow, 24)
        XCTAssertLessThanOrEqual(slow, 30)
    }
}
