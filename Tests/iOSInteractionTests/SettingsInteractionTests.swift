import XCTest

@MainActor
final class SettingsInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
    }

    override func tearDown() {
        if let testRun, testRun.failureCount > 0, app.state == .runningForeground {
            capture("failure")
        }
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testSettingsTabKeepsTheCurrentPageAndNavigationStack() {
        verifyNavigationRetention(directPresentation: false)
    }

    func testDirectSettingsPresentationKeepsTheCurrentPageAndNavigationStack() {
        verifyNavigationRetention(directPresentation: true)
    }

    func testReorderedSettingsTabKeepsTheCurrentPageAndNavigationStack() {
        verifyNavigationRetention(directPresentation: false, settingsFirst: true)
    }

    private func verifyNavigationRetention(directPresentation: Bool, settingsFirst: Bool = false) {
        launchNavigation(directPresentation: directPresentation, settingsFirst: settingsFirst)
        let settings = directPresentation
            ? app.buttons["fixture-open-settings"] : app.buttons["gearshape"].firstMatch
        let downloads = app.buttons["arrow.down.circle"].firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 10), app.debugDescription)
        settings.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["house"].firstMatch.isSelected)
        app.buttons["Close"].tap()
        downloads.tap()
        XCTAssertTrue(app.buttons["Download Settings"].waitForExistence(timeout: 5))

        for iteration in 0..<2 {
            settings.tap()
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5), app.debugDescription)
            capture("settings-over-downloads-\(iteration)")
            XCTAssertTrue(downloads.isSelected, "Settings must not replace the selected content tab.")
            app.buttons["Close"].tap()
            XCTAssertTrue(app.buttons["Download Settings"].waitForExistence(timeout: 5))
        }

        app.buttons["Download Settings"].tap()
        let back = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        app.collectionViews.firstMatch.swipeUp()
        let retainedRow = app.switches["Download Failed"]
        XCTAssertTrue(retainedRow.isHittable)
        capture("before-settings-over-pushed-downloads")
        let retainedY = retainedRow.frame.minY
        settings.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        capture("settings-over-pushed-downloads")
        XCTAssertTrue(downloads.isSelected)
        app.buttons["Close"].tap()
        XCTAssertTrue(back.waitForExistence(timeout: 5), "The pushed page must survive the drawer.")
        XCTAssertEqual(retainedRow.frame.minY, retainedY, accuracy: 2, "Closing Settings must retain scroll position.")
        back.tap()
        XCTAssertTrue(app.buttons["Download Settings"].waitForExistence(timeout: 5))
    }

    func testSettingsFromMoreKeepsTheMorePage() throws {
        launchNavigation(settingsInMore: true)
        let more = app.tabBars.buttons["More"]
        try XCTSkipIf(app.windows.firstMatch.frame.width >= 600, "Regular-width iPad has direct tabs.")
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
        button("Settings").tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        capture("settings-over-more")
        XCTAssertTrue(more.isSelected)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
        XCTAssertTrue(more.isSelected)
    }

    func testCardsRowNavigatesWithoutOpeningDisplaySize() {
        launch()
        let cards = app.buttons["appearance-cards"]
        XCTAssertTrue(cards.waitForExistence(timeout: 5), app.debugDescription)
        cards.tap()
        capture("after-tapping-cards")
        XCTAssertTrue(app.navigationBars["Cards"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["card-labels-off"].exists)
        XCTAssertFalse(app.buttons["Micro"].exists)
        XCTAssertFalse(app.buttons["Huge"].exists)
    }

    func testDisplaySizeRemainsAnIndependentMenu() {
        launch()
        let size = app.buttons["appearance-display-size"]
        XCTAssertTrue(size.waitForExistence(timeout: 5), app.debugDescription)
        size.tap()
        XCTAssertTrue(app.buttons["Small"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["Small"].tap()
        XCTAssertTrue(app.navigationBars["Appearance"].exists)
        XCTAssertTrue(size.staticTexts["Small"].exists, app.debugDescription)
        app.buttons["appearance-cards"].tap()
        XCTAssertTrue(app.navigationBars["Cards"].waitForExistence(timeout: 3), app.debugDescription)
    }

    func testCardsOpenFromTheFullSettingsNavigation() {
        openSettingsPage("Appearance")
        app.buttons["appearance-cards"].tap()
        XCTAssertTrue(app.navigationBars["Cards"].waitForExistence(timeout: 3), app.debugDescription)
        assertInlineTitle("Cards")
        XCTAssertFalse(app.buttons["Micro"].exists)
    }

    func testMetadataArtworkLinkReturnsWithoutStackingDuplicatePages() {
        openSettingsPage("Metadata Providers", verifyTitleLayout: false)
        let hadBackButton = app.navigationBars.buttons["BackButton"].exists
        for _ in 0..<2 {
            let artwork = app.buttons["metadata-artwork-preferences"]
            XCTAssertTrue(artwork.waitForExistence(timeout: 5), app.debugDescription)
            reveal(artwork)
            artwork.tap()
            XCTAssertTrue(app.navigationBars["Artwork"].waitForExistence(timeout: 5), app.debugDescription)
            let metadata = app.buttons["artwork-metadata-providers"]
            reveal(metadata)
            metadata.tap()
            XCTAssertTrue(app.navigationBars["Metadata Providers"].waitForExistence(timeout: 5))
        }
        XCTAssertEqual(app.navigationBars.buttons["BackButton"].exists, hadBackButton)
        if hadBackButton {
            app.navigationBars.buttons["BackButton"].tap()
            XCTAssertFalse(app.navigationBars["Artwork"].exists)
            XCTAssertFalse(app.navigationBars["Metadata Providers"].exists)
        }
    }

    func testArtworkMetadataLinkReturnsToTheSameProfilePreferences() {
        openSettingsPage("Appearance", verifyTitleLayout: false)
        app.buttons["appearance-artwork"].tap()
        XCTAssertTrue(app.navigationBars["Artwork"].waitForExistence(timeout: 5))
        let library = app.buttons["artwork-preset-library"]
        library.tap()
        let metadata = app.buttons["artwork-metadata-providers"]
        reveal(metadata)
        metadata.tap()
        XCTAssertTrue(app.navigationBars["Metadata Providers"].waitForExistence(timeout: 5))
        let artwork = app.buttons["metadata-artwork-preferences"]
        reveal(artwork)
        artwork.tap()
        XCTAssertTrue(app.navigationBars["Artwork"].waitForExistence(timeout: 5))
        XCTAssertTrue(library.isSelected)
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["Appearance"].waitForExistence(timeout: 5))
    }

    func testThemeMenusAndToggleKeepSeparateActions() {
        launch()
        let appearance = button("Appearance")
        appearance.tap()
        XCTAssertTrue(app.buttons["Light"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["Light"].tap()
        XCTAssertTrue(appearance.staticTexts["Light"].exists)
        let gradient = app.switches["Gradient Backgrounds"]
        let before = gradient.value as? String
        gradient.tap()
        XCTAssertNotEqual(gradient.value as? String, before)
        XCTAssertTrue(appearance.staticTexts["Light"].exists)
        let glass = button("Liquid Glass")
        glass.tap()
        XCTAssertTrue(app.buttons["System"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["Light"].exists)
        app.buttons["System"].tap()
        XCTAssertTrue(app.navigationBars["Appearance"].exists)
    }

    func testCardPreviewsAndPerViewMenusRemainIndependent() {
        launch()
        app.buttons["appearance-cards"].tap()
        let labels = app.buttons["card-labels-on"]
        XCTAssertTrue(labels.waitForExistence(timeout: 3))
        labels.tap()
        XCTAssertTrue(labels.isSelected)
        XCTAssertTrue(app.navigationBars["Cards"].exists)
        app.buttons["card-label-customization"].tap()
        let home = app.buttons["card-label-view-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        home.tap()
        XCTAssertTrue(app.buttons["No labels"].waitForExistence(timeout: 3))
        app.buttons["No labels"].tap()
        XCTAssertTrue(home.staticTexts["No labels"].exists)
        let browse = app.buttons["card-label-view-browse"]
        let filmography = app.buttons["card-label-view-filmography"]
        XCTAssertTrue(browse.staticTexts["Default · Labels"].exists)
        browse.tap()
        app.buttons["Labels"].tap()
        XCTAssertTrue(browse.staticTexts["Labels"].exists)
        XCTAssertTrue(home.staticTexts["No labels"].exists)
        reveal(filmography)
        XCTAssertTrue(filmography.staticTexts["Default · Labels"].exists)
        filmography.tap()
        app.buttons["No labels"].tap()
        XCTAssertTrue(filmography.staticTexts["No labels"].exists)
        XCTAssertTrue(browse.staticTexts["Labels"].exists)
        capture("independent-caption-overrides")
    }

    func testSettingsSectionsOpenTheirOwnDestinations() {
        for title in [
            "Trackers", "Appearance", "Customize Home", "Live TV", "Detail Page",
            "Playback", "Subtitles", "Spoilers", "Circadian Mode",
            "Profiles", "Servers", "Downloads", "Seerr", "Metadata Providers", "Help & Diagnostics", "Attributions"
        ] {
            openSettingsPage(title)
            app.terminate()
        }
    }

    func testDetailRatingLinkDoesNotOpenItsNeighboringPicker() {
        openSettingsPage("Detail Page")
        let priority = app.buttons["Rating sources & order"]
        XCTAssertTrue(priority.waitForExistence(timeout: 3), app.debugDescription)
        priority.tap()
        XCTAssertTrue(app.navigationBars["Rating sources & order"].waitForExistence(timeout: 3), app.debugDescription)
    }

    func testPlaybackIntervalMenusChangeOnlyTheirOwnSelection() {
        openSettingsPage("Playback")
        let backward = button("Skip backward")
        let forward = button("Skip forward")
        let rewind = button("Resume rewind")
        reveal(backward)
        let forwardBefore = forward.label
        let rewindBefore = rewind.label
        backward.tap()
        let five = seconds(5)
        XCTAssertTrue(app.buttons[five].waitForExistence(timeout: 3))
        app.buttons[five].tap()
        XCTAssertTrue(backward.staticTexts[five].exists)
        XCTAssertEqual(forward.label, forwardBefore)
        XCTAssertEqual(rewind.label, rewindBefore)
        forward.tap()
        let sixty = seconds(60)
        app.buttons[sixty].tap()
        XCTAssertTrue(forward.staticTexts[sixty].exists)
        XCTAssertTrue(backward.staticTexts[five].exists)
        rewind.tap()
        let two = seconds(2)
        XCTAssertTrue(app.buttons[two].waitForExistence(timeout: 3))
        app.buttons[two].tap()
        XCTAssertTrue(rewind.staticTexts[two].exists)
        XCTAssertTrue(forward.staticTexts[sixty].exists)
    }

    func testSpoilerSwitchesAndMenuRemainIndependent() {
        openSettingsPage("Spoilers")
        let protection = app.switches["Protect unwatched episodes"]
        let ratings = app.switches["Hide ratings until watched"]
        let treatment = button("Thumbnail treatment")
        XCTAssertFalse(treatment.isEnabled)
        protection.tap()
        XCTAssertTrue(treatment.isEnabled)
        treatment.tap()
        XCTAssertTrue(app.buttons["Placeholder Art"].waitForExistence(timeout: 3))
        app.buttons["Placeholder Art"].tap()
        XCTAssertTrue(treatment.staticTexts["Placeholder Art"].exists)
        XCTAssertEqual(protection.value as? String, "1")
        XCTAssertEqual(ratings.value as? String, "0")
        ratings.tap()
        XCTAssertEqual(ratings.value as? String, "1")
        XCTAssertTrue(treatment.staticTexts["Placeholder Art"].exists)
        protection.tap()
        XCTAssertFalse(treatment.isEnabled)
        XCTAssertEqual(ratings.value as? String, "1")
    }

    func testSubtitleToggleInsertsOnlyItsOwnNavigationRow() {
        openSettingsPage("Subtitles")
        let liveStyle = app.switches["Use a separate style for Live TV"]
        XCTAssertEqual(liveStyle.value as? String, "0")
        liveStyle.tap()
        let liveLink = button("Customize Live TV subtitles")
        XCTAssertTrue(liveLink.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(button("Customize subtitle style").exists)
        liveStyle.tap()
        XCTAssertFalse(liveLink.exists)
        let hearing = button("Hearing impaired")
        reveal(hearing)
        let forced = button("Forced subtitles")
        let forcedBefore = forced.label
        hearing.tap()
        capture("subtitle-search-menu")
        XCTAssertTrue(app.buttons["Prefer SDH"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["Prefer SDH"].tap()
        XCTAssertTrue(hearing.staticTexts["Prefer SDH"].exists)
        XCTAssertEqual(forced.label, forcedBefore)
    }

    func testCircadianPictureMenusAndPreviewKeepSeparateActions() {
        openSettingsPage("Circadian Mode")
        app.switches["Circadian Mode"].tap()
        button("Schedule").tap()
        app.buttons["Always On"].tap()
        let warmth = button("Warmth")
        let dimness = button("Dimness")
        let dimnessBefore = dimness.label
        warmth.tap()
        app.buttons["Toasty"].tap()
        XCTAssertTrue(warmth.staticTexts["Toasty"].exists)
        XCTAssertEqual(dimness.label, dimnessBefore)
        dimness.tap()
        app.buttons["Sorta Dark"].tap()
        XCTAssertTrue(dimness.staticTexts["Sorta Dark"].exists)
        XCTAssertTrue(warmth.staticTexts["Toasty"].exists)
        let preview = button("Preview a Day")
        reveal(preview)
        preview.tap()
        XCTAssertTrue(app.staticTexts["Simulated time"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["Toasty"].exists)
    }

    func testLiveTVSegmentedPickerAndSwitchesRemainIndependent() {
        openSettingsPage("Live TV")
        let sort = app.segmentedControls.firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 3))
        sort.buttons["Name"].tap()
        XCTAssertTrue(sort.buttons["Name"].isSelected)
        let preview = app.switches["Preview after watching"]
        let recent = app.switches["Recently watched"]
        let recentBefore = recent.value as? String
        let previewBefore = preview.value as? String
        preview.tap()
        XCTAssertNotEqual(preview.value as? String, previewBefore)
        XCTAssertEqual(recent.value as? String, recentBefore)
        XCTAssertTrue(sort.buttons["Name"].isSelected)
    }

    func testHomeRowToggleDoesNotOpenArtworkPicker() {
        openSettingsPage("Customize Home")
        let row = app.switches["Continue Watching"].firstMatch
        let artwork = button("Continue Watching")
        if row.value as? String == "0" { row.tap() }
        XCTAssertTrue(artwork.exists)
        row.tap()
        XCTAssertEqual(row.value as? String, "0")
        XCTAssertFalse(artwork.exists)
        row.tap()
        XCTAssertTrue(artwork.exists)
        XCTAssertTrue(app.navigationBars["Customize Home"].exists)
    }

    private func openSettingsPage(_ title: String, verifyTitleLayout: Bool = true) {
        launch(settingsRoot: true)
        let usesAboutPage = app.windows.firstMatch.frame.width >= 600
            && ["Help & Diagnostics", "Attributions"].contains(title)
        if usesAboutPage {
            let about = button("About")
            reveal(about, settingsMenu: true)
            about.tap()
            XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 3), app.debugDescription)
        }
        let row = button(title)
        reveal(row, settingsMenu: !usesAboutPage)
        row.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3), app.debugDescription)
        if verifyTitleLayout { assertInlineTitle(title) }
    }

    private func assertInlineTitle(_ title: String) {
        let bar = app.navigationBars[title]
        let heading = bar.staticTexts[title].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 3), app.debugDescription)
        var titleRegion = bar.frame
        let sidebar = app.navigationBars["Settings"]
        // iPad reports a full-window bar, but centers its title in the detail column.
        if sidebar.exists, sidebar.frame.width < bar.frame.width {
            if sidebar.frame.minX <= bar.frame.minX {
                titleRegion.origin.x = sidebar.frame.maxX
                titleRegion.size.width = bar.frame.maxX - sidebar.frame.maxX
            } else {
                titleRegion.size.width = sidebar.frame.minX - bar.frame.minX
            }
        }
        XCTAssertEqual(heading.frame.midX, titleRegion.midX, accuracy: 4, app.debugDescription)
        XCTAssertLessThanOrEqual(bar.frame.height, 64, "Subpages must not reserve a large-title block.")
        XCTAssertLessThanOrEqual(heading.frame.height, 32, "Subpages must use the native inline title font.")
    }

    private func button(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@", title, title + ","
        )).firstMatch
    }

    private func seconds(_ count: Int) -> String {
        Duration.seconds(count).formatted(.units(allowed: [.seconds], width: .abbreviated).locale(Locale(identifier: "en_US")))
    }

    private func launch(settingsRoot: Bool = false) {
        app.launchArguments = [
            settingsRoot ? "--settings-interaction-fixture" : "--appearance-interaction-fixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
    }

    private func launchNavigation(
        settingsInMore: Bool = false,
        directPresentation: Bool = false,
        settingsFirst: Bool = false
    ) {
        app.launchArguments = [
            "--navigation-interaction-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        if settingsInMore { app.launchArguments.append("--settings-in-more") }
        if directPresentation { app.launchArguments.append("--settings-direct-presentation") }
        if settingsFirst { app.launchArguments.append("--settings-first") }
        app.launch()
    }

    private func reveal(_ element: XCUIElement, settingsMenu: Bool = false) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            if settingsMenu {
                app.scrollViews.firstMatch.swipeUp()
            } else {
                app.collectionViews.element(boundBy: app.collectionViews.count - 1).swipeUp()
            }
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
