import XCTest

@MainActor
final class SearchKeyboardInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    private var results: XCUIElement {
        app.scrollViews.containing(.staticText, identifier: "Keyboard result 01").firstMatch
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
    }

    override func tearDown() {
        if let testRun, testRun.failureCount > 0 {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testBlankSpaceDismissesKeyboardBeforeEnteringQuery() {
        let field = launch()
        focus(field)
        tapBelowHeader(field)
        assertKeyboardDismissed()
        XCTAssertFalse(app.buttons["Clear search"].exists)
        focus(field)
        field.typeText("empty")
        XCTAssertEqual(field.value as? String, "empty")
    }

    func testContentTapPreservesQueryAcrossSearchStates() {
        for (query, marker) in [
            ("empty", "No Results"), ("slow", "Searching"),
            ("failed", "Search unavailable"), ("result", "Keyboard result 01")
        ] {
            let field = launch()
            focus(field)
            field.typeText(query)
            XCTAssertTrue(app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", marker)
            ).firstMatch.waitForExistence(timeout: 8), app.debugDescription)
            if query == "result" {
                // The native scroll view's horizontal gutter is outside the result card.
                results.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.15)).tap()
            } else {
                tapBelowHeader(field)
            }
            assertKeyboardDismissed()
            XCTAssertEqual(field.value as? String, query)
            app.terminate()
        }
    }

    func testFieldAndClearButtonKeepKeyboardAvailable() {
        let field = launch()
        focus(field)
        field.typeText("empty")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        field.typeText("result")
        XCTAssertEqual(field.value as? String, "result")
    }

    func testRetryStillRunsOnTheFirstTap() {
        let field = launch()
        focus(field)
        field.typeText("retry")
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        retry.tap()
        XCTAssertTrue(app.staticTexts["Keyboard result 01"].waitForExistence(timeout: 8))
        assertKeyboardDismissed()
        XCTAssertEqual(field.value as? String, "retry")
    }

    func testResultStillOpensOnTheFirstTap() {
        let field = launch()
        focus(field)
        field.typeText("result")
        let result = app.staticTexts["Keyboard result 01"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8))
        result.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(field.wait(for: \.exists, toEqual: false, timeout: 5), app.debugDescription)
        assertKeyboardDismissed()
    }

    func testScrollingDismissesKeyboardWithoutClearingQuery() {
        let field = launch()
        focus(field)
        field.typeText("many")
        XCTAssertTrue(app.staticTexts["Keyboard result 01"].waitForExistence(timeout: 8))
        results.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)
            ))
        assertKeyboardDismissed()
        XCTAssertEqual(field.value as? String, "many")
    }

    func testSettingsButtonStillOpensOnTheFirstTap() {
        let field = launch()
        focus(field)
        app.buttons["search-settings-avatar"].tap()
        XCTAssertTrue(app.staticTexts["search-fixture-settings"].waitForExistence(timeout: 5))
    }

    @discardableResult
    private func launch() -> XCUIElement {
        app.launchArguments = ["--search-keyboard-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let field = app.textFields["Search your libraries"]
        XCTAssertTrue(field.wait(for: \.isHittable, toEqual: true, timeout: 10), app.debugDescription)
        return field
    }

    private func focus(_ field: XCUIElement) {
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func tapBelowHeader(_ field: XCUIElement) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 40)).tap()
    }

    private func assertKeyboardDismissed() {
        XCTAssertTrue(app.keyboards.firstMatch.wait(for: \.exists, toEqual: false, timeout: 5))
    }
}
