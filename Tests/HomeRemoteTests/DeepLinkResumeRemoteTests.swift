import XCTest

@MainActor
final class DeepLinkResumeRemoteTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testWarmResumeStartsAtSavedPosition() {
        exercise(choice: "Resume", expectedPosition: 3)
    }

    func testWarmStartOverStartsAtZero() {
        exercise(choice: "Start Over", expectedPosition: 0)
    }

    func testCancellingWarmResumeAllowsAnotherPlayback() {
        let app = launch()
        defer { app.terminate() }
        sendResumedTitle(app)
        choose("Cancel", in: app)
        let play = app.buttons["deep-link-play-first"]
        waitUntil { play.exists && play.hasFocus }
        XCTAssertFalse(app.staticTexts["deep-link-playing"].exists)
        XCUIRemote.shared.press(.select)
        expectPlayback("first:0", in: app)
    }

    private func exercise(choice: String, expectedPosition: Int) {
        let app = launch()
        defer { app.terminate() }
        sendResumedTitle(app)
        choose(choice, in: app)
        expectPlayback("resumed:\(expectedPosition)", in: app)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--deep-link-resume-fixture"]
        app.launch()
        expectPlayback("first:0", in: app)
        return app
    }

    private func sendResumedTitle(_ app: XCUIApplication) {
        let button = app.buttons["deep-link-send-resumed"]
        waitUntil { button.exists && button.hasFocus }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons.matching(identifier: "Resume").firstMatch.waitForExistence(timeout: 10))
    }

    private func choose(_ title: String, in app: XCUIApplication) {
        let buttons = app.buttons.matching(identifier: title)
        XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if buttons.allElementsBoundByIndex.contains(where: \.hasFocus) { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(buttons.allElementsBoundByIndex.contains(where: \.hasFocus))
        XCUIRemote.shared.press(.select)
    }

    private func expectPlayback(_ value: String, in app: XCUIApplication) {
        waitUntil {
            let marker = app.staticTexts["deep-link-playing"]
            return marker.exists && marker.label == value
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
}
