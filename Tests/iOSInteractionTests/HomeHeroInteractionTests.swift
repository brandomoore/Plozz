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

    func testTitleAndDescriptionOpenDetailsWithoutStartingPlayback() {
        let artwork = app.buttons["home-hero-artwork-detail"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 15), app.debugDescription)
        for label in ["Hero Movie", "A movie description in the Home hero."] {
            let text = app.staticTexts[label].firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 10), app.debugDescription)
            capture("home-hero-glass")
            text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            assertDetail("Details for movie from jellyfin")
            capture("detail-hero-glass")
            app.navigationBars.buttons.firstMatch.tap()
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
