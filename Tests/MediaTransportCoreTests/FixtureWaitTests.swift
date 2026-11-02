import XCTest

final class FixtureWaitTests: XCTestCase {
    func testWaitsAllowWorkToResumeAfterSchedulerYields() async {
        let synchronousReady = ContinuousClock.now + .milliseconds(50)
        let synchronous = await waitUntil { ContinuousClock.now >= synchronousReady }
        XCTAssertTrue(synchronous)

        let asynchronousReady = ContinuousClock.now + .milliseconds(50)
        let asynchronous = await waitUntilAsync { ContinuousClock.now >= asynchronousReady }
        XCTAssertTrue(asynchronous)
    }

    func testUnfulfilledConditionsExpire() async {
        let synchronous = await waitUntil(timeout: .milliseconds(10)) { false }
        let asynchronous = await waitUntilAsync(timeout: .milliseconds(10)) { false }
        XCTAssertFalse(synchronous)
        XCTAssertFalse(asynchronous)
    }
}
