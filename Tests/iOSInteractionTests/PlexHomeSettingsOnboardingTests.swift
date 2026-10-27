import XCTest

@MainActor
final class PlexHomeSettingsOnboardingTests: XCTestCase {
    func testDeduplicatedLockedProfileAuthenticatesInsideTheSettingsChooser() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--plex-home-settings-onboarding-fixture"]
        app.launch()
        defer { app.terminate() }
        app.buttons["Open Settings"].tap()
        let add = app.buttons["Add Plex profiles"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let all = app.buttons["plex-home-add-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        let locked = app.buttons["plex-home-user-locked"]
        XCTAssertTrue(locked.waitForExistence(timeout: 5))
        locked.tap()
        XCTAssertTrue(app.buttons["1"].waitForExistence(timeout: 5))
        let authorization = XCTAttachment(screenshot: app.screenshot())
        authorization.name = "Locked profile authorization above Settings"
        authorization.lifetime = .keepAlways
        self.add(authorization)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(locked.waitForExistence(timeout: 5))
        locked.tap()
        XCTAssertTrue(app.buttons["1"].waitForExistence(timeout: 5))
        for digit in ["1", "3", "5", "7"] { app.buttons[digit].tap() }
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        let current = app.staticTexts["onboarding-active-profile"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertEqual(current.label, "Locked viewer")
    }
}
