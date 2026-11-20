import XCTest

@MainActor
final class PlexUserChooserInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
    }

    override func tearDown() {
        if app.state == .runningForeground {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testExplanationAndWholeRowTapSelectWithoutReplacingSheet() {
        launch()
        XCTAssertTrue(app.staticTexts["Who are you on Fixture Plex?"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts[
            "Plozz will play as this person here, show their watchlist, and save to it."
        ].exists)
        let korra = app.buttons["plex-user-korra"]
        korra.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).tap()
        XCTAssertTrue(waitUntilSelected(korra), app.debugDescription)
        assertSameSheet()
        XCTAssertFalse(app.buttons["2"].exists)
        XCTAssertTrue(app.buttons["Done"].isEnabled)
    }

    func testPlexQuestionFollowsProfilePickAndClosesOnSelection() {
        app.launchArguments = ["--plex-user-chooser-fixture", "--pending-profile-chooser"]
        app.launch()
        let profile = app.buttons["Other viewer"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10), app.debugDescription)
        let user = app.buttons["plex-user-korra"]
        XCTAssertFalse(user.exists, "The restored profile cannot ask ahead of the picker.")
        profile.tap()
        XCTAssertTrue(user.waitForExistence(timeout: 10), app.debugDescription)
        user.tap()
        XCTAssertTrue(user.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 2), "Switching profiles must not abort the app.")
    }

    func testSlowSelectionGivesFeedbackAndCancelPreservesOwner() {
        launch(["--slow-chooser"])
        let korra = app.buttons["plex-user-korra"]
        korra.tap()
        XCTAssertEqual(korra.value as? String, "Loading", app.debugDescription)
        XCTAssertFalse(app.buttons["Done"].isEnabled)
        XCTAssertFalse(app.buttons["2"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.buttons["plex-user-owner"].value as? String, "Selected")
        XCTAssertTrue(korra.isEnabled)
        assertSameSheet()
    }

    func testProtectedSelectionUsesInlinePINAndCancelKeepsPriorIdentity() {
        launch()
        app.buttons["plex-user-protected"].tap()
        XCTAssertTrue(app.buttons["2"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.otherElements["fixture-global-pin"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["plex-user-owner"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["plex-user-owner"].value as? String, "Selected")
        app.buttons["plex-user-protected"].tap()
        XCTAssertTrue(app.buttons["2"].waitForExistence(timeout: 5))
        for digit in ["2", "4", "6", "8"] { app.buttons[digit].tap() }
        let selected = app.buttons["plex-user-protected"]
        XCTAssertTrue(selected.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(selected.value as? String, "Selected")
        assertSameSheet()
    }

    func testFailedSelectionRetriesInPlaceWithoutSavingPrematurely() {
        launch(["--failed-chooser"])
        app.buttons["plex-user-korra"].tap()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons["plex-user-owner"].value as? String, "Selected")
        XCTAssertFalse(app.buttons["2"].exists)
        app.buttons["Retry"].tap()
        XCTAssertTrue(waitUntilSelected(app.buttons["plex-user-korra"]))
        assertSameSheet()
    }

    private func launch(_ arguments: [String] = []) {
        app.launchArguments = ["--plex-user-chooser-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["plex-user-korra"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func assertSameSheet(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.staticTexts["fixture-chooser-presentations"].label, "1", file: file, line: line)
        XCTAssertFalse(app.staticTexts["fixture-global-pin"].exists, file: file, line: line)
    }

    private func waitUntilSelected(_ element: XCUIElement) -> Bool {
        XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: element)
        ], timeout: 8) == .completed
    }
}
