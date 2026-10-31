import XCTest

@MainActor
final class DiagnosticsSharingInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
    }

    override func tearDown() {
        if let testRun, testRun.failureCount > 0 { capture("failure") }
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testEnableSharingRequiresConsentAndNeverSendsAutomatically() {
        launch()
        let enable = app.buttons["diagnostics-enable-sharing"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(enable.isEnabled)
        XCTAssertTrue(app.staticTexts["Turn on Share Diagnostics to send a report."].exists)
        XCTAssertFalse(app.buttons["diagnostics-submit"].exists)
        capture("sharing-off")
        enable.tap()
        let decline = app.buttons["Don't Share"]
        XCTAssertTrue(decline.waitForExistence(timeout: 5), app.debugDescription)
        decline.tap()
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["diagnostics-sharing-toggle"].value as? String, "0")
        XCTAssertEqual(app.staticTexts["diagnostics-submission-count"].label, "0")

        enable.tap()
        let consent = app.buttons["Share Diagnostics"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        capture("sharing-consent")
        consent.tap()
        let send = app.buttons["diagnostics-submit"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(send.isEnabled, "A required message must still be provided after opting in.")
        XCTAssertEqual(app.switches["diagnostics-sharing-toggle"].value as? String, "1")
        XCTAssertEqual(app.staticTexts["diagnostics-submission-count"].label, "0")
        capture("sharing-on-message-required")

        let message = messageField
        XCTAssertTrue(message.exists, app.debugDescription)
        message.tap()
        message.typeText("Silo search returned no matches")
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertEqual(app.staticTexts["diagnostics-submission-count"].label, "1")
    }

    func testUnavailableBuildUsesNativeDisabledControlsAndExplainsWhy() {
        launch(arguments: ["--diagnostics-unavailable"])
        let send = app.buttons["diagnostics-submit"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(send.isEnabled)
        XCTAssertTrue(app.buttons["diagnostics-information-button"].isEnabled)
        XCTAssertFalse(app.switches["diagnostics-sharing-toggle"].isEnabled)
        XCTAssertFalse(app.buttons["diagnostics-enable-sharing"].exists)
        XCTAssertTrue(app.staticTexts["Diagnostic sharing is unavailable in this build."].exists)
        XCTAssertEqual(app.staticTexts["diagnostics-submission-count"].label, "0")
        capture("sharing-unavailable")
    }

    func testMessageSurvivesConsentWithoutSubmission() {
        launch()
        let message = messageField
        XCTAssertTrue(message.waitForExistence(timeout: 10), app.debugDescription)
        message.tap()
        message.typeText("Search returned no matches")
        app.buttons["diagnostics-enable-sharing"].tap()
        let consent = app.buttons["Share Diagnostics"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.tap()
        let send = app.buttons["diagnostics-submit"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        XCTAssertEqual(message.value as? String, "Search returned no matches")
        XCTAssertEqual(app.staticTexts["diagnostics-submission-count"].label, "0")
    }

    func testBusyAndSubmittedActionsStayDisabled() {
        for argument in ["--diagnostics-sending", "--diagnostics-submitted"] {
            launch(arguments: [argument, "--diagnostics-enabled", "--diagnostics-with-message"])
            let toggle = app.switches["diagnostics-sharing-toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            XCTAssertEqual(toggle.value as? String, "1")
            XCTAssertEqual(messageField.value as? String, "Search returned no matches")
            let send = app.buttons["diagnostics-submit"]
            XCTAssertTrue(send.waitForExistence(timeout: 5))
            XCTAssertFalse(send.isEnabled)
            XCTAssertTrue(app.buttons["diagnostics-information-button"].isEnabled)
            XCTAssertEqual(app.staticTexts["diagnostics-submission-count"].label, "0")
            app.terminate()
        }
    }

    func testInformationExplainsSharingWithoutEnablingOrSending() {
        launch()
        let info = app.buttons["diagnostics-information-button"]
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(info.frame.width, 44)
        XCTAssertGreaterThanOrEqual(info.frame.height, 44)
        let disclosures = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "through Sentry"))
        XCTAssertEqual(disclosures.count, 0, "Detailed disclosures should not crowd the settings page.")
        info.tap()
        XCTAssertTrue(app.staticTexts["Automatic Reports"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Manual Reports"].exists)
        XCTAssertEqual(disclosures.count, 2)
        XCTAssertTrue(app.buttons["privacy-policy-link"].exists)
        capture("sharing-information")
        app.buttons["Done"].tap()
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["diagnostics-sharing-toggle"].value as? String, "0")
        XCTAssertEqual(app.staticTexts["diagnostics-submission-count"].label, "0")
    }

    private func launch(arguments: [String] = []) {
        app.launchArguments = ["--diagnostics-sharing-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
    }

    private var messageField: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "diagnostics-message").firstMatch
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "diagnostics-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
