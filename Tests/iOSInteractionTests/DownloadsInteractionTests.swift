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
        XCTAssertFalse(app.buttons["download-open-in"].exists, "Show menus must not export multiple files.")
        XCTAssertFalse(app.navigationBars["Andor"].exists, "Opening the menu must not navigate.")
        app.buttons["Pause Show"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
        show.tap()
        XCTAssertTrue(app.navigationBars["Andor"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Season 2"].exists)
        XCTAssertTrue(app.staticTexts["E1 · One Year Later"].exists)
        backButton(to: "Downloads").tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 3))
        XCTAssertFalse(backButton(to: "Downloads").exists, "One tap must push only one page.")
    }

    func testCompletedRowsUseDownloadSymbolsWithoutCompletionCopyOrChevrons() {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let row = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Downloaded Show 12"
        )).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(row.label.contains("Downloaded"), row.label)
        XCTAssertFalse(row.label.contains("Available offline"), row.label)
        XCTAssertTrue(row.label.contains("100 MB"), row.label)
        XCTAssertFalse(list.images["chevron.right"].exists)
        XCTAssertFalse(list.images["chevron.forward"].exists)
        row.tap()
        XCTAssertTrue(app.navigationBars["Downloaded Show 12"].waitForExistence(timeout: 3))
        let episode = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "E12 · Episode 12"
        )).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(episode.label.contains("Downloaded"), episode.label)
        XCTAssertFalse(episode.label.contains("Available offline"), episode.label)
        XCTAssertTrue(episode.label.contains("100 MB"), episode.label)
        XCTAssertFalse(list.images["chevron.right"].exists)
    }

    func testCompletedEpisodeMenuKeepsDownloadsInPlozzWithoutOpeningDetails() {
        let show = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Downloaded Show 12"
        )).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 10), app.debugDescription)
        show.tap()
        let menu = app.buttons["More actions for Episode 12"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3), app.debugDescription)
        menu.tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["download-open-in"].exists, "Downloaded episodes must not offer file export.")
        XCTAssertFalse(app.buttons["Open in…"].exists)
        XCTAssertTrue(app.navigationBars["Downloaded Show 12"].exists)
    }

    func testCompletedMovieMenuKeepsDownloadsInPlozzWithoutOpeningDetails() {
        app.terminate()
        app.launchArguments = ["--downloads-interaction-fixture", "--download-movie"]
        app.launch()
        let menu = app.buttons["More actions for Downloaded Movie"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["download-open-in"].exists, "Downloaded movies must not offer file export.")
        XCTAssertFalse(app.buttons["Open in…"].exists)
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
    }

    func testEpisodeArtworkAlignsWithSeasonHeadingsInBothCardStyles() {
        for framed in [false, true] {
            app.terminate()
            app.launchArguments = ["--downloads-interaction-fixture"]
            if framed { app.launchArguments.append("--framed-downloads") }
            app.launch()
            let show = app.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@", "Downloaded Show 12"
            )).firstMatch
            XCTAssertTrue(show.waitForExistence(timeout: 10), app.debugDescription)
            show.tap()
            let heading = app.staticTexts["Season 2"]
            XCTAssertTrue(heading.waitForExistence(timeout: 3))
            let episode = app.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@", "E12 · Episode 12"
            )).firstMatch
            let artwork = episode.images["tv"]
            XCTAssertTrue(artwork.exists, app.debugDescription)
            XCTAssertEqual(
                artwork.frame.minX, heading.frame.minX, accuracy: 2,
                "The artwork edge must align with the heading, allowing its thin media-edge stroke."
            )
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = framed ? "aligned-framed-downloads" : "aligned-borderless-downloads"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
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
        XCTAssertFalse(app.buttons["download-open-in"].exists, "Incomplete downloads cannot be exported.")
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

    func testCompletedEpisodeDetailsRemainNavigableAcrossRepeatedPushes() {
        app.terminate()
        app.launchArguments = ["--downloads-interaction-fixture", "--download-details"]
        app.launch()
        for _ in 0..<4 {
            let show = app.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@", "Downloaded Show 12"
            )).firstMatch
            XCTAssertTrue(show.waitForExistence(timeout: 10), app.debugDescription)
            show.tap()
            XCTAssertTrue(app.navigationBars["Downloaded Show 12"].waitForExistence(timeout: 3))
            let episode = app.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@", "E12 · Episode 12"
            )).firstMatch
            XCTAssertTrue(episode.waitForExistence(timeout: 3), app.debugDescription)
            episode.tap()
            XCTAssertTrue(
                app.staticTexts["Downloaded episode fixture details."].waitForExistence(timeout: 5),
                app.debugDescription
            )
            backButton(to: "Downloaded Show 12").tap()
            XCTAssertTrue(app.navigationBars["Downloaded Show 12"].waitForExistence(timeout: 3))
            backButton(to: "Downloads").tap()
            XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 3))
        }
    }

    private func backButton(to title: String) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR label == %@",
            "BackButton", title, "Back"
        )).firstMatch
    }
}
