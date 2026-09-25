#if DEBUG
import XCTest

@testable import FeaturePlayback

final class LiveSeekableWindowTests: XCTestCase {
    func testUsesNewestContiguousSeekableRange() {
        let window = LiveSeekableWindow(ranges: [
            (start: 100, duration: 20),
            (start: 125, duration: 15),
        ])

        XCTAssertEqual(window?.lowerBound, 125)
        XCTAssertEqual(window?.upperBound, 140)
        XCTAssertEqual(window?.duration, 15)
    }

    func testRejectsInvalidAndEmptyRanges() {
        XCTAssertNil(LiveSeekableWindow(ranges: []))
        XCTAssertNil(LiveSeekableWindow(ranges: [
            (start: .nan, duration: 30),
            (start: 10, duration: 0),
        ]))
    }

    func testTinyWindowDoesNotAdvertiseTimeShift() {
        let window = LiveSeekableWindow(ranges: [(start: 20, duration: 2.9)])

        XCTAssertEqual(window?.supportsTimeShift, false)
    }

    func testLiveEdgeUsesRealUpperBound() {
        let window = LiveSeekableWindow(ranges: [(start: 100, duration: 60)])

        XCTAssertEqual(window?.isAtLiveEdge(currentTime: 158), true)
        XCTAssertEqual(window?.isAtLiveEdge(currentTime: 150), false)
    }

    func testLiveTargetStaysJustInsidePlaylistBoundary() {
        let window = LiveSeekableWindow(ranges: [(start: 100, duration: 60)])

    }

    @MainActor
    func testGoLiveOnlyWhenTheViewerIsActuallyBehind() {
        // A channel nobody touched: HLS's normal delay swings as segments land,
        // and none of it counts as being behind.
        for behind in [0.5, 3, 6, 9, 18, 24] as [TimeInterval] {
            XCTAssertFalse(LiveChannelPlayerModel.isBehindLive(behind, timeShifted: false), "\(behind)s")
        }
        XCTAssertTrue(LiveChannelPlayerModel.isBehindLive(45, timeShifted: false), "fallen well behind on its own")
        XCTAssertFalse(LiveChannelPlayerModel.isBehindLive(29.99, timeShifted: false))
        XCTAssertTrue(LiveChannelPlayerModel.isBehindLive(30, timeShifted: false))
        XCTAssertTrue(LiveChannelPlayerModel.isBehindLive(4, timeShifted: true), "paused past the edge")
        XCTAssertFalse(LiveChannelPlayerModel.isBehindLive(2, timeShifted: true), "still at the edge")
    }
}
#endif
