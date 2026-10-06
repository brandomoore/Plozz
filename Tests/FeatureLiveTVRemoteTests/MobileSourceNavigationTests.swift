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
        capture("playlist-editor", in: app)
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
        assertInlineTitle("Sources", in: app)
        capture("source-list", in: app)

        for (identifier, title) in [
            ("live-tv-add-playlist", "IPTV source"),
            ("live-tv-add-server", "Media server"),
            ("live-tv-import-playlist", "Imported playlist")
        ] {
            tapVisible(app.buttons[identifier], in: app)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
            assertInlineTitle(title, in: app)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 5), app.debugDescription)
        }
        XCTAssertFalse(app.switches["live-tv-source-enabled-fixture"].exists)
        XCTAssertFalse(app.buttons["live-tv-remove-source-fixture"].exists)
        tapVisible(app.buttons["live-tv-source-details-fixture"], in: app)
        XCTAssertTrue(app.navigationBars["Fixture IPTV"].waitForExistence(timeout: 5))
        assertInlineTitle("Fixture IPTV", in: app)
        capture("source-controls", in: app)
        for (identifier, title) in [
            ("live-tv-source-scan-fixture", "Check channels"),
            ("live-tv-edit-source-fixture", "IPTV source"),
            ("live-tv-source-status-fixture", "Source details"),
            ("live-tv-source-guides-fixture", "Guide options")
        ] {
            tapVisible(app.buttons[identifier], in: app)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
            assertInlineTitle(title, in: app)
            if identifier == "live-tv-source-guides-fixture" {
                XCTAssertFalse(app.buttons["live-tv-guide-mapping-fixture"].exists,
                               "Guide correction must not be offered before any guide exists.")
            }
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Fixture IPTV"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 1 writes 0 requests 0")
        }
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(sources.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testCloseDoesNotSaveAndGuideControlsAppearOnlyAfterAddingAGuide() {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let playlist = app.buttons["live-tv-setup-playlist"]
        XCTAssertTrue(playlist.waitForExistence(timeout: 10))
        playlist.tap()
        let close = app.buttons["live-tv-close-sheet"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(close.label, "Close")
        XCTAssertFalse(app.buttons["Done"].exists)
        XCTAssertFalse(app.buttons["live-tv-remove-guide"].exists)
        XCTAssertEqual(app.textFields.matching(identifier: "XMLTV guide URL (optional)").count, 0)
        let add = app.buttons["live-tv-add-guide"]
        XCTAssertEqual(add.label, "Add guide")
        capture("new-playlist-sheet", in: app)
        add.tap()
        XCTAssertEqual(app.textFields.matching(identifier: "XMLTV guide URL (optional)").count, 1)
        XCTAssertEqual(add.label, "Add another guide")
        app.buttons["live-tv-remove-guide"].tap()
        XCTAssertEqual(add.label, "Add guide")
        XCTAssertFalse(app.buttons["live-tv-remove-guide"].exists)
        close.tap()
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 0 writes 0 requests 0")
    }

    @MainActor
    func testSourceRemovalRequiresConfirmationAndReturnsToTheList() {
        let app = XCUIApplication()
        app.launchArguments = ["--typed-sources", "--configured-sources", "--catalog-sources"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["fixture-sources"].waitForExistence(timeout: 10))
        app.buttons["fixture-sources"].tap()
        let source = app.buttons["live-tv-source-details-fixture"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        source.tap()
        tapVisible(app.buttons["live-tv-remove-source-fixture"], in: app)
        let confirmation = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Remove source", "live-tv-remove-source-fixture"
        )).firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 1 writes 0 requests 0")
        confirmation.tap()
        XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(source.exists)
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 0 writes 1 requests 0")
    }

    @MainActor
    func testFailedRemovalRetainsTheSourceAndShowsTheErrorOnItsPage() {
        let app = XCUIApplication()
        app.launchArguments = ["--typed-sources", "--configured-sources", "--source-save-fails"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["fixture-sources"].waitForExistence(timeout: 10))
        app.buttons["fixture-sources"].tap()
        tapVisible(app.buttons["live-tv-source-details-fixture"], in: app)
        tapVisible(app.buttons["live-tv-remove-source-fixture"], in: app)
        let confirmation = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Remove source", "live-tv-remove-source-fixture"
        )).firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        confirmation.tap()
        XCTAssertTrue(app.otherElements["live-tv-source-mutation-error"].waitForExistence(timeout: 5)
                      || app.staticTexts["live-tv-source-mutation-error"].exists, app.debugDescription)
        XCTAssertTrue(app.navigationBars["Fixture IPTV"].exists)
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 1 writes 0 requests 0")
    }

    @MainActor
    func testExistingGuidesRemainEditableAndMappingIsReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["--typed-sources", "--configured-sources", "--catalog-sources", "--source-guides"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["fixture-sources"].waitForExistence(timeout: 10))
        app.buttons["fixture-sources"].tap()
        tapVisible(app.buttons["live-tv-source-details-fixture"], in: app)
        tapVisible(app.buttons["live-tv-edit-source-fixture"], in: app)
        XCTAssertEqual(app.textFields.matching(identifier: "XMLTV guide URL (optional)").count, 1)
        XCTAssertEqual(app.textFields["XMLTV guide URL (optional)"].value as? String, "https://example.invalid/guide.xml")
        app.navigationBars.buttons.firstMatch.tap()
        tapVisible(app.buttons["live-tv-source-guides-fixture"], in: app)
        tapVisible(app.buttons["live-tv-guide-mapping-fixture"], in: app)
        XCTAssertTrue(app.navigationBars["Guide mapping"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Guide options"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["fixture-source-metrics"].label, "Sources 1 writes 0 requests 0")
    }

    @MainActor
    func testOnboardingChoicesFitPhoneAndAdaptToLargeTextAndRTL() {
        for arguments in [[], ["--setup-accessibility"], ["--rtl", "--light"]] {
            let app = XCUIApplication()
            app.launchArguments = ["--setup-cards"] + arguments
            app.launch()
            defer { app.terminate() }
            let cards = ["playlist", "server", "library"].map { app.buttons["live-tv-setup-\($0)"] }
            XCTAssertTrue(cards[0].waitForExistence(timeout: 10))
            XCTAssertLessThan(cards[0].frame.maxY, cards[1].frame.minY)
            if arguments.isEmpty {
                for card in cards {
                    XCTAssertTrue(card.isHittable)
                    XCTAssertLessThan(card.frame.maxY, app.frame.maxY - 34)
                    XCTAssertLessThan(card.frame.height, 200)
                }
            }
            for (card, action) in zip(cards, ["playlist", "server", "library"]) {
                tapVisible(card, in: app)
                XCTAssertEqual(app.staticTexts["fixture-setup-action"].label, action)
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "live-tv-onboarding-" + (arguments.isEmpty ? "standard" : arguments.joined(separator: "-"))
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func assertInlineTitle(_ title: String, in app: XCUIApplication) {
        let bar = app.navigationBars[title]
        let heading = bar.staticTexts[title].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(heading.frame.midX, bar.frame.midX, accuracy: 4, app.debugDescription)
        XCTAssertLessThanOrEqual(bar.frame.height, 64, "Subpages must not reserve a large-title block.")
        XCTAssertLessThanOrEqual(heading.frame.height, 32, "Subpages must use the native inline title font.")
    }

    @MainActor
    private func tapVisible(_ row: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 {
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : app.frame.minY + 50
            if row.isHittable, row.frame.minY >= top, row.frame.maxY <= app.frame.maxY - 40 { break }
            if row.frame.minY < top { app.scrollViews.firstMatch.swipeDown() }
            else { app.scrollViews.firstMatch.swipeUp() }
        }
        XCTAssertTrue(row.isHittable, app.debugDescription)
        row.tap()
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
