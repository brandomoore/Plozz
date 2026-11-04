import XCTest
@testable import EnginePlozzigen

final class PipelineDiagnosticCadenceTests: XCTestCase {
    func testPauseHeartbeatPreservesTransitionsAndNormalPlaybackCadence() {
        var cadence = PipelineDiagnosticCadence()
        XCTAssertTrue(cadence.shouldEmit(identity: "playing", paused: false, now: 0))
        XCTAssertFalse(cadence.shouldEmit(identity: "playing", paused: false, now: 1.99))
        XCTAssertTrue(cadence.shouldEmit(identity: "playing", paused: false, now: 2))
        XCTAssertTrue(cadence.shouldEmit(identity: "paused", paused: true, now: 2.1))
        XCTAssertFalse(cadence.shouldEmit(identity: "paused", paused: true, now: 32.09))
        XCTAssertTrue(cadence.shouldEmit(identity: "paused", paused: true, now: 32.1))
        XCTAssertTrue(cadence.shouldEmit(identity: "paused-new-track", paused: true, now: 32.2))
        XCTAssertTrue(cadence.shouldEmit(identity: "playing", paused: false, now: 32.3))
        XCTAssertTrue(cadence.shouldEmit(identity: "new-load-playing", paused: false, now: 32.4))
    }
}
