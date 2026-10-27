import XCTest

@MainActor
final class SettingsWorkspaceRemoteTests: XCTestCase {
    func testAppNavigationEntryAndTitleStayConsistent() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        defer { app.terminate() }
        try focus(section("screensNavigation", in: app), in: app)
        XCUIRemote.shared.press(.select)
        let navigation = app.buttons["settings-page-navigation"]
        try focus(navigation, in: app)
        XCTAssertEqual(navigation.label, "App navigation")
        XCTAssertLessThan(navigation.frame.maxY, app.buttons["settings-page-customize-home"].frame.minY)
        capture("app-navigation-entry", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Top Bar"].waitForExistence(timeout: 5))
        assertInlineSettingsHeader("App navigation", back: pageBack("settings-workspace-back", in: app), in: app)
        XCTAssertFalse(app.switches["detail-zoom-enabled"].exists)
        XCTAssertFalse(app.staticTexts["Zoom when opening titles"].exists)
        capture("app-navigation-page", in: app)
        try focus(app.buttons["Reset Navigation"], in: app)
        capture("app-navigation-arrangement", in: app)
        XCUIRemote.shared.press(.menu)
        waitForEnabled(navigation)
        XCTAssertTrue(hasFocus(navigation), "Back must restore focus to App navigation.")
        #else
        throw XCTSkip("Simulator-only navigation screenshot review.")
        #endif
    }

    func testDetailThemeMusicUsesOneOffChoiceAndThreeVolumeLevels() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        defer { app.terminate() }
        try focus(section("screensNavigation", in: app), in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["settings-page-title-details"], in: app)
        XCUIRemote.shared.press(.select)
        let music = app.buttons["Theme music"]
        try focus(music, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Low"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Off")).count, 1)
        XCTAssertFalse(app.staticTexts[
            "Choose what plays behind the hero on a title's detail page. Trailer and theme music never play together."
        ].exists)
        XCTAssertTrue(app.staticTexts["Play a title's theme music while you browse its detail page."].exists)
        for level in ["Low", "Medium", "High"] {
            let option = app.buttons[level]
            try focus(option, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertEqual(option.value as? String, "Selected", "\(level) must remain selectable.")
        }
        capture("detail-background-volume-options", in: app)
        try focus(app.buttons["Off"], in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(app.buttons["Off"].value as? String, "Selected")
        XCTAssertFalse(app.buttons["Low"].exists, "Background Off hides the volume choices.")
        XCUIRemote.shared.press(.menu)
        let detailPage = app.buttons["settings-page-title-details"]
        try focus(detailPage, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(app.buttons["Off"].value as? String, "Selected")
        try focus(music, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["High"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.buttons["High"].value as? String, "Selected",
            "Switching the background retains the chosen volume."
        )
        #else
        throw XCTSkip("Never changes detail settings on a physical device.")
        #endif
    }

    func testDetailSizingCannotBeSkippedBetweenBackAndBackground() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        defer { app.terminate() }
        try focus(section("screensNavigation", in: app), in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["settings-page-title-details"], in: app)
        XCUIRemote.shared.press(.select)
        let logo = app.buttons["Logo size"]
        let text = app.buttons["Text size"]
        let back = pageBack(in: app)
        XCTAssertTrue(logo.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(text.exists, app.debugDescription)

        func press(_ direction: XCUIRemote.Button, expecting target: XCUIElement) {
            XCUIRemote.shared.press(direction)
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.hasFocus(target) }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed,
                           "Vertical navigation must reach \(target.label). \(app.debugDescription)")
        }

        try focus(back, in: app)
        press(.down, expecting: logo)
        press(.down, expecting: text)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(["Off", "Trailer", "Theme music"].contains { hasFocus(app.buttons[$0]) },
                      "Down from Text size must enter Background.")
        for option in ["Off", "Trailer", "Theme music"] {
            try focus(app.buttons[option], in: app)
            press(.up, expecting: text)
            press(.up, expecting: logo)
            press(.up, expecting: back)
            for control in [logo, text] {
                press(.down, expecting: control)
                let original = try XCTUnwrap(control.value as? String)
                XCUIRemote.shared.press(.right)
                XCTAssertTrue(hasFocus(control), "Left/Right must still adjust without navigating.")
                XCTAssertNotEqual(control.value as? String, original)
                XCUIRemote.shared.press(.left)
                XCTAssertEqual(control.value as? String, original)
            }
            XCUIRemote.shared.press(.down)
        }
        capture("detail-size-vertical-focus", in: app)
        let labels = app.buttons["settings-group-detail-page-card-labels"]
        try focus(labels, in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Cards")).firstMatch.exists)
        XCTAssertLessThan(app.buttons["Theme music"].frame.maxY, labels.frame.minY)
        capture("detail-customization-scopes", in: app)
        #else
        throw XCTSkip("Never changes detail settings on a physical device.")
        #endif
    }

    func testCustomizeLibrariesPlacesNavigationBeforeRecommendedPageSettings() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        defer { app.terminate() }
        try focus(section("screensNavigation", in: app), in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["settings-page-customize-libraries"], in: app)
        XCUIRemote.shared.press(.select)
        let navigation = app.buttons["library-navigation-settings"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5), app.debugDescription)
        let recommended = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] %@", "Recommended Page")
        ).firstMatch
        let libraries = app.staticTexts["Recommended rows"]
        let appearance = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] %@", "Page appearance")
        ).firstMatch
        XCTAssertTrue(recommended.exists, app.debugDescription)
        XCTAssertTrue(libraries.exists, app.debugDescription)
        XCTAssertTrue(appearance.exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Recommended Page Rows"].exists,
                       "This page lists libraries; row settings belong inside the selected library.")
        XCTAssertLessThan(navigation.frame.maxY, appearance.frame.minY)
        XCTAssertLessThan(appearance.frame.maxY, recommended.frame.minY)
        XCTAssertLessThan(recommended.frame.maxY, libraries.frame.minY)
        let back = pageBack(in: app)
        try focus(back, in: app)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(hasFocus(navigation), "Down from Back must reach Library Navigation before logo or row controls.")
        capture("libraries-navigation-first", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Reset Navigation"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        waitForEnabled(navigation)
        XCTAssertTrue(hasFocus(navigation), "Returning from the tab editor must restore its originating action.")
        #else
        throw XCTSkip("Simulator-only library settings navigation review.")
        #endif
    }

    func testSharedChevronHeaderKeepsRightAlignedFocusBridge() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(style: "tabBar")
        defer { app.terminate() }
        try focus(section("appearance", in: app), in: app)
        XCUIRemote.shared.press(.select)
        let link = app.buttons["settings-page-night-shift"]
        try focus(link, in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["Always On"], in: app)
        XCUIRemote.shared.press(.up)
        let back = pageBack(in: app)
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.hasFocus(back) }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed,
                       "Up from the rightmost mode must reach the shared chevron button.")
        XCTAssertEqual(back.label, "Back")
        XCTAssertLessThan(back.frame.width, back.frame.height * 2)
        capture("shared-chevron-header-right-aligned-focus", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        #else
        throw XCTSkip("Simulator-only shared header review.")
        #endif
    }

    func testContinueWatchingGroupsFollowArtworkAndKeepNativeFocus() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(style: "tabBar")
        defer { app.terminate() }
        try focus(section("screensNavigation", in: app), in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["settings-page-customize-home"], in: app)
        XCUIRemote.shared.press(.select)
        try openHomeSections(in: app)
        try focus(app.buttons["home-section-home-continueWatching"], in: app)
        XCUIRemote.shared.press(.select)
        let artwork = app.buttons["continue-watching-style-portraitPosters"]
        let details = app.buttons["continue-watching-playback-details"]
        let labels = app.buttons["card-label-view-continueWatchingPortrait"]
        let merge = app.switches["home-merge-next-up"]
        let action = app.buttons["continue-watching-action"]
        try focus(artwork, in: app)
        let back = pageBack(in: app)
        assertInlineSettingsHeader("Continue Watching", back: back, in: app)
        XCTAssertEqual(back.label, "Back")
        XCTAssertLessThan(back.frame.width, back.frame.height * 2)
        capture("continue-watching-artwork-first", in: app)
        XCTAssertLessThan(artwork.frame.maxY, details.frame.minY)
        for control in [details, labels, merge, action] {
            XCUIRemote.shared.press(.down)
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.hasFocus(control) }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed,
                           "Down must reach \(control.identifier). \(app.debugDescription)")
        }
        XCTAssertEqual(
            app.staticTexts["continue-watching-remote-help"].label,
            "You can also press Play/Pause on your remote to play the focused item."
        )
        let mergeBefore = merge.value as? String
        let actionBefore = action.value as? String
        XCUIRemote.shared.press(.select)
        XCTAssertNotEqual(action.value as? String, actionBefore)
        XCTAssertEqual(merge.value as? String, mergeBefore)
        XCTAssertTrue(hasFocus(action))
        capture("continue-watching-behavior-group", in: app)
        for control in [merge, labels, details] {
            XCUIRemote.shared.press(.up)
            let focused = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in self.hasFocus(control) }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed,
                           "Up must reach \(control.identifier). \(app.debugDescription)")
        }
        try focus(back, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["home-section-home-continueWatching"].waitForExistence(timeout: 5))
        #else
        throw XCTSkip("Never changes Home preferences on a physical device.")
        #endif
    }

    func testEpisodeCountStyleMenuKeepsWatchModeAndRetainsHiddenChoice() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(style: "tabBar")
        defer { app.terminate() }
        try focus(section("appearance", in: app), in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["settings-page-cards"], in: app)
        XCUIRemote.shared.press(.select)
        let style = app.buttons["episode-count-style"]
        let watched = app.buttons["watch-indicator-preview-watched"]
        let wasSelected = watched.isSelected
        for choice in ["Attached", "Floating"] {
            try focus(style, in: app)
            XCUIRemote.shared.press(.select)
            let option = app.cells.containing(.any, identifier: choice).firstMatch
            try focus(option, in: app)
            XCUIRemote.shared.press(.select)
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in style.value as? String == choice && self.hasFocus(style) },
                object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            XCTAssertEqual(watched.isSelected, wasSelected)
        }
        let toggle = app.switches["unwatched-episode-count-toggle"]
        try focus(toggle, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(style.waitForNonExistence(timeout: 5))
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(style.waitForExistence(timeout: 5))
        XCTAssertEqual(style.value as? String, "Floating")
        capture("episode-count-floating", in: app)
        #else
        throw XCTSkip("Never changes appearance preferences on a physical device.")
        #endif
    }

    func testWatchIndicatorColorRailSupportsDirectionalSelectionAndExit() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(style: "tabBar")
        defer { app.terminate() }
        try focus(section("appearance", in: app), in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["settings-page-cards"], in: app)
        XCUIRemote.shared.press(.select)
        let colors = ["white", "blue", "green", "yellow", "orange", "red", "pink", "purple"]
        let white = app.buttons["watch-indicator-color-white"]
        try focus(white, in: app)
        for (index, color) in colors.enumerated() {
            let button = app.buttons["watch-indicator-color-\(color)"]
            if index > 0 { XCUIRemote.shared.press(.right) }
            XCTAssertTrue(hasFocus(button), "Right must traverse the colour row in order.")
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(button.isSelected)
            XCTAssertTrue(hasFocus(button), "Selecting a colour must not replace its focus target.")
        }
        capture("watch-color-purple", in: app)
        XCUIRemote.shared.press(.down)
        XCTAssertFalse(hasFocus(app.buttons["watch-indicator-color-purple"]))
        try focus(white, in: app)
        XCUIRemote.shared.press(.up)
        XCTAssertFalse(hasFocus(white), "The colour row must allow returning to the indicator previews.")
        #else
        throw XCTSkip("Never changes appearance preferences on a physical device.")
        #endif
    }

    func testSwitchingFromPinnedSidebarKeepsNavigationSettingsResponsive() throws {
        try exerciseSidebarSwitch(from: "rail")
    }

    func testSwitchingFromTopBarKeepsNavigationSettingsResponsive() throws {
        try exerciseSidebarSwitch(from: "tabBar")
    }

    private func exerciseSidebarSwitch(from style: String) throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(style: style)
        defer { app.terminate() }
        let navigation = app.buttons["settings-page-navigation"]
        try focus(section("screensNavigation", in: app), in: app)
        XCUIRemote.shared.press(.select)
        try focus(navigation, in: app)
        XCUIRemote.shared.press(.select)
        let choice = app.buttons["Sidebar"]
        try focus(choice, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(hasFocus(choice), "Changing chrome must preserve the focused Settings control. \(app.debugDescription)")
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(hasFocus(app.buttons["Pinned Sidebar"]), "The next directional input must work.")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(navigation.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(hasFocus(navigation), "Back must return to the Navigation action.")

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(section("screensNavigation", in: app).waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertFalse(section("screensNavigation", in: app).exists, app.debugDescription)
        try openSettingsIfNeeded(in: app)
        try enterAndReturn("playback", in: app)
        #else
        throw XCTSkip("Never changes navigation settings on a physical device.")
        #endif
    }

    func testDeviceSetupOpensAndReturnsToICloudSettings() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        defer { app.terminate() }
        try focus(section("syncSetup", in: app), in: app)
        XCUIRemote.shared.press(.select)
        for attempt in 1...2 {
            let setup = app.buttons.containing(.staticText, identifier: "Set Up Another Device").firstMatch
            XCTAssertTrue(setup.waitForExistence(timeout: 5), app.debugDescription)
            try focus(setup, in: app)
            XCUIRemote.shared.press(.select)
            let heading = app.staticTexts["Set up another device"]
            XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
            let disappeared = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !heading.exists }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [disappeared], timeout: 2), .timedOut,
                           "Setup must not disappear without user input.")
            capture("device-setup-open-\(attempt)", in: app)
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(setup.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(heading.exists)
        }
        #else
        throw XCTSkip("Simulator-only setup presentation review.")
        #endif
    }

    func testSettingsMenusShareWholeRowFocusAndRestoreChoices() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        defer { capture("settings-menus-final", in: app) }
        let language = section("language", in: app)
        try focus(language, in: app)
        let menuWidth = language.frame.width
        XCTAssertGreaterThan(menuWidth, 800)
        capture("settings-language-whole-row", in: app)
        try focus(section("playback", in: app), in: app)
        XCUIRemote.shared.press(.select)
        let audio = app.buttons["Preferred audio language"]
        try focus(audio, in: app)
        XCTAssertTrue(hasFocus(audio))
        XCTAssertEqual(audio.frame.width, menuWidth, accuracy: 1)
        XCTAssertEqual(audio.value as? String, "Original")
        capture("settings-audio-whole-row", in: app)
        XCUIRemote.shared.press(.select)
        let device = app.cells.containing(.any, identifier: "Device").firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 5), app.debugDescription)
        try focus(device, in: app)
        XCUIRemote.shared.press(.select)
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in audio.value as? String == "Device" }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        XCTAssertTrue(hasFocus(audio), "Selecting a menu value must restore the full row's focus.")
        XCUIRemote.shared.press(.select)
        try focus(app.cells.containing(.any, identifier: "Original").firstMatch, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(audio.value as? String, "Original")

        let separate = app.switches["Set separately for movies, TV shows & anime"]
        try focus(separate, in: app)
        XCUIRemote.shared.press(.select)
        let movies = app.buttons["Movies"]
        try focus(movies, in: app)
        XCTAssertEqual(movies.frame.width, menuWidth, accuracy: 1)
        capture("settings-audio-per-type", in: app)
        try focus(separate, in: app)
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.menu)
        waitForCategoryFocus("playback", in: app)
        try focus(section("subtitles", in: app), in: app)
        XCUIRemote.shared.press(.select)
        let subtitles = app.buttons["Subtitle language"]
        try focus(subtitles, in: app)
        XCTAssertEqual(subtitles.frame.width, menuWidth, accuracy: 1)
        capture("settings-subtitle-whole-row", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells.containing(.any, identifier: "Device Default")
            .firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCUIRemote.shared.press(.menu)
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.hasFocus(subtitles) }, object: nil
        )
        let restoration = XCTWaiter.wait(for: [restored], timeout: 5)
        capture("settings-subtitle-menu-return", in: app)
        XCTAssertEqual(restoration, .completed, app.debugDescription)
        XCUIRemote.shared.press(.menu)
        waitForCategoryFocus("subtitles", in: app)
        #else
        throw XCTSkip("Never changes language preferences on a physical device.")
        #endif
    }

    func testSettingsSectionsAndNestedPagesInTheProductionApp() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        defer { capture("final-state", in: app) }
        let playback = section("playback", in: app)
        XCTAssertTrue(playback.isSelected, app.debugDescription)
        XCTAssertTrue(app.buttons["settings-profile-switch"].exists)
        XCTAssertTrue(app.buttons["settings-profile-edit"].exists)
        XCTAssertFalse(app.buttons["settings-group-language"].exists,
                       "Categories must not preview a second page beside the list.")
        assertCenteredSettingsColumn(in: app)
        capture("01-playback", in: app)
        XCTAssertFalse(section("general", in: app).exists)
        XCTAssertFalse(section("customizeHome", in: app).exists)
        XCTAssertFalse(app.buttons["settings-page-theme"].exists)
        let profileRows = ["playback", "subtitles", "liveTV", "myLibraries", "appearance",
                           "screensNavigation", "integrations", "language"].map { section($0, in: app) }
        XCTAssertTrue(profileRows.allSatisfy(\.exists), app.debugDescription)
        let positions = profileRows.map(\.frame.minY)
        XCTAssertEqual(positions, positions.sorted())
        try enterAndReturn("playback", in: app)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(section("subtitles", in: app).isSelected, app.debugDescription)

        for (index, name) in [
            "subtitles", "liveTV", "myLibraries", "appearance", "screensNavigation", "integrations",
            "servers", "profile", "parentalPIN", "seerr", "syncSetup", "metadata", "help"
        ].enumerated() {
            let target = section(name, in: app)
            XCTAssertTrue(target.exists, "Missing Settings section: \(name)")
            try focus(target, in: app)
            XCTAssertTrue(hasFocus(target))
            capture(String(format: "%02d-%@", index + 2, name), in: app)
            try enterAndReturn(name, in: app, usingRight: index.isMultiple(of: 2))
        }
        try focus(section("playback", in: app), in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Audio"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["settings-page-subtitles"].exists)
        XCTAssertFalse(app.staticTexts["Show subtitles"].exists)
        capture("19-playback-entered", in: app)
        let audioKeyline = app.staticTexts["Audio"].frame.minX
        for label in [
            "Preferred audio language", "Set separately for movies, TV shows & anime",
            "Remember audio language per series", "Spatial audio", "Autoplay & Up Next"
        ] {
            let text = app.staticTexts[label].firstMatch
            XCTAssertTrue(text.exists, label)
            XCTAssertEqual(text.frame.minX, audioKeyline, accuracy: 1,
                           "\(label) must share the section-heading keyline.")
        }
        let helper = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "How Plozz picks the audio language")
        ).firstMatch
        XCTAssertFalse(helper.exists)
        XCTAssertFalse(section("screensNavigation", in: app).exists, app.debugDescription)
        XCUIRemote.shared.press(.menu)
        try focus(section("subtitles", in: app), in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Show subtitles"].waitForExistence(timeout: 5), app.debugDescription)
        capture("20-subtitles", in: app)
        let style = app.buttons["Customize subtitle style"]
        try focus(style, in: app)
        capture("subtitles-lower", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Back"))
            .firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        capture("subtitle-style", in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(style.waitForExistence(timeout: 5), app.debugDescription)
        XCUIRemote.shared.press(.menu)
        waitForCategoryFocus("subtitles", in: app)
        #else
        throw XCTSkip("Never seeds or changes settings on a physical device.")
        #endif
    }

    func testLanguageOpensItsPickerDirectlyAndKeepsFeedbackReachable() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        let language = section("language", in: app)
        try focus(language, in: app)
        if language.value as? String != "System", language.value as? String != "English" {
            XCUIRemote.shared.press(.select)
            try focus(app.cells.containing(.any, identifier: "English").firstMatch, in: app)
            XCUIRemote.shared.press(.select)
            try focus(language, in: app)
        }
        capture("language-row", in: app)
        XCTAssertEqual(language.label, "Language")
        let originalValue = try XCTUnwrap(language.value as? String)
        XCTAssertTrue(originalValue.contains("System") || originalValue.contains("English"), originalValue)
        let originalOption = originalValue.contains("System") ? "System" : "English"
        XCTAssertLessThanOrEqual(language.frame.height, 80)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.cells.containing(.any, identifier: "English").firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["settings-category-back"].exists)
        capture("language-picker", in: app)
        XCUIRemote.shared.press(.menu)
        waitForCategoryFocus("language", in: app)

        XCUIRemote.shared.press(.select)
        try focus(app.cells.containing(.any, identifier: "Français").firstMatch, in: app)
        XCUIRemote.shared.press(.select)
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                language.exists && (language.value as? String)?.contains("Français") == true
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        try focus(language, in: app)
        XCUIRemote.shared.press(.select)
        let feedback = app.cells.containing(.any, identifier: "settings-language-feedback").firstMatch
        for _ in 0..<50 where !feedback.exists { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(feedback.waitForExistence(timeout: 5), app.debugDescription)
        try focus(feedback, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["settings-language-feedback-close"].waitForExistence(timeout: 5), app.debugDescription)
        capture("language-feedback", in: app)
        XCUIRemote.shared.press(.menu)
        waitForCategoryFocus("language", in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.cells.containing(.any, identifier: "English").firstMatch, in: app)
        XCUIRemote.shared.press(.select)
        if originalOption == "System" {
            try focus(language, in: app)
            XCUIRemote.shared.press(.select)
            try focus(app.cells.containing(.any, identifier: "System").firstMatch, in: app)
            XCUIRemote.shared.press(.select)
        }
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        XCTAssertEqual(language.value as? String, originalValue)
        try focus(section("playback", in: app), in: app)
        #else
        throw XCTSkip("Never changes language on a physical device.")
        #endif
    }

    func testCompactAboutRemainsAtSettingsRoot() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        XCTAssertTrue(section("screensNavigation", in: app).exists)
        XCTAssertTrue(app.staticTexts["Trakt, Simkl, AniList, MyAnimeList, Last.fm"].exists)
        XCTAssertFalse(section("about", in: app).exists)
        let version = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Version ")).firstMatch
        try focus(version, in: app)
        let summary = app.descendants(matching: .any).matching(identifier: "settings-about-summary").firstMatch
        XCTAssertTrue(summary.exists)
        XCTAssertLessThanOrEqual(summary.frame.height, 400, "About should remain a compact root summary.")
        let attributions = app.buttons["Attributions"]
        try focus(attributions, in: app)
        capture("about-inline", in: app)
        let discord = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Scan to join the Plozz Discord community")
        ).firstMatch
        let github = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Scan to view the Plozz GitHub repository")
        ).firstMatch
        XCTAssertTrue(discord.exists)
        XCTAssertTrue(github.exists)
        XCTAssertEqual(discord.frame.minY, github.frame.minY, accuracy: 1)
        XCTAssertEqual(discord.frame.height, github.frame.height, accuracy: 1)
        XCTAssertEqual(discord.frame.width, github.frame.width, accuracy: 1)
        XCTAssertLessThanOrEqual(github.frame.height, 180, "The QR code must not wrap below its caption.")
        XCUIRemote.shared.press(.select)
        let back = pageBack("settings-category-back", in: app)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        assertInlineSettingsHeader("Attributions", back: back, in: app)
        XCUIRemote.shared.press(.menu)
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.hasFocus(attributions) }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        try focus(section("playback", in: app), in: app)
        #else
        throw XCTSkip("Never seeds or changes settings on a physical device.")
        #endif
    }

    func testAppearancePagesAndNavigationStyleChanges() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        defer { capture("appearance-final-state", in: app) }
        try focus(section("appearance", in: app), in: app)
        XCUIRemote.shared.press(.select)
        assertInlineSettingsHeader("Appearance", back: pageBack("settings-category-back", in: app), in: app)
        for id in ["theme", "cards", "artwork", "night-shift"] {
            XCTAssertTrue(app.buttons["settings-page-\(id)"].exists)
        }
        for id in ["display-size", "navigation", "music-player", "title-details", "customize-home", "spoilers"] {
            XCTAssertFalse(app.buttons["settings-page-\(id)"].exists)
        }
        let cards = app.buttons["settings-page-cards"]
        let artwork = app.buttons["settings-page-artwork"]
        XCTAssertEqual(artwork.frame.minY - cards.frame.maxY, 8, accuracy: 1)
        let theme = app.buttons["settings-page-theme"]
        XCTAssertTrue(theme.waitForExistence(timeout: 5), app.debugDescription)
        try focus(theme, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Gradient Backgrounds"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Liquid Glass")).firstMatch.exists,
                      app.debugDescription)
        capture("theme", in: app)
        assertCenteredSettingsColumn(in: app)
        XCUIRemote.shared.press(.menu)
        waitForEnabled(theme)
        try focus(app.buttons["settings-page-artwork"], in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["artwork-customization"].waitForExistence(timeout: 5))
        capture("artwork", in: app)
        try focus(app.buttons["artwork-customization"], in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["view-customization-back"].waitForExistence(timeout: 5), app.debugDescription)
        assertInlineSettingsHeader("Artwork by view", back: pageBack("view-customization-back", in: app), in: app)
        capture("artwork-customization", in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["artwork-customization"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        try focus(app.buttons["settings-page-cards"], in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["Default"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["DISPLAY SIZE"].waitForExistence(timeout: 5), app.debugDescription)
        let cardHeadings = ["Labels", "Watched Indicator", "Focus", "Style", "Display Size"].map {
            app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", $0)).firstMatch
        }
        XCTAssertTrue(cardHeadings.allSatisfy(\.exists))
        let cardPositions = cardHeadings.map(\.frame.minY)
        XCTAssertEqual(cardPositions, cardPositions.sorted(), "Display Size must be the final Cards group.")
        capture("cards-top", in: app)
        try focus(app.buttons["Default"], in: app)
        capture("display-size", in: app)
        XCTAssertTrue(app.buttons["card-label-customization"].waitForExistence(timeout: 5))
        capture("cards", in: app)
        try focus(app.buttons["card-label-customization"], in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["view-customization-back"].waitForExistence(timeout: 5), app.debugDescription)
        assertInlineSettingsHeader("Customize labels", back: pageBack("view-customization-back", in: app), in: app)
        capture("card-label-customization", in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["card-label-customization"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        for (page, heading) in [("night-shift", "Circadian Mode")] {
            let link = app.buttons["settings-page-\(page)"]
            try focus(link, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 5), app.debugDescription)
            capture(page, in: app)
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
        }
        XCUIRemote.shared.press(.menu)
        waitForCategoryFocus("appearance", in: app)
        try focus(section("screensNavigation", in: app), in: app)
        XCUIRemote.shared.press(.select)
        assertInlineSettingsHeader("Screens & Navigation", back: pageBack("settings-category-back", in: app), in: app)
        for id in ["customize-home", "customize-libraries", "navigation", "title-details", "music-player", "spoilers"] {
            XCTAssertTrue(app.buttons["settings-page-\(id)"].exists)
        }
        XCTAssertFalse(app.buttons["settings-page-cards"].exists)
        XCTAssertTrue(app.staticTexts["All screens"].exists)
        XCTAssertTrue(app.staticTexts["Customize individual screens"].exists)
        let ratings = app.switches["settings-group-content-ratings"]
        try focus(ratings, in: app)
        capture("content-ratings-focused", in: app)
        let ratingValue = ratings.value as? String
        XCUIRemote.shared.press(.select)
        XCTAssertNotEqual(ratings.value as? String, ratingValue)
        XCTAssertTrue(app.buttons["settings-page-spoilers"].exists, "Toggling must not navigate away.")
        capture("content-ratings-off", in: app)
        XCUIRemote.shared.press(.select)
        capture("screens-navigation", in: app)
        let home = app.buttons["settings-page-customize-home"]
        try focus(home, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["home-section-hero"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["home-customize-labels"].exists)
        XCTAssertTrue(app.buttons["home-sections-settings"].exists)
        capture("customize-home", in: app)
        assertCenteredSettingsColumn(in: app)
        try openHomeSections(in: app)
        try focus(app.buttons["home-section-home-continueWatching"], in: app)
        XCUIRemote.shared.press(.select)
        capture("home-rows", in: app)
        assertCenteredSettingsColumn(in: app)
        XCUIRemote.shared.press(.menu)
        waitForEnabled(app.buttons["home-section-home-continueWatching"])
        XCUIRemote.shared.press(.menu)
        waitForEnabled(app.buttons["home-sections-settings"])
        XCUIRemote.shared.press(.menu)
        waitForEnabled(home)
        XCTAssertTrue(hasFocus(home))
        try focus(app.buttons["settings-page-navigation"], in: app)
        XCUIRemote.shared.press(.select)
        for style in ["Top Bar", "Sidebar", "Pinned Sidebar"] {
            let choice = app.buttons[style]
            XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
            try focus(choice, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.staticTexts["Prevent Accidental Exit"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(section("screensNavigation", in: app).exists)
            capture("navigation-\(style)", in: app)
        }
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["settings-page-navigation"].waitForExistence(timeout: 5), app.debugDescription)
        for (page, heading) in [
            ("spoilers", "Spoiler Protection"),
            ("music-player", "Music Player"),
            ("title-details", "Detail Page")
        ] {
            let link = app.buttons["settings-page-\(page)"]
            try focus(link, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.staticTexts[heading].waitForExistence(timeout: 5), app.debugDescription)
            if page == "title-details" {
                for title in ["Episode browser", "Related titles", "Extras"] {
                    let labels = app.buttons.matching(identifier: "settings-group-detail-page-card-labels")
                        .matching(NSPredicate(format: "label == %@", title)).firstMatch
                    try focus(labels, in: app)
                    let value = labels.value as? String
                    XCUIRemote.shared.press(.select)
                    XCTAssertNotEqual(labels.value as? String, value)
                }
            }
            capture(page, in: app)
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
        }
        XCUIRemote.shared.press(.menu)
        waitForCategoryFocus("screensNavigation", in: app)
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    func testNativeSidebarAndTopBarEntryAndExit() throws {
        #if targetEnvironment(simulator)
        for style in ["sidebar", "tabBar"] {
            let app = try launchSettings(style: style)
            XCTAssertTrue(section("playback", in: app).isSelected)
            capture("entry-\(style)", in: app)
            try enterAndReturn("playback", in: app)
            XCUIRemote.shared.press(.menu)
            XCTAssertFalse(section("playback", in: app).exists, app.debugDescription)
            capture("exit-\(style)", in: app)
            try openSettingsIfNeeded(in: app)
            try enterAndReturn("playback", in: app)
            app.terminate()
        }
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    func testRootCategoriesOnlyStaySelectedWhileFocused() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        defer { app.terminate() }
        let playback = section("playback", in: app)
        for identifier in ["settings-profile-switch", "settings-profile-edit"] {
            try focus(playback, in: app)
            XCTAssertTrue(playback.isSelected)
            try focus(app.buttons[identifier], in: app)
            XCTAssertFalse(playback.isSelected, "Remembering Playback for Back must not keep it highlighted.")
            capture("selection-\(identifier)", in: app)
        }
        try focus(playback, in: app)
        try enterAndReturn("playback", in: app)
        XCTAssertTrue(playback.isSelected)

        let language = section("language", in: app)
        try focus(language, in: app)
        XCTAssertTrue(language.isSelected)
        try focus(app.buttons["settings-profile-switch"], in: app)
        XCTAssertFalse(language.isSelected, "Native menu rows must release their selected state too.")

        let help = section("help", in: app)
        try focus(help, in: app)
        try enterAndReturn("help", in: app)
        XCTAssertTrue(help.isSelected)
        try focus(app.buttons.containing(.staticText, identifier: "Attributions").firstMatch, in: app)
        XCTAssertFalse(help.isSelected)
        XCTAssertFalse(playback.isSelected)
        capture("selection-after-help", in: app)
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    func testProfileEditorAndSwitcherShareTheWorkspace() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        try focus(app.buttons["settings-profile-edit"], in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["How this profile looks, and who can open it."].waitForExistence(timeout: 5))
        capture("profile-edit", in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(section("playback", in: app).waitForExistence(timeout: 5))
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.buttons["settings-profile-switch"].isEnabled }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed, app.debugDescription)
        try focus(app.buttons["settings-profile-switch"], in: app)
        XCUIRemote.shared.press(.select)
        let sam = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Sam")).firstMatch
        XCTAssertTrue(sam.waitForExistence(timeout: 5), app.debugDescription)
        capture("profile-switcher", in: app)
        try focus(sam, in: app)
        XCUIRemote.shared.press(.select)
        try openSettingsIfNeeded(in: app)
        XCTAssertEqual(app.buttons["settings-profile-switch"].value as? String, "Sam")
        XCTAssertTrue(section("playback", in: app).isSelected)
        capture("profile-switched", in: app)
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    func testProfileAppearanceAndPINUseFullWidthDestinations() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(style: "tabBar")
        try focus(app.buttons["settings-profile-edit"], in: app)
        XCUIRemote.shared.press(.select)
        let appearance = app.buttons["profile.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5), app.debugDescription)
        try focus(appearance, in: app)
        XCUIRemote.shared.press(.select)
        let heading = app.staticTexts["Edit Profile"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThan(heading.frame.height, 90, "The editor heading must stay on one line.")
        XCTAssertGreaterThan(heading.frame.width, 200)
        let done = app.buttons["Done"]
        let back = pageBack("settings-workspace-back", in: app)
        let revert = app.buttons["Revert All Changes"]
        for action in [back, revert] {
            XCTAssertEqual(action.frame.midY, done.frame.midY, accuracy: 1,
                           "All profile editor actions must share one center-aligned row.")
        }
        XCTAssertTrue(app.textFields["profile-name-input"].exists)
        XCTAssertFalse(revert.isEnabled)
        // Cross into the editor column before the single-column vertical navigation helper.
        XCUIRemote.shared.press(.right)
        try focus(done, in: app)
        XCTAssertTrue(app.frame.contains(done.frame), "The editor actions must fit on screen.")
        capture("profile-appearance-full-width", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(appearance.waitForExistence(timeout: 5), app.debugDescription)
        let lock = app.buttons["profile.lock"]
        try focus(lock, in: app)
        XCUIRemote.shared.press(.select)
        let pinTitle = app.staticTexts["pin-entry-title"]
        XCTAssertTrue(pinTitle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThan(pinTitle.frame.minX, app.frame.midX - 400,
                          "PIN prose must start in the left half of a centered two-column composition.")
        try focus(app.buttons["1"], in: app)
        capture("profile-lock-full-width", in: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(lock.waitForExistence(timeout: 5), app.debugDescription)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(section("playback", in: app).waitForExistence(timeout: 5))
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    func testKidsSettingsRequirePINOnlyWhenConfigured() throws {
        #if targetEnvironment(simulator)
        for mode in ["no-pin", "pin"] {
            let app = try launchSettings(profile: "Sam", kids: mode)
            XCTAssertFalse(section("servers", in: app).exists)
            XCTAssertFalse(section("metadata", in: app).exists)
            capture("kids-\(mode)", in: app)
            for personal in ["appearance", "screensNavigation", "language"] {
                XCTAssertTrue(section(personal, in: app).exists)
            }
            for household in ["metadata", "servers", "profile", "parentalPIN", "seerr", "syncSetup"] {
                XCTAssertFalse(section(household, in: app).exists)
            }
            try focus(section("screensNavigation", in: app), in: app)
            try enterAndReturn("screensNavigation", in: app)
            try focus(section("myLibraries", in: app), in: app)
            XCUIRemote.shared.press(.select)
            if mode == "pin" {
                XCTAssertTrue(app.buttons["1"].waitForExistence(timeout: 5), app.debugDescription)
                let keypadFocused = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in self.hasFocus(app.buttons["1"]) }, object: nil
                )
                XCTAssertEqual(XCTWaiter.wait(for: [keypadFocused], timeout: 5), .completed,
                               "The PIN page must take native focus before Menu can cancel it.")
                capture("kids-pin-required", in: app)
                XCUIRemote.shared.press(.menu)
                waitForCategoryFocus("myLibraries", in: app)
                XCUIRemote.shared.press(.select)
                for digit in ["1", "2", "3", "4"] {
                    try focus(app.buttons[digit], in: app)
                    XCUIRemote.shared.press(.select)
                }
                let unlocked = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in !app.buttons["1"].exists }, object: nil
                )
                XCTAssertEqual(XCTWaiter.wait(for: [unlocked], timeout: 5), .completed, app.debugDescription)
                XCTAssertTrue(app.buttons["settings-category-back"].exists, "Unlock must stay in the category.")
                XCTAssertFalse(section("myLibraries", in: app).exists)
                capture("kids-unlocked", in: app)
            } else {
                XCTAssertTrue(app.buttons["settings-category-back"].waitForExistence(timeout: 5))
            }
            XCTAssertFalse(section("metadata", in: app).exists)
            XCTAssertFalse(section("servers", in: app).exists)
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(section("playback", in: app).waitForExistence(timeout: 5))
            XCTAssertFalse(section("metadata", in: app).exists)
            XCTAssertFalse(section("servers", in: app).exists)
            app.terminate()
        }
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    func testTrackersHideUnreleasedWetrakr() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(style: "tabBar")
        try focus(section("integrations", in: app), in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["settings-page-trakt"].waitForExistence(timeout: 5), app.debugDescription)
        for tracker in ["trakt", "simkl", "anilist", "mal", "lastfm"] {
            XCTAssertTrue(app.buttons["settings-page-\(tracker)"].exists, app.debugDescription)
        }
        XCTAssertFalse(app.buttons["settings-page-wetrakr"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["WeTrakr"].exists, app.debugDescription)
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    func testPlaybackLiveTVAndTrackerChildPages() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(style: "tabBar")
        for (category, pages) in [
            ("playback", []),
            ("liveTV", ["sources", "hidden-channels"]),
            ("integrations", ["trakt", "simkl", "anilist", "mal", "lastfm"])
        ] {
            try focus(section(category, in: app), in: app)
            XCUIRemote.shared.press(.select)
            if category == "playback" {
                let separate = app.switches["Set each marker separately"]
                XCTAssertTrue(separate.waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertFalse(app.buttons["settings-page-skip-intros-mode"].exists)
                try focus(separate, in: app)
                let community = app.switches["Use community markers"]
                XCTAssertTrue(community.exists, app.debugDescription)
                try focus(community, in: app)
                capture("playback-inline-skip-controls", in: app)
            }
            for page in pages {
                let link = app.buttons["settings-page-\(page)"]
                XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
                try focus(link, in: app)
                XCUIRemote.shared.press(.select)
                XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Back"))
                    .firstMatch.waitForExistence(timeout: 5), app.debugDescription)
                capture("child-\(page)", in: app)
                XCUIRemote.shared.press(.menu)
                XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
            }
            for _ in 0..<9 { XCUIRemote.shared.press(.down) }
            capture("lower-\(category)", in: app)
            XCUIRemote.shared.press(.menu)
        }
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    func testUninstrumentedSettingsEntry() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(diagnostics: false)
        try enterAndReturn("playback", in: app)
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    func testHomeSectionEditorKeepsHeroFixedAndUsesNativeBack() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        defer { app.terminate() }
        try focus(section("screensNavigation", in: app), in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["settings-page-customize-home"], in: app)
        XCUIRemote.shared.press(.select)
        let hero = app.buttons["home-section-hero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5), app.debugDescription)
        try focus(hero, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["Home layout"].waitForExistence(timeout: 5))
        try focus(app.buttons["Showcase"], in: app)
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.menu)
        waitForEnabled(hero)
        XCTAssertEqual(hero.label, "Layout")
        XCTAssertEqual(hero.value as? String, "Showcase")
        XCTAssertFalse(app.staticTexts["Pinned at top"].exists)
        try focus(hero, in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["Fullscreen Hero"], in: app)
        XCUIRemote.shared.press(.select)
        let enabledHero = app.switches["hero-enabled"]
        try focus(enabledHero, in: app)
        if enabledHero.value as? String != "1" { XCUIRemote.shared.press(.select) }
        XCUIRemote.shared.press(.menu)
        waitForEnabled(hero)
        XCTAssertEqual(hero.label, "Layout")
        XCTAssertEqual(hero.value as? String, "Hero")
        XCTAssertFalse(app.staticTexts["Pinned at top"].exists)
        capture("home-hero-pin", in: app)
        try openHomeSections(in: app)
        let reorder = app.buttons["home-section-reorder"]
        let preset = app.buttons["home-row-preset"]
        XCTAssertGreaterThanOrEqual(preset.frame.minY - reorder.frame.maxY, 16)
        XCTAssertFalse(hero.exists)
        try focus(reorder, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(hero.exists)
        XCTAssertFalse(app.staticTexts["Pinned at top"].exists)
        capture("home-hero-pin-reordering", in: app)
        XCTAssertFalse(app.staticTexts["HIDDEN"].exists)
        let watching = app.buttons.containing(.staticText, identifier: "Continue Watching").firstMatch
        try focus(watching, in: app)
        let originalY = watching.frame.minY
        let watchlist = app.buttons.containing(.staticText, identifier: "Watchlist").firstMatch
        let movingUp = originalY > watchlist.frame.minY
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(movingUp ? .up : .down)
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                watching.exists && self.hasFocus(watching)
                    && (movingUp ? watching.frame.minY < originalY : watching.frame.minY > originalY)
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed, app.debugDescription)
        XCUIRemote.shared.press(.select)
        waitForEnabled(reorder)
        try focus(reorder, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(hero.exists)
        XCTAssertFalse(app.staticTexts["Pinned at top"].exists)
        let configured = app.buttons["home-section-home-continueWatching"]
        try focus(configured, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["home-section-remove"].waitForExistence(timeout: 5), app.debugDescription)
        capture("home-section-continue-watching", in: app)
        XCUIRemote.shared.press(.menu)
        waitForEnabled(configured)
        XCTAssertTrue(hasFocus(configured), "Back must restore the section that opened its configuration.")
        try focus(reorder, in: app)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(hasFocus(pageBack("settings-workspace-back", in: app)), app.debugDescription)
        capture("home-section-header-back", in: app)
        let watchingWasBelowWatchlist = configured.frame.minY > app.buttons["home-section-home-watchlist"].frame.minY
        XCTAssertEqual(preset.value as? String, "Custom")
        try focus(preset, in: app)
        XCUIRemote.shared.press(.select)
        let combinedOption = app.cells.containing(.other, identifier: "Combined rows").firstMatch
        XCTAssertTrue(combinedOption.waitForExistence(timeout: 5), app.debugDescription)
        try focus(combinedOption, in: app)
        XCUIRemote.shared.press(.select)
        let confirmation = app.sheets["Replace your row arrangement?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        try focus(confirmation.buttons.matching(identifier: "Cancel").firstMatch, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertTrue(configured.exists)
        XCTAssertEqual(configured.frame.minY > app.buttons["home-section-home-watchlist"].frame.minY, watchingWasBelowWatchlist)
        try focus(preset, in: app)
        XCUIRemote.shared.press(.select)
        try focus(combinedOption, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        try focus(confirmation.buttons.matching(identifier: "Combined rows").firstMatch, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-section-home-recentlyAdded"].waitForExistence(timeout: 5))
        try assertAddSectionActions(in: app)
        #else
        throw XCTSkip("Simulator-only Home editor navigation.")
        #endif
    }

    func testHomeSectionAddActionsFillTheListAndReturnFocus() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--home-section-editor-fixture", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home-section-hero"].waitForExistence(timeout: 5))
        try openHomeSections(in: app)
        try assertAddSectionActions(in: app)
        #else
        throw XCTSkip("Simulator-only Home editor navigation.")
        #endif
    }

    func testSingleHomeRowCanBeEditedAndRemoved() throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--home-section-editor-fixture", "--single-home-row", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        try openHomeSections(in: app)
        let edit = app.buttons["home-section-reorder"]
        XCTAssertTrue(edit.isEnabled, "A single row still supports removal through Edit.")
        try focus(edit, in: app)
        XCUIRemote.shared.press(.select)
        let row = app.buttons.containing(.staticText, identifier: "Continue Watching").firstMatch
        try focus(row, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(edit.isEnabled, "A lone row cannot be lifted for reordering.")
        XCUIRemote.shared.press(.select, forDuration: 1)
        let remove = app.cells.containing(.other, identifier: "Remove from Home").firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 3), app.debugDescription)
        try focus(remove, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        try focus(edit, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(edit.isEnabled)
        try focus(app.buttons["home-section-add"], in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["home-add-home-continueWatching"].waitForExistence(timeout: 3))
        capture("home-ux-last-row-removed", in: app)
        #else
        throw XCTSkip("Simulator-only Home editor interaction.")
        #endif
    }

    private func assertAddSectionActions(in app: XCUIApplication) throws {
        let section = app.buttons["home-section-home-continueWatching"]
        XCTAssertFalse(app.buttons["home-section-add-bottom"].exists)
        for identifier in ["home-section-add"] {
            let add = app.buttons[identifier]
            try focus(add, in: app)
            XCTAssertGreaterThanOrEqual(add.frame.width, section.frame.width,
                                       "Add row must fill the rows' content width.")
            XCTAssertLessThanOrEqual(add.frame.width - section.frame.width, 16,
                                     "Only the native focused button's outer margin may exceed the row width.")
            XCTAssertEqual(add.frame.midX, section.frame.midX, accuracy: 1)
            if identifier == "home-section-add" {
                XCTAssertGreaterThanOrEqual(add.frame.minY - app.buttons["home-row-preset"].frame.maxY, 20)
                XCTAssertGreaterThanOrEqual(
                    app.buttons["home-section-home-continueWatching"].frame.minY - add.frame.maxY, 20
                )
            }
            capture(identifier, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.staticTexts["Add row"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(app.buttons["home-add-collection"].label, "From a collection")
            XCTAssertFalse(app.buttons["home-section-reorder"].exists)
            if identifier == "home-section-add" {
                try focus(app.buttons["home-add-collection"], in: app)
                XCUIRemote.shared.press(.select)
                XCTAssertTrue(app.staticTexts["Choose collection"].waitForExistence(timeout: 5))
                let pickerControl = app.scrollViews["view-customization-scroll"].buttons
                    .matching(NSPredicate(format: "enabled == true")).firstMatch
                try focus(pickerControl, in: app)
                XCUIRemote.shared.press(.menu)
                XCTAssertTrue(app.buttons["home-add-collection"].waitForExistence(timeout: 5))
                try focus(app.buttons["home-add-collection"], in: app)
            }
            XCUIRemote.shared.press(.menu)
            waitForEnabled(add)
            XCTAssertTrue(hasFocus(add))
        }
    }

    private func openHomeSections(in app: XCUIApplication) throws {
        let sections = app.buttons["home-sections-settings"]
        try focus(sections, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["home-row-preset"].waitForExistence(timeout: 5), app.debugDescription)
    }

    func testHomeCustomizationKeepsAppearanceAboveSectionActions() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        defer { app.terminate() }
        try focus(section("screensNavigation", in: app), in: app)
        XCUIRemote.shared.press(.select)
        let navigation = app.buttons["settings-page-navigation"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        XCTAssertLessThan(navigation.frame.maxY, app.buttons["settings-page-customize-home"].frame.minY)
        capture("screen-customization-entry", in: app)
        try focus(app.buttons["settings-page-customize-home"], in: app)
        XCUIRemote.shared.press(.select)
        let hero = app.buttons["home-section-hero"]
        let labels = app.buttons["home-customize-labels"]
        let sections = app.buttons["home-sections-settings"]
        let reorder = app.buttons["home-section-reorder"]
        let preset = app.buttons["home-row-preset"]
        let add = app.buttons["home-section-add"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        try focus(hero, in: app)
        XCTAssertGreaterThanOrEqual(hero.frame.height, 74,
                                    "A disclosure must use full row geometry, never the deprecated text-height strip.")
        XCTAssertLessThan(hero.frame.maxY, labels.frame.minY)
        XCTAssertLessThan(labels.frame.maxY, sections.frame.minY)
        XCTAssertFalse(reorder.exists)
        XCTAssertFalse(preset.exists)
        XCTAssertFalse(add.exists)
        XCTAssertFalse(app.images["pin.fill"].exists, "Page appearance is not a pinned content section.")
        let back = pageBack(in: app)
        try focus(back, in: app)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(hasFocus(hero), "Down from Back must enter page appearance, not row actions.")
        try focus(labels, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["card-label-view-home"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["card-label-page"].exists)
        try focus(app.buttons["card-label-view-home"], in: app)
        XCTAssertTrue(app.staticTexts["Card labels"].exists)
        let preview = app.descendants(matching: .any)["card-label-preview-home"].firstMatch
        let watchingLabels = app.buttons["card-label-view-continueWatchingPortrait"]
        XCTAssertLessThan(preview.frame.minY - watchingLabels.frame.maxY, 170,
                          "The scoped preview belongs directly below the controls and shared-scope note.")
        capture("home-ux-card-labels", in: app)
        XCUIRemote.shared.press(.menu)
        capture("home-labels-return", in: app)
        waitForEnabled(labels)
        XCTAssertTrue(hasFocus(labels))
        capture("home-customization-scopes", in: app)
        try focus(hero, in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["Showcase"], in: app)
        XCUIRemote.shared.press(.select)
        capture("home-ux-layout", in: app)
        XCUIRemote.shared.press(.menu)
        waitForEnabled(hero)
        try focus(hero, in: app)
        capture("home-layout-full-height-focus", in: app)
        let layout = hero.label
        try openHomeSections(in: app)
        XCTAssertEqual(preset.label, "Preset")
        XCTAssertLessThan(preset.frame.maxY, add.frame.minY)
        XCTAssertEqual(reorder.frame.midY, pageBack(in: app).frame.midY, accuracy: 8,
                       "Edit belongs inline with the title and Back, not on a separate row.")
        try focus(reorder, in: app)
        capture("home-ux-rows", in: app)
        XCUIRemote.shared.press(.left)
        XCTAssertTrue(hasFocus(pageBack(in: app)))
        XCUIRemote.shared.press(.right)
        XCTAssertTrue(hasFocus(reorder), "Header actions must share native horizontal navigation.")
        XCUIRemote.shared.press(.left)
        XCUIRemote.shared.press(.down)
        XCTAssertTrue(hasFocus(preset), "Down from the header should enter the row settings.")
        let discovery = app.buttons["home-layout-discovery"]
        try focus(discovery, in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["Showcase"], in: app)
        XCUIRemote.shared.press(.menu)
        waitForEnabled(discovery)
        XCTAssertTrue(hasFocus(discovery))
        try focus(reorder, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(hero.exists)
        XCTAssertFalse(labels.exists)
        XCTAssertFalse(preset.isEnabled)
        XCTAssertFalse(add.isEnabled)
        XCTAssertTrue(reorder.isEnabled)
        XCTAssertEqual(reorder.label, "Done")
        XCTAssertFalse(discovery.isEnabled, "Layout-managed Discovery must not become an editable section.")
        try focus(reorder, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(reorder.label, "Edit")
        XCUIRemote.shared.press(.menu)
        waitForEnabled(sections)
        XCTAssertTrue(hasFocus(sections))
        XCTAssertEqual(hero.label, layout)
        XCTAssertTrue(labels.isEnabled)
        #else
        throw XCTSkip("Simulator-only Home editor hierarchy.")
        #endif
    }

    func testHomeSectionWarningDetailsAndRetryUseNativeControls() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--home-section-warning-fixture", "-AppleLanguages", "(en)"]
        app.launch()
        defer { app.terminate() }
        let details = app.buttons["Details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5), app.debugDescription)
        try focus(details, in: app)
        XCUIRemote.shared.press(.select)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "serverUnreachable")).firstMatch.exists)
        try focus(alert.buttons["OK"].firstMatch, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        let retry = app.buttons["Retry"]
        try focus(retry, in: app)
        XCTAssertTrue(hasFocus(retry), app.debugDescription)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(app.staticTexts["section-warning-retries"].label, "Retries: 1")
        capture("home-section-native-warning-actions", in: app)
    }

    func testHomeReorderAcceptsHeldAndRapidDirectionalInput() throws {
        try verifyHomeReorder(fromHoldMenu: false)
    }

    func testHomeHoldMenuLiftsSelectedRowAndAcceptsImmediateMovement() throws {
        try verifyHomeReorder(fromHoldMenu: true)
    }

    private func verifyHomeReorder(fromHoldMenu: Bool) throws {
        #if targetEnvironment(simulator)
        continueAfterFailure = false
        let app: XCUIApplication
        if fromHoldMenu {
            app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
            app.launchArguments = ["--home-section-editor-fixture", "-AppleLanguages", "(en)"]
            app.launch()
        } else {
            app = try launchSettings()
            try focus(section("screensNavigation", in: app), in: app)
            XCUIRemote.shared.press(.select)
            try focus(app.buttons["settings-page-customize-home"], in: app)
            XCUIRemote.shared.press(.select)
        }
        defer { app.terminate() }
        try openHomeSections(in: app)
        XCTAssertTrue(app.buttons["home-section-home-continueWatching"].waitForExistence(timeout: 5))
        let controls: Set<String> = [
            "home-section-hero", "home-section-reorder", "home-section-add", "home-section-add-bottom"
        ]
        let count = app.buttons.allElementsBoundByIndex.filter {
            $0.identifier.hasPrefix("home-section-") && !controls.contains($0.identifier)
        }.count
        XCTAssertGreaterThan(count, 2)
        let reorder = app.buttons["home-section-reorder"]
        let watching = app.buttons.containing(.staticText, identifier: "Continue Watching").firstMatch
        if fromHoldMenu {
            let original = app.buttons["home-section-home-continueWatching"]
            try focus(original, in: app)
            XCUIRemote.shared.press(.select, forDuration: 1)
            let startReorder = app.cells.containing(.other, identifier: "Reorder").firstMatch
            XCTAssertTrue(startReorder.waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertTrue(app.cells.containing(.other, identifier: "Remove from Home").firstMatch.exists)
            try focus(startReorder, in: app)
            XCUIRemote.shared.press(.select)
        } else {
            try focus(reorder, in: app)
            XCUIRemote.shared.press(.select)
            try focus(watching, in: app)
            XCUIRemote.shared.press(.select)
        }
        let lifted = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.hasFocus(watching) && !reorder.isEnabled }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [lifted], timeout: 5), .completed, app.debugDescription)
        XCUIRemote.shared.press(.down, forDuration: 3)
        capture("home-reorder-held-down", in: app)
        XCTAssertTrue(watching.staticTexts[String(count)].exists,
                      "Holding Down must move the lifted row all the way to the bottom. \(app.debugDescription)")
        XCTAssertTrue(hasFocus(watching))
        XCUIRemote.shared.press(.up, forDuration: 3)
        capture("home-reorder-held-up", in: app)
        XCTAssertTrue(watching.staticTexts["1"].exists,
                      "Holding Up must reach the top without reversing direction. \(app.debugDescription)")
        XCTAssertTrue(hasFocus(watching))
        let moves = min(3, count - 1)
        for _ in 0..<moves { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(watching.staticTexts[String(moves + 1)].exists, app.debugDescription)
        for _ in 0..<moves { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(watching.staticTexts["1"].exists, app.debugDescription)
        XCTAssertTrue(hasFocus(watching))
        XCUIRemote.shared.press(.select)
        waitForEnabled(reorder)
        func menuAction(_ title: String) throws {
            XCUIRemote.shared.press(.select, forDuration: 1)
            let action = app.cells.containing(.other, identifier: title).firstMatch
            XCTAssertTrue(action.waitForExistence(timeout: 3), app.debugDescription)
            try focus(action, in: app)
            XCUIRemote.shared.press(.select)
        }
        for (title, rank) in [("Move to bottom", count), ("Move to top", 1)] {
            try menuAction(title)
            let followed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in watching.staticTexts[String(rank)].exists && self.hasFocus(watching) },
                object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [followed], timeout: 3), .completed, app.debugDescription)
        }
        try menuAction("Remove from Home")
        XCTAssertTrue(watching.waitForNonExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(app.staticTexts["HIDDEN"].exists)
        waitForEnabled(reorder)
        try focus(reorder, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(app.buttons["home-section-home-continueWatching"].exists)
        if fromHoldMenu { return }
        try focus(app.buttons["home-section-add"], in: app)
        XCUIRemote.shared.press(.select)
        let addWatching = app.buttons["home-add-home-continueWatching"]
        XCTAssertTrue(addWatching.waitForExistence(timeout: 3), app.debugDescription)
        try focus(addWatching, in: app)
        XCUIRemote.shared.press(.select)
        let restored = app.buttons["home-section-home-continueWatching"]
        XCTAssertTrue(restored.waitForExistence(timeout: 3), app.debugDescription)
        try focus(restored, in: app)
        try menuAction("Remove from Home")
        XCTAssertTrue(restored.waitForNonExistence(timeout: 3))
        try focus(app.buttons["home-section-add"], in: app)
        XCUIRemote.shared.press(.select)
        try focus(addWatching, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(restored.waitForExistence(timeout: 3), app.debugDescription)
        #else
        throw XCTSkip("Simulator-only Home reorder input regression.")
        #endif
    }

    func testHeldReorderScrollsLongListsAndCrossesVisibilityDivider() throws {
        #if targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PLOZZ_SETTINGS_REVIEW"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        defer { app.terminate() }
        for allowsHiding in [false, true] {
            app.launchArguments = ["--reorder-input-fixture"] + (allowsHiding ? ["--with-hidden-rows"] : [])
            app.launch()
            let row = app.buttons.containing(.staticText, identifier: "Row 0").firstMatch
            try focus(row, in: app)
            XCUIRemote.shared.press(.select)
            XCUIRemote.shared.press(.down, forDuration: 4)
            let position = app.staticTexts["reorder-fixture-position"]
            XCTAssertEqual(position.label, "Position \(allowsHiding ? 25 : 23); hidden \(allowsHiding)")
            func positions() throws -> [Int] {
                let value = try XCTUnwrap(position.value as? String)
                return try value.split(separator: ",").map { try XCTUnwrap(Int($0)) }
            }
            let downward = try positions()
            XCTAssertEqual(downward, Array(1...23) + (allowsHiding ? [23, 24, 25] : []),
                           "Every delivered move must advance, never bounce or skip a row.")
            XCTAssertTrue(hasFocus(row), app.debugDescription)
            XCTAssertTrue(row.isHittable)
            XCTAssertGreaterThan(row.frame.minY, 0)
            XCTAssertLessThan(row.frame.maxY, app.frame.maxY)
            capture("long-reorder-bottom-hidden-\(allowsHiding)", in: app)
            XCUIRemote.shared.press(.up, forDuration: 4)
            XCTAssertEqual(position.label, "Position 0; hidden false")
            let upward = Array(try positions().dropFirst(downward.count))
            XCTAssertEqual(upward, (allowsHiding ? [24, 23] : []) + Array((0...23).reversed().dropFirst(allowsHiding ? 0 : 1)))
            XCTAssertTrue(hasFocus(row), app.debugDescription)
            XCTAssertTrue(row.isHittable)
            capture("long-reorder-top-hidden-\(allowsHiding)", in: app)
            XCUIRemote.shared.press(.down, forDuration: 0.7)
            let releasedPosition = position.label
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            XCTAssertEqual(position.label, releasedPosition, "Repetition must stop when the button is released.")
            XCUIRemote.shared.press(.up, forDuration: 4)
            XCUIRemote.shared.press(.select)
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(hasFocus(app.buttons.containing(.staticText, identifier: "Row 1").firstMatch))
            app.terminate()
        }
        #else
        throw XCTSkip("Task-owned simulator input fixture.")
        #endif
    }

    func testHeroRandomAndDiscoverySourcesKeepSettingsResponsive() throws {
        #if targetEnvironment(simulator)
        func openSources(in app: XCUIApplication) throws {
            try focus(section("screensNavigation", in: app), in: app)
            XCUIRemote.shared.press(.select)
            try focus(app.buttons["settings-page-customize-home"], in: app)
            XCUIRemote.shared.press(.select)
            try focus(app.buttons["home-section-hero"], in: app)
            XCUIRemote.shared.press(.select)
            try focus(app.buttons["Fullscreen Hero"], in: app)
            XCUIRemote.shared.press(.select)
            try focus(app.buttons["hero-settings-titles"], in: app)
            XCUIRemote.shared.press(.select)
        }

        var app = try launchSettings()
        defer { app.terminate() }
        try openSources(in: app)

        let random = app.switches["Random from Library"]
        let discovery = app.switches["Discovery"]
        for source in [random, discovery] {
            try focus(source, in: app)
            if source.value as? String == "1" { XCUIRemote.shared.press(.select) }
            XCTAssertEqual(source.value as? String, "0")
        }
        for source in [random, discovery] {
            try focus(source, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertEqual(source.value as? String, "1")
            XCTAssertTrue(hasFocus(source), app.debugDescription)
        }
        capture("hero-random-and-discovery-enabled", in: app)
        let providers = app.buttons["hero-settings-discovery"]
        for visit in 0..<3 {
            try focus(providers, in: app)
            XCUIRemote.shared.press(.select)
            let labels = app.switches["Show provider labels"]
            XCTAssertTrue(labels.waitForExistence(timeout: 5), app.debugDescription)
            try focus(labels, in: app)
            let previous = labels.value as? String
            XCUIRemote.shared.press(.select)
            XCTAssertNotEqual(labels.value as? String, previous)
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(providers.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(hasFocus(providers), app.debugDescription)
            if visit == 0 {
                XCUIRemote.shared.press(.menu)
                let sources = app.buttons["hero-settings-titles"]
                XCTAssertTrue(sources.waitForExistence(timeout: 5))
                try focus(sources, in: app)
                XCUIRemote.shared.press(.select)
            }
        }

        app.terminate()
        // Use native top-bar entry after relaunch; the fixture leaves Hero preferences intact.
        app = try launchSettings(style: "tabBar")
        try openSources(in: app)
        for title in ["Random from Library", "Discovery"] {
            XCTAssertEqual(app.switches[title].value as? String, "1", "The enabled sources must survive restart.")
        }
        let restoredDiscovery = app.switches["Discovery"]
        try focus(restoredDiscovery, in: app)
        for value in ["0", "1"] {
            XCUIRemote.shared.press(.select)
            XCTAssertEqual(restoredDiscovery.value as? String, value)
            XCTAssertTrue(hasFocus(restoredDiscovery), app.debugDescription)
        }
        let restoredProviders = app.buttons["hero-settings-discovery"]
        try focus(restoredProviders, in: app)
        XCUIRemote.shared.press(.select)
        let labels = app.switches["Show provider labels"]
        XCTAssertTrue(labels.waitForExistence(timeout: 5), app.debugDescription)
        try focus(labels, in: app)
        let previous = labels.value as? String
        XCUIRemote.shared.press(.select)
        XCTAssertNotEqual(labels.value as? String, previous)
        XCUIRemote.shared.press(.menu)
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.hasFocus(restoredProviders) }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed, app.debugDescription)
        #else
        throw XCTSkip("Simulator-only Hero source investigation.")
        #endif
    }

    func testHeroEditorsRemainInsideTheSettingsPane() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        try focus(section("screensNavigation", in: app), in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["settings-page-customize-home"], in: app)
        XCUIRemote.shared.press(.select)
        let hero = app.buttons["home-section-hero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        try focus(hero, in: app)
        XCUIRemote.shared.press(.select)
        let fullscreen = app.buttons["Fullscreen Hero"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5))
        try focus(fullscreen, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["hero-settings-titles"].waitForExistence(timeout: 5))
        capture("hero", in: app)
        for label in ["Items to show", "Seconds per item"] {
            let stepper = app.buttons[label]
            try focus(stepper, in: app)
            XCTAssertGreaterThan(stepper.frame.width, 700)
            let title = app.staticTexts[label].firstMatch
            let peer = app.staticTexts["Hide watched content"].firstMatch
            XCTAssertEqual(title.frame.minX, peer.frame.minX, accuracy: 1)
            XCTAssertEqual(title.frame.height, peer.frame.height, accuracy: 1)
            let original = try XCTUnwrap(stepper.value as? String)
            XCUIRemote.shared.press(.right)
            XCTAssertNotEqual(stepper.value as? String, original)
            XCTAssertTrue(stepper.hasFocus)
            XCUIRemote.shared.press(.left)
            XCTAssertEqual(stepper.value as? String, original)
            capture("hero-stepper-\(label)", in: app)
        }
        for (page, content) in [
            ("titles", "Hero content sources"), ("ratings", "Ratings"), ("trailers", "Trailers")
        ] {
            let link = app.buttons["hero-settings-\(page)"]
            try focus(link, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.buttons["view-customization-back"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[content].exists)
            capture("hero-\(page)", in: app)
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(link.waitForExistence(timeout: 5))
        }
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    func testCircadianSteppersKeepWholeRowFocusAndRestoreValues() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings()
        try focus(section("appearance", in: app), in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["settings-page-night-shift"], in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["Manual"], in: app)
        XCUIRemote.shared.press(.select)
        for label in ["Turns on", "Turns off", "Fade", "Darkness", "Warmth"] {
            let stepper = app.buttons[label]
            try focus(stepper, in: app)
            XCTAssertGreaterThan(stepper.frame.width, 700)
            let original = try XCTUnwrap(stepper.value as? String)
            XCUIRemote.shared.press(.right)
            XCTAssertNotEqual(stepper.value as? String, original)
            XCTAssertTrue(stepper.hasFocus)
            XCUIRemote.shared.press(.left)
            XCTAssertEqual(stepper.value as? String, original)
            capture("circadian-stepper-\(label)", in: app)
        }
        try focus(app.buttons["Always On"], in: app)
        XCUIRemote.shared.press(.up)
        let back = pageBack(in: app)
        let headerFocused = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.hasFocus(back) }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [headerFocused], timeout: 5), .completed,
                       "Up from the rightmost mode must reach Back across the full header width.")
        capture("circadian-header-back", in: app)
        XCUIRemote.shared.press(.down)
        XCUIRemote.shared.press(.select)
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !app.buttons["Darkness"].exists }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed,
                       "Restore the fixture before later visual checks.")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["settings-page-night-shift"].waitForExistence(timeout: 5))
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    func testPlozzChannelsOpensFromSourcesAndReturnsFromCustomEditor() throws {
        #if targetEnvironment(simulator)
        let app = launchSourcesNavigationFixture()
        defer { app.terminate() }
        let manage = app.buttons["live-tv-manage-library-channels"]
        for _ in 0..<2 {
            try focus(manage, in: app)
            XCUIRemote.shared.press(.select)
            let automatic = app.switches["live-tv-automatic-enabled"]
            XCTAssertTrue(automatic.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(manage.exists && manage.isEnabled,
                           "The retained Sources page must not accept input behind its child.")
            let previous = automatic.value as? String
            try focus(automatic, in: app)
            XCUIRemote.shared.press(.select)
            let updated = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in automatic.value as? String != previous }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed,
                           "The management page must reflect the live enabled state.")
            XCUIRemote.shared.press(.select)
            let restored = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in automatic.value as? String == previous }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
            capture("sources-plozz-channels", in: app)
            let create = app.buttons["live-tv-create-custom-channel"]
            try focus(create, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.buttons["library-channel-preview-save"].waitForExistence(timeout: 5),
                          app.debugDescription)
            XCTAssertFalse(automatic.exists && automatic.isEnabled)
            try focus(pageBack("live-tv-settings-back", in: app), in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(create.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(automatic.exists, "Back from the editor must return one level to Plozz channels.")
            XCUIRemote.shared.press(.menu)
            waitForEnabled(manage)
        }
        #else
        throw XCTSkip("Never seeds sources on a physical device.")
        #endif
    }

    func testChannelAvailabilityOpensDirectlyFromSources() throws {
        #if targetEnvironment(simulator)
        let app = launchSourcesNavigationFixture()
        defer { app.terminate() }
        let check = app.buttons["Check channel availability"]
        for _ in 0..<2 {
            try focus(check, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.staticTexts["Check channels"].waitForExistence(timeout: 5),
                          app.debugDescription)
            XCTAssertTrue(app.buttons.matching(identifier: "live-tv-scan-source").firstMatch
                .waitForExistence(timeout: 10), app.debugDescription)
            let manage = app.buttons["live-tv-manage-library-channels"]
            XCTAssertFalse(manage.exists && manage.isEnabled)
            XCTAssertFalse(app.buttons["live-tv-cancel-scan"].exists, "Opening the page must not start a scan.")
            capture("sources-channel-availability", in: app)
            try focus(pageBack("live-tv-settings-back", in: app), in: app)
            XCUIRemote.shared.press(.select)
            waitForEnabled(check)
        }
        #else
        throw XCTSkip("Never seeds sources on a physical device.")
        #endif
    }

    func testGeneratedChannelsScrollWithinTheirSectionAndReleaseFocus() throws {
        #if targetEnvironment(simulator)
        let app = launchChannelSettingsFixture()
        defer { app.terminate() }
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "live-tv-generated-channel-")
        ).allElementsBoundByIndex
        XCTAssertGreaterThan(rows.count, 8, "Exercise a lineup longer than its viewport.")
        let first = try XCTUnwrap(rows.first)
        let lineup = app.descendants(matching: .any)["live-tv-generated-lineup"].firstMatch
        try focus(first, in: app)
        capture("generated-lineup-entry", in: app)
        let viewport = lineup.frame.intersection(app.frame)
        for row in rows.prefix(4) {
            XCTAssertGreaterThanOrEqual(row.frame.minY, viewport.minY)
            XCTAssertLessThanOrEqual(row.frame.maxY, viewport.maxY)
        }
        let fifth = rows[4].frame
        let visibleFraction = viewport.intersection(fifth).height / fifth.height
        XCTAssertEqual(visibleFraction, 0.5, accuracy: 0.05,
                       "Show half of the fifth row before scrolling to advertise the remaining lineup.")
        for (index, row) in rows.enumerated() {
            if index > 0 { XCUIRemote.shared.press(.down) }
            XCTAssertTrue(hasFocus(row), "Down must browse every generated channel. \(app.debugDescription)")
            let visible = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    row.frame.minY >= lineup.frame.minY - 1 && row.frame.maxY <= lineup.frame.maxY + 1
                }, object: nil
            )
            let result = XCTWaiter.wait(for: [visible], timeout: 3)
            if result != .completed { capture("generated-lineup-clipped-\(index)", in: app) }
            XCTAssertEqual(result, .completed, "The focused row must be fully inside its scrolling section.")
        }
        capture("generated-lineup-end", in: app)
        XCUIRemote.shared.press(.down)
        let create = app.buttons["live-tv-create-custom-channel"]
        XCTAssertTrue(hasFocus(create), "Down at the end must leave the lineup.")
        XCTAssertGreaterThanOrEqual(create.frame.height, 74)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(hasFocus(try XCTUnwrap(rows.last)), "Up must reenter at the last channel.")
        for _ in 1..<rows.count { XCUIRemote.shared.press(.up) }
        XCTAssertTrue(hasFocus(first))
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(hasFocus(app.buttons["live-tv-automatic-retry"]), "Up at the start must leave the lineup.")
        #else
        throw XCTSkip("Never seeds libraries on a physical device.")
        #endif
    }

    func testCustomChannelControlsUseSharedSizingAndIndependentLibraryChecks() throws {
        #if targetEnvironment(simulator)
        let app = launchChannelSettingsFixture()
        defer { app.terminate() }
        let create = app.buttons["live-tv-create-custom-channel"]
        try focus(create, in: app)
        capture("channel-create-action", in: app)
        XCUIRemote.shared.press(.select)
        let movies = app.switches["library-channel-movies"]
        XCTAssertTrue(movies.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Comedy preset"].exists)
        for identifier in ["library-channel-icon", "library-channel-order"] {
            let control = app.buttons[identifier]
            try focus(control, in: app)
            XCTAssertGreaterThanOrEqual(control.frame.height, 74)
            XCTAssertEqual(control.frame.height, movies.frame.height, accuracy: 1)
        }
        capture("channel-editor-controls", in: app)
        let order = app.buttons["library-channel-order"]
        for title in ["Movies", "Shows in episode order"] {
            try focus(order, in: app)
            XCUIRemote.shared.press(.select)
            let option = app.cells.containing(.any, identifier: title).firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
            try focus(option, in: app)
            XCUIRemote.shared.press(.select)
            let applied = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    app.switches["library-channel-episodes"].isEnabled == (title != "Movies")
                }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 5), .completed)
        }
        let icon = app.buttons["library-channel-icon"]
        try focus(icon, in: app)
        XCUIRemote.shared.press(.select)
        let favorite = app.cells.containing(.any, identifier: "Favorites").firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 5), app.debugDescription)
        try focus(favorite, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(icon.label.contains("Favorites") || icon.staticTexts["Favorites"].exists)
        let libraries = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library-channel-source-")
        ).allElementsBoundByIndex
        XCTAssertEqual(libraries.count, 2, "Both provider libraries must be available.")
        for library in libraries {
            try focus(library, in: app)
            XCTAssertGreaterThanOrEqual(library.frame.height, 74)
            XCTAssertFalse(library.isSelected)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(library.isSelected)
        }
        let first = try XCTUnwrap(libraries.first)
        try focus(first, in: app)
        capture("channel-source-libraries", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertFalse(first.isSelected)
        XCTAssertTrue(try XCTUnwrap(libraries.last).isSelected, "Changing one library must preserve the other.")
        let preview = app.buttons["library-channel-preview-save"]
        try focus(preview, in: app)
        XCTAssertGreaterThanOrEqual(preview.frame.height, 74)
        capture("channel-editor-rules", in: app)
        XCUIRemote.shared.press(.menu)
        waitForEnabled(create)
        #else
        throw XCTSkip("Never seeds libraries on a physical device.")
        #endif
    }

    private func launchChannelSettingsFixture() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--channel-settings-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["live-tv-create-custom-channel"].waitForExistence(timeout: 15),
                      app.debugDescription)
        return app
    }

    private func launchSourcesNavigationFixture() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--sources-navigation-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["live-tv-manage-library-channels"].waitForExistence(timeout: 10),
                      app.debugDescription)
        return app
    }

    func testLiveTVOverviewKeepsAllSourcesReachableAndAddInTheHeader() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--sources-navigation-fixture", "--settings-overview-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let first = app.buttons["live-tv-source-details-fixture"]
        XCTAssertTrue(first.waitForExistence(timeout: 15), app.debugDescription)
        let add = app.buttons["live-tv-add-source"]
        XCTAssertTrue(add.exists)
        let lineup = app.descendants(matching: .any)["live-tv-sources-list"].firstMatch
        try focus(first, in: app)
        let viewport = lineup.frame.intersection(app.frame)
        for index in 0..<4 {
            let suffix = index == 0 ? "fixture" : "fixture-\(index)"
            let row = app.buttons["live-tv-source-details-\(suffix)"]
            XCTAssertGreaterThanOrEqual(row.frame.minY, viewport.minY - 1)
            XCTAssertLessThanOrEqual(row.frame.maxY, viewport.maxY + 1)
        }
        let fifth = app.buttons["live-tv-source-details-fixture-4"].frame
        XCTAssertEqual(viewport.intersection(fifth).height / fifth.height, 0.5, accuracy: 0.08)
        capture("live-tv-overview-entry", in: app)
        for index in 1..<6 {
            XCUIRemote.shared.press(.down)
            XCTAssertTrue(hasFocus(app.buttons["live-tv-source-details-fixture-\(index)"]),
                          "Down must reach each source without escaping the bounded list.")
        }
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.switches["live-tv-source-enabled-fixture-5"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        try focus(add, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["live-tv-add-server"].waitForExistence(timeout: 5))
        for identifier in ["live-tv-add-playlist", "live-tv-add-server"] {
            let action = app.buttons[identifier]
            try focus(action, in: app)
            XCTAssertEqual(try assertStandardFormFocusFill(action), 74, accuracy: 1)
        }
        let rootHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let automatic = app.switches["live-tv-automatic-enabled"]
                return !automatic.exists || !automatic.isEnabled
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [rootHidden], timeout: 5), .completed,
                       "The retained root must not accept input behind Add source.\n\(app.debugDescription)")
        capture("live-tv-add-source-page", in: app)
        XCUIRemote.shared.press(.menu)
        let automatic = app.switches["live-tv-automatic-enabled"]
        try focus(automatic, in: app)
        XCTAssertTrue(automatic.label.contains("Auto-create channels from your libraries"))
        let automaticTitle = automatic.staticTexts["Auto-create channels from your libraries"].firstMatch
        XCTAssertTrue(automaticTitle.exists)
        XCTAssertLessThanOrEqual(automaticTitle.frame.height, 40,
                                "The TV label should fit on one line without shrinking.")
        XCTAssertTrue(app.buttons["live-tv-manage-library-channels"].label.contains("Manage channels"))
        XCTAssertFalse(app.staticTexts["Channels made from your movies and shows."].exists)
        capture("live-tv-automatic-action-label", in: app)
        for identifier in [
            "live-tv-manage-library-channels", "live-tv-start-view", "live-tv-channel-order",
            "live-tv-guide-preferences", "live-tv-channel-visibility"
        ] {
            let row = app.buttons[identifier]
            try focus(row, in: app)
            XCTAssertEqual(try assertStandardFormFocusFill(row), 74, accuracy: 1,
                           "Single-line navigation and menu controls must share their painted height.")
        }
        let order = app.buttons["live-tv-channel-order"]
        for choice in ["Name", "Channel number"] {
            try focus(order, in: app)
            XCUIRemote.shared.press(.select)
            let option = app.cells.containing(.any, identifier: choice).firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
            try focus(option, in: app)
            XCUIRemote.shared.press(.select)
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in order.value as? String == choice }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            XCTAssertTrue(hasFocus(order), "Changing channel order must return to the root menu row.")
            XCTAssertTrue(app.buttons["live-tv-manage-library-channels"].isEnabled)
        }
        try focus(app.buttons["live-tv-guide-preferences"], in: app)
        capture("live-tv-standard-form-controls", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.switches["Auto preview"].waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
    }

    @discardableResult
    private func assertStandardFormFocusFill(_ row: XCUIElement) throws -> CGFloat {
        let image = try XCTUnwrap(row.screenshot().image.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var longest = 0
        var current = 0
        for y in 0..<image.height {
            let pixel = (y * image.width + image.width / 2) * 4
            if bytes[pixel] > 230 && bytes[pixel + 1] > 230 && bytes[pixel + 2] > 230 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        let scale = CGFloat(image.width) / row.frame.width
        XCTAssertGreaterThanOrEqual(CGFloat(longest) / scale, 70,
                                   "The painted focus fill, not just outer padding, must span a standard form row.")
        return CGFloat(longest) / scale
    }

    func testCompactIPTVSourcesAndChildBackNavigation() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(style: "tabBar", sources: true)
        defer { capture("compact-final-state", in: app) }
        try focus(section("metadata", in: app), in: app)
        XCUIRemote.shared.press(.select)
        let recommended = app.buttons["Recommended"]
        XCTAssertTrue(recommended.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThanOrEqual(recommended.frame.height, 66)
        capture("compact-metadata-options", in: app)
        XCUIRemote.shared.press(.menu)
        try focus(section("liveTV", in: app), in: app)
        XCUIRemote.shared.press(.select)
        let first = app.buttons["live-tv-source-details-settings-review-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["settings-page-sources"].exists,
                       "Sources belong directly on the Live TV settings page.")
        let add = app.buttons["live-tv-add-source"]
        XCTAssertTrue(add.exists)
        XCTAssertTrue(app.switches["live-tv-automatic-enabled"].exists)
        let lineup = app.descendants(matching: .any)["live-tv-sources-list"].firstMatch
        try focus(first, in: app)
        let viewport = lineup.frame.intersection(app.frame)
        for index in 0..<4 {
            let row = app.buttons["live-tv-source-details-settings-review-\(index)"]
            XCTAssertGreaterThanOrEqual(row.frame.minY, viewport.minY - 1)
            XCTAssertLessThanOrEqual(row.frame.maxY, viewport.maxY + 1)
        }
        let fifth = app.buttons["live-tv-source-details-settings-review-4"].frame
        XCTAssertEqual(viewport.intersection(fifth).height / fifth.height, 0.5, accuracy: 0.08,
                       "The shared fade must reveal part of the fifth source.")
        for index in 0..<6 {
            let row = app.buttons["live-tv-source-details-settings-review-\(index)"]
            XCTAssertTrue(row.exists)
            if index > 0 { XCUIRemote.shared.press(.down) }
            XCTAssertTrue(hasFocus(row), "Every source must be reachable in order.")
        }
        capture("live-tv-sources-scrolled", in: app)
        XCTAssertFalse(app.buttons["live-tv-remove-source-settings-review-0"].exists)
        try focus(add, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["live-tv-add-server"].waitForExistence(timeout: 5))
        capture("live-tv-add-source", in: app)
        let detailScroll = try XCTUnwrap(app.scrollViews.allElementsBoundByIndex.first {
            $0.buttons["live-tv-add-server"].exists
        })
        let detailMaxX = detailScroll.frame.maxX
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        try focus(app.buttons["live-tv-guide-preferences"], in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertLessThan(
            app.staticTexts["Preview the focused channel as you browse."].firstMatch.frame.height,
            app.staticTexts["Auto preview"].firstMatch.frame.height
        )
        capture("live-tv-guide-preferences", in: app)
        XCUIRemote.shared.press(.menu)
        try focus(first, in: app)
        XCUIRemote.shared.press(.select)
        let back = pageBack("live-tv-settings-back", in: app)
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Northstar TV"].exists)
        capture("iptv-source-controls", in: app)
        for link in [
            "live-tv-edit-source-settings-review-0",
            "live-tv-source-guides-settings-review-0"
        ] {
            try focus(app.buttons[link], in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
            if link == "live-tv-source-guides-settings-review-0" {
                for identifier in ["live-tv-guide-lookback", "live-tv-guide-lookahead"] {
                    let menu = app.buttons[identifier]
                    XCTAssertTrue(menu.exists)
                    XCTAssertLessThanOrEqual(menu.frame.maxX, detailMaxX - 28)
                }
            }
            capture(link, in: app)
            try focus(back, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.buttons[link].waitForExistence(timeout: 5), app.debugDescription)
        }
        try focus(back, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(first.waitForExistence(timeout: 5), app.debugDescription)
        #else
        throw XCTSkip("Never seeds sources on a physical device.")
        #endif
    }

    func testSubtitleStyleEditorsExpandAndRestoreTheWorkspace() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(style: "tabBar")
        defer { capture("subtitle-fullscreen-final-state", in: app) }
        try focus(section("subtitles", in: app), in: app)
        XCUIRemote.shared.press(.select)
        let primaryStyle = app.buttons["Customize subtitle style"]
        let styleVisible = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in primaryStyle.exists && primaryStyle.isHittable }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [styleVisible], timeout: 5), .completed,
                       "Subtitle style must be visible near the top without scrolling after the transition.")
        XCTAssertLessThan(primaryStyle.frame.minY, app.staticTexts["Subtitle language"].firstMatch.frame.minY)
        for (title, captureName) in [
            ("Customize subtitle style", "subtitle-style"),
            ("Customize Live TV subtitles", "subtitle-style-live-tv")
        ] {
            if title == "Customize Live TV subtitles", !app.buttons[title].exists {
                let separateStyle = app.switches["Use a separate style for Live TV"]
                try focus(separateStyle, in: app)
                XCUIRemote.shared.press(.select)
            }
            let link = app.buttons[title]
            XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
            try focus(link, in: app)
            capture("\(captureName)-before", in: app)
            XCUIRemote.shared.press(.select)
            let heading = app.staticTexts[title]
            XCTAssertTrue(heading.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(section("subtitles", in: app).exists, app.debugDescription)
            XCTAssertFalse(app.buttons["settings-profile-switch"].exists)
            let back = pageBack(in: app)
            XCTAssertLessThan(back.frame.minX, 200, "The editor must reclaim the sidebar column.")
            let controlColumn = app.scrollViews["subtitle-style-editor-card"]
            XCTAssertTrue(controlColumn.waitForExistence(timeout: 5))
            XCTAssertFalse(controlColumn.buttons["settings-workspace-back"].exists)
            XCTAssertFalse(controlColumn.staticTexts[title].exists)
            let headingAtEntry = heading.frame
            assertInlineSettingsHeader(title, back: back, in: app)
            XCTAssertGreaterThan(controlColumn.frame.minY, heading.frame.maxY)
            XCTAssertFalse(app.staticTexts["Appearance"].exists)
            let preview = app.otherElements["subtitle-style-preview"]
            XCTAssertTrue(preview.exists)
            let previewAtEntry = preview.frame
            XCTAssertTrue(back.exists)
            let editorCard = controlColumn
            XCTAssertTrue(editorCard.exists)
            XCTAssertFalse(editorCard.buttons["settings-workspace-back"].exists,
                           "Page navigation belongs outside the Appearance card.")
            capture(captureName, in: app)
            let font = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Font")).firstMatch
            let matchedSystemStyle = !font.isEnabled
            let matchSystemStyle = app.buttons["Match Apple TV Subtitle Style"]
            if matchedSystemStyle {
                try focus(matchSystemStyle, in: app)
                XCUIRemote.shared.press(.select)
            }
            try focus(font, in: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.staticTexts["Font"].waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(section("subtitles", in: app).exists)
            try focus(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "System Fonts")).firstMatch,
                      in: app)
            XCTAssertEqual(heading.frame, headingAtEntry, "Only the editor pane may scroll.")
            XCTAssertEqual(preview.frame.minY, previewAtEntry.minY, accuracy: 1)
            XCTAssertEqual(preview.frame.width, previewAtEntry.width, accuracy: 1)
            XCTAssertEqual(preview.frame.height, previewAtEntry.height, accuracy: 1)
            capture("\(captureName)-fonts", in: app)
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(matchSystemStyle.waitForExistence(timeout: 5), app.debugDescription)
            if matchedSystemStyle {
                try focus(matchSystemStyle, in: app)
                XCUIRemote.shared.press(.select)
            }
            let paneBeforePreview = controlColumn.frame
            let previewHeader = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Preview")).firstMatch
            try focus(previewHeader, in: app)
            let expanded = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    app.buttons["HDR preview"].exists
                        && controlColumn.frame.height < paneBeforePreview.height - 100
                }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
            XCTAssertEqual(heading.frame, headingAtEntry)
            XCTAssertEqual(preview.frame, previewAtEntry)
            let previewControls = app.otherElements["subtitle-preview-controls"]
            XCTAssertGreaterThan(previewControls.frame.minY, controlColumn.frame.maxY)
            XCTAssertLessThan(previewControls.frame.maxY, app.frame.maxY)
            capture("\(captureName)-preview-expanded", in: app)
            XCUIRemote.shared.press(.select)
            let fullScreenBack = app.buttons["Back"].firstMatch
            XCTAssertTrue(fullScreenBack.waitForExistence(timeout: 5))
            XCUIRemote.shared.press(.menu)
            XCTAssertTrue(previewHeader.waitForExistence(timeout: 5))
            try focus(matchSystemStyle, in: app)
            let collapsed = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    abs(controlColumn.frame.height - paneBeforePreview.height) < 1
                }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed)
            XCTAssertEqual(heading.frame, headingAtEntry)
            if title == "Customize subtitle style" {
                XCUIRemote.shared.press(.menu)
            } else {
                let back = pageBack(in: app)
                try focus(back, in: app)
                XCUIRemote.shared.press(.select)
            }
            XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(section("subtitles", in: app).exists)
            XCTAssertFalse(app.buttons["settings-profile-switch"].exists)
            XCTAssertTrue(app.buttons["settings-category-back"].exists)
            capture("\(captureName)-returned", in: app)
        }
        XCUIRemote.shared.press(.menu)
        waitForCategoryFocus("subtitles", in: app)
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    func testDirectionalSteppersAdjustWithoutMovingFocus() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(style: "tabBar")
        defer { capture("directional-steppers-final", in: app) }
        try focus(section("playback", in: app), in: app)
        XCUIRemote.shared.press(.select)
        var trailingEdge: CGFloat?
        for label in ["Time before the end", "Backward", "Forward", "Rewind on resume"] {
            let stepper = app.buttons[label]
            XCTAssertTrue(stepper.waitForExistence(timeout: 5), app.debugDescription)
            try focus(stepper, in: app)
            let initialValue = stepper.value as? String
            XCTAssertNotNil(initialValue)
            let title = app.staticTexts[label].firstMatch
            let labelInsideTarget = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in stepper.frame.contains(title.frame) }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [labelInsideTarget], timeout: 3), .completed,
                           "After native scrolling settles, the focus target must contain its label.")
            let initialFrame = stepper.frame
            XCTAssertGreaterThan(initialFrame.width, 800, "The entire Settings row must receive native focus.")
            let peer = app.staticTexts["Show Up Next card"].firstMatch
            XCTAssertEqual(title.frame.minX, peer.frame.minX, accuracy: 1,
                           "Stepper text must align with neighboring setting rows.")
            XCTAssertEqual(title.frame.height, peer.frame.height, accuracy: 1)
            if let trailingEdge {
                XCTAssertEqual(initialFrame.maxX, trailingEdge, accuracy: 2)
            } else {
                trailingEdge = initialFrame.maxX
            }
            XCUIRemote.shared.press(.right)
            XCTAssertTrue(hasFocus(stepper), "Right must adjust rather than move focus.")
            XCTAssertNotEqual(stepper.value as? String, initialValue)
            XCTAssertEqual(stepper.frame.width, initialFrame.width, accuracy: 1)
            XCTAssertEqual(stepper.frame.height, initialFrame.height, accuracy: 1)
            XCTAssertEqual(stepper.frame.minX, initialFrame.minX, accuracy: 1)
            XCUIRemote.shared.press(.left)
            XCTAssertEqual(stepper.value as? String, initialValue)
            XCTAssertTrue(hasFocus(stepper))
            capture("directional-stepper-\(label)", in: app)
            XCUIRemote.shared.press(.down)
            XCTAssertFalse(hasFocus(stepper), "Down must remain native navigation.")
            try focus(stepper, in: app)
            XCUIRemote.shared.press(.up)
            XCTAssertFalse(hasFocus(stepper), "Up must remain native navigation.")
        }
        XCTAssertEqual(
            app.staticTexts["Backward"].firstMatch.frame.height,
            app.staticTexts["Rewind on resume"].firstMatch.frame.height, accuracy: 1
        )
        #else
        throw XCTSkip("Never changes settings on a physical device.")
        #endif
    }

    func testAlignedIdentityHeadersAndCompactDetailPageControls() throws {
        #if targetEnvironment(simulator)
        let app = try launchSettings(style: "tabBar")
        let profile = app.staticTexts["settings-profile-name"]
        let everyone = app.staticTexts["settings-everyone-name"]
        XCTAssertTrue(profile.exists && everyone.exists, app.debugDescription)
        XCTAssertEqual(profile.frame.minX, everyone.frame.minX, accuracy: 2)
        XCTAssertEqual(profile.frame.height, everyone.frame.height, accuracy: 2)
        XCTAssertLessThanOrEqual(profile.frame.height, 46)
        let avatar = app.descendants(matching: .any).matching(identifier: "settings-profile-avatar").firstMatch
        let scope = app.descendants(matching: .any).matching(identifier: "settings-everyone-icon").firstMatch
        XCTAssertTrue(avatar.exists && scope.exists, app.debugDescription)
        XCTAssertEqual(avatar.frame.width, scope.frame.width, accuracy: 1)
        XCTAssertEqual(avatar.frame.height, scope.frame.height, accuracy: 1)
        XCTAssertEqual(scope.frame.width, 52, accuracy: 1)
        capture("aligned-settings-headers", in: app)
        try focus(section("servers", in: app), in: app)
        capture("everyone-circular-badge-and-divider", in: app)

        try focus(section("screensNavigation", in: app), in: app)
        XCUIRemote.shared.press(.select)
        try focus(app.buttons["settings-page-title-details"], in: app)
        XCUIRemote.shared.press(.select)
        let showScores = app.switches["Show review scores"]
        XCTAssertTrue(showScores.waitForExistence(timeout: 5), app.debugDescription)
        let back = pageBack(in: app)
        XCTAssertTrue(back.exists)
        let scroll = try XCTUnwrap(app.scrollViews.allElementsBoundByIndex.first {
            $0.buttons["settings-workspace-back"].exists
        }, "Back must be inside the page scroll view, not overlaid above it.")
        capture("detail-page-scrolling-back", in: app)
        try focus(showScores, in: app)
        let countLabel = app.staticTexts.matching(NSPredicate(
            format: "label ==[c] %@", "Maximum ratings shown"
        )).firstMatch
        XCTAssertTrue(countLabel.exists, app.debugDescription)
        XCTAssertGreaterThan(countLabel.frame.minY, showScores.frame.maxY)
        XCTAssertLessThanOrEqual(countLabel.frame.minY - showScores.frame.maxY, 40,
                                "Related review-score controls must use the compact shared gap.")
        let countControl = app.buttons["Maximum ratings shown"]
        try focus(countControl, in: app)
        let originalCount = countControl.value as? String
        XCTAssertNotNil(originalCount)
        XCTAssertGreaterThan(countControl.frame.width, 800)
        XCTAssertTrue(countControl.frame.contains(countLabel.frame))
        XCUIRemote.shared.press(originalCount == "10" ? .left : .right)
        XCTAssertNotEqual(countControl.value as? String, originalCount)
        XCTAssertTrue(hasFocus(countControl))
        XCUIRemote.shared.press(originalCount == "10" ? .right : .left)
        XCTAssertEqual(countControl.value as? String, originalCount)
        capture("compact-review-score-controls", in: app)
        let age = app.switches["Show Common Sense age"]
        try focus(age, in: app)
        XCTAssertTrue(scroll.buttons["settings-workspace-back"].exists)
        capture("detail-page-scrolled", in: app)
        try focus(back, in: app)
        capture("detail-page-back-returned", in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["settings-page-title-details"].waitForExistence(timeout: 5))
        #else
        throw XCTSkip("Simulator-only Settings review.")
        #endif
    }

    private func launchSettings(
        style: String = "rail", profile: String = "Alex", kids: String = "off",
        diagnostics: Bool = false, sources: Bool = false
    ) throws -> XCUIApplication {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PLOZZ_SETTINGS_REVIEW"] == "1",
            "Requires the production app installed on a task-owned simulator."
        )
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz")
        app.launchEnvironment["PLOZZ_SHOTS_SETTINGS"] = "1"
        app.launchEnvironment["PLOZZ_SHOTS_SETTINGS_NAVIGATION"] = style
        app.launchEnvironment["PLOZZ_SHOTS_SETTINGS_KIDS"] = kids
        if sources {
            app.launchEnvironment["PLOZZ_SHOTS_SETTINGS_SOURCES"] = try XCTUnwrap(
                ProcessInfo.processInfo.environment["PLOZZ_SETTINGS_SOURCE_ORIGIN"],
                "Source review requires an owned loopback fixture server."
            )
        }
        if diagnostics { app.launchEnvironment["PLZHFOCUS"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let declineDiagnostics = app.buttons.matching(NSPredicate(format: "label == %@", "Don't Share")).firstMatch
        if declineDiagnostics.waitForExistence(timeout: 2) {
            try focus(declineDiagnostics, in: app)
            XCUIRemote.shared.press(.select)
        }
        if app.buttons["Looks good"].waitForExistence(timeout: 2) {
            try focus(app.buttons["Looks good"], in: app)
            XCUIRemote.shared.press(.select)
        }
        try completeAppearanceChoices(in: app)
        let alex = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", profile)).firstMatch
        if alex.waitForExistence(timeout: 2) {
            try focus(alex, in: app)
            XCUIRemote.shared.press(.select)
        }
        try completeAppearanceChoices(in: app)
        let keepPreviewsOff = app.buttons["live-tv-preview-disable"]
        if keepPreviewsOff.waitForExistence(timeout: 2) {
            try focus(keepPreviewsOff, in: app)
            XCUIRemote.shared.press(.select)
        }
        if sources { capture("source-fixture-entry", in: app) }
        try openSettingsIfNeeded(in: app)
        return app
    }

    private func completeAppearanceChoices(in app: XCUIApplication) throws {
        for title in [
            "Choose theme for this profile",
            "Choose navigation for this profile",
            "Choose Home layout for this profile"
        ] {
            if app.staticTexts[title].waitForExistence(timeout: 2) {
                try focus(app.buttons["Continue"], in: app)
                XCUIRemote.shared.press(.select)
            }
        }
    }

    private func openSettingsIfNeeded(in app: XCUIApplication) throws {
        let playback = section("playback", in: app)
        if !playback.waitForExistence(timeout: 3) {
            XCTAssertEqual(app.state, .runningForeground, "Settings navigation requires the actual foreground app.")
            let settings = app.buttons.matching(NSPredicate(
                format: "label IN %@", ["Settings", "Réglages"]
            )).firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
            if !settings.isEnabled {
                XCUIRemote.shared.press(.menu)
                waitForEnabled(settings)
            }
            try focus(settings, in: app, stoppingWhen: { playback.exists })
            if !playback.waitForExistence(timeout: 2) { XCUIRemote.shared.press(.select) }
        }
        XCTAssertTrue(playback.waitForExistence(timeout: 20), app.debugDescription)
        try focus(playback, in: app)
    }

    private func section(_ route: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: "settings-section-\(route)")
            .matching(NSPredicate(format: "enabled == true")).firstMatch
    }

    private func waitForCategoryFocus(_ route: String, in app: XCUIApplication) {
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.hasFocus(self.section(route, in: app)) }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed,
                       "Native focus must return after the page transition. \(app.debugDescription)")
    }

    private func enterAndReturn(_ route: String, in app: XCUIApplication, usingRight: Bool = false) throws {
        let selected = section(route, in: app)
        let other = section(route == "playback" ? "subtitles" : "playback", in: app)
        XCUIRemote.shared.press(usingRight ? .right : .select)
        let arrived = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !selected.exists && !other.exists && app.buttons["settings-category-back"].exists
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: 4), .completed,
                       "Native focus did not enter \(route). \(app.debugDescription)")
        assertCenteredSettingsColumn(in: app)
        capture("editing-\(route)", in: app)
        if route == "appearance" {
            try focus(app.buttons["settings-page-cards"], in: app)
            capture("appearance-options", in: app)
        }
        if usingRight {
            try focus(app.buttons["settings-category-back"], in: app)
            XCUIRemote.shared.press(.select)
        } else {
            XCUIRemote.shared.press(.menu)
        }
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.hasFocus(selected) && selected.isSelected && other.exists && other.isEnabled },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 4), .completed,
                       "Native focus did not return from \(route). \(app.debugDescription)")
        assertCenteredSettingsColumn(in: app)
    }

    private func waitForEnabled(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.exists && element.isEnabled }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

    private func assertInlineSettingsHeader(_ title: String, back: XCUIElement, in app: XCUIApplication) {
        let heading = app.staticTexts[title].firstMatch
        let aligned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                heading.exists && back.exists
                    && back.frame.maxX < heading.frame.minX
                    && abs(back.frame.midY - heading.frame.midY) <= 1
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [aligned], timeout: 5), .completed,
                       "The shared Back button and title must form one horizontal header. \(app.debugDescription)")
    }

    private func assertCenteredSettingsColumn(in app: XCUIApplication) {
        let scroll = app.scrollViews.allElementsBoundByIndex.first { scroll in
            scroll.isEnabled && scroll.buttons.allElementsBoundByIndex.contains {
                $0.isEnabled && ($0.identifier.hasPrefix("settings-section-")
                    || ["settings-category-back", "settings-workspace-back",
                        "live-tv-settings-back", "view-customization-back"].contains($0.identifier))
            }
        }
        guard let scroll else {
            XCTFail("No current Settings column. \(app.debugDescription)")
            return
        }
        XCTAssertEqual(scroll.frame.width, 960, accuracy: 1, "Every ordinary Settings page shares one width.")
        XCTAssertEqual(scroll.frame.midX, app.frame.midX, accuracy: 1, "Settings pages stay centered.")
    }

    private func focus(
        _ target: XCUIElement, in app: XCUIApplication, stoppingWhen: () -> Bool = { false }
    ) throws {
        guard target.waitForExistence(timeout: 5) else {
            XCTFail("Missing focus target. \(app.debugDescription)")
            return
        }
        var requestedNavigation = false
        var lastDirection: XCUIRemote.Button = .left
        for _ in 0..<35 {
            if stoppingWhen() { return }
            if hasFocus(target) { return }
            let nativeFocused = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch
            let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings-section-"))
                .allElementsBoundByIndex.first(where: \.isSelected)
            guard let focused = nativeFocused.exists ? nativeFocused : selected else {
                if !requestedNavigation && target.label == "Settings" {
                    XCUIRemote.shared.press(.menu)
                    requestedNavigation = true
                } else {
                    // Single-label SwiftUI buttons can highlight without exposing AX focus.
                    XCUIRemote.shared.press(lastDirection)
                }
                continue
            }
            let from = focused.frame
            let to = target.frame
            let playback = section("playback", in: app)
            let fullWidthSettings = pageBack("settings-category-back", in: app).exists
                || pageBack(in: app).exists || pageBack("live-tv-settings-back", in: app).exists
                || app.navigationBars["Home rows"].exists
            let sameDetail = fullWidthSettings
                || (playback.exists && from.minX > playback.frame.maxX && to.minX > playback.frame.maxX)
            if sameDetail && to.maxY <= from.minY {
                lastDirection = .up
            } else if sameDetail && to.minY >= from.maxY {
                lastDirection = .down
            } else if to.minX > from.maxX {
                lastDirection = .right
            } else if to.maxX < from.minX {
                lastDirection = .left
            } else if min(to.maxY, from.maxY) > max(to.minY, from.minY),
                      abs(to.midX - from.midX) > abs(to.midY - from.midY) {
                // Native focus scaling can overlap adjacent cards' horizontal frames.
                lastDirection = to.midX > from.midX ? .right : .left
            } else {
                lastDirection = to.midY < from.midY ? .up : .down
            }
            XCUIRemote.shared.press(lastDirection)
        }
        capture("unreachable-focus-\(target.identifier)", in: app)
        XCTFail("Could not focus \(target.identifier) \(target.label). \(app.debugDescription)")
    }

    private func hasFocus(_ target: XCUIElement) -> Bool {
        guard target.exists, target.isEnabled else { return false }
        return target.hasFocus || target.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
    }

    private func pageBack(_ identifier: String = "settings-workspace-back", in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(identifier: identifier)
            .matching(NSPredicate(format: "enabled == true")).firstMatch
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        // Behavior is asserted separately; let the native animation finish for the image.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "settings-native-\(name)"
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "settings-native-\(name)-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
