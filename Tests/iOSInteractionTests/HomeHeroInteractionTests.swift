import XCTest

@MainActor
final class HomeHeroInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--home-hero-fixture"]
        app.launch()
    }

    override func tearDown() async throws {
        if let testRun, testRun.failureCount > 0 {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.terminate()
        app = nil
        try await super.tearDown()
    }

    func testArtworkTapOpensCurrentItemAndAccountAfterPaging() {
        let artwork = app.buttons["home-hero-artwork-detail"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(artwork.label, "More Info")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "More Info")).count, 1,
                       "Only the artwork link should expose More Info; the mobile action button is removed.")
        XCTAssertEqual(artwork.value as? String, "Hero Movie")
        artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        assertDetail("Details for movie from jellyfin")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(artwork.wait(for: \.isHittable, toEqual: true, timeout: 5))

        let start = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3))
        let end = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        let paged = expectation(for: NSPredicate(format: "value == %@", "Hero Episode"), evaluatedWith: artwork)
        wait(for: [paged], timeout: 5)
        XCTAssertTrue(artwork.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        XCTAssertFalse(app.navigationBars.buttons.firstMatch.exists,
                       "A carousel swipe must not activate the artwork link.")
        artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        assertDetail("Details for series from emby")
    }

    func testOpeningEpisodeShowsSeededDetailWhileItsShowLoads() {
        app.terminate()
        app.launchArguments += ["--hero-native-chrome", "--hero-series-loading"]
        app.launch()
        let artwork = app.buttons["home-hero-artwork-detail"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 15))
        artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        assertLoadingSeriesDetail()
        capture("series-artwork-during-resolution")
        app.buttons["hero-complete-series-lookup"].tap()
        assertDetail("Details for series from emby")
    }

    func testFailedShowLookupStillOffersRetryFromSeededDetail() throws {
        app.terminate()
        app.launchArguments += ["--hero-native-chrome", "--hero-series-loading", "--hero-series-failure"]
        app.launch()
        let artwork = app.buttons["home-hero-artwork-detail"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 15))
        artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        assertLoadingSeriesDetail()
        app.buttons["hero-complete-series-lookup"].tap()
        XCTAssertTrue(app.staticTexts["Unable to load details"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Try Again"].isHittable)
        let count = app.staticTexts["hero-series-lookup-count"]
        let previous = try XCTUnwrap(Int(count.label))
        app.buttons["Try Again"].tap()
        XCTAssertTrue(count.wait(for: \.label, toEqual: String(previous + 1), timeout: 5))
        app.buttons["hero-complete-series-lookup"].tap()
        XCTAssertTrue(app.staticTexts["Unable to load details"].waitForExistence(timeout: 8))
    }

    func testForegroundActionsAndVerticalScrollingRemainIndependent() {
        let artwork = app.buttons["home-hero-artwork-detail"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 15), app.debugDescription)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Play")).firstMatch
        XCTAssertTrue(play.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
        play.tap()
        XCTAssertTrue(app.staticTexts["hero-play-count"].wait(for: \.label, toEqual: "1", timeout: 5))
        XCTAssertTrue(artwork.isHittable)
        app.buttons["Add to Watchlist"].tap()
        XCTAssertTrue(app.staticTexts["hero-watchlist-count"].wait(for: \.label, toEqual: "1", timeout: 5))
        XCTAssertTrue(artwork.isHittable)
        XCTAssertFalse(app.navigationBars.buttons.firstMatch.exists)

        let followingRow = app.staticTexts["hero-following-row"]
        let initialY = followingRow.frame.minY
        let start = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        let end = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(followingRow.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertLessThan(followingRow.frame.minY, initialY - 80)
        XCTAssertFalse(app.navigationBars.buttons.firstMatch.exists)
        XCTAssertEqual(artwork.value as? String, "Hero Movie", "Vertical scrolling must not page the carousel.")
    }

    func testNativeHeroChromePreservesActionsAndTabNavigation() {
        app.terminate()
        app.launchArguments += ["--hero-native-chrome"]
        app.launch()
        let artwork = app.buttons["home-hero-artwork-detail"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 15), app.debugDescription)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Play")).firstMatch
        XCTAssertTrue(play.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
        let profile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Settings for ")).firstMatch
        XCTAssertTrue(profile.wait(for: \.isHittable, toEqual: true, timeout: 5), app.debugDescription)
        capture("native-home-hero")
        for (index, screen) in XCUIScreen.screens.enumerated() {
            let attachment = XCTAttachment(screenshot: screen.screenshot())
            attachment.name = "native-home-hero-screen-\(index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        play.tap()
        XCTAssertTrue(app.staticTexts["hero-play-count"].wait(for: \.label, toEqual: "1", timeout: 5))
        app.buttons["Add to Watchlist"].tap()
        XCTAssertTrue(app.staticTexts["hero-watchlist-count"].wait(for: \.label, toEqual: "1", timeout: 5))
        let search = app.buttons["Search"].firstMatch
        XCTAssertTrue(search.isHittable, app.debugDescription)
        search.tap()
        XCTAssertTrue(app.staticTexts["Search fixture"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Home"].firstMatch.tap()
        XCTAssertTrue(artwork.wait(for: \.isHittable, toEqual: true, timeout: 5))
    }

    func testReturningFromPlayingTrailerKeepsMovieAndResumeAction() {
        app.terminate()
        app.launchArguments += ["--hero-native-chrome", "--hero-logo", "--hero-detail-trailer"]
        app.launch()
        let artwork = app.buttons["home-hero-artwork-detail"]
        let play = app.buttons["home-hero-play"]
        XCTAssertTrue(play.wait(for: \.isHittable, toEqual: true, timeout: 15))
        let originalLabel = play.label
        artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let mute = app.buttons["Unmute trailer"]
        XCTAssertTrue(mute.wait(for: \.isHittable, toEqual: true, timeout: 20), app.debugDescription)
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.004, dy: 0.48))
        let partial = app.coordinate(withNormalizedOffset: CGVector(dx: 0.14, dy: 0.48))
        edge.press(forDuration: 0.1, thenDragTo: partial, withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertTrue(mute.isHittable, "Cancelling must leave the detail trailer playing.")
        let finish = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.48))
        edge.press(forDuration: 0.1, thenDragTo: finish, withVelocity: .slow, thenHoldForDuration: 0.8)
        XCTAssertTrue(play.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertEqual(artwork.value as? String, "Hero Movie")
        XCTAssertEqual(play.label, originalLabel)
        XCTAssertFalse(mute.exists, "The detail-only trailer must not appear on Home.")
    }

    func testCompactHomeActionsScrollAwayAndRemainUsableWithOrWithoutHero() {
        for heroEnabled in [true, false] {
            app.terminate()
            app.launchArguments = [
                "--home-hero-fixture", "--hero-native-chrome", "--hero-header-audio", "--back-interaction"
            ] + (heroEnabled ? [] : ["--hero-disabled"])
            app.launch()
            let profile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Settings for ")).firstMatch
            XCTAssertTrue(profile.wait(for: \.isHittable, toEqual: true, timeout: 15), app.debugDescription)
            XCTAssertFalse(app.navigationBars.buttons.firstMatch.exists,
                           "Profile and mute must be in the scroll view, not pinned in the navigation bar.")
            if heroEnabled {
                XCTAssertEqual(app.buttons["home-hero-artwork-detail"].frame.minY, app.frame.minY, accuracy: 1,
                               "Sharing the native bar must not reserve a row above the hero.")
            }
            let initialFrame = profile.frame
            XCTAssertEqual(initialFrame.width, 44, accuracy: 1)
            XCTAssertEqual(initialFrame.height, 44, accuracy: 1)
            profile.tap()
            XCTAssertTrue(app.staticTexts["hero-settings-count"].wait(for: \.label, toEqual: "1", timeout: 5))
            let unmute = app.buttons["Unmute trailer"]
            XCTAssertTrue(unmute.isHittable, app.debugDescription)
            unmute.tap()
            XCTAssertTrue(app.buttons["Mute trailer"].waitForExistence(timeout: 5), app.debugDescription)
            capture("scrolling-home-actions-hero-\(heroEnabled)-rest")
            let scroll = app.scrollViews.firstMatch
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.65))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertTrue(profile.wait(for: \.isHittable, toEqual: false, timeout: 5),
                          "Profile must scroll away instead of staying pinned above the page.")
            XCTAssertFalse(app.buttons["Mute trailer"].isHittable)
            capture("scrolling-home-actions-hero-\(heroEnabled)-scrolled")
            scroll.swipeDown()
            XCTAssertTrue(profile.wait(for: \.isHittable, toEqual: true, timeout: 5))
            XCTAssertEqual(profile.frame.minY, initialFrame.minY, accuracy: 1)
            profile.tap()
            XCTAssertTrue(app.staticTexts["hero-settings-count"].wait(for: \.label, toEqual: "2", timeout: 5))
        }
    }

    func testTitleAndDescriptionOpenDetailsWithoutStartingPlayback() {
        let artwork = app.buttons["home-hero-artwork-detail"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 15), app.debugDescription)
        for label in ["Hero Movie", "A movie description in the Home hero."] {
            let text = app.staticTexts[label].firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 10), app.debugDescription)
            capture("home-hero-glass")
            text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            assertDetail("Details for movie from jellyfin")
            let play = app.buttons["detail-hero-play"]
            XCTAssertTrue(play.isHittable)
            XCTAssertLessThan(play.frame.width, 130, "Plain movie Play should fit its icon and label.")
            XCTAssertGreaterThanOrEqual(play.frame.height, 44)
            capture("detail-hero-glass")
            let back = app.navigationBars.buttons.firstMatch
            let backFrame = back.frame
            app.scrollViews.firstMatch.swipeUp()
            XCTAssertTrue(back.isHittable)
            XCTAssertEqual(back.frame.minY, backFrame.minY, accuracy: 1)
            XCTAssertEqual(back.frame.minX, backFrame.minX, accuracy: 1)
            back.tap()
            XCTAssertTrue(artwork.wait(for: \.isHittable, toEqual: true, timeout: 5))
        }
    }

    func testLoadedLogoOpensDetails() {
        app.terminate()
        app.launchArguments += ["--hero-logo", "--hero-light"]
        app.launch()
        let artwork = app.buttons["home-hero-artwork-detail"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 15), app.debugDescription)
        let logo = app.images["Hero Movie"].firstMatch
        XCTAssertTrue(logo.waitForExistence(timeout: 10), app.debugDescription)
        capture("home-hero-loaded-logo")
        logo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertDetail("Details for movie from jellyfin")
    }

    func testSeasonsSheetPausesAutoAdvanceAndResumesWithAFreshDwell() {
        app.terminate()
        app.launchArguments += ["--hero-auto-advance"]
        app.launch()
        XCTAssertTrue(app.buttons["Open Seasons"].waitForExistence(timeout: 15))
        app.buttons["Open Seasons"].tap()
        let selection = app.staticTexts["sheet-hero-selection"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        let current = selection.label
        XCTAssertFalse(current.isEmpty)
        XCTAssertFalse(current.contains(","), "Open the sheet before a transition begins.")
        let hiddenAdvance = expectation(
            for: NSPredicate(format: "label != %@", current), evaluatedWith: selection
        )
        hiddenAdvance.isInverted = true
        wait(for: [hiddenAdvance], timeout: 5)
        app.buttons["Close"].tap()
        let artwork = app.buttons["home-hero-artwork-detail"]
        XCTAssertTrue(artwork.wait(for: \.isHittable, toEqual: true, timeout: 5))
        let title = artwork.value as? String ?? ""
        let immediateAdvance = expectation(
            for: NSPredicate(format: "value != %@", title), evaluatedWith: artwork
        )
        immediateAdvance.isInverted = true
        wait(for: [immediateAdvance], timeout: 1)
        let resumedAdvance = expectation(
            for: NSPredicate(format: "value != %@", title), evaluatedWith: artwork
        )
        wait(for: [resumedAdvance], timeout: 6)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertLoadingSeriesDetail() {
        XCTAssertTrue(app.staticTexts["Hero Series"].waitForExistence(timeout: 5))
        let play = app.buttons["detail-hero-play"]
        XCTAssertTrue(play.exists)
        XCTAssertFalse(play.isEnabled, "Unresolved series playback must remain unavailable.")
        XCTAssertFalse(app.staticTexts["Details for series from emby"].exists)
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
    }

    private func assertDetail(_ text: String) {
        let detail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-hero-artwork-detail"].wait(
            for: \.isHittable, toEqual: false, timeout: 5
        ))
        XCTAssertEqual(app.staticTexts["hero-play-count"].label, "0", "Artwork taps must not start playback.")
    }
}
