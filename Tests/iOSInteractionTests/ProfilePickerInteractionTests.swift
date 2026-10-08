import XCTest

@MainActor
final class ProfilePickerInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
    }

    override func tearDown() async throws {
        if app.state == .runningForeground {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.lifetime = .keepAlways
            add(image)
        }
        app.terminate()
        app = nil
        try await super.tearDown()
    }

    func testSelectionCancelAndFreshPresentation() {
        launch()
        XCTAssertFalse(app.staticTexts["Choose a profile to continue."].exists)
        app.buttons["Alex"].tap()
        XCTAssertTrue(app.staticTexts["fixture-profile-result"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["fixture-profile-result"].label, "Alex")
        app.buttons["Open picker"].tap()
        XCTAssertTrue(app.buttons["Sam"].waitForExistence(timeout: 3))
        app.buttons["profile-picker-close"].tap()
        XCTAssertEqual(app.staticTexts["fixture-profile-result"].label, "Cancelled")
    }

    func testEditModeAndLongPressPushOneProfilePage() {
        launch()
        app.buttons["profile-picker-edit"].tap()
        XCTAssertFalse(app.buttons["Add Profile"].exists)
        XCTAssertFalse(app.buttons["profile-picker-close"].exists)
        app.buttons["Alex"].tap()
        XCTAssertTrue(app.navigationBars["Alex"].waitForExistence(timeout: 3), app.debugDescription)
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["profile-picker-edit"].waitForExistence(timeout: 3))
        app.buttons["profile-picker-edit"].tap()
        XCTAssertTrue(app.buttons["Add Profile"].waitForExistence(timeout: 3))
        app.buttons["Sam"].press(forDuration: 1)
        app.buttons["Edit Profile"].tap()
        XCTAssertTrue(app.navigationBars["Sam"].waitForExistence(timeout: 3))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["Alex"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists)
    }

    func testAdultAndKidsCreationRemainSeparateEntryPoints() {
        for title in ["Add Profile", "Add Kids Profile"] {
            launch()
            app.buttons[title].tap()
            XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertTrue(app.textFields.firstMatch.exists, app.debugDescription)
            app.buttons["Cancel"].tap()
            if app.alerts["Discard changes?"].waitForExistence(timeout: 1) {
                app.alerts.buttons["Discard"].tap()
            }
            XCTAssertTrue(app.staticTexts["fixture-profile-result"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.staticTexts["fixture-profile-result"].label, "Cancelled")
        }
    }

    func testRestrictedLaunchPickerExposesNoManagementOrDismissal() {
        launch(["--restricted-picker", "--launch-picker"])
        XCTAssertFalse(app.buttons["profile-picker-edit"].exists)
        XCTAssertFalse(app.buttons["profile-picker-close"].exists)
        XCTAssertFalse(app.buttons["Add Profile"].exists)
        XCTAssertFalse(app.buttons["Add Kids Profile"].exists)
        app.buttons["Jamie"].tap()
        XCTAssertTrue(app.staticTexts["fixture-profile-result"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["fixture-profile-result"].label, "Jamie")
    }

    private func launch(_ arguments: [String] = []) {
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = ["--profile-picker-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["Alex"].waitForExistence(timeout: 10), app.debugDescription)
    }
}
