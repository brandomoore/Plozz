import XCTest
import Vision
import UIKit

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

    func testPhoneBrowsingAndSettingsStayPortraitWithoutPlayback() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        launchNavigation(directPresentation: true)
        let downloads = app.tabBars.buttons["Downloads"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 10))
        for page in 0..<3 {
            if page == 1 {
                downloads.tap()
                XCTAssertTrue(app.buttons["Download Settings"].waitForExistence(timeout: 5))
            } else if page == 2 {
                app.buttons["fixture-open-settings"].tap()
                XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
            }
            XCUIDevice.shared.orientation = .landscapeLeft
            let rotates = XCTNSPredicateExpectation(predicate: NSPredicate { [app] _, _ in
                guard let app else { return false }
                return app.frame.width > app.frame.height
            }, object: nil)
            rotates.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [rotates], timeout: 1), .completed)
            XCUIDevice.shared.orientation = .portrait
        }
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
            ? app.buttons["fixture-open-settings"]
            : app.buttons.matching(NSPredicate(format: "label == %@", "Settings")).firstMatch
        let downloads = app.buttons.matching(NSPredicate(format: "label == %@", "Downloads")).firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 10), app.debugDescription)
        settings.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Home"].firstMatch.isSelected)
        app.buttons["Close"].tap()
        downloads.tap()
        XCTAssertTrue(app.buttons["Download Settings"].waitForExistence(timeout: 5))

        for iteration in 0..<2 {
            settings.tap()
            XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5), app.debugDescription)
            capture("settings-over-downloads-\(iteration)")
            XCTAssertTrue(app.buttons.matching(identifier: "Downloads").allElementsBoundByIndex.contains { $0.isSelected },
                          "Settings must not replace the selected content tab.")
            app.buttons["Close"].tap()
            XCTAssertTrue(app.buttons["Download Settings"].waitForExistence(timeout: 5))
        }

        app.buttons["Download Settings"].tap()
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        app.collectionViews.firstMatch.swipeUp()
        let retainedRow = app.switches["Download Failed"]
        XCTAssertTrue(retainedRow.isHittable)
        capture("before-settings-over-pushed-downloads")
        let retainedY = retainedRow.frame.minY
        settings.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        capture("settings-over-pushed-downloads")
        XCTAssertTrue(app.buttons.matching(identifier: "Downloads").allElementsBoundByIndex.contains { $0.isSelected })
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
        app.tables.cells.containing(.staticText, identifier: "Settings").firstMatch.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        capture("settings-over-more")
        XCTAssertTrue(more.isSelected)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
        XCTAssertTrue(more.isSelected)
    }

    func testMoreDestinationsKeepBackTitleAndProfileInOneNavigationRow() throws {
        launchNavigation(arguments: ["--content-in-more"])
        try XCTSkipIf(app.windows.firstMatch.frame.width >= 600, "Regular-width iPad has direct tabs.")
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        for title in ["Downloads", "Search"] {
            let row = app.tables.cells.containing(.staticText, identifier: title).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
            row.tap()
            let back = app.buttons["more-navigation-back"]
            XCTAssertTrue(back.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
            let bar = app.navigationBars[title]
            XCTAssertTrue(bar.waitForExistence(timeout: 5), app.debugDescription)
            let heading = bar.staticTexts[title]
            let avatar = bar.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@", "Settings for "
            )).firstMatch
            XCTAssertTrue(heading.exists, app.debugDescription)
            XCTAssertTrue(avatar.isHittable, app.debugDescription)
            XCTAssertEqual(app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).count, 1)
            XCTAssertEqual(heading.frame.midY, back.frame.midY, accuracy: 6, "\(title) title alignment")
            XCTAssertEqual(avatar.frame.midY, back.frame.midY, accuracy: 6, "\(title) profile alignment")
            XCTAssertFalse(app.buttons["search-settings-avatar"].exists)
            capture("more-single-header-\(title)")
            if title == "Downloads" {
                app.buttons["Download Settings"].tap()
                let innerBack = app.buttons["BackButton"]
                XCTAssertTrue(innerBack.waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertFalse(back.exists, "A deeper page must go back within the existing destination stack.")
                innerBack.tap()
                XCTAssertTrue(back.wait(for: \.isHittable, toEqual: true, timeout: 5))
            }
            back.tap()
            XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5), app.debugDescription)
        }
    }

    func testAllLibrariesFromMoreCombinesMoviesAndShows() throws {
        launchNavigation(arguments: ["--libraries-in-more", "--all-libraries-fixture"])
        let more = app.tabBars.buttons["More"]
        if more.waitForExistence(timeout: 5) { more.tap() }
        let row = app.tables.cells.containing(.staticText, identifier: "All Libraries").firstMatch
        if row.waitForExistence(timeout: 3) {
            row.tap()
        } else {
            app.buttons["All Libraries"].firstMatch.tap()
        }
        XCTAssertTrue(app.navigationBars["All Libraries"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.scrollViews.staticTexts["Harbor"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.scrollViews.staticTexts["Orbit"].waitForExistence(timeout: 10), app.debugDescription)
        capture("all-libraries-combined-grid")
    }

    func testDefaultAndFiveExplicitPagesDoNotCreateMore() throws {
        let fixture = ["--libraries-in-more", "--all-libraries-fixture"]
        launchNavigation(arguments: fixture + ["--default-navigation"])
        XCTAssertTrue(app.tabBars.buttons["Downloads"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        XCTAssertTrue(app.tabBars.buttons["Search"].exists)
        XCTAssertFalse(app.tabBars.buttons["More"].exists)
        XCTAssertFalse(app.buttons["All Libraries"].exists)
        capture("three-default-pages")
        app.terminate()
        launchNavigation(arguments: fixture + ["--five-navigation-pages"])
        XCTAssertTrue(app.buttons["All Libraries"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.tabBars.buttons["More"].exists)
        app.buttons["All Libraries"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["All Libraries"].waitForExistence(timeout: 5), app.debugDescription)
        capture("five-explicit-pages")
    }

    func testLibraryFromMoreKeepsItsTitleAndProfileBesideBack() throws {
        launchNavigation(arguments: ["--libraries-in-more"])
        try XCTSkipIf(app.windows.firstMatch.frame.width >= 600, "Regular-width iPad has direct tabs.")
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        let row = app.tables.cells.containing(.staticText, identifier: "Movies").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        let back = app.buttons["more-navigation-back"]
        XCTAssertTrue(back.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
        let bar = app.navigationBars["Movies"]
        let heading = bar.staticTexts["Movies"]
        let avatar = bar.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Settings for "
        )).firstMatch
        XCTAssertTrue(heading.exists, app.debugDescription)
        XCTAssertTrue(avatar.isHittable, app.debugDescription)
        XCTAssertEqual(app.navigationBars.allElementsBoundByIndex.filter(\.isHittable).count, 1)
        XCTAssertEqual(heading.frame.midY, back.frame.midY, accuracy: 6)
        XCTAssertEqual(avatar.frame.midY, back.frame.midY, accuracy: 6)
        capture("more-single-header-Movies")
        back.tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
    }

    func testAdaptiveNavigationPageCaptures() {
        launchNavigation(settingsInMore: true)
        for title in ["Home", "Watchlist", "Live TV", "Downloads", "Search", "Settings"] {
            let tab = app.buttons[title].firstMatch
            if tab.waitForExistence(timeout: 2), tab.isHittable {
                tab.tap()
            } else {
                let more = app.tabBars.buttons["More"]
                XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
                more.tap()
                let row = app.tables.cells.containing(.staticText, identifier: title).firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
                row.tap()
            }
            if title == "Settings" {
                XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5), app.debugDescription)
            } else if title == "Search" {
                XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            } else {
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
            }
            capture("adaptive-\(title)-\(Int(app.frame.width))x\(Int(app.frame.height))")
            if title == "Settings" { app.buttons["Close"].tap() }
        }
    }

    func testSearchInputRemainsReadableAndEditableAcrossThemes() {
        XCUIDevice.shared.orientation = .portrait
        for (theme, arguments) in [
            ("dark", [String]()),
            ("light", ["--search-light-theme"]),
            ("black", ["--search-black-theme"])
        ] {
            launchNavigation(settingsInMore: true, arguments: arguments)
            let search = app.buttons["Search"].firstMatch
            if search.waitForExistence(timeout: 2), search.isHittable {
                search.tap()
            } else {
                let more = app.tabBars.buttons["More"]
                XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
                more.tap()
                let row = app.tables.cells.containing(.staticText, identifier: "Search").firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
                row.tap()
            }
            let field = app.textFields["Search your libraries"]
            XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(field.isHittable)
            let settingsTab = app.buttons["Settings"].firstMatch
            let toolbarAvatar = app.navigationBars.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Settings for ")
            ).firstMatch
            if (settingsTab.exists && settingsTab.isHittable) || toolbarAvatar.exists {
                XCTAssertTrue(app.buttons["search-settings-avatar"].waitForNonExistence(timeout: 5))
            } else {
                XCTAssertTrue(app.buttons["search-settings-avatar"].exists)
            }
            capture("search-\(theme)-empty")
            field.tap()
            field.typeText("Sample")
            XCTAssertEqual(field.value as? String, "Sample")
            capture("search-\(theme)-editing")
            let clear = app.buttons["Clear search"]
            XCTAssertTrue(clear.isHittable)
            clear.tap()
            XCTAssertEqual(field.value as? String, "Movies, shows, and episodes")
            XCTAssertFalse(clear.exists)
        }
    }

    func testCardsRowNavigatesWithoutOpeningDisplaySize() {
        launch()
        let cards = app.buttons["appearance-cards"]
        XCTAssertTrue(cards.waitForExistence(timeout: 5), app.debugDescription)
        cards.tap()
        capture("after-tapping-cards")
        XCTAssertTrue(app.navigationBars["Cards"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["card-label-picker"].exists)
        XCTAssertFalse(app.buttons["Micro"].exists)
        XCTAssertFalse(app.buttons["Huge"].exists)
    }

    func testEpisodeCountToggleUpdatesCompactWatchIndicatorPreview() throws {
        launch()
        app.buttons["appearance-cards"].tap()
        XCTAssertTrue(app.navigationBars["Cards"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appearance-cards"].waitForNonExistence(timeout: 5))
        let toggle = app.switches["unwatched-episode-count-toggle"]
        reveal(toggle, fullyVisible: true)
        let preview = app.descendants(matching: .any)["watch-indicator-preview"].firstMatch
        let picker = app.buttons["watch-indicator-picker"]
        for mode in ["watched", "unwatched", "hidden"] {
            reveal(picker, fullyVisible: true)
            picker.tap()
            app.buttons["watch-indicator-option-\(mode)"].tap()
            reveal(preview, fullyVisible: true)
            let enabled = try XCTUnwrap(preview.screenshot().image.pngData())
            tapNativeSwitch(toggle)
            XCTAssertEqual(toggle.value as? String, "0")
            reveal(preview, fullyVisible: true)
            XCTAssertNotEqual(try XCTUnwrap(preview.screenshot().image.pngData()), enabled)
            tapNativeSwitch(toggle)
            XCTAssertEqual(toggle.value as? String, "1")
        }
        XCTAssertFalse(app.buttons["watch-indicator-color-white"].exists)
        XCTAssertTrue(app.buttons["episode-count-style"].exists)
        capture("watch-count-previews")
    }

    func testWideCardPreviewChoicesStaySideBySideAndSelectIndependently() throws {
        launch()
        let orientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = orientation }
        if app.frame.width < 750 {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        try XCTSkipIf(app.frame.width < 750, "Requires a wide mobile window.")
        app.buttons["appearance-cards"].tap()
        XCTAssertTrue(app.navigationBars["Cards"].waitForExistence(timeout: 5))
        let labelChoices = ["recommended", "on", "off"].map { app.buttons["card-labels-\($0)"] }
        XCTAssertTrue(labelChoices[0].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["card-label-picker"].exists)
        for choice in labelChoices {
            XCTAssertEqual(choice.frame.midY, labelChoices[0].frame.midY, accuracy: 1)
            choice.tap()
            XCTAssertTrue(choice.isSelected)
            XCTAssertEqual(labelChoices.filter(\.isSelected).count, 1)
        }
        let watchChoices = ["watched", "unwatched", "hidden"].map {
            app.buttons["watch-indicator-preview-\($0)"]
        }
        reveal(watchChoices[0], fullyVisible: true)
        XCTAssertFalse(app.buttons["watch-indicator-picker"].exists)
        for (index, choice) in watchChoices.enumerated() {
            XCTAssertEqual(choice.frame.midY, watchChoices[0].frame.midY, accuracy: 1)
            choice.tap()
            XCTAssertEqual(app.buttons["watch-indicator-color-white"].exists, index != 2)
            XCTAssertEqual(app.switches["unwatched-episode-count-toggle"].value as? String, "1")
            XCTAssertTrue(labelChoices[2].isSelected, "Watch choices must not change labels.")
        }
        capture("wide-card-preview-choices")
    }

    func testEpisodeCountStyleChangesWithoutSelectingAnotherWatchIndicator() throws {
        launch()
        app.buttons["appearance-cards"].tap()
        XCTAssertTrue(app.navigationBars["Cards"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appearance-cards"].waitForNonExistence(timeout: 5))
        let style = app.buttons["episode-count-style"]
        reveal(style, fullyVisible: true)
        XCTAssertEqual(style.label, "Episode count style")
        let indicator = app.buttons["watch-indicator-picker"]
        let originalValue = indicator.value as? String
        for choice in ["Attached", "Floating"] {
            style.tap()
            let option = app.buttons["episode-count-style-\(choice.lowercased())"]
            XCTAssertTrue(option.waitForExistence(timeout: 3), app.debugDescription)
            option.tap()
            XCTAssertEqual(style.value as? String, choice, "The native picker must expose its selected value.")
            XCTAssertEqual(indicator.value as? String, originalValue)
        }
        let toggle = app.switches["unwatched-episode-count-toggle"]
        tapNativeSwitch(toggle)
        XCTAssertFalse(style.exists)
        tapNativeSwitch(toggle)
        XCTAssertEqual(style.value as? String, "Floating", "Hiding counts must retain the style.")
        capture("episode-count-floating")
    }

    func testProgressBarsUseNativeIndependentToggleAndSurviveNavigation() {
        launch()
        app.buttons["appearance-cards"].tap()
        XCTAssertTrue(app.navigationBars["Cards"].waitForExistence(timeout: 5))
        let progress = app.switches["progress-bars-toggle"]
        reveal(progress, fullyVisible: true)
        XCTAssertEqual(progress.value as? String, "1")
        tapNativeSwitch(progress)
        XCTAssertEqual(progress.value as? String, "0")
        XCTAssertEqual(app.switches["unwatched-episode-count-toggle"].value as? String, "1")
        app.navigationBars["Cards"].buttons.firstMatch.tap()
        app.buttons["appearance-cards"].tap()
        reveal(progress, fullyVisible: true)
        XCTAssertEqual(progress.value as? String, "0")
        tapNativeSwitch(progress)
        XCTAssertEqual(progress.value as? String, "1")
    }

    func testWatchIndicatorColorsStayInOneRowAndSelectionSurvivesNavigation() {
        launch()
        app.buttons["appearance-cards"].tap()
        XCTAssertTrue(app.navigationBars["Cards"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appearance-cards"].waitForNonExistence(timeout: 5))
        let white = app.buttons["watch-indicator-color-white"]
        reveal(white, fullyVisible: true)
        XCTAssertTrue(white.isSelected)
        let colors = ["white", "blue", "green", "yellow", "orange", "red", "pink", "purple"]
        let buttons = colors.map { app.buttons["watch-indicator-color-\($0)"] }
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "watch-indicator-color-"
        )).count, 8)
        let y = white.frame.midY
        for button in buttons {
            XCTAssertEqual(button.frame.midY, y, accuracy: 1, "The palette must never wrap.")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }

        let blue = buttons[1]
        blue.tap()
        XCTAssertTrue(blue.isSelected)
        XCTAssertFalse(white.isSelected)
        let purple = buttons[7]
        if !purple.isHittable {
            let rail = app.scrollViews.containing(.button, identifier: "watch-indicator-color-blue").firstMatch
            rail.swipeLeft()
        }
        XCTAssertTrue(purple.isHittable)
        purple.tap()
        XCTAssertTrue(purple.isSelected)
        XCTAssertFalse(blue.isSelected)
        capture("watch-color-purple")
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["appearance-cards"].waitForExistence(timeout: 5))
        app.buttons["appearance-cards"].tap()
        XCTAssertTrue(app.navigationBars["Cards"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["appearance-cards"].waitForNonExistence(timeout: 5))
        reveal(purple, fullyVisible: true)
        XCTAssertTrue(purple.isSelected, "Returning must restore the selection and reveal it on the rail.")
    }

    func testDisplaySizeIsLastInCardsAndRemainsAnIndependentMenu() {
        launch()
        XCTAssertFalse(app.buttons["appearance-display-size"].exists)
        app.buttons["appearance-cards"].tap()
        let size = app.buttons["appearance-display-size"]
        reveal(size, fullyVisible: true)
        let style = app.staticTexts["STYLE"].firstMatch
        XCTAssertTrue(style.exists)
        XCTAssertLessThan(style.frame.minY, size.frame.minY)
        size.tap()
        XCTAssertTrue(app.buttons["Small"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["Small"].tap()
        XCTAssertTrue(app.navigationBars["Cards"].exists)
        XCTAssertTrue(size.staticTexts["Small"].exists, app.debugDescription)
        capture("cards-display-size-last")
    }

    func testCardsOpenFromTheFullSettingsNavigation() {
        openSettingsPage("Appearance")
        app.buttons["appearance-cards"].tap()
        XCTAssertTrue(app.navigationBars["Cards"].waitForExistence(timeout: 3), app.debugDescription)
        assertInlineTitle("Cards")
        XCTAssertFalse(app.buttons["Micro"].exists)
    }

    func testTrackersHideUnreleasedWetrakr() {
        openSettingsPage("Trackers")
        let wetrakr = NSPredicate(format: "label CONTAINS[c] %@", "WeTrakr")
        for _ in 0..<3 {
            XCTAssertEqual(app.buttons.matching(wetrakr).count, 0, app.debugDescription)
            XCTAssertEqual(app.staticTexts.matching(wetrakr).count, 0, app.debugDescription)
            app.collectionViews.firstMatch.swipeUp()
        }
    }

    func testRootOrganizationMatchesAcrossAdaptiveLayouts() {
        let titles = [
            "Playback", "Subtitles", "Live TV", "Libraries", "Appearance",
            "Screens & Navigation", "Trackers", "Language"
        ]
        for arguments in [[], ["--compact-settings"], ["--large-text"]] {
            launch(settingsRoot: true, arguments: arguments)
            capture("settings-root-\(arguments.joined())")
            for title in titles {
                let row = categoryButton(title)
                reveal(row, settingsMenu: true)
                XCTAssertTrue(row.isHittable, title)
            }
            XCTAssertTrue(categoryButton("Language").staticTexts["Language"].exists,
                          "The native menu must include the setting's label, not only its current language.")
            capture("settings-language-\(arguments.joined())")
            XCTAssertFalse(button("Customize Home").exists)
            XCTAssertFalse(button("Detail Page").exists)
            XCTAssertFalse(button("Circadian Mode").exists)
            XCTAssertFalse(button("Spoiler Protection").exists)
            categoryButton("Language").tap()
            XCTAssertTrue(app.buttons["English"].waitForExistence(timeout: 3), app.debugDescription)
            app.buttons["English"].tap()
            XCTAssertTrue(categoryButton("Language").isHittable)
            for title in ["Servers", "Profiles", "Parental PIN", "Seerr", "iCloud Sync", "Metadata Providers", "Downloads"] {
                let row = button(title)
                reveal(row, settingsMenu: true)
                XCTAssertTrue(row.isHittable)
            }
            capture("settings-everyone-\(arguments.joined())")
            reveal(button("Help & Diagnostics"), settingsMenu: true)
            XCTAssertTrue(app.staticTexts.matching(
                NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Version", "Version, ")
            ).firstMatch.exists)
            XCTAssertTrue(app.links["Discord"].exists || app.buttons["Discord"].exists)
            capture("settings-community-\(arguments.joined())")
            app.terminate()
        }
    }

    func testMozzBetaOpensThePublicInviteFromMobileSettings() {
        for arguments in [[], ["--compact-settings"], ["--large-text"], ["--kids-settings"]] {
            launch(settingsRoot: true, arguments: arguments + ["--capture-settings-links"])
            let link = app.descendants(matching: .any).matching(identifier: "settings-mozz-beta").firstMatch
            reveal(link, settingsMenu: true, fullyVisible: true)
            XCTAssertTrue(link.isHittable, app.debugDescription)
            XCTAssertTrue(link.label.contains("Mozz"), link.label)
            XCTAssertTrue(link.label.contains("Free, open-source music player"), link.label)
            XCTAssertTrue(link.label.contains("TestFlight public beta"), link.label)
            XCTAssertGreaterThanOrEqual(link.frame.height, 44)
            if !arguments.contains("--large-text"), link.frame.width >= 370 {
                XCTAssertLessThanOrEqual(link.frame.height, 84, "Keep the existing three-line row height.")
            }
            capture("settings-mozz-beta-\(arguments.joined())")
            link.tap()
            let destination = app.staticTexts["fixture-opened-settings-url"]
            XCTAssertTrue(destination.waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertEqual(destination.label, "https://testflight.apple.com/join/dmeawSSM")
            XCTAssertTrue(app.navigationBars["Settings"].exists)
            app.terminate()
        }
    }

    func testNestedAppearanceAndScreensKeepIndependentNavigation() {
        for title in ["Appearance", "Screens & Navigation"] {
            openSettingsPage(title)
            let children = title == "Appearance"
                ? ["Theme", "Cards", "Artwork", "Circadian Mode"]
                : ["Spoiler Protection", "Customize Home", "Customize Libraries", "App navigation", "Detail Page"]
            for child in children {
                let row = button(child)
                reveal(row)
                row.tap()
                XCTAssertTrue(app.navigationBars[child].waitForExistence(timeout: 5), app.debugDescription)
                capture("settings-child-\(child)")
                app.navigationBars.buttons["BackButton"].tap()
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
            }
            app.terminate()
        }
    }

    func testAllScreensToggleKeepsItsNativeActionBesideNavigation() {
        openSettingsPage("Screens & Navigation")
        let ratings = app.switches["show-content-ratings"]
        XCTAssertTrue(ratings.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["ALL SCREENS"].exists)
        let value = ratings.value as? String
        tapNativeSwitch(ratings)
        XCTAssertNotEqual(ratings.value as? String, value)
        XCTAssertTrue(app.navigationBars["Screens & Navigation"].exists)
        XCTAssertTrue(button("Spoiler Protection").exists)
        capture("all-screens-ratings-off")
        tapNativeSwitch(ratings)
        XCTAssertEqual(ratings.value as? String, value)
        button("Spoiler Protection").tap()
        XCTAssertTrue(app.navigationBars["Spoiler Protection"].waitForExistence(timeout: 3))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(ratings.waitForExistence(timeout: 3))
        XCTAssertEqual(ratings.value as? String, value)
    }

    func testAppNavigationEntryAndTitleStayConsistent() {
        openSettingsPage("Screens & Navigation")
        let navigation = button("App navigation")
        reveal(navigation, fullyVisible: true)
        XCTAssertGreaterThanOrEqual(navigation.frame.height, 44)
        XCTAssertLessThan(navigation.frame.maxY, button("Customize Home").frame.minY)
        XCTAssertFalse(button("Navigation").exists)
        capture("app-navigation-entry")
        navigation.tap()
        XCTAssertTrue(app.navigationBars["App navigation"].waitForExistence(timeout: 3))
        assertInlineTitle("App navigation")
        capture("app-navigation-page")
        let reset = app.buttons["Reset Navigation"]
        XCTAssertTrue(reset.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(reset.frame))
        app.navigationBars["App navigation"].buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["Screens & Navigation"].waitForExistence(timeout: 3))
        XCTAssertTrue(navigation.isHittable)
    }

    func testThemeMusicMuteUsesTheDetailToolbarAndCurrentPlayback() {
        app.terminate()
        app.launchArguments = ["--theme-mute-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let mute = app.buttons["theme-music-mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(mute.label, "Mute theme music")
        XCTAssertFalse(app.buttons["trailer-mute"].exists)
        mute.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "theme-music-mute")
            .matching(NSPredicate(format: "label == %@", "Unmute theme music")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["theme-player-audio"].label, "Muted")
        capture("theme-music-muted")
        mute.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "theme-music-mute")
            .matching(NSPredicate(format: "label == %@", "Mute theme music")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["theme-player-audio"].label, "Audible")
        capture("theme-music-unmuted")
        tapNativeSwitch(app.switches["Current item"])
        XCTAssertFalse(mute.exists, "Another item's theme must not expose this detail's control.")
        tapNativeSwitch(app.switches["Current item"])
        XCTAssertTrue(mute.waitForExistence(timeout: 3))
        tapNativeSwitch(app.switches["Active detail"])
        XCTAssertFalse(mute.exists, "A covered detail cannot control foreground audio.")
        tapNativeSwitch(app.switches["Active detail"])
        XCTAssertTrue(mute.waitForExistence(timeout: 3))
        app.buttons["Stop theme"].tap()
        XCTAssertFalse(mute.exists)
    }

    func testScreenCardLabelControlsShareCentralOverrides() {
        openSettingsPage("Screens & Navigation")
        let screens: [(String, String, [String])] = [
            ("Customize Home", "home", ["home", "continueWatchingPortrait", "homeLibraries"]),
            ("Customize Libraries", "library", ["recommended", "browse", "collections", "playlists", "continueWatchingPortrait"]),
            ("Detail Page", "detail", ["episodes", "related", "extras"])
        ]
        for (title, scope, views) in screens {
            let link = button(title)
            reveal(link)
            link.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertFalse(app.buttons["card-label-view-\(views[0])"].exists)
            let customize = app.buttons["\(scope)-customize-labels"]
            reveal(customize)
            customize.tap()
            let labelsTitle = scope == "home" ? "Card labels" : "Customize labels"
            XCTAssertTrue(app.navigationBars[labelsTitle].waitForExistence(timeout: 3))
            XCTAssertEqual(app.buttons["card-label-page"].exists, scope == "library")
            for view in views {
                let row: XCUIElement
                if title == "Customize Libraries" {
                    let name = view == "continueWatchingPortrait" ? "Recommended" : view.capitalized
                    selectCustomization(app.buttons["card-label-page"], expecting: name)
                    row = app.buttons["card-label-view-\(view)"]
                } else {
                    row = app.buttons["card-label-view-\(view)"]
                }

                reveal(row)
                if title == "Customize Libraries", view == "continueWatchingPortrait" {
                    XCTAssertEqual(row.value as? String, "Off", "Home and Libraries must share this override.")
                } else {
                    selectCustomization(row, expecting: "Off")
                }
            }
            XCTAssertFalse(app.buttons["card-label-view-filmography"].exists)
            XCTAssertFalse(app.buttons["card-label-view-search"].exists)
            capture("screen-card-labels-\(title)")
            app.navigationBars[labelsTitle].buttons["BackButton"].tap()
            app.navigationBars[title].buttons["BackButton"].tap()
        }
        let screensBack = app.navigationBars["Screens & Navigation"].buttons["BackButton"]
        if screensBack.exists { screensBack.tap() }
        let appearance = categoryButton("Appearance")
        reveal(appearance, settingsMenu: true)
        appearance.tap()
        app.buttons["appearance-cards"].tap()
        let customize = app.buttons["card-label-customization"]
        reveal(customize)
        customize.tap()
        let page = app.buttons["card-label-page"]
        for (name, views) in [
            ("Home", ["home", "continueWatchingPortrait", "homeLibraries"]),
            ("Recommended", ["recommended", "continueWatchingPortrait"]),
            ("Browse", ["browse"]), ("Collections", ["collections"]), ("Playlists", ["playlists"]),
            ("Detail Page", ["episodes", "related", "extras"])
        ] {
            selectCustomization(page, expecting: name)
            for view in views {
                let row = app.buttons["card-label-view-\(view)"]
                reveal(row)
                XCTAssertEqual(row.value as? String, "Off", "The central editor must show the contextual edit for \(view).")
            }
            capture("all-labels-\(name)")
        }
        for (name, view) in [("Search", "search"), ("Watchlist", "watchlist"), ("People", "filmography")] {
            selectCustomization(page, expecting: name)
            XCTAssertEqual(app.buttons["card-label-view-\(view)"].value as? String, "On",
                           "Unrelated pages must be preserved.")
        }
        selectCustomization(page, expecting: "Detail Page")
        let episodes = app.buttons["card-label-view-episodes"]
        reveal(episodes)
        selectCustomization(episodes, expecting: "On")
        for title in ["Customize labels", "Cards", "Appearance"] {
            let back = app.navigationBars[title].buttons["BackButton"]
            if title != "Appearance" || back.exists { back.tap() }
        }
        let screenSettings = categoryButton("Screens & Navigation")
        reveal(screenSettings, settingsMenu: true)
        screenSettings.tap()
        button("Detail Page").tap()
        reveal(app.buttons["detail-customize-labels"])
        app.buttons["detail-customize-labels"].tap()
        XCTAssertTrue(episodes.waitForExistence(timeout: 3))
        XCTAssertEqual(episodes.value as? String, "On", "Central edits must flow back into the screen's controls.")
        XCTAssertEqual(app.buttons["card-label-view-related"].value as? String, "Off")
        XCTAssertEqual(app.buttons["card-label-view-extras"].value as? String, "Off")
        capture("detail-labels-round-trip")
    }

    func testHomeLibraryLabelsInheritDefaultAndOverridesFollowPreview() {
        openSettingsPage("Customize Home")
        let customize = app.buttons["home-customize-labels"]
        reveal(customize)
        customize.tap()
        let parent = app.buttons["card-label-view-home"]
        let libraries = app.buttons["card-label-view-homeLibraries"]
        let watching = app.buttons["card-label-view-continueWatchingPortrait"]
        let preview = app.descendants(matching: .any)["card-label-preview-home"].firstMatch
        XCTAssertTrue(parent.waitForExistence(timeout: 3))
        selectCustomization(parent, expecting: "Off")
        reveal(libraries)
        XCTAssertEqual(libraries.value as? String, "Use default")
        XCTAssertEqual(watching.value as? String, "Use default")
        XCTAssertLessThan(preview.frame.maxY, watching.frame.minY)
        XCTAssertLessThan(watching.frame.minY, libraries.frame.minY)
        XCTAssertTrue(preview.label.contains("Libraries: Off"), preview.label)
        selectCustomization(libraries, expecting: "On")
        XCTAssertTrue(preview.label.contains("Libraries: On"), preview.label)
        XCTAssertEqual(watching.value as? String, "Use default")
        selectCustomization(libraries, expecting: "Use default")
        XCTAssertTrue(preview.label.contains("Libraries: Off"), preview.label)
        reveal(parent, towardTop: true)
        selectCustomization(parent, expecting: "On")
        reveal(libraries)
        XCTAssertTrue(preview.label.contains("Libraries: On"), preview.label)
        capture("home-library-label-override-below-preview")
    }

    func testLibraryLabelEditorUsesTouchSelectionAndPreservesUseDefault() {
        openSettingsPage("Customize Libraries")
        XCTAssertFalse(app.buttons["card-label-view-recommended"].exists)
        let customize = app.buttons["library-customize-labels"]
        reveal(customize)
        customize.tap()
        XCTAssertTrue(app.navigationBars["Customize labels"].waitForExistence(timeout: 3))
        let target = app.buttons["card-label-page"]
        let value = app.buttons["card-label-view-recommended"]
        let watching = app.buttons["card-label-view-continueWatchingPortrait"]
        XCTAssertEqual(target.label, "Page")
        XCTAssertEqual(target.value as? String, "Recommended")
        XCTAssertTrue(value.exists)
        XCTAssertTrue(watching.exists, "Recommended must show both options together.")
        XCTAssertEqual(value.label, "Default")
        XCTAssertEqual(watching.label, "Continue Watching")
        XCTAssertTrue(app.staticTexts["Overrides"].exists)
        XCTAssertLessThan(value.frame.maxY, app.staticTexts["Overrides"].frame.minY)
        XCTAssertLessThan(app.staticTexts["Overrides"].frame.maxY, watching.frame.minY)
        XCTAssertEqual(value.value as? String, "Mixed")
        let explanation = app.staticTexts["card-label-mixed-help"]
        XCTAssertTrue(explanation.exists)
        XCTAssertTrue(explanation.label.contains("series artwork"))
        XCTAssertFalse(explanation.label.contains("Showcase"), "Mobile help must describe mobile behavior.")
        capture("library-labels-mixed-explained")
        selectCustomization(value, expecting: "Off")
        XCTAssertFalse(explanation.exists, "Mixed help must follow the selected setting.")
        capture("library-labels-recommended-off")
        XCTAssertEqual(watching.value as? String, "Use default")
        let home = app.descendants(matching: .any)["card-label-preview-home"].firstMatch
        let recommended = app.descendants(matching: .any)["card-label-preview-recommended"].firstMatch
        XCTAssertFalse(home.exists, "The preview should stay on the selected page.")
        XCTAssertTrue(recommended.exists)
        XCTAssertLessThan(recommended.frame.maxY, watching.frame.minY,
                          "Recommended must place its Overrides section below the preview too.")
        XCTAssertTrue(app.staticTexts["Continue Watching is shared with Home."].exists)
        selectCustomization(watching, expecting: "On")
        capture("library-labels-watching-shared-on")
        XCTAssertEqual(value.value as? String, "Off", "Continue Watching must not edit the page's labels.")
        selectCustomization(target, expecting: "Browse")
        XCTAssertFalse(watching.exists, "Continue Watching is not another page or a Browse option.")
        XCTAssertFalse(app.staticTexts["Overrides"].exists)
        XCTAssertEqual(app.buttons["card-label-view-browse"].label, "Card labels")
        XCTAssertEqual(app.buttons["card-label-view-browse"].value as? String, "On")
        capture("library-labels-browse")
        selectCustomization(target, expecting: "Recommended")
        XCTAssertEqual(value.value as? String, "Off")
        XCTAssertEqual(watching.value as? String, "On")
        selectCustomization(watching, expecting: "Use default")
        app.navigationBars["Customize labels"].buttons["BackButton"].tap()
        XCTAssertTrue(customize.waitForExistence(timeout: 3))
    }

    func testKidsLibrariesRemainGatedWithTheAlignedCategories() {
        for arguments in [["--kids-settings", "--parental-pin"],
                          ["--kids-settings", "--parental-pin", "--compact-settings"]] {
            launch(settingsRoot: true, arguments: arguments)
            XCTAssertTrue(categoryButton("Playback").exists)
            XCTAssertFalse(categoryButton("Libraries").exists)
            XCTAssertFalse(button("Servers").exists)
            let library = button("Libraries")
            reveal(library, settingsMenu: true)
            library.tap()
            XCTAssertTrue(app.staticTexts["Enter the Parental PIN"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.buttons["Add Server"].exists)
            capture("settings-kids-parental-gate-\(arguments.joined())")
            for digit in 0...9 {
                let key = app.buttons[String(digit)]
                XCTAssertTrue(key.isHittable, "Every PIN digit must remain tappable.")
                XCTAssertEqual(key.frame.width, 74, accuracy: 1)
                XCTAssertEqual(key.frame.height, 74, accuracy: 1)
            }
            let delete = app.buttons["Delete"]
            XCTAssertTrue(delete.isHittable)
            XCTAssertEqual(delete.frame.width, 164, accuracy: 1)
            XCTAssertEqual(delete.frame.height, 74, accuracy: 1)
            app.buttons["1"].tap()
            app.buttons["9"].tap()
            delete.tap()
            for digit in ["2", "3", "4"] { app.buttons[digit].tap() }
            XCTAssertTrue(app.navigationBars["Libraries"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.staticTexts["Enter the Parental PIN"].exists)
            app.terminate()
        }
        launch(settingsRoot: true, arguments: ["--kids-settings"])
        let library = categoryButton("Libraries")
        reveal(library, settingsMenu: true)
        library.tap()
        XCTAssertTrue(app.navigationBars["Libraries"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Enter the Parental PIN"].exists)
    }

    func testSyncBreakdownAndReviewPreview() {
        openSettingsPage("iCloud Sync", verifyTitleLayout: false, arguments: ["--sync-breakdown-fixture"])
        let troubleshooting = button("Troubleshooting")
        reveal(troubleshooting)
        troubleshooting.tap()
        XCTAssertTrue(app.navigationBars["Troubleshooting"].waitForExistence(timeout: 5))
        let settings = app.descendants(matching: .any)["cloud-sync-category-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        capture("sync-data-breakdown")
        let erase = app.buttons["cloud-sync-erase"]
        reveal(erase)
        capture("sync-troubleshooting-recovery")
        erase.tap()
        let proceed = app.buttons["cloud-sync-erase-continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 5))
        XCTAssertEqual(proceed.label, "Erase Sync Data…")
        XCTAssertTrue(app.staticTexts["From iCloud"].exists)
        XCTAssertTrue(app.staticTexts["From this device"].exists)
        XCTAssertTrue(app.staticTexts["Not affected"].exists)
        XCTAssertFalse(app.staticTexts["Start over with iCloud Sync"].exists)
        capture("sync-erasure-review")
        revealSyncErasureControl(proceed)
        capture("sync-erasure-review-actions")
    }

    func testSyncTroubleshootingIsPublicWithSyncOffAndBothCancellationsAreSafe() {
        openSettingsPage("iCloud Sync", verifyTitleLayout: false)
        XCTAssertFalse(app.buttons["Turn Off Developer Mode"].exists)
        let troubleshooting = button("Troubleshooting")
        reveal(troubleshooting)
        troubleshooting.tap()
        XCTAssertTrue(app.navigationBars["Troubleshooting"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Refresh Breakdown"].exists)
        XCTAssertFalse(app.buttons["cloud-sync-reload"].isEnabled)
        let erase = app.buttons["cloud-sync-erase"]
        reveal(erase)
        erase.tap()
        XCTAssertTrue(app.buttons["cloud-sync-erase-continue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let cancel = app.buttons["cloud-sync-erase-cancel"]
        revealSyncErasureControl(cancel)
        cancel.tap()
        XCTAssertTrue(app.buttons["cloud-sync-erase-continue"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Troubleshooting"].waitForExistence(timeout: 5))
        reveal(erase)
        erase.tap()
        let proceed = app.buttons["cloud-sync-erase-continue"]
        revealSyncErasureControl(proceed)
        proceed.tap()
        let alert = app.alerts["Erase sync data?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        capture("sync-erasure-final-confirmation")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(proceed.isEnabled)
        cancel.tap()
        XCTAssertTrue(proceed.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Troubleshooting"].waitForExistence(timeout: 5))
    }

    func testSyncErasureFinalConfirmationInvokesOnlyOnce() {
        app.launchArguments = ["--sync-erasure-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["Review Erasure"].tap()
        let proceed = app.buttons["cloud-sync-erase-continue"]
        revealSyncErasureControl(proceed)
        proceed.tap()
        let alert = app.alerts["Erase sync data?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()
        proceed.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["cloud-sync-erase-final"].firstMatch.tap()
        XCTAssertTrue(proceed.waitForExistence(timeout: 5))
        XCTAssertFalse(proceed.isEnabled)
        app.buttons["cloud-sync-erase-cancel"].tap()
        XCTAssertTrue(proceed.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["fixture-erasure-count"].label, "Erasures: 1")
    }

    func testSyncErasureCannotStartWithoutAuthorization() {
        app.launchArguments = ["--sync-erasure-fixture", "--sync-erasure-denied", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["Review Erasure"].tap()
        let proceed = app.buttons["cloud-sync-erase-continue"]
        revealSyncErasureControl(proceed)
        XCTAssertFalse(proceed.isEnabled)
        app.buttons["cloud-sync-erase-cancel"].tap()
        XCTAssertTrue(proceed.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["fixture-erasure-count"].label, "Erasures: 0")
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
        app.buttons["appearance-theme"].tap()
        XCTAssertTrue(app.navigationBars["Theme"].waitForExistence(timeout: 5))
        let appearance = app.collectionViews.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@", "Appearance", "Appearance,"
        )).firstMatch
        appearance.tap()
        XCTAssertTrue(app.buttons["Light"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["Light"].tap()
        XCTAssertTrue(appearance.staticTexts["Light"].exists)
        let gradient = app.switches["Gradient Backgrounds"]
        let before = gradient.value as? String
        tapNativeSwitch(gradient)
        XCTAssertNotEqual(gradient.value as? String, before)
        XCTAssertTrue(appearance.staticTexts["Light"].exists)
        let glass = button("Liquid Glass")
        glass.tap()
        XCTAssertTrue(app.buttons["System"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.buttons["Light"].exists)
        app.buttons["System"].tap()
        XCTAssertTrue(app.navigationBars["Theme"].exists)
    }

    func testLabelEditsEnterCustomAndPresetsReplaceAllViews() {
        launch()
        app.buttons["appearance-cards"].tap()
        let picker = app.buttons["card-label-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.tap()
        let labels = app.buttons["card-labels-on"]
        XCTAssertTrue(labels.waitForExistence(timeout: 3))
        let appDefault = app.buttons["card-labels-recommended"]
        let hidden = app.buttons["card-labels-off"]
        XCTAssertEqual(appDefault.label, "App default")
        XCTAssertTrue(labels.label.contains("Show labels everywhere"))
        XCTAssertTrue(hidden.label.contains("Hide labels everywhere"))
        XCTAssertFalse(app.staticTexts["Plozz chooses where labels help."].exists)
        XCTAssertFalse(app.staticTexts["View customizations override this choice."].exists)
        labels.tap()
        XCTAssertTrue(picker.label.contains("Show labels everywhere") || picker.staticTexts["Show labels everywhere"].exists)
        capture("compact-labels-shown")
        XCTAssertTrue(app.navigationBars["Cards"].exists)
        let customization = app.buttons["card-label-customization"]
        reveal(customization)
        XCTAssertFalse(customization.label.contains("defaults"))
        customization.tap()
        let home = app.buttons["card-label-view-home"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertEqual(home.value as? String, "On")
        selectCustomization(home, expecting: "Off")
        selectCustomization(home, expecting: "Mixed")
        selectCustomization(home, expecting: "On")
        selectCustomization(home, expecting: "Off")
        let browse = app.buttons["card-label-view-browse"]
        let page = app.buttons["card-label-page"]
        selectCustomization(page, expecting: "Browse")
        selectCustomization(browse, expecting: "Off")
        selectCustomization(browse, expecting: "On")
        let episodes = app.buttons["card-label-view-episodes"]
        selectCustomization(page, expecting: "Movie & show details")
        selectCustomization(episodes, expecting: "Off")
        let filmography = app.buttons["card-label-view-filmography"]
        selectCustomization(page, expecting: "People")
        selectCustomization(filmography, expecting: "Off")
        app.navigationBars.buttons.firstMatch.tap()
        reveal(customization)
        XCTAssertTrue(customization.label.hasSuffix("Custom"))
        reveal(picker, towardTop: true)
        XCTAssertTrue(picker.label.contains("Custom") || picker.staticTexts["Custom"].exists)
        picker.tap()
        labels.tap()
        XCTAssertTrue(picker.label.contains("Show labels everywhere") || picker.staticTexts["Show labels everywhere"].exists)
        reveal(customization)
        XCTAssertFalse(customization.label.hasSuffix("Custom"))
        customization.tap()
        for (name, row) in [("Home", home), ("Browse", browse),
                            ("Movie & show details", episodes), ("People", filmography)] {
            selectCustomization(page, expecting: name)
            reveal(row)
            XCTAssertEqual(row.value as? String, "On")
        }
        app.navigationBars.buttons.firstMatch.tap()
        reveal(picker, towardTop: true)
        picker.tap()
        hidden.tap()
        reveal(customization)
        customization.tap()
        selectCustomization(page, expecting: "Browse")
        XCTAssertEqual(browse.value as? String, "Off")
        app.navigationBars.buttons.firstMatch.tap()
        reveal(picker, towardTop: true)
        picker.tap()
        appDefault.tap()
        reveal(customization)
        customization.tap()
        XCTAssertEqual(home.value as? String, "Mixed")
        selectCustomization(page, expecting: "Browse")
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

    func testArtworkMenusShowOnlySupportedChoicesAndPreserveOtherRows() throws {
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
        let library = app.buttons["Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(library.isSelected, "The menu must check the same effective value shown in the row.")
        XCTAssertTrue(app.buttons["Metadata providers"].exists)
        XCTAssertFalse(app.buttons["Use default"].exists)
        XCTAssertFalse(app.buttons["Mixed"].exists)
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
        selectCustomization(browse, expecting: "Library")
        reveal(hero, towardTop: true, fullyVisible: true)
        XCTAssertEqual(hero.value as? String, "Library", "Changing Browse must not change the hero.")
        app.navigationBars.buttons.firstMatch.tap()
        reveal(customize)
        XCTAssertTrue(customize.label.hasSuffix("Custom"))
        reveal(recommended, towardTop: true)
        recommended.tap()
        XCTAssertTrue(recommended.isSelected)
        reveal(customize)
        customize.tap()
        let details = app.buttons["artwork-view-details"]
        reveal(details, fullyVisible: true)
        XCTAssertEqual(details.value as? String, "Mixed")
        for value in ["Library", "Metadata providers", "Mixed"] {
            selectCustomization(details, expecting: value)
        }
        app.navigationBars.buttons.firstMatch.tap()
        reveal(customize)
        XCTAssertTrue(customize.label.hasSuffix("Custom"), "Mixed is an explicit per-view choice.")
        reveal(recommended, towardTop: true)
        recommended.tap()
        XCTAssertTrue(recommended.isSelected, "The preset remains the reset for all customizations.")
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
        XCTAssertTrue(app.buttons["Mixed"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["Mixed"].isSelected)
        XCTAssertTrue(app.buttons["On"].exists)
        XCTAssertTrue(app.buttons["Off"].exists)
        XCTAssertFalse(app.buttons["Use default"].exists)
        try assertMenuKeepsRowTitle("Home rows", in: titleFrame)
        capture("label-choice-menu")
        app.buttons["Off"].tap()
        XCTAssertEqual(home.value as? String, "Off")
        selectCustomization(home, expecting: "Mixed")
        let browse = app.buttons["card-label-view-browse"]
        browse.tap()
        XCTAssertTrue(app.buttons["On"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["On"].isSelected)
        XCTAssertTrue(app.buttons["Off"].exists)
        XCTAssertFalse(app.buttons["Mixed"].exists)
        XCTAssertFalse(app.buttons["Use default"].exists)
        app.buttons["Off"].tap()
        XCTAssertEqual(browse.value as? String, "Off")
    }

    func testArtworkPresetsHaveAnExternalHeadingAndSeparateCustomizationGroup() {
        launch()
        app.buttons["appearance-artwork"].tap()
        let recommended = app.buttons["artwork-preset-recommended"]
        XCTAssertTrue(recommended.waitForExistence(timeout: 3))
        let group = app.cells.containing(.button, identifier: "artwork-preset-recommended").firstMatch
        XCTAssertTrue(group.exists, app.debugDescription)
        let heading = app.staticTexts["artwork-preset-heading"]
        XCTAssertTrue(heading.exists)
        XCTAssertLessThanOrEqual(heading.frame.maxY, group.frame.minY)
        let customize = app.buttons["artwork-customization"]
        reveal(customize, fullyVisible: true)
        let customizationGroup = app.cells.containing(.button, identifier: "artwork-customization").firstMatch
        XCTAssertTrue(customizationGroup.exists, app.debugDescription)
        XCTAssertGreaterThanOrEqual(customizationGroup.frame.minY, group.frame.maxY)
        XCTAssertGreaterThan(app.staticTexts["Customize by view"].frame.minY - group.frame.maxY, 24)
        for name in ["recommended", "library", "online"] {
            XCTAssertTrue(group.buttons["artwork-preset-\(name)"].exists)
            XCTAssertFalse(customizationGroup.buttons["artwork-preset-\(name)"].exists)
        }
        capture("artwork-separated-presets")
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
        let title = option ?? value
        let choice = app.buttons[title]
        XCTAssertTrue(choice.waitForExistence(timeout: 3), app.debugDescription)
        choice.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(row.value as? String, value, app.debugDescription)
    }

    func testSettingsSectionsOpenTheirOwnDestinations() {
        for title in [
            "Playback", "Subtitles", "Live TV", "Libraries", "Appearance", "Screens & Navigation",
            "Trackers", "Customize Home", "App navigation", "Detail Page", "Theme", "Spoiler Protection", "Circadian Mode",
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

    func testPlayerOrientationChoicesStayInPlaybackSettingsOnIPhone() {
        openSettingsPage("Playback")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertFalse(app.staticTexts["playback-orientation-ipad-help"].exists)
            XCTAssertFalse(app.buttons["playback-orientation"].exists)
            return
        }
        let orientation = app.buttons["playback-orientation"]
        reveal(orientation)
        XCTAssertTrue(orientation.staticTexts["Landscape"].exists)
        for choice in ["Landscape", "Portrait", "Auto"] {
            orientation.tap()
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 3))
            app.buttons[choice].tap()
            XCTAssertTrue(orientation.staticTexts[choice].exists)
        }
    }

    func testPlaybackSettingsKeepTechnicalDetailsInAdvanced() {
        launchPlayback()
        let advanced = app.buttons["streaming-advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["streaming-codec"].exists)
        XCTAssertFalse(app.switches["streaming-force-transcoding"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "For movies and episodes from Plex"
        )).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Applies only to the full-screen video player."
        )).firstMatch.exists)
        capture("playback-simplified")

        let local = button("Local network")
        XCTAssertTrue(local.isEnabled)
        XCTAssertFalse(app.buttons["streaming-unavailable"].exists)
        XCTAssertFalse(app.staticTexts["Unavailable for network shares."].exists)
        local.tap()
        XCTAssertTrue(app.buttons["1080p · 8 Mbps"].waitForExistence(timeout: 3))
        app.buttons["1080p · 8 Mbps"].tap()
        XCTAssertTrue(app.navigationBars["Playback"].exists, "Quality menus must not open Advanced.")
        let remoteBefore = button("Remote Wi-Fi / Ethernet").label
        let cellularBefore = button("Cellular").label
        advanced.tap()
        XCTAssertTrue(app.navigationBars["Streaming quality"].waitForExistence(timeout: 5))
        for prefix in ["Lets the server", "Uses your server", "Silo currently", "Limits apply"] {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(
                format: "label BEGINSWITH %@", prefix
            )).firstMatch.exists)
        }
        XCTAssertFalse(app.staticTexts["May change HDR and audio formats."].exists)
        capture("playback-advanced-minimal")
        let codec = app.buttons["streaming-codec"]
        codec.tap()
        app.buttons["Prefer H.264"].tap()
        XCTAssertEqual(codec.value as? String, "Prefer H.264")
        let force = app.switches["streaming-force-transcoding"]
        tapNativeSwitch(force)
        XCTAssertEqual(force.value as? String, "1")
        XCTAssertTrue(app.staticTexts["May change HDR and audio formats."].waitForExistence(timeout: 3))
        capture("playback-advanced-warning")
        tapNativeSwitch(force)
        XCTAssertTrue(app.staticTexts["May change HDR and audio formats."].waitForNonExistence(timeout: 3))
        tapNativeSwitch(force)
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        XCTAssertEqual(local.value as? String, "1080p · 8 Mbps")
        XCTAssertEqual(button("Remote Wi-Fi / Ethernet").label, remoteBefore)
        XCTAssertEqual(button("Cellular").label, cellularBefore)
        advanced.tap()
        XCTAssertTrue(codec.waitForExistence(timeout: 5))
        XCTAssertEqual(codec.value as? String, "Prefer H.264")
        XCTAssertEqual(force.value as? String, "1")
    }

    func testStreamingQualityMakesShareOnlyRestrictionExplicit() {
        launchPlayback("--share-only-playback")
        let quality = app.buttons["streaming-unavailable"]
        XCTAssertTrue(quality.waitForExistence(timeout: 5))
        XCTAssertFalse(quality.isEnabled)
        XCTAssertTrue(quality.staticTexts["Original quality"].exists)
        XCTAssertTrue(app.staticTexts["Unavailable for network shares."].exists)
        XCTAssertFalse(button("Local network").exists)
        XCTAssertFalse(button("Remote Wi-Fi / Ethernet").exists)
        XCTAssertFalse(button("Cellular").exists)
        XCTAssertFalse(app.buttons["streaming-advanced"].exists)
        XCTAssertTrue(app.buttons["playback-read-ahead"].isEnabled)
        capture("playback-quality-unavailable")
    }

    func testUnavailableStreamingQualityExplanationRemainsVisibleAtAccessibilitySize() {
        launchPlayback("--share-only-playback", "--large-text")
        let quality = app.buttons["streaming-unavailable"]
        reveal(quality, fullyVisible: true)
        XCTAssertFalse(quality.isEnabled)
        XCTAssertTrue(quality.staticTexts["Original quality"].exists)
        let explanation = app.staticTexts["Unavailable for network shares."]
        reveal(explanation, fullyVisible: true)
        XCTAssertTrue(explanation.isHittable)
        capture("playback-quality-unavailable-large-text")
    }

    func testPlaybackAdvancedKeepsUnsupportedCodecsDisabled() {
        launchPlayback("--silo-streaming")
        app.buttons["streaming-advanced"].tap()
        let codec = app.buttons["streaming-codec"]
        XCTAssertTrue(codec.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Silo currently converts"
        )).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Choose a supported codec."].exists)
        codec.tap()
        XCTAssertTrue(app.buttons["Prefer HEVC (H.265)"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Prefer HEVC (H.265)"].isEnabled)
        app.buttons["Prefer H.264"].tap()
        XCTAssertEqual(codec.value as? String, "Prefer H.264")
        XCTAssertTrue(app.staticTexts["Choose a supported codec."].waitForNonExistence(timeout: 3))
    }

    func testPlaybackValueMenusRemainEditableAtAccessibilitySize() {
        launchPlayback("--large-text")
        for title in ["Local network", "Remote Wi-Fi / Ethernet", "Cellular"] {
            let row = button(title)
            reveal(row, fullyVisible: true)
            XCTAssertGreaterThanOrEqual(row.frame.height, 44)
            capture("playback-editable-\(title)")
            row.tap()
            XCTAssertTrue(app.buttons["1080p · 8 Mbps"].waitForExistence(timeout: 3))
            app.buttons["1080p · 8 Mbps"].tap()
            XCTAssertEqual(row.value as? String, "1080p · 8 Mbps")
        }
        let advanced = app.buttons["streaming-advanced"]
        reveal(advanced, fullyVisible: true)
        advanced.tap()
        let codec = app.buttons["streaming-codec"]
        XCTAssertTrue(codec.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(codec.frame.height, 44)
        codec.tap()
        app.buttons["Prefer HEVC (H.265)"].tap()
        XCTAssertEqual(codec.value as? String, "Prefer HEVC (H.265)")
        capture("playback-editable-codec-large-text")
    }

    func testPlaybackPrivacyDisclosureRemainsVisibleAtAccessibilitySize() throws {
        launchPlayback("--large-text")
        let copy = "Looks up missing markers on IntroDB and TheIntroDB using IMDb/TMDB IDs."
        let disclosure = app.staticTexts[copy]
        reveal(disclosure, fullyVisible: true)
        XCTAssertTrue(disclosure.isHittable)
        let image = try XCTUnwrap(disclosure.screenshot().image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.customWords = ["IntroDB", "TheIntroDB", "IMDb", "TMDB"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let rendered = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        // OCR confuses I/l in this font; the accessibility lookup checks the exact copy.
        let normalize = { (text: String) in text.lowercased().replacingOccurrences(of: "l", with: "i") }
        XCTAssertEqual(normalize(rendered), normalize(copy), "The complete disclosure must be visible, not truncated.")
        capture("playback-large-text")
    }

    func testReadAheadPresetsPersistForShareOnlyPlayback() {
        launchPlayback("--share-only-playback", "--reset-read-ahead")
        let picker = app.buttons["playback-read-ahead"]
        reveal(picker, fullyVisible: true)
        XCTAssertTrue(picker.staticTexts["Automatic"].exists)
        for choice in ["1 minute", "5 minutes", "10 minutes", "Maximum available", "Automatic", "10 minutes"] {
            picker.tap()
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 3))
            app.buttons[choice].tap()
            XCTAssertTrue(picker.staticTexts[choice].exists)
        }
        capture("read-ahead-share-only")
        app.terminate()
        launchPlayback("--share-only-playback")
        reveal(picker, fullyVisible: true)
        XCTAssertTrue(picker.staticTexts["10 minutes"].exists)
        picker.tap()
        app.buttons["Automatic"].tap()
    }

    func testReadAheadMaximumRemainsEditableAtAccessibilitySize() {
        launchPlayback("--large-text", "--reset-read-ahead")
        let picker = app.buttons["playback-read-ahead"]
        reveal(picker, fullyVisible: true)
        XCTAssertTrue(picker.label.contains("Video buffer"))
        picker.tap()
        XCTAssertTrue(app.buttons["Maximum available"].waitForExistence(timeout: 3))
        app.buttons["Maximum available"].tap()
        XCTAssertTrue(picker.staticTexts["Maximum available"].exists)
        let explanation = app.staticTexts[
            "Larger buffers use more storage. Unavailable with Apple’s native player."
        ]
        reveal(explanation, fullyVisible: true)
        XCTAssertTrue(explanation.isHittable)
        capture("read-ahead-maximum-large-text")
        reveal(picker, fullyVisible: true)
        picker.tap()
        app.buttons["Automatic"].tap()
    }

    private func launchPlayback(_ arguments: String...) {
        app.launchArguments = [
            "--playback-settings-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ] + arguments
        app.launch()
        XCTAssertTrue(app.navigationBars["Playback"].waitForExistence(timeout: 5))
    }

    func testCompactSkipDefaultsShowEffectiveValueAndNativeMenuChoices() {
        launchPlayback()
        let customize = app.buttons["skip-marker-settings"]
        reveal(customize, fullyVisible: true)
        customize.tap()
        let shared = app.buttons["skip-behavior-default"]
        XCTAssertTrue(shared.waitForExistence(timeout: 5), app.debugDescription)
        shared.tap()
        app.buttons["Skip instantly"].tap()
        XCTAssertEqual(shared.value as? String, "Skip instantly")
        app.buttons["skip-marker-intro"].tap()
        let movie = app.buttons["skip-behavior-intro-movie"]
        let anime = app.buttons["skip-behavior-intro-anime"]
        XCTAssertTrue(movie.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(movie.value as? String, "Skip instantly (default)")
        anime.tap()
        app.buttons["Show skip button"].tap()
        XCTAssertEqual(anime.value as? String, "Show skip button")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Default:")).firstMatch.exists)
        capture("compact-skip-default-closed")
        movie.tap()
        let choices = ["Use default", "Show skip button", "Skip instantly", "Skip after", "Off"]
        for title in choices {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), app.debugDescription)
        }
        for (previous, next) in zip(choices, choices.dropFirst()) {
            XCTAssertLessThan(app.buttons[previous].frame.midY, app.buttons[next].frame.midY)
        }
        XCTAssertGreaterThan(
            app.buttons["Off"].frame.minY - app.buttons["Skip after"].frame.maxY,
            app.buttons["Skip after"].frame.minY - app.buttons["Skip instantly"].frame.maxY
        )
        capture("compact-skip-default-menu-open")
        app.buttons["Show skip button"].tap()
        XCTAssertEqual(movie.value as? String, "Show skip button")
        XCTAssertEqual(anime.value as? String, "Show skip button")
        movie.tap()
        app.buttons["Use default"].tap()
        XCTAssertEqual(movie.value as? String, "Skip instantly (default)")
        XCTAssertEqual(anime.value as? String, "Show skip button")
        movie.tap()
        app.buttons["Off"].tap()
        XCTAssertEqual(movie.value as? String, "Off")
        XCTAssertEqual(anime.value as? String, "Show skip button")
        movie.tap()
        app.buttons["Use default"].tap()
        XCTAssertEqual(movie.value as? String, "Skip instantly (default)")
    }

    func testSpoilerSwitchesAndMenuRemainIndependent() {
        openSettingsPage("Spoiler Protection", verifyTitleLayout: false)
        let protection = app.switches["Protect unwatched episodes"]
        let ratings = app.switches["Hide ratings until watched"]
        let treatment = button("Thumbnail treatment")
        XCTAssertFalse(treatment.isEnabled)
        tapNativeSwitch(protection)
        XCTAssertTrue(treatment.isEnabled)
        treatment.tap()
        XCTAssertTrue(app.buttons["Placeholder Art"].waitForExistence(timeout: 3))
        app.buttons["Placeholder Art"].tap()
        XCTAssertTrue(treatment.staticTexts["Placeholder Art"].exists)
        XCTAssertEqual(protection.value as? String, "1")
        XCTAssertEqual(ratings.value as? String, "0")
        tapNativeSwitch(ratings)
        XCTAssertEqual(ratings.value as? String, "1")
        XCTAssertTrue(treatment.staticTexts["Placeholder Art"].exists)
        tapNativeSwitch(protection)
        XCTAssertFalse(treatment.isEnabled)
        XCTAssertEqual(ratings.value as? String, "1")
    }

    func testSubtitleToggleInsertsOnlyItsOwnNavigationRow() {
        openSettingsPage("Subtitles", verifyTitleLayout: false)
        let liveStyle = app.switches["Use a separate style for Live TV"]
        XCTAssertEqual(liveStyle.value as? String, "0")
        tapNativeSwitch(liveStyle)
        let liveLink = button("Customize Live TV subtitles")
        XCTAssertTrue(liveLink.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(button("Customize subtitle style").exists)
        tapNativeSwitch(liveStyle)
        XCTAssertFalse(liveLink.exists)
        let hearing = app.buttons["subtitle-sdh"]
        reveal(hearing)
        let forced = button("Forced subtitles")
        let forcedBefore = forced.label
        hearing.tap()
        capture("subtitle-search-menu")
        XCTAssertTrue(app.buttons["Prefer SDH"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["Prefer SDH"].tap()
        XCTAssertTrue(hearing.staticTexts["Prefer SDH"].exists)
        XCTAssertEqual(forced.label, forcedBefore)
        let fallback = app.staticTexts["Use SDH when available; otherwise use regular subtitles."]
        reveal(fallback, fullyVisible: true)
        XCTAssertTrue(fallback.isHittable)
        reveal(hearing, fullyVisible: true)
        hearing.tap()
        app.buttons["Only SDH"].tap()
        XCTAssertTrue(hearing.staticTexts["Only SDH"].exists)
        let strict = app.staticTexts["Use only SDH. Leave subtitles off if unavailable."]
        reveal(strict, fullyVisible: true)
        XCTAssertTrue(strict.isHittable)
        capture("subtitle-sdh-behavior")
    }

    func testCircadianPictureMenusAndPreviewKeepSeparateActions() {
        openSettingsPage("Circadian Mode", verifyTitleLayout: false)
        tapNativeSwitch(app.switches["Circadian Mode"])
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
        openSettingsPage("Live TV", verifyTitleLayout: false)
        let sort = app.segmentedControls.firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 3))
        sort.buttons["Name"].tap()
        XCTAssertTrue(sort.buttons["Name"].isSelected)
        let preview = app.switches["Preview after watching"]
        let recent = app.switches["Recently watched"]
        let recentBefore = recent.value as? String
        let previewBefore = preview.value as? String
        capture("live-tv-native-switches")
        tapNativeSwitch(preview)
        XCTAssertNotEqual(preview.value as? String, previewBefore)
        XCTAssertEqual(recent.value as? String, recentBefore)
        XCTAssertTrue(sort.buttons["Name"].isSelected)
    }

    func testContinueWatchingRowOpensItsOwnSettings() {
        openSettingsPage("Customize Home")
        openHomeSections()
        let label = app.staticTexts["Continue Watching"].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 3), app.debugDescription)
        label.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        capture("after-tapping-continue-watching-label")
        XCTAssertTrue(app.navigationBars["Continue Watching"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.switches["home-merge-next-up"].exists)
        XCTAssertFalse(app.navigationBars["Rows on Home"].exists)
    }

    func testContinueWatchingOffersThreeStablePresentationChoices() {
        openSettingsPage("Customize Home")
        openHomeSections()
        app.buttons["home-section-home-continueWatching"].tap()
        XCTAssertTrue(app.navigationBars["Continue Watching"].waitForExistence(timeout: 3))
        let merge = app.switches["home-merge-next-up"]
        XCTAssertTrue(merge.label.contains("Include Next Up"))
        XCTAssertTrue(merge.label.contains("Combines Next Up rows here."))
        let choices = ["logoAndArtwork", "thumbnail", "portraitPosters"].map {
            app.buttons["continue-watching-style-\($0)"]
        }
        for selected in [1, 2, 0] {
            let choice = choices[selected]
            reveal(choice)
            choice.tap()
            for (index, option) in choices.enumerated() {
                XCTAssertTrue(option.exists)
                XCTAssertEqual(option.isSelected, index == selected)
            }
            XCTAssertEqual(choice.label, ["Artwork + logo", "Thumbnail", "Poster"][selected])
            let labels = app.buttons["card-label-view-continueWatchingPortrait"]
            XCTAssertTrue(labels.exists)
            selectCustomization(labels, expecting: "On")
            capture("continue-watching-\(selected)-labels-on")
            selectCustomization(labels, expecting: "Off")
            capture("continue-watching-\(selected)-labels-off")
            let details = app.buttons["continue-watching-playback-details"]
            XCTAssertTrue(details.exists)
            for option in choices {
                XCTAssertFalse(option.frame.intersects(details.frame),
                               "Decorative preview content must not expand a choice over the playback control.")
            }
            selectCustomization(details, expecting: "Progress only")
            selectCustomization(details, expecting: "Detailed")
            if selected == 2 { capture("continue-watching-three-presentations") }
        }
        XCTAssertFalse(app.segmentedControls["continue-watching-layout"].exists)
    }

    func testContinueWatchingLabelsShareTheAppearanceOverride() {
        openSettingsPage("Customize Home")
        openHomeSections()
        app.buttons["home-section-home-continueWatching"].tap()
        let portrait = app.buttons["continue-watching-style-portraitPosters"]
        reveal(portrait, fullyVisible: true)
        portrait.tap()
        let labels = app.buttons["card-label-view-continueWatchingPortrait"]
        XCTAssertTrue(labels.waitForExistence(timeout: 3))
        XCTAssertEqual(labels.value as? String, "Use default")
        let details = app.buttons["continue-watching-playback-details"]
        XCTAssertTrue(details.exists)
        XCTAssertEqual(details.value as? String, "Detailed")
        selectCustomization(details, expecting: "Progress only")
        selectCustomization(labels, expecting: "On")
        capture("continue-watching-portrait-labels")
        for title in ["Continue Watching", "Home rows", "Customize Home", "Screens & Navigation"] {
            app.navigationBars[title].buttons["BackButton"].tap()
        }
        let appearance = categoryButton("Appearance")
        reveal(appearance, settingsMenu: true)
        appearance.tap()
        app.buttons["appearance-cards"].tap()
        let customize = app.buttons["card-label-customization"]
        reveal(customize)
        customize.tap()
        XCTAssertTrue(labels.waitForExistence(timeout: 3))
        XCTAssertEqual(labels.value as? String, "On")
        selectCustomization(labels, expecting: "Off")
        capture("appearance-portrait-labels")
        for title in ["Customize labels", "Cards", "Appearance"] {
            app.navigationBars[title].buttons["BackButton"].tap()
        }
        let screens = categoryButton("Screens & Navigation")
        reveal(screens, settingsMenu: true)
        screens.tap()
        button("Customize Home").tap()
        openHomeSections()
        app.buttons["home-section-home-continueWatching"].tap()
        XCTAssertTrue(labels.waitForExistence(timeout: 3))
        XCTAssertEqual(labels.value as? String, "Off")
        let landscape = app.buttons["continue-watching-style-logoAndArtwork"]
        reveal(landscape, fullyVisible: true)
        landscape.tap()
        XCTAssertTrue(labels.exists)
        XCTAssertEqual(labels.value as? String, "Off")
        XCTAssertTrue(details.exists)
        XCTAssertEqual(details.value as? String, "Progress only")
        reveal(portrait, fullyVisible: true)
        portrait.tap()
        XCTAssertTrue(labels.waitForExistence(timeout: 3))
        XCTAssertEqual(labels.value as? String, "Off", "Changing artwork must preserve the label override.")
        XCTAssertEqual(details.value as? String, "Progress only", "Artwork and caption changes must preserve playback details.")
        selectCustomization(details, expecting: "Detailed")
        selectCustomization(labels, expecting: "Use default")
    }

    func testContinueWatchingGroupedControlsKeepSelectionsIndependent() {
        openSettingsPage("Customize Home")
        openHomeSections()
        app.buttons["home-section-home-continueWatching"].tap()
        XCTAssertTrue(app.navigationBars["Continue Watching"].waitForExistence(timeout: 3))
        let artwork = app.buttons["continue-watching-style-portraitPosters"]
        let details = app.buttons["continue-watching-playback-details"]
        let labels = app.buttons["card-label-view-continueWatchingPortrait"]
        let merge = app.switches["home-merge-next-up"]
        let action = app.buttons["continue-watching-action"]
        reveal(artwork, fullyVisible: true)
        artwork.tap()
        XCTAssertLessThan(artwork.frame.maxY, details.frame.minY)
        XCTAssertLessThan(details.frame.maxY, labels.frame.minY)
        XCTAssertLessThan(labels.frame.maxY, merge.frame.minY)
        XCTAssertLessThan(merge.frame.maxY, action.frame.minY)
        selectCustomization(details, expecting: "Progress only")
        selectCustomization(labels, expecting: "On")
        let mergeBefore = merge.value as? String
        selectCustomization(action, expecting: "Open detail page")
        XCTAssertEqual(merge.value as? String, mergeBefore)
        XCTAssertEqual(details.value as? String, "Progress only")
        XCTAssertEqual(labels.value as? String, "On")
        XCTAssertTrue(artwork.isSelected)
        reveal(merge, fullyVisible: true)
        tapNativeSwitch(merge)
        XCTAssertNotEqual(merge.value as? String, mergeBefore)
        XCTAssertEqual(action.value as? String, "Open detail page")
        capture("continue-watching-grouped-controls")
    }

    func testHeroSettingsNavigationKeepsProfileModelsAndEdits() {
        openSettingsPage("Customize Home")
        app.buttons["home-section-hero"].tap()
        for (page, title, setting) in [
            ("ratings", "Ratings", "hero-ratings"),
            ("trailers", "Trailers", "hero-trailers")
        ] {
            let link = app.buttons["hero-settings-\(page)"]
            reveal(link)
            link.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
            let toggle = app.switches[setting]
            XCTAssertTrue(toggle.waitForExistence(timeout: 3), app.debugDescription)
            let before = toggle.value as? String
            tapNativeSwitch(toggle)
            let after = toggle.value as? String
            XCTAssertNotEqual(after, before)
            app.navigationBars[title].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Hero"].waitForExistence(timeout: 3))
            reveal(link)
            XCTAssertTrue(link.label.contains(after == "1" ? "On" : "Off"), link.label)
            link.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
            XCTAssertEqual(toggle.value as? String, after, "Reopening must use the same profile model.")
            app.navigationBars[title].buttons.firstMatch.tap()
        }
    }

    func testNestedHeroSettingsNavigationKeepsProfileModels() {
        openSettingsPage("Customize Home")
        app.buttons["home-section-hero"].tap()
        let sources = app.buttons["hero-settings-titles"]
        reveal(sources)
        sources.tap()
        XCTAssertTrue(app.navigationBars["Hero content sources"].waitForExistence(timeout: 5))
        for (source, page, title, content) in [
            ("Random from Library", "libraries", "Random libraries", "No movie or TV libraries are enabled on Home."),
            ("Collections", "collections", "Choose collections", "No available collection sources."),
            ("Discovery", "discovery", "Discovery", "Show provider labels")
        ] {
            let toggle = app.switches[source]
            reveal(toggle, fullyVisible: true)
            if toggle.value as? String != "1" { tapNativeSwitch(toggle) }
            let link = app.buttons["hero-settings-\(page)"]
            reveal(link)
            link.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.staticTexts[content].firstMatch.waitForExistence(timeout: 3), app.debugDescription)
            if page == "discovery" {
                let labels = app.switches["Show provider labels"]
                let before = labels.value as? String
                tapNativeSwitch(labels)
                XCTAssertNotEqual(labels.value as? String, before)
            }
            app.navigationBars[title].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Hero content sources"].waitForExistence(timeout: 3))
            XCTAssertEqual(toggle.value as? String, "1", "Nested navigation must not replace the source settings.")
        }
    }

    private func openHomeSections() {
        let sections = app.buttons["home-sections-settings"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5), app.debugDescription)
        sections.tap()
        XCTAssertTrue(app.navigationBars["Home rows"].waitForExistence(timeout: 3), app.debugDescription)
    }

    func testHomeSectionArtworkAndMergeKeepSeparateActions() {
        openSettingsPage("Customize Home")
        let hero = app.buttons["home-section-hero"]
        let labels = app.buttons["home-customize-labels"]
        let sectionsLink = app.buttons["home-sections-settings"]
        let page = settingsPageFrame(containing: "home-section-hero")
        for link in [hero, labels, sectionsLink] {
            XCTAssertEqual(link.frame.minX - page.minX, 24, accuracy: 2)
            XCTAssertEqual(page.maxX - link.frame.maxX, 24, accuracy: 2)
            XCTAssertGreaterThanOrEqual(link.frame.height, 44)
        }
        XCTAssertLessThan(hero.frame.maxY, labels.frame.minY)
        XCTAssertLessThan(labels.frame.maxY, sectionsLink.frame.minY)
        XCTAssertFalse(app.buttons["home-row-preset"].exists)
        XCTAssertFalse(app.buttons["home-section-reorder"].exists)
        capture("home-customization-hub")
        openHomeSections()
        let sections = app.descendants(matching: .any)["home-section-controls"].firstMatch
        let preset = app.buttons["home-row-preset"]
        let reorder = app.buttons["home-section-reorder"]
        XCTAssertTrue(preset.isHittable, app.debugDescription)
        XCTAssertEqual(preset.label, "Preset")
        XCTAssertTrue(sections.frame.contains(preset.frame))
        XCTAssertGreaterThanOrEqual(preset.frame.height, 44)
        XCTAssertGreaterThan(preset.frame.minY, reorder.frame.maxY)
        XCTAssertGreaterThanOrEqual(preset.frame.minX, page.minX + 20)
        XCTAssertLessThanOrEqual(preset.frame.maxX, page.maxX - 20)
        let add = app.buttons["home-section-add"]
        XCTAssertTrue(add.isHittable, app.debugDescription)
        XCTAssertEqual(add.label, "Add row")
        XCTAssertEqual(add.frame.minX, sections.frame.minX, accuracy: 2)
        XCTAssertEqual(add.frame.width, sections.frame.width, accuracy: 2)
        XCTAssertGreaterThan(add.frame.minY, sections.frame.maxY)
        XCTAssertGreaterThanOrEqual(app.buttons["home-section-home-continueWatching"].frame.minY - add.frame.maxY, 24)
        XCTAssertFalse(app.navigationBars["Home rows"].buttons["home-section-add"].exists,
                       "The full-width action replaces the small toolbar icon.")
        XCTAssertTrue(app.navigationBars["Home rows"].buttons["home-section-reorder"].exists,
                      "The dedicated editor owns its native toolbar Edit/Done action.")
        XCTAssertTrue(reorder.isHittable, app.debugDescription)
        XCTAssertGreaterThan(reorder.frame.minX, page.midX)
        XCTAssertFalse(app.buttons["home-section-add-bottom"].exists)
        capture("home-section-action-bar-and-gutters")
        let watching = app.buttons["home-section-home-continueWatching"]
        XCTAssertTrue(watching.waitForExistence(timeout: 3), app.debugDescription)
        watching.tap()
        let merge = app.switches["home-merge-next-up"]
        let original = merge.value as? String
        let thumbnail = app.buttons["continue-watching-style-thumbnail"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertLessThan(thumbnail.frame.height, thumbnail.frame.width * 1.5,
                          "Artwork cards should scale with width, not keep the old 200pt swatch slot.")
        XCTAssertGreaterThanOrEqual(thumbnail.frame.height, 44)
        capture("home-section-compact-artwork")
        thumbnail.tap()
        XCTAssertTrue(app.navigationBars["Continue Watching"].exists)
        XCTAssertEqual(merge.value as? String, original)
        tapNativeSwitch(merge)
        let updated = merge.value as? String
        XCTAssertNotEqual(original, updated)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home rows"].waitForExistence(timeout: 3))
        watching.tap()
        XCTAssertEqual(merge.value as? String, updated)
        XCTAssertTrue(thumbnail.isSelected, app.debugDescription)
    }

    func testHomeRowPresetsRequireConfirmationAndKeepRowsEditable() {
        openSettingsPage("Customize Home")
        openHomeSections()
        let preset = app.buttons["home-row-preset"]
        XCTAssertTrue(preset.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(preset.label.contains("Match server") || preset.value as? String == "Match server")
        preset.tap()
        let same = app.buttons["Match server"]
        XCTAssertTrue(same.waitForExistence(timeout: 3), app.debugDescription)
        same.tap()
        XCTAssertFalse(app.staticTexts["Replace your row arrangement?"].exists)

        preset.tap()
        app.buttons["Combined rows"].tap()
        XCTAssertTrue(app.staticTexts["Replace your row arrangement?"].waitForExistence(timeout: 3))
        capture("home-row-preset-confirmation")
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(dismissRegion.exists, app.debugDescription)
            dismissRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95)).tap()
        }
        XCTAssertTrue(app.staticTexts["Replace your row arrangement?"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(preset.label.contains("Match server") || preset.value as? String == "Match server")

        preset.tap()
        app.buttons["Combined rows"].tap()
        let confirm = app.buttons["Combined rows"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Replace your row arrangement?"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Home rows"].exists)
        XCTAssertTrue(app.buttons["home-section-home-recentlyAdded"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["HIDDEN"].exists)
        XCTAssertTrue(preset.label.contains("Combined rows") || preset.value as? String == "Combined rows")
        capture("home-row-shared-preset")
    }

    func testHomeRowNativeDragReordersAndPersists() {
        openSettingsPage("Customize Home")
        let hero = app.buttons["home-section-hero"]
        let heroLabel = hero.label
        openHomeSections()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder '")).count, 0)
        let reorder = app.buttons["home-section-reorder"]
        let original = app.buttons["home-section-home-continueWatching"]
        original.press(forDuration: 1)
        let menu = app.collectionViews.buttons["Reorder"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.collectionViews.buttons["Remove from Home"].exists)
        menu.tap()
        XCTAssertEqual(reorder.label, "Done")
        XCTAssertFalse(app.buttons["home-row-preset"].isEnabled)
        XCTAssertFalse(app.buttons["home-section-add"].isEnabled)
        XCTAssertFalse(app.buttons["home-section-add-bottom"].exists)
        XCTAssertFalse(hero.exists)
        XCTAssertFalse(app.staticTexts["HIDDEN"].exists)
        let watching = app.staticTexts["Continue Watching"].firstMatch
        let watchlist = app.staticTexts["Watchlist"].firstMatch
        XCTAssertTrue(watching.waitForExistence(timeout: 3))
        XCTAssertLessThan(watching.frame.minY, watchlist.frame.minY)
        let cell = app.cells.containing(.staticText, identifier: "Continue Watching").firstMatch
        let handle = cell.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder '")).firstMatch
        XCTAssertTrue(handle.isHittable, app.debugDescription)
        capture("home-row-before-native-drag")
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = start.withOffset(CGVector(dx: 0, dy: watchlist.frame.maxY - watching.frame.midY))
        start.press(forDuration: 1, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 3)
        let reordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in watching.frame.minY > watchlist.frame.minY }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 3), .completed, app.debugDescription)
        XCTAssertTrue(reorder.isHittable, "Done must stay reachable in the native toolbar after dragging.")
        XCTAssertFalse(hero.exists, "Page appearance must not enter the section editor.")
        capture("home-row-after-native-drag")
        reorder.tap()
        XCTAssertEqual(reorder.label, "Edit")
        let preset = app.buttons["home-row-preset"]
        XCTAssertTrue(preset.label.contains("Custom") || preset.value as? String == "Custom")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder '")).count, 0)
        app.navigationBars["Home rows"].buttons.firstMatch.tap()
        XCTAssertTrue(hero.waitForExistence(timeout: 3))
        XCTAssertEqual(hero.label, heroLabel)
        openHomeSections()
        reorder.tap()
        XCTAssertGreaterThan(watching.frame.minY, watchlist.frame.minY)
    }

    func testScreenCustomizationHierarchyKeepsNavigationAndPageScopesSeparate() {
        openSettingsPage("Screens & Navigation")
        let navigation = app.buttons["screens-navigation"]
        let spoilers = app.buttons["screens-spoilers"]
        XCTAssertLessThan(navigation.frame.maxY, spoilers.frame.minY)
        capture("screen-customization-entry")
        openSettingsPage("Customize Libraries")
        let tabs = app.buttons["library-navigation-settings"]
        let labels = app.buttons["library-customize-labels"]
        let rows = app.staticTexts["Recommended rows"]
        XCTAssertLessThan(tabs.frame.maxY, labels.frame.minY)
        XCTAssertLessThan(labels.frame.maxY, rows.frame.minY)
        XCTAssertFalse(app.buttons["home-row-preset"].exists)
        XCTAssertFalse(app.buttons["home-section-reorder"].exists)
        capture("library-customization-scopes")
        openSettingsPage("Detail Page")
        let detailLabels = app.buttons["detail-customize-labels"]
        reveal(detailLabels)
        let background = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Background,")).firstMatch
        XCTAssertTrue(background.exists)
        XCTAssertLessThan(background.frame.maxY, detailLabels.frame.minY)
        XCTAssertFalse(app.buttons["home-section-reorder"].exists)
        capture("detail-customization-scopes")
        detailLabels.tap()
        XCTAssertTrue(app.buttons["card-label-view-episodes"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["card-label-page"].exists, "Detail labels stay in the existing scoped editor.")
    }

    func testHomeSectionsCanBeRemovedAndAddedWithoutChangingTheirSettings() {
        openSettingsPage("Customize Home")
        openHomeSections()
        let watching = app.buttons["home-section-home-continueWatching"]
        for identifier in ["home-section-add"] {
            reveal(watching)
            watching.tap()
            let merge = app.switches["home-merge-next-up"]
            tapNativeSwitch(merge)
            let value = merge.value as? String
            reveal(app.buttons["home-section-remove"])
            app.buttons["home-section-remove"].tap()
            XCTAssertTrue(app.navigationBars["Home rows"].waitForExistence(timeout: 3))
            XCTAssertFalse(watching.exists)
            let hiddenSettings = app.buttons["home-hidden-continue-watching-settings"]
            reveal(hiddenSettings)
            hiddenSettings.tap()
            XCTAssertTrue(app.navigationBars["Continue Watching"].waitForExistence(timeout: 3))
            XCTAssertEqual(merge.value as? String, value)
            XCTAssertFalse(app.buttons["home-section-remove"].exists)
            app.navigationBars.buttons.firstMatch.tap()
            let add = app.buttons[identifier]
            reveal(add)
            let page = settingsPageFrame(containing: identifier)
            XCTAssertEqual(add.frame.width, page.width - 48, accuracy: 2,
                           "Add row must fill the page's content width.")
            add.tap()
            XCTAssertEqual(app.buttons["home-add-collection"].label, "From a collection")
            XCTAssertTrue(app.staticTexts["Available rows"].exists)
            let option = app.buttons["home-add-home-continueWatching"]
            XCTAssertTrue(option.waitForExistence(timeout: 3), app.debugDescription)
            option.tap()
            XCTAssertTrue(app.navigationBars["Home rows"].waitForExistence(timeout: 3))
            reveal(watching)
            watching.tap()
            XCTAssertEqual(merge.value as? String, value)
            capture("home-section-restored-settings-\(identifier)")
            app.navigationBars.buttons.firstMatch.tap()
        }
    }

    func testFeaturedCardIncludingMetadataAndBottomPaddingSelectsExactlyOnce() {
        app.launchArguments = ["--featured-card-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let card = app.buttons["Featured title"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(card.frame.width, min(440, max(220, app.windows.firstMatch.frame.width - 48)), accuracy: 1)
        XCTAssertEqual(card.frame.height, card.frame.width * 1.125, accuracy: 1,
                       "The touch target must cover the artwork's full height, not just its upper image.")
        capture("featured-card-touch-target")
        let count = app.staticTexts["featured-selection-count"]
        for (index, point) in [
            CGVector(dx: 0.5, dy: 0.15),
            CGVector(dx: 0.5, dy: 0.75),
            CGVector(dx: 0.5, dy: 0.90),
            CGVector(dx: 0.85, dy: 0.96)
        ].enumerated() {
            card.coordinate(withNormalizedOffset: point).tap()
            XCTAssertTrue(count.wait(for: \.label, toEqual: "\(index + 1)", timeout: 3),
                          "The entire card must select exactly once at \(point): \(app.debugDescription)")
        }
        let following = app.staticTexts["featured-following-row"]
        let initialY = following.frame.minY
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo:
                card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        XCTAssertLessThan(following.frame.minY, initialY - 80)
        XCTAssertEqual(count.label, "4", "Scrolling must not activate the card.")
    }

    func testCollectionSelectionOpensEditorAndKeepsSettingsAcrossNestedNavigation() {
        app.launchArguments = [
            "--collection-settings-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        openHomeSections()
        let add = app.buttons["home-section-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        add.tap()
        app.buttons["home-add-collection"].tap()
        let weekend = button("Weekend picks")
        XCTAssertTrue(weekend.waitForExistence(timeout: 5), app.debugDescription)
        weekend.tap()
        XCTAssertTrue(app.navigationBars["Create row"].waitForExistence(timeout: 5), app.debugDescription)
        let landscape = app.segmentedControls.buttons["Landscape"]
        XCTAssertTrue(landscape.exists, app.debugDescription)
        landscape.tap()
        XCTAssertTrue(app.staticTexts["Orbit"].waitForExistence(timeout: 5), app.debugDescription)
        capture("collection-section-created-from-picker")

        let source = app.buttons["collection-section-source"]
        reveal(source)
        source.tap()
        let favorites = button("Favorites")
        XCTAssertTrue(favorites.waitForExistence(timeout: 5), app.debugDescription)
        favorites.tap()
        XCTAssertTrue(app.navigationBars["Create row"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Favorites"].exists, app.debugDescription)
        XCTAssertTrue(landscape.isSelected)
        let save = app.buttons["collection-section-save"]
        reveal(save)
        save.tap()
        XCTAssertTrue(app.navigationBars["Add row"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Home rows"].waitForExistence(timeout: 5))
        let section = button("Favorites")
        reveal(section)
        section.tap()
        XCTAssertTrue(app.navigationBars["Edit section"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(landscape.isSelected)
        XCTAssertTrue(app.staticTexts["Orbit"].waitForExistence(timeout: 5))
        capture("collection-section-reopened-after-saving")
    }

    private func openSettingsPage(
        _ title: String, verifyTitleLayout: Bool = true, arguments: [String] = []
    ) {
        launch(settingsRoot: true, arguments: arguments)
        let parent: String? = switch title {
        case "Customize Home", "Customize Libraries", "App navigation", "Detail Page", "Spoiler Protection":
            "Screens & Navigation"
        case "Theme", "Circadian Mode": "Appearance"
        default: nil
        }
        if let parent {
            let row = categoryButton(parent)
            reveal(row, settingsMenu: true)
            row.tap()
            XCTAssertTrue(app.navigationBars[parent].waitForExistence(timeout: 3), app.debugDescription)
        }

        let row = parent == nil ? categoryButton(title) : button(title)
        reveal(row, settingsMenu: parent == nil)
        row.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3), app.debugDescription)
        if verifyTitleLayout { assertInlineTitle(title, centered: title != "Customize Home") }
    }

    private func revealSyncErasureControl(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.isHittable { return }
            app.scrollViews["cloud-sync-erase-review"].swipeUp()
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func assertInlineTitle(_ title: String, centered: Bool = true) {
        let bar = app.navigationBars[title]
        let heading = bar.staticTexts[title].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 3), app.debugDescription)
        var titleRegion = bar.frame
        let sidebar = app.navigationBars["Settings"]
        // iPad reports a full-window bar, but centers its title in the detail column.
        if sidebar.exists, sidebar.frame.width < bar.frame.width {
            // Floating iPad sidebars have an outer inset and the same gap on their inner edge.
            if sidebar.frame.midX < bar.frame.midX {
                titleRegion.origin.x = sidebar.frame.maxX + max(0, sidebar.frame.minX - bar.frame.minX)
                titleRegion.size.width = bar.frame.maxX - titleRegion.minX
            } else {
                titleRegion.size.width = sidebar.frame.minX - bar.frame.minX
                    - max(0, bar.frame.maxX - sidebar.frame.maxX)
            }
        }
        if centered {
            XCTAssertEqual(heading.frame.midX, titleRegion.midX, accuracy: 4, app.debugDescription)
        } else {
            XCTAssertGreaterThanOrEqual(heading.frame.minX, titleRegion.minX)
            XCTAssertLessThanOrEqual(heading.frame.maxX, titleRegion.maxX)
        }
        XCTAssertLessThanOrEqual(bar.frame.height, 64, "Subpages must not reserve a large-title block.")
        XCTAssertLessThanOrEqual(heading.frame.height, 32, "Subpages must use the native inline title font.")
    }

    private func tapNativeSwitch(_ row: XCUIElement) {
        let control = row.switches.firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 3), "Expected the native switch inside its labeled row.")
        control.tap()
    }

    private func button(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label == %@ OR label BEGINSWITH %@", title, title + ","
        )).firstMatch
    }

    private func categoryButton(_ title: String) -> XCUIElement {
        let identifiers = [
            "Playback": "playback", "Subtitles": "subtitles", "Live TV": "liveTV",
            "Libraries": "libraries", "Appearance": "appearance",
            "Screens & Navigation": "screensNavigation", "Trackers": "trackers", "Language": "language"
        ]
        if let identifier = identifiers[title] {
            return app.buttons["settings-category-\(identifier)"]
        }
        return button(title)
    }

    private func seconds(_ count: Int) -> String {
        Duration.seconds(count).formatted(.units(allowed: [.seconds], width: .abbreviated).locale(Locale(identifier: "en_US")))
    }

    private func launch(settingsRoot: Bool = false, arguments: [String] = []) {
        app.launchArguments = [
            settingsRoot ? "--settings-interaction-fixture" : "--appearance-interaction-fixture",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ] + arguments
        app.launch()
    }

    private func launchNavigation(
        settingsInMore: Bool = false,
        directPresentation: Bool = false,
        settingsFirst: Bool = false,
        arguments: [String] = []
    ) {
        app.launchArguments = [
            "--navigation-interaction-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ] + arguments
        if settingsInMore { app.launchArguments.append("--settings-in-more") }
        if directPresentation { app.launchArguments.append("--settings-direct-presentation") }
        if settingsFirst { app.launchArguments.append("--settings-first") }
        app.launch()
    }

    private func settingsPageFrame(containing identifier: String) -> CGRect {
        var frame = app.scrollViews.containing(.any, identifier: identifier).firstMatch.frame
        let sidebar = app.navigationBars["Settings"]
        // iPad's scroll view extends behind the floating sidebar; its content uses the safe area.
        if sidebar.exists, sidebar.frame.width < frame.width {
            if sidebar.frame.midX < frame.midX {
                frame = CGRect(x: sidebar.frame.maxX, y: frame.minY,
                               width: frame.maxX - sidebar.frame.maxX, height: frame.height)
            } else {
                frame.size.width = sidebar.frame.minX - frame.minX
            }
        }
        return frame
    }

    private func reveal(
        _ element: XCUIElement,
        settingsMenu: Bool = false,
        towardTop: Bool = false,
        fullyVisible: Bool = false
    ) {
        for _ in 0..<10 {
            var scroll = settingsMenu
                ? app.scrollViews.firstMatch
                : (app.collectionViews.count > 0
                    ? app.collectionViews.element(boundBy: app.collectionViews.count - 1)
                    : app.scrollViews.element(boundBy: app.scrollViews.count - 1))
            if !settingsMenu, element.exists, !element.identifier.isEmpty {
                let collection = app.collectionViews.containing(.any, identifier: element.identifier).firstMatch
                let container = app.scrollViews.containing(.any, identifier: element.identifier).firstMatch
                if collection.exists {
                    scroll = collection
                } else if container.exists {
                    scroll = container
                }
            }
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
        for (index, screen) in XCUIScreen.screens.enumerated() where index > 0 {
            let display = XCTAttachment(screenshot: screen.screenshot())
            display.name = "\(name)-display-\(index)"
            display.lifetime = .keepAlways
            add(display)
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
