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
        XCTAssertTrue(app.staticTexts["Living Room Server"].firstMatch.exists)
        let second = app.buttons["download-version-2"]
        XCTAssertEqual(second.value as? String, "Not selected")
        second.tap()
        XCTAssertEqual(second.value as? String, "Selected")
        capture("episode-download-versions")
        app.buttons["BackButton"].tap()
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

    func testDownloadedEpisodeRequiresConfirmationAndCancelKeepsTheCopy() {
        relaunch(["--downloaded-episode"])
        app.buttons["downloaded-episode"].tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(app.staticTexts["Remove this download from this device?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved copies: 2"].exists)
        if cancel.exists {
            cancel.tap()
        } else {
            app.otherElements["PopoverDismissRegion"].tap()
        }
        XCTAssertTrue(app.buttons["downloaded-episode"].exists)
        XCTAssertTrue(app.staticTexts["Saved copies: 2"].exists)
        XCTAssertTrue(app.staticTexts["Queued: 0"].exists)
    }

    func testConfirmedRemovalLeavesTheOtherSavedCopy() {
        relaunch(["--downloaded-episode"])
        app.buttons["downloaded-episode"].tap()
        let remove = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", "Remove Download", "downloaded-episode")
        ).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription)
        capture("episode-remove-download-confirmation")
        remove.tap()
        XCTAssertTrue(app.staticTexts["Saved copies: 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["downloaded-episode"].exists)
        XCTAssertTrue(app.staticTexts["Queued: 0"].exists)
    }

    func testUncheckingTheOnlyEpisodeDisablesDownload() {
        app.terminate()
        app.launchArguments.append("--single-download-episode")
        app.launch()
        app.buttons["Download Season"].tap()
        let confirm = app.buttons["confirm-download-selection"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.buttons["download-version-1"].tap()
        XCTAssertFalse(confirm.isEnabled)
        app.buttons["download-version-1"].tap()
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Queued: 1"].waitForExistence(timeout: 5))
    }

    func testAskOffAutomaticallyDownloadsSingleVersionEpisode() {
        relaunch(["--single-download-episode", "--one-download-version", "--download-ask-off", "--slow-download-preparation"])
        app.buttons["Download Season"].tap()
        XCTAssertTrue(app.staticTexts["Sheets: 0"].exists)
        XCTAssertFalse(app.staticTexts["Preparing Downloads"].exists)
        XCTAssertTrue(app.staticTexts["Queued: 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["confirm-download-selection"].exists)
        XCTAssertTrue(app.staticTexts["Sheets: 0"].exists)
    }

    func testAskOffAutomaticallyDownloadsSingleVersionMovie() {
        relaunch(["--download-movie", "--one-download-version", "--download-ask-off"])
        app.buttons["Download Season"].tap()
        XCTAssertTrue(app.staticTexts["Queued: 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["confirm-download-selection"].exists)
        XCTAssertTrue(app.staticTexts["Sheets: 0"].exists)
    }

    func testAlwaysAskStillConfirmsSingleVersion() {
        relaunch(["--single-download-episode", "--one-download-version"])
        app.buttons["Download Season"].tap()
        let confirm = app.buttons["confirm-download-selection"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Queued: 1"].exists)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Queued: 1"].waitForExistence(timeout: 5))
    }

    func testAutomaticPreparationErrorCanRetryWithoutPresentingASelectionSheet() {
        relaunch(["--single-download-episode", "--one-download-version", "--download-ask-off", "--fail-download-preparation"])
        app.buttons["Download Season"].tap()
        XCTAssertTrue(app.alerts["Download Failed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Queued: 0"].exists)
        app.alerts.buttons["Try Again"].tap()
        XCTAssertTrue(app.staticTexts["Queued: 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sheets: 0"].exists)
    }

    func testAutomaticSubmissionFailureIsVisibleWithoutOpeningASelectionSheet() {
        relaunch(["--single-download-episode", "--one-download-version", "--download-ask-off", "--fail-download-submit"])
        app.buttons["Download Season"].tap()
        XCTAssertTrue(app.alerts["Download Failed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["The file could not be saved."].exists)
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Download Season"].isEnabled)
        XCTAssertTrue(app.staticTexts["Queued: 0"].exists)
        XCTAssertTrue(app.staticTexts["Sheets: 0"].exists)
    }

    func testCancelledPreparationCannotQueueOrPresentLater() {
        relaunch(["--single-download-episode", "--one-download-version", "--download-ask-off",
                  "--slow-download-preparation", "--cancel-download-preparation"])
        app.buttons["Download Season"].tap()
        app.buttons["Cancel Preparation"].tap()
        XCTAssertFalse(app.staticTexts["Queued: 1"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Queued: 0"].exists)
        XCTAssertTrue(app.staticTexts["Sheets: 0"].exists)
        XCTAssertTrue(app.buttons["Download Season"].isEnabled)
    }

    func testAskOffStillConfirmsSeasonWithOneVersionPerEpisode() {
        relaunch(["--one-download-version", "--download-ask-off"])
        app.buttons["Download Season"].tap()
        XCTAssertTrue(app.buttons["confirm-download-selection"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Queued: 0"].waitForExistence(timeout: 5))
    }

    func testSingleEpisodeShowsVersionChoicesImmediatelyWithAskOff() {
        relaunch(["--single-download-episode", "--download-ask-off"])
        app.buttons["Download Season"].tap()
        XCTAssertTrue(app.buttons["confirm-download-selection"].waitForExistence(timeout: 5))
        let first = app.buttons["download-version-1"]
        let second = app.buttons["download-version-2"]
        XCTAssertTrue(first.exists)
        XCTAssertTrue(second.exists)
        XCTAssertTrue(app.staticTexts["Living Room Server"].firstMatch.exists)
        XCTAssertFalse(app.buttons["episode-versions-1-1"].exists)
        XCTAssertFalse(app.staticTexts["Season 1"].exists)
        second.tap()
        XCTAssertEqual(first.value as? String, "Selected")
        XCTAssertEqual(second.value as? String, "Selected")
        capture("single-episode-download-versions")
        app.buttons["confirm-download-selection"].tap()
        XCTAssertTrue(app.staticTexts["Queued: 2"].waitForExistence(timeout: 5))
    }

    func testSeasonWithOneEpisodeStillUsesTheNestedVersionPage() {
        relaunch(["--single-download-episode", "--bulk-download"])
        app.buttons["Download Season"].tap()
        let episode = app.buttons["episode-versions-1-1"]
        XCTAssertTrue(episode.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["download-version-1"].exists)
        episode.tap()
        XCTAssertTrue(app.buttons["download-version-1"].waitForExistence(timeout: 5))
    }

    func testMovieVersionChoicesRemainExclusiveWithAskOff() {
        relaunch(["--download-movie", "--download-ask-off"])
        app.buttons["Download Season"].tap()
        let first = app.buttons["download-version-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        app.buttons["download-version-2"].tap()
        XCTAssertEqual(first.value as? String, "Not selected")
        XCTAssertEqual(app.buttons["download-version-2"].value as? String, "Selected")
        app.buttons["confirm-download-selection"].tap()
        XCTAssertTrue(app.staticTexts["Queued: 1"].waitForExistence(timeout: 5))
    }

    private func relaunch(_ arguments: [String]) {
        app.terminate()
        app.launchArguments = ["--download-selection-fixture"] + arguments
        app.launch()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
