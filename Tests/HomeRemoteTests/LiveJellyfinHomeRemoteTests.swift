import Foundation
import XCTest
import notify

final class LiveJellyfinHomeRemoteTests: XCTestCase {
    func testProfileRealHome() throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["PLOZZ_PERFORMANCE_ATTACH"] == "1",
              ProcessInfo.processInfo.environment["PLOZZ_JELLYFIN_HOME_BROKER"] != nil,
              let runID = ProcessInfo.processInfo.environment["PLOZZ_LIVE_HOME_RUN_ID"] else {
            throw XCTSkip("Requires the explicitly authorized live profiling lane.")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        XCTAssertEqual(app.state, .runningForeground)
        let start = app.buttons["live-home-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 35))
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Real Home data ready"].waitForExistence(timeout: 35))
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 5)
        XCTAssertTrue(hero.hasFocus)
        func focusedLabel() -> String {
            app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch.label
        }
        var rowDepth = 0
        for depth in 1...8 {
            XCUIRemote.shared.press(.down)
            let before = focusedLabel()
            XCUIRemote.shared.press(.right)
            let moved = !before.isEmpty && before != focusedLabel()
            XCUIRemote.shared.press(.left)
            if moved {
                rowDepth = depth
                break
            }
        }
        XCTAssertGreaterThan(rowDepth, 0, "Real data must include a horizontally navigable media row.")
        for _ in 0..<rowDepth { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(hero.hasFocus)
        XCTAssertEqual(notify_post("com.thatcube.Plozz.live-home.\(runID).navigation"), UInt32(NOTIFY_STATUS_OK))
        for _ in 0..<3 {
            for _ in 0..<rowDepth { XCUIRemote.shared.press(.down) }
            XCTAssertFalse(hero.hasFocus)
            let before = focusedLabel()
            for _ in 0..<4 { XCUIRemote.shared.press(.right) }
            XCTAssertTrue(before != focusedLabel(), "Native horizontal focus must actually move.")
            for _ in 0..<4 { XCUIRemote.shared.press(.left) }
            for _ in 0..<rowDepth { XCUIRemote.shared.press(.up) }
            XCTAssertTrue(hero.hasFocus)
        }
        XCTAssertEqual(notify_post("com.thatcube.Plozz.live-home.\(runID).finish"), UInt32(NOTIFY_STATUS_OK))
        XCTAssertTrue(app.staticTexts["Real Home measured"].waitForExistence(timeout: 10))
        #else
        throw XCTSkip("The live profiling lane is simulator-only.")
        #endif
    }
}
