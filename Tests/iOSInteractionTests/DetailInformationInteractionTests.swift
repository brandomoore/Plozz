import XCTest

@MainActor
final class DetailInformationInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        MainActor.assumeIsolated {
            app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            if let testRun, testRun.failureCount > 0 {
                let tree = XCTAttachment(string: app.debugDescription)
                tree.lifetime = .keepAlways
                add(tree)
            }
            app.terminate()
            app = nil
        }
        super.tearDown()
    }

    func testCastMoreIncludesPeopleOutsideThePreviewAndKeepsNavigation() {
        launch()
        reveal(app.buttons["detail-cast-more"])
        app.buttons["detail-cast-more"].tap()
        let last = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Person 40")).firstMatch
        reveal(last)
        last.tap()
        XCTAssertTrue(app.staticTexts["Person 40"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.navigationBars["Cast"].exists)
    }

    func testCrewMorePreservesTheLastDirector() {
        launch()
        let more = app.buttons["detail-crew-directors-more"]
        reveal(more)
        more.tap()
        XCTAssertTrue(app.navigationBars["Crew"].waitForExistence(timeout: 5), app.debugDescription)
        reveal(app.staticTexts["Director 60"])
        XCTAssertTrue(app.staticTexts["Director 60"].isHittable)
    }

    func testSingleLongValueGetsMoreWithoutAnOversizedList() {
        launch(["--detail-single-long-value"])
        let more = app.buttons["detail-details-original-title-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
        more.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5), app.debugDescription)
        let value = String(repeating: "A very long original title ", count: 40)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expandedValue = app.collectionViews.staticTexts
            .matching(NSPredicate(format: "label == %@", value)).firstMatch
        XCTAssertTrue(expandedValue.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func launch(_ options: [String] = []) {
        app.launchArguments = ["--detail-information-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + options
        app.launch()
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<12 where !element.exists || !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }
}
