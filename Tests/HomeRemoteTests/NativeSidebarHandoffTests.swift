import XCTest

@MainActor
final class NativeSidebarHandoffTests: XCTestCase {
    func testProductionHomeDoesNotReclaimFocusDuringNativeSidebarSelection() {
        exerciseProductionHome(enterUsing: .select)
    }

    func testRightReturnsToProductionHomeWithoutSelectingTheHighlightedTab() {
        exerciseProductionHome(enterUsing: .right)
    }

    private func exerciseProductionHome(enterUsing button: XCUIRemote.Button) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture", "--native-sidebar-home"]
        app.launchEnvironment["PLZHFOCUS_STDOUT"] = "1"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 15), app.debugDescription)
        if !hero.hasFocus { XCUIRemote.shared.press(.select) }
        assertFocused(hero, app: app)
        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["Home"], app: app)
        XCUIRemote.shared.press(.playPause)
        XCTAssertEqual(app.staticTexts["native-production-armed"].label, "settings")
        XCUIRemote.shared.press(.down)
        assertFocused(app.buttons["Settings"], app: app)
        XCUIRemote.shared.press(button)
        if button == .right {
            assertFocused(hero, app: app)
            XCTAssertFalse(app.buttons["native-production-settings"].exists)
            XCTAssertEqual(app.staticTexts["native-production-premature-focus"].label, "1",
                           "The recorder must detect the intentional return to Home.")
            return
        }
        let destination = app.buttons["native-production-settings"]
        XCTAssertTrue(destination.waitForExistence(timeout: 10), app.debugDescription)
        assertFocused(destination, app: app)
        XCTAssertEqual(app.staticTexts["native-production-premature-focus"].label, "0", app.debugDescription)
    }

    func testNativeSidebarDoesNotVisitOutgoingContentWhenSelectingAnotherPage() {
        exerciseNativeSidebar(enterUsing: .select)
    }

    func testRightReturnsToCurrentNativePageWithoutSelectingTheHighlightedTab() {
        exerciseNativeSidebar(enterUsing: .right)
    }

    private func exerciseNativeSidebar(enterUsing button: XCUIRemote.Button) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--native-sidebar-handoff-fixture"]
        app.launch()
        defer { app.terminate() }

        let home = app.buttons["native-page-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 15), app.debugDescription)
        if !home.hasFocus { XCUIRemote.shared.press(.select) }
        assertFocused(home, app: app)
        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["Home"], app: app)
        XCUIRemote.shared.press(.playPause)
        XCUIRemote.shared.press(.down)
        assertFocused(app.buttons["Settings"], app: app)
        XCUIRemote.shared.press(button)
        if button == .right {
            assertFocused(home, app: app)
            XCTAssertFalse(app.buttons["native-page-settings"].exists)
            XCTAssertEqual(app.staticTexts["native-premature-focus-home"].label, "1")
            return
        }

        let settings = app.buttons["native-page-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        assertFocused(settings, app: app)
        XCTAssertEqual(app.staticTexts["native-premature-focus-settings"].label, "0", app.debugDescription)
    }

    private func assertFocused(
        _ element: XCUIElement, app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.exists && element.hasFocus },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed,
                       app.debugDescription, file: file, line: line)
    }
}
