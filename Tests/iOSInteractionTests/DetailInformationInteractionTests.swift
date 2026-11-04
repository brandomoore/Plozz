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

    func testFamilyGuidanceTileOpensAndDismissesItsDetails() {
        launch(["--detail-layout-guidance"])
        checkGuidanceSheet()
    }

    func testCompactFamilyGuidanceTileKeepsItsFullDetails() {
        launch(["--detail-layout-ratings-1-guide"])
        checkGuidanceSheet()
    }

    func testStackedRatingGridUsesTheFullContentWidth() {
        launch(["--detail-layout-ratings-5-guide"])
        let guide = app.buttons["family-guidance-tile"]
        reveal(guide)
        XCTAssertEqual(guide.frame.maxX, app.frame.maxX - 24, accuracy: 1,
                       "The last grid row must reach the same trailing inset as the other sections.")
    }

    func testSpoilerProtectionCoversTheEntireRatingGridUntilRevealed() {
        launch(["--detail-layout-ratings-1-guide", "--detail-layout-hide-ratings"])
        let prompt = app.buttons["Show Ratings"]
        let score = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail-rating-")).firstMatch
        reveal(prompt)
        XCTAssertFalse(score.exists)
        XCTAssertFalse(app.buttons["family-guidance-tile"].isHittable)
        prompt.tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        XCTAssertTrue(score.waitForExistence(timeout: 5))
        checkGuidanceSheet()
    }

    private func checkGuidanceSheet() {
        let tile = app.buttons["family-guidance-tile"]
        reveal(tile)
        tile.tap()
        let sheet = app.navigationBars["Family guidance"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "language"))
            .firstMatch.waitForExistence(timeout: 5), "The compact tile must retain its full guidance in the sheet.")
        sheet.buttons["Done"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(tile.isHittable)
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
