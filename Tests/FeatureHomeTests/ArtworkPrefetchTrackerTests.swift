import CoreModels
import CoreUI
import XCTest
@testable import FeatureHome

@MainActor
final class ArtworkPrefetchTrackerTests: XCTestCase {
    func testCellCompletionOrderCannotReverseOrMoveBackTheWindow() {
        let tracker = ArtworkPrefetchTracker()
        XCTAssertEqual(tracker.indices(aheadFrom: 41, total: 100, columns: 6, generation: 1), Array(41...53))
        tracker.updateDirection(at: 0)
        tracker.updateDirection(at: 2_000)
        for index in [12, 35, 6, 29, 0] {
            XCTAssertFalse(tracker.updateDirection(at: 2_000))
            XCTAssertEqual(tracker.indices(aheadFrom: index, total: 100, columns: 6, generation: 1), Array(41...53))
        }
        XCTAssertTrue(tracker.forward)
    }

    func testReversalRebasesTheWindowWithoutDiscardingOverlappingWork() async throws {
        let tracker = ArtworkPrefetchTracker(limiter: ConcurrencyLimiter(limit: 1))
        let calls = PrefetchCalls()
        let started = expectation(description: "Artwork preparation started")
        let request = ArtworkPrefetchWindow.Request(id: "shared-url-poster") {
            await calls.record()
            started.fulfill()
        }
        _ = tracker.indices(aheadFrom: 24, total: 100, columns: 6, generation: 1)
        tracker.window.update([request])
        await fulfillment(of: [started], timeout: 10)
        tracker.updateDirection(at: 2_000)
        for _ in 0..<20 {
            XCTAssertTrue(tracker.updateDirection(at: 1_999))
            XCTAssertEqual(tracker.indices(aheadFrom: 18, total: 100, columns: 6, generation: 1), Array((6...18).reversed()))
            tracker.window.update([request])
            XCTAssertTrue(tracker.updateDirection(at: 2_000))
            XCTAssertEqual(tracker.indices(aheadFrom: 24, total: 100, columns: 6, generation: 1), Array(24...36))
            tracker.window.update([request])
        }
        tracker.window.cancelAll()
        let count = await calls.count
        XCTAssertEqual(count, 1, "Reversals retain the same request while it remains in the window.")
    }

    func testGenerationAndDensityChangesResetTheFrontier() {
        let tracker = ArtworkPrefetchTracker()
        _ = tracker.indices(aheadFrom: 90, total: 100, columns: 6, generation: 1)
        XCTAssertEqual(tracker.indices(aheadFrom: 0, total: 100, columns: 6, generation: 2), Array(0...12))
        XCTAssertEqual(tracker.indices(aheadFrom: 0, total: 100, columns: 4, generation: 2), Array(0...8))
        tracker.reset()
        XCTAssertEqual(tracker.indices(aheadFrom: 1, total: 3, columns: 6, generation: 2), [1, 2])
    }

}

private actor PrefetchCalls {
    private(set) var count = 0
    func record() { count += 1 }
}
