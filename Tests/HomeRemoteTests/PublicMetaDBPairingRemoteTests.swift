import XCTest

@MainActor
final class PublicMetaDBPairingRemoteTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
    }

    override func tearDown() {
        if let testRun, testRun.failureCount > 0 {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.lifetime = .keepAlways
            add(tree)
            capture("pairing-focus-failure")
        }
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testEntryFocusAndBackTraversalSurviveQRLoadingAndReentry() {
        launch()
        openEntry()
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        let qr = app.images["QR code"]
        XCTAssertTrue(qr.exists && manual.frame.minY >= qr.frame.maxY)
        focusFromAbove(manual)
        for _ in 0..<3 {
            press(.up, expecting: back)
            press(.down, expecting: manual)
        }
        press(.right, expecting: cancel)
        XCUIRemote.shared.press(.select)
        selectConnect()
        focusFromAbove(manual)
        press(.up, expecting: back)
        XCUIRemote.shared.press(.select)
        waitForFocus(app.buttons["fixture.open-publicmetadb"])
        openEntry()
        XCUIRemote.shared.press(.menu)
        waitForFocus(app.buttons["fixture.open-publicmetadb"])
    }

    func testUnavailableQRAllowsRetryOrImmediateManualEntry() {
        launch(unavailable: true)
        openEntry()
        let error = app.staticTexts["publicmetadb.pair.error"], retry = app.buttons["publicmetadb.pair.retry"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(keyField.exists || code.exists)
        press(.up, expecting: retry)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        selectManual()
        XCTAssertFalse(error.exists || retry.exists || code.exists)
        XCTAssertFalse(app.buttons["publicmetadb.connect"].isEnabled)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        waitForFocus(keyField)
        press(.down, expecting: cancel)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["publicmetadb.pair"].waitForExistence(timeout: 5))
        XCTAssertFalse(keyField.exists)
    }

    func testCanSwitchToManualWhileChallengeIsLoading() {
        launch(loading: true)
        openEntry()
        XCTAssertFalse(code.exists || app.images["QR code"].exists)
        XCTAssertTrue(app.activityIndicators["Loading QR code…"].exists)
        selectManual()
        XCTAssertFalse(app.activityIndicators["Loading QR code…"].exists)
    }

    func testManualConnectionShowsSharedConnectedStatus() {
        launch()
        openEntry()
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        selectManual()
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        keyField.typeText("pm-" + String(repeating: "a", count: 60))
        XCUIRemote.shared.press(.menu)
        waitForFocus(keyField)
        press(.down, expecting: app.buttons["publicmetadb.pair.cancel"])
        press(.left, expecting: app.buttons["publicmetadb.connect"])
        XCUIRemote.shared.press(.select)
        let activation = app.switches["publicmetadb.enabled"]
        XCTAssertTrue(activation.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(activation.value as? String, "1")
        XCTAssertTrue(app.staticTexts["publicmetadb.status"].label.contains("Connected"))
        XCTAssertFalse(app.buttons["Tracking settings"].exists || app.buttons["Done"].exists)
        XCTAssertFalse(keyField.exists)
        capture("pairing-connected")
    }

    private var keyField: XCUIElement { app.secureTextFields["publicmetadb.key"] }
    private var code: XCUIElement { app.staticTexts["publicmetadb.pair.code"] }
    private var manual: XCUIElement { app.buttons["publicmetadb.pair.manual"] }
    private var cancel: XCUIElement { app.buttons["publicmetadb.pair.cancel"] }
    private var back: XCUIElement { app.buttons["settings-workspace-back"] }

    private func launch(unavailable: Bool = false, loading: Bool = false) {
        app.launchArguments = [
            "--publicmetadb-pairing-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ] + (unavailable ? ["--pairing-unavailable"] : []) + (loading ? ["--pairing-loading"] : [])
        app.launch()
    }

    private func openEntry() {
        waitForFocus(app.buttons["fixture.open-publicmetadb"])
        XCUIRemote.shared.press(.select)
        waitForFocus(app.buttons["publicmetadb.pair"])
        XCTAssertTrue(app.staticTexts["PublicMetaDB"].exists && back.exists)
        selectConnect()
    }

    private func selectConnect() {
        let entry = app.buttons["publicmetadb.pair"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        focusFromAbove(entry)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(manual.waitForExistence(timeout: 5) && manual.isEnabled && cancel.isEnabled)
        XCTAssertTrue(app.staticTexts["plozz.app/pmdb"].exists)
        waitForFocus(manual)
        XCTAssertFalse(keyField.exists || app.keyboards.firstMatch.exists)
    }

    private func selectManual() {
        focusFromAbove(manual)
        XCUIRemote.shared.press(.select)
        waitForFocus(keyField)
        XCTAssertFalse(manual.exists || code.exists || app.images["QR code"].exists || app.keyboards.firstMatch.exists)
    }

    private func focusFromAbove(_ target: XCUIElement) {
        for _ in 0..<4 where !target.hasFocus { XCUIRemote.shared.press(.down) }
        waitForFocus(target)
    }

    private func press(_ direction: XCUIRemote.Button, expecting target: XCUIElement) {
        XCUIRemote.shared.press(direction)
        waitForFocus(target)
    }

    private func waitForFocus(_ target: XCUIElement) {
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in target.exists && target.hasFocus }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed,
                       "Expected focus on \(target.identifier). \(app.debugDescription)")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
