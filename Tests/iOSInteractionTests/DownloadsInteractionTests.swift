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

    func testDownloadingShowLongPressOpensShowDetails() {
        app.terminate()
        app.launchArguments = ["--downloads-interaction-fixture", "--download-details"]
        app.launch()
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Andor")).firstMatch
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        for _ in 0..<8 {
            if show.isHittable { break }
            list.swipeUp()
        }
        XCTAssertTrue(show.isHittable, app.debugDescription)
        show.press(forDuration: 1)
        let goToShow = app.buttons["Go to Show"]
        XCTAssertTrue(goToShow.waitForExistence(timeout: 3), app.debugDescription)
        goToShow.tap()
        XCTAssertTrue(app.staticTexts["Downloaded show fixture details."].waitForExistence(timeout: 5))
        backButton(to: "Downloads").tap()
        let menu = app.buttons["More actions for Andor"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        XCTAssertTrue(app.buttons["Pause Show"].waitForExistence(timeout: 3),
                      "Navigation must not pause the active download.")
    }

    func testMovieLongPressOpensDetailsDuringAndAfterDownload() {
        for active in [true, false] {
            app.terminate()
            app.launchArguments = ["--downloads-interaction-fixture", "--download-details", "--download-movie"]
            if active { app.launchArguments.append("--download-active") }
            app.launch()
            let movie = app.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@", "Downloaded Movie"
            )).firstMatch
            XCTAssertTrue(movie.waitForExistence(timeout: 10), app.debugDescription)
            movie.press(forDuration: 1)
            let goToMovie = app.buttons["Go to Movie"]
            XCTAssertTrue(goToMovie.waitForExistence(timeout: 3), app.debugDescription)
            goToMovie.tap()
            XCTAssertTrue(app.staticTexts["Downloaded movie fixture details."].waitForExistence(timeout: 5))
            backButton(to: "Downloads").tap()
            if active { XCTAssertTrue(app.buttons["Pause All"].exists) }
        }
    }

    func testDownloadedShowEpisodeMenusOpenShowDetailsInBothModes() {
        app.terminate()
        app.launchArguments = ["--downloads-interaction-fixture", "--download-details"]
        app.launch()
        let show = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Downloaded Show 12"
        )).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 10), app.debugDescription)
        show.tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 3), app.debugDescription)
        let title = showPage("Downloaded Show 12")
        XCTAssertTrue(title.exists)
        XCTAssertFalse(title.frame.intersects(backButton(to: "Downloads").frame))
        let navigationBar = app.navigationBars.firstMatch
        if navigationBar.frame.width > navigationBar.frame.height {
            XCTAssertGreaterThanOrEqual(title.frame.minY, navigationBar.frame.maxY)
        }
        app.buttons["Edit"].tap()
        title.tap()
        XCTAssertFalse(app.buttons["download-remove-selected"].isEnabled,
                       "The page title must not be selectable.")
        app.buttons["download-edit-cancel"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(app.staticTexts["Season 2"].frame.minY, title.frame.maxY)
        XCTAssertTrue(app.buttons["More actions for Episode 12"].isHittable)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "download-show-normal-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "download-show-scrolling-title"
        attachment.lifetime = .keepAlways
        add(attachment)
        for editing in [false, true] {
            if editing { app.buttons["Edit"].tap() }
            app.buttons["More actions for Episode 12"].tap()
            let goToShow = app.buttons["Go to Show"]
            XCTAssertTrue(goToShow.waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertTrue(app.buttons["Play"].exists)
            XCTAssertTrue(app.buttons["Remove Download"].exists)
            goToShow.tap()
            XCTAssertTrue(app.staticTexts["Downloaded show fixture details."].waitForExistence(timeout: 5))
            backButton(to: "Downloaded Show 12").tap()
            XCTAssertTrue(app.staticTexts["E12 · Episode 12"].waitForExistence(timeout: 3))
        }
    }

    func testEditSelectsAcrossSeasonsAndConfirmsOnlySelectedDownloads() {
        openEditableShow()
        app.buttons["Edit"].tap()
        let remove = app.buttons["download-remove-selected"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        XCTAssertFalse(remove.isEnabled)
        app.staticTexts["E1 · One Year Later"].tap()
        app.staticTexts["E3 · Episode 3"].tap()
        XCTAssertTrue(remove.isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "download-edit-multiselect"
        attachment.lifetime = .keepAlways
        add(attachment)
        remove.tap()
        XCTAssertTrue(app.buttons["Remove 2 Downloads"].waitForExistence(timeout: 3))
        dismissRemovalConfirmation()
        XCTAssertTrue(app.staticTexts["E1 · One Year Later"].exists)
        remove.tap()
        app.buttons["Remove 2 Downloads"].tap()
        XCTAssertTrue(app.staticTexts["E1 · One Year Later"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["E3 · Episode 3"].exists)
        XCTAssertTrue(app.staticTexts["E2 · Episode 2"].exists)
        XCTAssertFalse(remove.isEnabled)
        app.buttons["Select All"].tap()
        remove.tap()
        XCTAssertTrue(app.buttons["Remove 1 Downloads"].waitForExistence(timeout: 3))
        app.buttons["Remove 1 Downloads"].tap()
        XCTAssertTrue(app.staticTexts["No Downloads"].waitForExistence(timeout: 5))
    }

    func testDownloadedShowCancelStaysOnTheNativeNavigationEdge() {
        openEditableShow()
        let back = backButton(to: "Downloads")
        XCTAssertTrue(back.isHittable, app.debugDescription)
        let navigationIsOnRight = back.frame.midX > app.frame.midX
        let normal = XCTAttachment(screenshot: app.screenshot())
        normal.name = "download-native-back"
        normal.lifetime = .keepAlways
        add(normal)
        app.buttons["Edit"].tap()
        let cancel = app.buttons["download-edit-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(cancel.isHittable)
        XCTAssertEqual(cancel.frame.midX > app.frame.midX, navigationIsOnRight,
                       "Cancel must use the same native navigation edge as Back.")
        XCTAssertFalse(cancel.frame.intersects(showPage("Andor").frame))
        let editing = XCTAttachment(screenshot: app.screenshot())
        editing.name = "download-native-cancel"
        editing.lifetime = .keepAlways
        add(editing)
        cancel.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        back.tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 3))
    }

    func testEditCancelClearsSelectionAndItemRemovalKeepsOtherDownloads() {
        openEditableShow()
        app.buttons["Edit"].tap()
        app.buttons["Select All"].tap()
        app.buttons["download-edit-cancel"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 3))
        app.buttons["Edit"].tap()
        XCTAssertFalse(app.buttons["download-remove-selected"].isEnabled)
        app.staticTexts["E2 · Episode 2"].tap()
        app.buttons["More actions for Episode 2"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
        app.buttons["Remove Download"].tap()
        XCTAssertTrue(app.staticTexts["E2 · Episode 2"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["download-remove-selected"].isEnabled)
        XCTAssertTrue(app.staticTexts["E1 · One Year Later"].exists)
        XCTAssertTrue(app.staticTexts["E3 · Episode 3"].exists)
        app.buttons["Select All"].tap()
        app.buttons["download-remove-selected"].tap()
        XCTAssertTrue(app.buttons["Remove 2 Downloads"].waitForExistence(timeout: 3))
    }

    func testEpisodePlayMenuPresentsPlayerInBothModes() {
        openEditableShow()
        for editing in [false, true] {
            if editing { app.buttons["Edit"].tap() }
            app.buttons["More actions for Episode 2"].tap()
            let play = app.buttons["Play"]
            XCTAssertTrue(play.waitForExistence(timeout: 3))
            XCTAssertTrue(play.isEnabled)
            play.tap()
            let close = app.buttons["Close player"]
            XCTAssertTrue(close.waitForExistence(timeout: 10), app.debugDescription)
            close.tap()
            XCTAssertTrue(showPage("Andor").waitForExistence(timeout: 5))
        }
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
        XCTAssertFalse(showPage("Andor").exists, "Opening the menu must not navigate.")
        app.buttons["Pause Show"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
        for _ in 0..<8 {
            if show.isHittable { break }
            list.swipeDown()
        }
        show.tap()
        XCTAssertTrue(showPage("Andor").waitForExistence(timeout: 3), app.debugDescription)
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
        XCTAssertTrue(showPage("Downloaded Show 12").waitForExistence(timeout: 3))
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
        XCTAssertTrue(app.buttons["Remove Download"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["download-open-in"].exists, "Downloaded episodes must not offer file export.")
        XCTAssertFalse(app.buttons["Open in…"].exists)
        XCTAssertTrue(showPage("Downloaded Show 12").exists)
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
        XCTAssertTrue(showPage("Andor").exists)
        XCTAssertTrue(app.staticTexts["E2 · Episode 2"].exists)
        app.collectionViews.buttons["More actions"].tap()
        app.buttons["Remove"].tap()
        XCTAssertTrue(app.buttons["Remove 3 Episodes"].waitForExistence(timeout: 3), app.debugDescription)
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            app.otherElements["PopoverDismissRegion"].tap()
        }
        XCTAssertTrue(app.staticTexts["E2 · Episode 2"].exists)
        app.collectionViews.buttons["More actions"].tap()
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
            XCTAssertTrue(showPage("Downloaded Show 12").waitForExistence(timeout: 3))
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
            XCTAssertTrue(showPage("Downloaded Show 12").waitForExistence(timeout: 3))
            backButton(to: "Downloads").tap()
            XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 3))
        }
    }

    private func openEditableShow() {
        app.terminate()
        app.launchArguments = ["--downloads-interaction-fixture", "--download-details", "--download-edit"]
        app.launch()
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Andor")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 10))
        show.tap()
        XCTAssertTrue(showPage("Andor").waitForExistence(timeout: 5), app.debugDescription)
    }

    private func showPage(_ title: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ AND label == %@", "download-show-title", title
        )).firstMatch
    }

    private func dismissRemovalConfirmation() {
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            app.otherElements["PopoverDismissRegion"].tap()
        }
    }

    private func backButton(to title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR label == %@",
            "BackButton", title, "Back"
        )).firstMatch
    }
}
