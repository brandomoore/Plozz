import XCTest

@MainActor
final class GuideVerticalNavigationRemoteTests: XCTestCase {
    func testVerticalBrowsingKeepsCurrentProgramsDespiteWideMovies() {
        let app = launchGuide()
        defer { app.terminate() }
        for row in 1..<7 {
            XCUIRemote.shared.press(.down)
            assertSelected("Current \(row)", in: app)
        }
        XCUIRemote.shared.press(.down)
        assertSelected("channel-7", in: app)
        for row in (0..<7).reversed() {
            XCUIRemote.shared.press(.up)
            assertSelected("Current \(row)", in: app)
        }
    }

    func testHorizontalBrowsingHandsOffToNativeUntilNowResetsIt() {
        let app = launchGuide()
        defer { app.terminate() }
        XCUIRemote.shared.press(.down)
        assertSelected("Current 1", in: app)
        XCUIRemote.shared.press(.right)
        assertSelected("Future 1.1", in: app)
        XCUIRemote.shared.press(.down)
        assertSelected("Future 2.1", in: app)
        for _ in 0..<12 where !app.buttons["guide-now"].hasFocus {
            XCUIRemote.shared.press(.up)
        }
        XCTAssertTrue(app.buttons["guide-now"].hasFocus)
        XCUIRemote.shared.press(.select)
        assertSelected("Current 0", in: app)
        XCUIRemote.shared.press(.down)
        assertSelected("Current 1", in: app)
    }

    private func launchGuide() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--guide-navigation-fixture"]
        app.launch()
        assertSelected("Current 0", in: app)
        return app
    }

    private func assertSelected(_ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let probe = app.staticTexts["guide-focus-probe"]
        let predicate = NSPredicate { _, _ in probe.exists && probe.label == title }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 8)
        if result != .completed {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "unexpected-guide-focus"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(result, .completed, "Expected \(title)", file: file, line: line)
    }
}
