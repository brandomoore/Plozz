import XCTest
import Vision

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

    func testLabelEditsEnterCustomAndPresetsReplaceAllViews() {
        launch()
        app.buttons["appearance-cards"].tap()
        let labels = app.buttons["card-labels-on"]
        XCTAssertTrue(labels.waitForExistence(timeout: 3))
        let appDefault = app.buttons["card-labels-recommended"]
        let hidden = app.buttons["card-labels-off"]
        XCTAssertEqual(appDefault.label, "App default")
        XCTAssertTrue(labels.label.contains("Show labels everywhere"))
        XCTAssertTrue(hidden.label.contains("Hide labels everywhere"))
        XCTAssertEqual(appDefault.frame.height, labels.frame.height, accuracy: 1)
        XCTAssertEqual(hidden.frame.height, labels.frame.height, accuracy: 1)
        XCTAssertFalse(app.staticTexts["Plozz chooses where labels help."].exists)
        XCTAssertFalse(app.staticTexts["View customizations override this choice."].exists)
        labels.tap()
        XCTAssertTrue(labels.isSelected)
        XCTAssertTrue(app.navigationBars["Cards"].exists)
        let customization = app.buttons["card-label-customization"]
        reveal(customization)
        XCTAssertFalse(customization.label.contains("defaults"))
        customization.tap()
        let home = app.buttons["card-label-view-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertEqual(home.value as? String, "On")
        selectCustomization(home, expecting: "Off")
        selectCustomization(home, option: "Use default", expecting: "On")
        selectCustomization(home, expecting: "Off")
        let browse = app.buttons["card-label-view-browse"]
        selectCustomization(browse, expecting: "Off")
        selectCustomization(browse, expecting: "On")
        let episodes = app.buttons["card-label-view-episodes"]
        selectCustomization(episodes, expecting: "Off")
        let filmography = app.buttons["card-label-view-filmography"]
        selectCustomization(filmography, expecting: "Off")
        app.navigationBars.buttons.firstMatch.tap()
        reveal(customization)
        XCTAssertTrue(customization.label.hasSuffix("Custom"))
        for preset in [appDefault, labels, hidden] { XCTAssertFalse(preset.isSelected) }
        reveal(labels, towardTop: true)
        labels.tap()
        XCTAssertTrue(labels.isSelected)
        reveal(customization)
        XCTAssertFalse(customization.label.hasSuffix("Custom"))
        customization.tap()
        for row in [home, browse, episodes, filmography] {
            reveal(row)
            XCTAssertEqual(row.value as? String, "On")
        }
        app.navigationBars.buttons.firstMatch.tap()
        reveal(hidden, towardTop: true)
        hidden.tap()
        reveal(customization)
        customization.tap()
        reveal(browse, towardTop: true)
        XCTAssertEqual(browse.value as? String, "Off")
        app.navigationBars.buttons.firstMatch.tap()
        reveal(appDefault, towardTop: true)
        appDefault.tap()
        reveal(customization)
        customization.tap()
        XCTAssertEqual(home.value as? String, "Mixed")
        XCTAssertEqual(browse.value as? String, "On")
        XCTAssertFalse(app.buttons["card-label-remove-customizations"].exists)
        capture("labels-restored-preset")
    }

    func testArtworkEditsEnterCustomAndPresetReselectionReplacesAllViews() {
        launch()
        app.buttons["appearance-artwork"].tap()
        let providers = app.buttons["artwork-preset-online"]
        XCTAssertTrue(providers.waitForExistence(timeout: 3))
        providers.tap()
        let customize = app.buttons["artwork-customization"]
        reveal(customize)
        XCTAssertFalse(customize.label.contains("defaults"))
        customize.tap()
        let hero = app.buttons["artwork-view-home"]
        XCTAssertTrue(hero.waitForExistence(timeout: 3))
        XCTAssertEqual(hero.label, "Showcase / hero")
        selectCustomization(hero, expecting: "Library")
        for area in ["homeRows", "recommended", "collections", "playlists"] {
            let row = app.buttons["artwork-view-\(area)"]
            reveal(row, fullyVisible: true)
            XCTAssertEqual(row.value as? String, "Metadata providers",
                           "A different location must not inherit the edited Home hero choice.")
            selectCustomization(row, expecting: "Library")
        }
        XCTAssertFalse(app.buttons["artwork-view-recommendedHero"].exists,
                       "Mobile Recommended has no hero to customize.")
        let browse = app.buttons["artwork-view-browse"]
        reveal(browse, towardTop: true, fullyVisible: true)
        XCTAssertTrue(browse.waitForExistence(timeout: 3))
        XCTAssertEqual(browse.value as? String, "Metadata providers")
        for _ in 0..<3 {
            selectCustomization(browse, expecting: "Library")
            selectCustomization(browse, expecting: "Metadata providers")
        }
        let downloads = app.buttons["artwork-view-downloads"]
        reveal(downloads, fullyVisible: true)
        XCTAssertEqual(downloads.value as? String, "Metadata providers")
        selectCustomization(downloads, expecting: "Library")
        app.navigationBars.buttons.firstMatch.tap()
        reveal(customize)
        XCTAssertTrue(customize.label.hasSuffix("Custom"))
        for preset in ["recommended", "library", "online"] {
            XCTAssertFalse(app.buttons["artwork-preset-\(preset)"].isSelected)
        }
        reveal(providers, towardTop: true)
        providers.tap()
        XCTAssertTrue(providers.isSelected)
        reveal(customize)
        XCTAssertFalse(customize.label.hasSuffix("Custom"))
        customize.tap()
        reveal(downloads)
        XCTAssertEqual(downloads.value as? String, "Metadata providers")
        reveal(browse, towardTop: true, fullyVisible: true)
        selectCustomization(browse, expecting: "Library")
        app.navigationBars.buttons.firstMatch.tap()
        let library = app.buttons["artwork-preset-library"]
        reveal(library, towardTop: true)
        library.tap()
        reveal(customize)
        customize.tap()
        XCTAssertEqual(browse.value as? String, "Library")
        reveal(downloads)
        XCTAssertEqual(downloads.value as? String, "Library")
        app.navigationBars.buttons.firstMatch.tap()
        let recommended = app.buttons["artwork-preset-recommended"]
        reveal(recommended, towardTop: true)
        recommended.tap()
        reveal(customize)
        customize.tap()
        XCTAssertEqual(app.buttons["artwork-view-continueWatching"].value as? String, "Metadata providers")
        XCTAssertEqual(browse.value as? String, "Library")
        XCTAssertFalse(app.buttons["artwork-remove-customizations"].exists)
        capture("artwork-restored-preset")
    }

    func testArtworkMenusWaitForAChoiceAndRestoreOnlyTheirOwnDefault() throws {
        launch()
        app.buttons["appearance-artwork"].tap()
        let recommended = app.buttons["artwork-preset-recommended"]
        XCTAssertTrue(recommended.waitForExistence(timeout: 3))
        let customize = app.buttons["artwork-customization"]
        reveal(customize)
        customize.tap()
        let browse = app.buttons["artwork-view-browse"]
        reveal(browse, fullyVisible: true)
        XCTAssertEqual(browse.value as? String, "Library")
        let titleFrame = app.staticTexts["artwork-view-browse-title"].frame
        let dismissMenu = app.navigationBars["Artwork by view"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        browse.tap()
        let automatic = app.buttons["Use default"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(automatic.isSelected, "The menu must check the inherited choice, not a guessed source.")
        XCTAssertTrue(app.buttons["Library"].exists)
        XCTAssertTrue(app.buttons["Metadata providers"].exists)
        try assertMenuKeepsRowTitle("Browse", in: titleFrame)
        capture("artwork-choice-menu")
        dismissMenu.tap()
        XCTAssertTrue(browse.waitForExistence(timeout: 3))
        XCTAssertEqual(browse.value as? String, "Library")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(recommended.isSelected, "Opening and dismissing a menu must not customize the preset.")

        reveal(customize)
        customize.tap()
        let hero = app.buttons["artwork-view-home"]
        selectCustomization(hero, expecting: "Library")
        selectCustomization(browse, expecting: "Metadata providers")
        selectCustomization(browse, option: "Use default", expecting: "Library")
        reveal(hero, towardTop: true, fullyVisible: true)
        XCTAssertEqual(hero.value as? String, "Library", "Resetting Browse must not reset the hero.")
        app.navigationBars.buttons.firstMatch.tap()
        reveal(customize)
        XCTAssertTrue(customize.label.hasSuffix("Custom"))
        customize.tap()
        selectCustomization(hero, option: "Use default", expecting: "Metadata providers")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(recommended.isSelected, "Removing the final override must restore the original preset.")
    }

    func testLabelMenuKeepsItsTitleInTheRowWithoutRepeatingIt() throws {
        launch()
        app.buttons["appearance-cards"].tap()
        let customization = app.buttons["card-label-customization"]
        reveal(customization)
        customization.tap()
        let home = app.buttons["card-label-view-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        let titleFrame = app.staticTexts["card-label-view-home-title"].frame
        home.tap()
        XCTAssertTrue(app.buttons["Use default"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["Labels"].exists)
        XCTAssertTrue(app.buttons["No labels"].exists)
        try assertMenuKeepsRowTitle("Home rows", in: titleFrame)
        capture("label-choice-menu")
        app.buttons["No labels"].tap()
        XCTAssertEqual(home.value as? String, "Off")
    }

    private func assertMenuKeepsRowTitle(_ title: String, in frame: CGRect) throws {
        XCTAssertFalse(frame.isEmpty)
        let image = app.screenshot().image
        let cgImage = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cgImage.width) / image.size.width
        let crop = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: (frame.minX - 2) * scale, y: (frame.minY - 2) * scale,
            width: (frame.width + 4) * scale, height: (frame.height + 4) * scale
        )))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: crop).perform([request])
        let copy = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertEqual(copy, title, "Opening a value menu must leave the original row title visible.")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(
            format: "label == %@ AND identifier == ''", title
        )).count, 0, "The native menu must not repeat the row title as a header.")
    }

    private func selectCustomization(_ row: XCUIElement, option: String? = nil, expecting value: String) {
        reveal(row, fullyVisible: true)
        XCTAssertGreaterThanOrEqual(row.frame.height, 44 - 0.001)
        row.tap()
        let title = option ?? (value == "On" ? "Labels" : value == "Off" ? "No labels" : value)
        let choice = app.buttons[title]
        XCTAssertTrue(choice.waitForExistence(timeout: 3), app.debugDescription)
        choice.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(row.value as? String, value, app.debugDescription)
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

    private func reveal(
        _ element: XCUIElement,
        settingsMenu: Bool = false,
        towardTop: Bool = false,
        fullyVisible: Bool = false
    ) {
        for _ in 0..<10 {
            let scroll = settingsMenu
                ? app.scrollViews.firstMatch
                : app.collectionViews.element(boundBy: app.collectionViews.count - 1)
            var viewport = scroll.frame.intersection(app.windows.firstMatch.frame)
            if fullyVisible, app.navigationBars.firstMatch.exists {
                let top = max(viewport.minY, app.navigationBars.firstMatch.frame.maxY)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width,
                                  height: max(0, viewport.maxY - top))
            }
            if element.exists && element.isHittable
                && (!fullyVisible || viewport.contains(element.frame)) {
                return
            }
            if fullyVisible, element.exists, element.frame.minY < viewport.minY {
                scroll.swipeDown()
            } else if fullyVisible, element.exists, element.frame.maxY > viewport.maxY {
                scroll.swipeUp()
            } else if towardTop {
                scroll.swipeDown()
            } else {
                scroll.swipeUp()
            }
        }
        XCTFail("Could not reveal the requested row before tapping it. \(app.debugDescription)")
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
