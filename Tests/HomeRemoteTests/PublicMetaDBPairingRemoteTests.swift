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
        let field = keyField
        waitForFocus(field)
        XCTAssertTrue(app.staticTexts["publicmetadb.pair.code"].waitForExistence(timeout: 5))
        waitForFocus(field)
        capture("pairing-key-initial-focus")
        for _ in 0..<3 {
            press(.up, expecting: back)
            press(.down, expecting: field)
        }
        press(.down, expecting: app.buttons["publicmetadb.pair.cancel"])
        press(.up, expecting: field)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCUIRemote.shared.press(.menu)
        waitForFocus(field)
        press(.up, expecting: back)
        capture("pairing-back-focus")
        XCUIRemote.shared.press(.select)
        waitForFocus(app.buttons["fixture.open-publicmetadb"])
        openEntry()
        waitForFocus(keyField)
    }

    func testUnavailableQRKeepsManualFieldAndBackReachable() {
        launch(unavailable: true)
        openEntry()
        waitForFocus(keyField)
        XCTAssertTrue(app.staticTexts["publicmetadb.pair.error"].waitForExistence(timeout: 5))
        press(.up, expecting: back)
        press(.down, expecting: app.buttons["publicmetadb.pair.retry"])
        press(.right, expecting: keyField)
        press(.up, expecting: back)
        press(.down, expecting: app.buttons["publicmetadb.pair.retry"])
        press(.right, expecting: keyField)
        capture("pairing-unavailable-key-focus")
    }

    func testManualConnectionShowsSharedConnectedStatus() {
        launch()
        openEntry()
        waitForFocus(keyField)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        keyField.typeText("pm-" + String(repeating: "a", count: 60))
        XCUIRemote.shared.press(.menu)
        waitForFocus(keyField)
        press(.down, expecting: app.buttons["publicmetadb.pair.cancel"])
        press(.left, expecting: app.buttons["publicmetadb.connect"])
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["publicmetadb.browse"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["publicmetadb.status"].label.contains("Connected"))
        XCTAssertFalse(keyField.exists)
        capture("pairing-connected")
    }

    private var keyField: XCUIElement { app.secureTextFields["publicmetadb.key"] }
    private var back: XCUIElement { app.buttons["settings-workspace-back"] }

    private func launch(unavailable: Bool = false) {
        app.launchArguments = [
            "--publicmetadb-pairing-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ] + (unavailable ? ["--pairing-unavailable"] : [])
        app.launch()
    }

    private func openEntry() {
        waitForFocus(app.buttons["fixture.open-publicmetadb"])
        XCUIRemote.shared.press(.select)
        waitForFocus(back)
        press(.down, expecting: app.buttons["publicmetadb.pair"])
        XCUIRemote.shared.press(.select)
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
