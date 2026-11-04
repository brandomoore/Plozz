import XCTest

@MainActor
final class DownloadSelectionInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--download-selection-fixture"]
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
        try await super.tearDown()
    }

    func testDefaultSheetKeepsFifteenVersionsCollapsedAndQueuesTenNotOneHundredFifty() {
        app.buttons["Download Season"].tap()
        let confirm = app.buttons["confirm-download-selection"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Season 1"].exists)
        XCTAssertTrue(app.staticTexts["First Light"].exists)
        XCTAssertTrue(app.staticTexts["15 versions"].firstMatch.exists)
        XCTAssertFalse(app.buttons["download-version-1"].exists)
        capture("episode-download-selection")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Queued: 10"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func testVersionSelectionAllowsAdditionalCopiesAndEpisodeToggleOnlyChangesThatEpisode() {
        app.buttons["Download Season"].tap()
        let episode = app.buttons["episode-versions-1-1"]
        XCTAssertTrue(episode.waitForExistence(timeout: 5), app.debugDescription)
        episode.tap()
        let first = app.buttons["download-version-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(first.value as? String, "Selected")
        let second = app.buttons["download-version-2"]
        XCTAssertEqual(second.value as? String, "Not selected")
        second.tap()
        XCTAssertEqual(second.value as? String, "Selected")
        capture("episode-download-versions")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["2 versions selected"].waitForExistence(timeout: 3))
        app.buttons["select-episode-1-2"].tap()
        XCTAssertFalse(app.buttons["download-version-1"].exists, "The checkbox must not open the version page.")
        app.buttons["confirm-download-selection"].tap()
        XCTAssertTrue(app.staticTexts["Queued: 10"].waitForExistence(timeout: 5))
    }

    func testCancelDoesNotQueueAnything() {
        app.buttons["Download Season"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.staticTexts["Queued: 0"].waitForExistence(timeout: 5))
    }

    func testUncheckingTheOnlyEpisodeDisablesDownload() {
        app.terminate()
        app.launchArguments.append("--single-download-episode")
        app.launch()
        app.buttons["Download Season"].tap()
        let confirm = app.buttons["confirm-download-selection"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.buttons["select-episode-1-1"].tap()
        XCTAssertFalse(confirm.isEnabled)
        app.buttons["select-episode-1-1"].tap()
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Queued: 1"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
