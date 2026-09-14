import XCTest

@MainActor
final class DetailReturnFocusRemoteTests: XCTestCase {
    func testRepeatedDetailVisitsReturnToTheSelectedHomeCard() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--production-home-fixture", "--pinned-home"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Production Home ready"].waitForExistence(timeout: 30))
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        XCTAssertTrue(hero.hasFocus)
        XCTAssertFalse(app.buttons["Navigation"].isEnabled, "Navigation must start closed while Home receives focus.")
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 1)
        XCUIRemote.shared.press(.down)
        Thread.sleep(forTimeInterval: 1)
        assertFocused("Fixture movie 24", in: app)
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.right)
        assertFocused("Fixture movie 26", in: app)
        for visit in 0..<5 {
            if visit == 3 { XCUIRemote.shared.press(.left) }
            let title = visit < 3 ? "Fixture movie 26" : "Fixture movie 25"
            assertFocused(title, in: app)
            XCUIRemote.shared.press(.select)
            let opened = app.staticTexts["Detail fixture \(title)"].waitForExistence(timeout: 10)
            if !opened {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "failed-detail-open"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            XCTAssertTrue(opened)
            Thread.sleep(forTimeInterval: 2)
            XCUIRemote.shared.press(.menu)
            assertFocused(title, in: app)
            XCTAssertFalse(app.buttons["Navigation"].isEnabled)
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "home-focus-after-repeated-detail-visits"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func assertFocused(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        let predicate = NSPredicate { _, _ in focused.exists && focused.staticTexts[title].exists }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5)
        if result != .completed {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "failed-return-focus-\(title)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(result, .completed, "Expected focus on \(title)", file: file, line: line)
    }
}
