import XCTest

@MainActor
final class PinnedNavigationBackTests: XCTestCase {
    func testBackFromHomeOpensNavigationThenExitsWithoutReturningHomeAgain() {
        let app = launch(root: "home")
        defer { app.terminate() }
        assertFocused(app.buttons["back-page-home"], app: app)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Home", app: app)
        XCUIRemote.shared.press(.menu)
        assertExited(app)
    }

    func testBackFromOtherPinnedRootsOpensNavigationThenHomeThenExits() {
        for (root, title) in [
            ("watchlist", "Watchlist"), ("search", "Search"),
            ("liveTV", "Live TV"), ("music", "Music"), ("settings", "Settings")
        ] {
            let app = launch(root: root)
            defer { app.terminate() }
            assertFocused(app.buttons["back-page-\(root)"], app: app)
            XCUIRemote.shared.press(.menu)
            assertNavigationFocused(title, app: app)
            XCUIRemote.shared.press(.menu)
            assertFocused(app.buttons["back-page-home"], app: app)
            XCUIRemote.shared.press(.menu)
            assertExited(app)
        }
    }

    func testBackCanReturnToHiddenHomeWithoutLosingTheExitStep() {
        let app = launch(root: "settings", arguments: ["--back-hidden-home"])
        defer { app.terminate() }
        assertFocused(app.buttons["back-page-settings"], app: app)
        XCTAssertFalse(app.buttons["Home"].exists)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Settings", app: app)
        XCUIRemote.shared.press(.menu)
        assertFocused(app.buttons["back-page-home"], app: app)
        XCUIRemote.shared.press(.menu)
        assertExited(app)
    }

    func testPushedPagesPopBeforeBackOpensNavigationAndResetHomeExit() {
        let app = launch(root: "settings")
        defer { app.terminate() }
        assertFocused(app.buttons["back-page-settings"], app: app)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Settings", app: app)
        XCUIRemote.shared.press(.menu)
        assertFocused(app.buttons["back-page-home"], app: app)
        XCUIRemote.shared.press(.select)
        assertFocused(app.buttons["back-detail-1"], app: app)
        XCUIRemote.shared.press(.select)
        assertFocused(app.buttons["back-detail-2"], app: app)
        XCUIRemote.shared.press(.menu)
        assertFocused(app.buttons["back-detail-1"], app: app)
        XCUIRemote.shared.press(.menu)
        assertFocused(app.buttons["back-page-home"], app: app)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Home", app: app)
    }

    func testDialogBackDoesNotOpenBackgroundNavigation() {
        let app = launch(root: "settings")
        defer { app.terminate() }
        assertFocused(app.buttons["back-page-settings"], app: app)
        XCUIRemote.shared.press(.down)
        assertFocused(app.buttons["back-open-dialog"], app: app)
        XCUIRemote.shared.press(.select)
        assertFocused(app.buttons["back-dialog"], app: app)
        XCUIRemote.shared.press(.menu)
        assertFocused(app.buttons["back-open-dialog"], app: app)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Settings", app: app)
    }

    func testExplicitlyOpeningNavigationAgainResetsTheHomeExitStep() {
        let app = launch(root: "settings")
        defer { app.terminate() }
        assertFocused(app.buttons["back-page-settings"], app: app)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Settings", app: app)
        XCUIRemote.shared.press(.menu)
        assertFocused(app.buttons["back-page-home"], app: app)
        XCUIRemote.shared.press(.left)
        assertNavigationFocused("Home", app: app)
        XCUIRemote.shared.press(.select)
        assertFocused(app.buttons["back-page-home"], app: app)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Home", app: app)
    }

    func testReturningToTheAppRestartsTheBackSequence() {
        let app = launch(root: "home")
        defer { app.terminate() }
        assertFocused(app.buttons["back-page-home"], app: app)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Home", app: app)
        XCUIRemote.shared.press(.menu)
        assertExited(app)
        app.activate()
        assertFocused(app.buttons["back-page-home"], app: app)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Home", app: app)
    }

    func testContextMenuBackDoesNotOpenBackgroundNavigation() {
        let app = launch(root: "home")
        defer { app.terminate() }
        assertFocused(app.buttons["back-page-home"], app: app)
        XCUIRemote.shared.press(.select, forDuration: 1)
        assertFocused(app.cells.containing(.any, identifier: "Context action").firstMatch, app: app)
        XCUIRemote.shared.press(.menu)
        assertFocused(app.buttons["back-page-home"], app: app)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Home", app: app)
    }

    func testHoldingBackStillUsesTheSystemShortcut() {
        let app = launch(root: "settings")
        defer { app.terminate() }
        assertFocused(app.buttons["back-page-settings"], app: app)
        XCUIRemote.shared.press(.menu, forDuration: 1)
        assertExited(app)
    }

    func testBackDuringDestinationHandoffCannotExitOrSkipHomePresentation() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--navigation-handoff-fixture", "--manual-navigation-handoff"]
        app.launch()
        defer { app.terminate() }
        assertFocused(app.buttons["handoff-page-home"], app: app)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Home", app: app)
        XCUIRemote.shared.press(.down)
        assertNavigationFocused("Music", app: app)
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Music", app: app)
        XCUIRemote.shared.press(.playPause)
        assertFocused(app.buttons["handoff-page-music"], app: app)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Music", app: app)
        XCUIRemote.shared.press(.menu)
        XCUIRemote.shared.press(.menu)
        assertNavigationFocused("Music", app: app)
        XCUIRemote.shared.press(.playPause)
        assertFocused(app.buttons["handoff-page-home"], app: app)
        XCUIRemote.shared.press(.menu)
        assertExited(app)
    }

    private func launch(root: String, arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--pinned-back-fixture", "--back-root=\(root)"] + arguments
        app.launch()
        return app
    }

    private func assertFocused(
        _ element: XCUIElement, app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.exists && element.hasFocus }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed,
                       app.debugDescription, file: file, line: line)
    }

    private func assertNavigationFocused(
        _ title: String, app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.buttons.allElementsBoundByIndex.contains { $0.label.hasPrefix(title) && $0.hasFocus }
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed,
                       app.debugDescription, file: file, line: line)
    }

    private func assertExited(
        _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed,
                       "The final Back must reach tvOS.", file: file, line: line)
    }
}
