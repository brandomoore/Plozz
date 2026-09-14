import XCTest

@MainActor
final class PinnedRailBoundaryTests: XCTestCase {
    func testLongRailStopsAtBottom() { exerciseBoundary(top: false, short: false) }
    func testShortRailStopsAtBottom() { exerciseBoundary(top: false, short: true) }
    func testLongRailStopsAtProfile() { exerciseBoundary(top: true, short: false) }
    func testShortRailStopsAtProfile() { exerciseBoundary(top: true, short: true) }

    func testLiveTVExperimentalLabelPreservesNavigationRowGeometry() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--navigation-fixture", "--navigation-short", "--navigation-live-tv"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["navigation-page"].waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.left)
        let liveTV = app.buttons["Live TV"]
        assertFocused(liveTV)
        XCTAssertEqual(liveTV.value as? String, "Experimental")
        XCUIRemote.shared.press(.up)
        let ordinaryRow = app.buttons["Library 1"]
        assertFocused(ordinaryRow)
        let ordinaryFocusedHeight = ordinaryRow.frame.height
        XCUIRemote.shared.press(.down)
        assertFocused(liveTV)
        XCTAssertEqual(liveTV.frame.height, ordinaryFocusedHeight, accuracy: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "pinned-live-tv-experimental"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIRemote.shared.press(.down)
        assertFocused(liveTV)
        XCUIRemote.shared.press(.right)
        XCTAssertFalse(liveTV.hasFocus)
    }

    private func exerciseBoundary(top: Bool, short: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--navigation-fixture"] + (short ? ["--navigation-short"] : [])
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["navigation-page"].waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.left)
        let settings = app.buttons["Settings"]
        assertFocused(settings)
        let target: XCUIElement
        let direction: XCUIRemote.Button
        if top {
            for _ in 0..<(short ? 4 : 32) { XCUIRemote.shared.press(.up) }
            target = app.buttons["Navigation"]
            direction = .up
        } else {
            target = settings
            direction = .down
        }
        assertFocused(target)
        for _ in 0..<4 {
            XCUIRemote.shared.press(direction)
            assertFocused(target)
        }
        XCUIRemote.shared.press(direction, forDuration: 0.8)
        assertFocused(target)
        XCTAssertTrue(app.buttons["Navigation"].isEnabled, "Boundary input must not collapse the menu or hide the profile name.")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "pinned-\(short ? "short" : "long")-\(top ? "top" : "bottom")"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCUIRemote.shared.press(.right)
        let returned = NSPredicate { _, _ in
            ["navigation-page", "navigation-reorder", "navigation-open"].contains { app.buttons[$0].hasFocus }
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returned, object: nil)], timeout: 5),
            .completed
        )
    }

    private func assertFocused(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in element.exists && element.hasFocus }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 4),
            .completed, "The boundary item must retain focus.", file: file, line: line
        )
    }
}
