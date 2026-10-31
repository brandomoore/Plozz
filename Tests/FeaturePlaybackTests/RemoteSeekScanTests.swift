import XCTest
@testable import FeaturePlayback

final class RemoteSeekScanTests: XCTestCase {
    func testAllEightForwardAndBackwardRatesAndCaps() {
        let rates: [Double] = [8, 24, 48, 96, 192, 384, 768, 1536]
        for forward in [true, false] {
            var level = 0
            let sign = forward ? 1 : -1
            for (index, rate) in rates.enumerated() {
                level = RemoteSeekScan.nextLevel(level, forward: forward)
                XCTAssertEqual(level, (index + 1) * sign)
                XCTAssertEqual(RemoteSeekScan.rate(at: level), rate * Double(sign))
            }
            XCTAssertEqual(RemoteSeekScan.nextLevel(level, forward: forward), 8 * sign)
        }
        XCTAssertEqual(RemoteSeekScan.rate(at: 0), 0)
    }

    func testOppositeClicksSlowThenReverseWithoutAnIdleStep() {
        for forward in [true, false] {
            let sign = forward ? 1 : -1
            var level = 8 * sign
            for expected in stride(from: 7, through: 1, by: -1) {
                level = RemoteSeekScan.nextLevel(level, forward: !forward)
                XCTAssertEqual(level, expected * sign)
            }
            XCTAssertEqual(RemoteSeekScan.nextLevel(level, forward: !forward), -sign)
        }
    }

    func testMovementUsesElapsedTimeAndClampsAtBothEnds() {
        XCTAssertEqual(RemoteSeekScan.position(from: 100, level: 2, elapsed: 0.25, duration: 7200), 106)
        XCTAssertEqual(RemoteSeekScan.position(from: 100, level: -2, elapsed: 0.25, duration: 7200), 94)
        XCTAssertEqual(RemoteSeekScan.position(from: 100, level: -8, elapsed: 1, duration: 7200), 0)
        XCTAssertEqual(RemoteSeekScan.position(from: 7100, level: 8, elapsed: 1, duration: 7200), 7200)
    }
}
