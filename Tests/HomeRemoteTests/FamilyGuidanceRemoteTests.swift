import XCTest

@MainActor
final class FamilyGuidanceRemoteTests: XCTestCase {
    func testRatingTileOpensGuidanceAndReturnsFocus() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Ratings"].exists)
        let tile = app.descendants(matching: .any)["family-guidance-tile"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "family-guidance-rating-tile"
        before.lifetime = .keepAlways
        add(before)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["What parents need to know"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Recommended age: 16+"].exists)
        XCTAssertTrue(app.staticTexts["Content guidance"].exists)
        let sheet = XCTAttachment(screenshot: app.screenshot())
        sheet.name = "family-guidance-detail-sheet"
        sheet.lifetime = .keepAlways
        add(sheet)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["What parents need to know"].waitForExistence(timeout: 5))
    }

    func testFailedGuidanceOffersRetryWithoutLosingBasicRating() {
        let app = launch(extra: "--family-guidance-failure")
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        let retry = app.buttons["Retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Common Sense Media"].exists)
        for _ in 0..<6 where !retry.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(retry.hasFocus)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["What parents need to know"].waitForExistence(timeout: 5))
    }

    func testRestrictedGuidanceDoesNotPretendTheContentIsSafe() {
        let app = launch(extra: "--family-guidance-restricted")
        defer { app.terminate() }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts[
            "Detailed guidance requires Plex Pass access for the account viewing this title."
        ].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Content guidance"].exists)
    }

    private func launch(extra: String? = nil) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--family-guidance-fixture"] + (extra.map { [$0] } ?? [])
        app.launch()
        XCTAssertTrue(app.staticTexts["family-guidance-fixture-ready"].waitForExistence(timeout: 15))
        return app
    }
}
