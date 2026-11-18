import XCTest

@MainActor
final class EmptyPinnedNavigationTests: XCTestCase {
    func testLiveTVSetupAcceptsSelectionAndRightFromPinnedNavigation() {
        exercise(destination: "Live TV", downCount: 1, content: "live-tv-setup-playlist")
    }

    func testSettingsAcceptsSelectionAndRightFromPinnedNavigationWithoutMedia() {
        exercise(destination: "Settings", downCount: 2, content: "settings-section-playback")
    }

    func testColdLiveTVSetupStartsOnTheFirstChoice() {
        let app = launch(start: "liveTV")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["live-tv-setup-playlist"].waitForExistence(timeout: 15))
        assertFocused(app.buttons["live-tv-setup-playlist"], in: app)
    }

    func testColdSettingsStartsOnItsPreferredCategory() {
        let app = launch(start: "settings")
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["settings-section-playback"].waitForExistence(timeout: 15))
        assertFocused(app.buttons["settings-section-playback"], in: app)
    }

    func testRetainedLiveTVDoesNotBlockSettingsOrHomeEntry() {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 15))
        assertFocused(app.buttons["Try Again"], in: app)
        var currentDestination = "Home"
        for (destination, moves, content) in [
            ("Live TV", [XCUIRemote.Button.down], "live-tv-setup-playlist"),
            ("Settings", [.down], "settings-section-playback"),
            ("Home", [.up, .up], "Try Again"),
            ("Live TV", [.down], "live-tv-setup-playlist")
        ] {
            XCUIRemote.shared.press(.left)
            assertFocused(app.buttons[currentDestination], in: app)
            for move in moves { XCUIRemote.shared.press(move) }
            assertFocused(app.buttons[destination], in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.buttons[content].waitForExistence(timeout: 10), app.debugDescription)
            assertFocused(app.buttons[content], in: app)
            currentDestination = destination
        }
    }

    private func launch(start: String = "home") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--empty-pinned-navigation-fixture", "--empty-pinned-start=\(start)",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launchEnvironment["PLZHFOCUS_STDOUT"] = "1"
        app.launch()
        return app
    }

    private func exercise(destination: String, downCount: Int, content: String) {
        let app = launch()
        defer { app.terminate() }
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15), app.debugDescription)
        assertFocused(retry, in: app)
        XCUIRemote.shared.press(.left)
        assertFocused(app.buttons["Home"], in: app)
        for _ in 0..<downCount { XCUIRemote.shared.press(.down) }
        assertFocused(app.buttons[destination], in: app)
        XCUIRemote.shared.press(.select)
        let target = app.buttons[content]
        XCTAssertTrue(target.waitForExistence(timeout: 10), app.debugDescription)
        assertFocused(target, in: app)
        for action in [XCUIRemote.Button.right, .select] {
            XCUIRemote.shared.press(.left)
            assertFocused(app.buttons[destination], in: app)
            XCUIRemote.shared.press(action)
            assertFocused(target, in: app)
        }
        attachScreenshot(of: app, name: "Pinned navigation - \(destination) focused")
    }

    private func assertFocused(
        _ element: XCUIElement, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                element.exists && (element.hasFocus
                    || (element.identifier == "settings-section-playback"
                        && app.staticTexts["empty-pinned-native-focus"].label == "playback")
                    || element.descendants(matching: .any).allElementsBoundByIndex.contains(where: \.hasFocus))
            }, object: nil
        )
        let result = XCTWaiter.wait(for: [expected], timeout: 5)
        if result != .completed {
            attachScreenshot(of: app, name: "Pinned navigation focus failure")
        }
        XCTAssertEqual(result, .completed, app.debugDescription, file: file, line: line)
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
}
