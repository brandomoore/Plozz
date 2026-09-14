import XCTest

@MainActor
final class NavigationDestinationHandoffTests: XCTestCase {
    func testDestinationSelectionDoesNotFocusTheOutgoingPageWhileLoading() {
        let app = launchFixture()
        defer { app.terminate() }
        let home = app.buttons["handoff-page-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        assertFocused(home)

        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["Home"])
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        assertFocused(app.buttons["Settings"])
        XCUIRemote.shared.press(.select)

        let destination = app.buttons["handoff-page-settings"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        assertFocused(destination)
        XCTAssertEqual(
            app.staticTexts["handoff-premature-focus"].label, "0",
            "Selecting another page must not first move focus into the outgoing page."
        )

        for (title, page) in [("Music", "music"), ("Home", "home")] {
            XCUIRemote.shared.press(.left)
            XCUIRemote.shared.press(.up)
            assertFocused(app.buttons[title])
            XCUIRemote.shared.press(.select)
            let destination = app.buttons["handoff-page-\(page)"]
            XCTAssertTrue(destination.waitForExistence(timeout: 10))
            assertFocused(destination)
            XCTAssertEqual(app.staticTexts["handoff-premature-focus"].label, "0")
        }
    }

    func testSelectingTheCurrentDestinationDoesNotWaitForAnotherAppearance() {
        let app = launchFixture()
        defer { app.terminate() }
        let page = app.buttons["handoff-page-home"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        assertFocused(page)
        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["Home"])
        XCUIRemote.shared.press(.select)
        assertFocused(page)
        XCTAssertEqual(app.staticTexts["handoff-premature-focus"].label, "0")
    }

    func testPendingNavigationCanBeReplacedWithoutReleasingFocusEarly() {
        let app = launchFixture(arguments: ["--manual-navigation-handoff"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["handoff-page-home"].waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["Home"])
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.down)
        assertFocused(app.buttons["Settings"])
        XCUIRemote.shared.press(.select)
        assertFocused(app.buttons["Settings"])

        XCUIRemote.shared.press(.up)
        assertFocused(app.buttons["Music"])
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.right)
        assertFocused(app.buttons["Music"])
        XCUIRemote.shared.press(.playPause)
        let page = app.buttons["handoff-page-music"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        assertFocused(page)
        XCTAssertFalse(app.buttons["handoff-page-settings"].exists)
        XCTAssertEqual(app.staticTexts["handoff-premature-focus"].label, "0")
    }

    private func launchFixture(arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--navigation-handoff-fixture"] + arguments
        app.launch()
        return app
    }

    private func assertFocused(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.exists && element.hasFocus },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed, file: file, line: line)
    }
}
