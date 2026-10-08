import XCTest

@MainActor
final class DownloadsInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--downloads-interaction-fixture"]
        app.launch()
    }

    override func tearDown() async throws {
        if app.state == .runningForeground {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.terminate()
        app = nil
        try await super.tearDown()
    }

    func testLibraryMenuAndShowNavigationHaveSeparateTapTargets() {
        XCTAssertTrue(app.buttons["Pause All"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThanOrEqual(app.buttons["Pause All"].frame.height, 60)
        let list = app.collectionViews.firstMatch
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Andor")).firstMatch
        for _ in 0..<8 {
            if show.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(show.isHittable, app.debugDescription)
        let menu = app.buttons["More actions for Andor"]
        XCTAssertGreaterThanOrEqual(menu.frame.width, 44)
        XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
        menu.tap()
        XCTAssertTrue(app.buttons["Pause Show"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars["Andor"].exists, "Opening the menu must not navigate.")
        app.buttons["Pause Show"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
        show.tap()
        XCTAssertTrue(app.navigationBars["Andor"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Season 2"].exists)
        XCTAssertTrue(app.staticTexts["E1 · One Year Later"].exists)
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists, "One tap must push only one page.")
    }

    func testEpisodeActionsDoNotNavigateAndSeasonRemovalRequiresConfirmation() throws {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Andor")).firstMatch
        for _ in 0..<8 {
            if show.isHittable { break }
            list.swipeUp()
        }
        show.tap()
        let episodeMenu = app.buttons["More actions for One Year Later"]
        XCTAssertTrue(episodeMenu.waitForExistence(timeout: 3), app.debugDescription)
        episodeMenu.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        let pause = try XCTUnwrap(app.buttons.matching(
            NSPredicate(format: "label == %@", "Pause")
        ).allElementsBoundByIndex.last(where: \.isHittable))
        pause.tap()
        XCTAssertTrue(app.navigationBars["Andor"].exists)
        XCTAssertTrue(app.staticTexts["E2 · Episode 2"].exists)
        app.buttons["More actions"].tap()
        app.buttons["Remove"].tap()
        XCTAssertTrue(app.buttons["Remove 3 Episodes"].waitForExistence(timeout: 3), app.debugDescription)
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            app.otherElements["PopoverDismissRegion"].tap()
        }
        XCTAssertTrue(app.staticTexts["E2 · Episode 2"].exists)
        app.buttons["More actions"].tap()
        app.buttons["Remove"].tap()
        let confirmation = app.buttons["Remove 3 Episodes"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["More actions for Andor"].exists)
    }
}
