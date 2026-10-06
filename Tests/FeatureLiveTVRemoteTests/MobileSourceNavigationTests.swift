import XCTest

final class MobileSourceNavigationTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPlaylistSelectionPushesOnlyItsEditorAndOneBackReturnsToSources() {
        let app = XCUIApplication()
        app.launchArguments = ["--typed-sources", "--configured-sources", "--catalog-sources"]
        app.launch()
        defer { app.terminate() }
        let entry = app.buttons["fixture-sources"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        let add = app.buttons["live-tv-add-playlist"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let action = app.buttons["live-tv-playlist-action"]
        XCTAssertTrue(action.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(action.label, "Add source", app.debugDescription)
        XCTAssertEqual(app.textFields["live-tv-playlist-url"].value as? String, "https://example.com/channels.m3u")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["live-tv-add-server"].exists)
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 1 writes 0 requests 0")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testSettingsSourceActionsEachPushOneDestination() {
        let app = XCUIApplication()
        app.launchArguments = ["--source-settings", "--configured-sources", "--catalog-sources"]
        app.launch()
        defer { app.terminate() }
        let sources = app.buttons["Sources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 10))
        sources.tap()
        XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 5))

        for (identifier, title) in [
            ("live-tv-add-playlist", "IPTV source"),
            ("live-tv-add-server", "Media server"),
            ("live-tv-import-playlist", "Imported playlist"),
            ("live-tv-source-scan-fixture", "Check channels"),
            ("live-tv-edit-source-fixture", "IPTV source"),
            ("live-tv-guide-mapping-fixture", "Guide mapping"),
            ("live-tv-source-details-fixture", "Source details")
        ] {
            let row = app.buttons[identifier]
            for _ in 0..<8 {
                let top = app.navigationBars.firstMatch.frame.maxY
                if row.isHittable, row.frame.minY >= top, row.frame.maxY <= app.frame.maxY - 70 { break }
                if row.frame.minY < top { app.scrollViews.firstMatch.swipeDown() }
                else { app.scrollViews.firstMatch.swipeUp() }
            }
            XCTAssertTrue(row.isHittable, "Missing source action \(identifier): \(app.debugDescription)")
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 1 writes 0 requests 0")
        }
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(sources.waitForExistence(timeout: 5), app.debugDescription)
    }
}
