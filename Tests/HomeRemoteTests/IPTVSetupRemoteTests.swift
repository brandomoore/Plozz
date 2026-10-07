import XCTest

@MainActor
final class IPTVSetupRemoteTests: XCTestCase {
    func testAdvancedDisclosureExpandsAndCollapsesWithoutMovingFocus() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--iptv-setup-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let advanced = app.buttons["iptv-advanced-options"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(advanced.value as? String, "Collapsed")
        XCTAssertFalse(app.buttons["iptv-authentication"].exists)
        XCTAssertFalse(app.staticTexts["HTTP is unencrypted. Use HTTPS when available."].exists)
        let collapsed = XCTAttachment(screenshot: app.screenshot())
        collapsed.name = "iptv-setup-collapsed"
        collapsed.lifetime = .keepAlways
        add(collapsed)
        for _ in 0..<8 {
            if advanced.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        assertFocused(advanced)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(advanced.value as? String, "Expanded")
        assertFocused(advanced)
        let authentication = app.buttons["iptv-authentication"]
        XCTAssertTrue(authentication.exists, app.debugDescription)
        XCUIRemote.shared.press(.down)
        assertFocused(authentication)
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "iptv-setup-expanded"
        expanded.lifetime = .keepAlways
        add(expanded)
        XCUIRemote.shared.press(.select)
        let basic = app.cells.containing(.any, identifier: "Username and password").firstMatch
        XCTAssertTrue(basic.waitForExistence(timeout: 5), app.debugDescription)
        XCUIRemote.shared.press(.down)
        assertFocused(basic)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["Username"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["Password"].exists)
        assertFocused(authentication)
        XCUIRemote.shared.press(.up)
        assertFocused(advanced)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(advanced.value as? String, "Collapsed")
        assertFocused(advanced)
        XCTAssertFalse(authentication.exists)
        XCTAssertFalse(app.textFields["Guide URL (optional)"].exists)
    }

    private func assertFocused(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in
            element.exists && (element.hasFocus || element.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists)
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5),
            .completed, element.debugDescription, file: file, line: line
        )
    }
}
