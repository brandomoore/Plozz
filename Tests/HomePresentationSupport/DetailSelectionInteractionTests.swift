import XCTest

@MainActor
final class DetailSelectionInteractionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testMovieServerAndVersionReachPlayHandoff() {
        exerciseSelection(series: false)
    }

    func testSeriesServerAndVersionHandOffAnEpisode() {
        exerciseSelection(series: true)
    }

    func testRefreshedAndClearedProgressReachNextPlay() {
        let app = launch(["--selection-single"])
        defer { app.terminate() }
        let play = app.buttons["detail-hero-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20), app.debugDescription)
        handoff(app, expected: "plex|plex-movie|file-large|0")
        backgroundAndReturn(app)
        waitUntil { play.label.contains("15m") }
        handoff(app, expected: "plex|plex-movie|file-large|900")
        backgroundAndReturn(app)
        waitUntil { !play.label.contains("15m") }
        handoff(app, expected: "plex|plex-movie|file-large|0")
    }

    private func exerciseSelection(series: Bool) {
        let app = launch(series ? ["--selection-series"] : [])
        defer { app.terminate() }
        let play = app.buttons["detail-hero-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20), app.debugDescription)
        if series { waitUntil { play.label.contains("E1") } }
        openMore(app)
        select(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Server'")).firstMatch, in: app)
        select(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Fixture Jellyfin'")).firstMatch, in: app)
        openMore(app)
        select(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Version'")).firstMatch, in: app)
        let version = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'version.' AND label CONTAINS '720'"
        )).firstMatch
        select(version, in: app)
        handoff(app, expected: "jellyfin|jellyfin-\(series ? "episode" : "movie")|file-small|0")
    }

    private func launch(_ flags: [String]) -> XCUIApplication {
        #if os(tvOS)
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        #else
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        #endif
        app.launchArguments = ["--detail-selection-fixture"] + flags
        app.launch()
        return app
    }

    private func openMore(_ app: XCUIApplication) {
        #if os(tvOS)
        select(app.buttons["detail-hero-more"], in: app)
        #else
        select(app.buttons["More actions"], in: app)
        #endif
    }

    private func handoff(_ app: XCUIApplication, expected: String) {
        select(app.buttons["detail-hero-play"], in: app)
        #if os(iOS)
        XCTAssertTrue(app.buttons["playback-failure-retry"].waitForExistence(timeout: 20), app.debugDescription)
        select(app.buttons["Close player"], in: app)
        #endif
        let receipt = app.staticTexts["selection-receipt"]
        waitUntil { receipt.exists && receipt.label == expected }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = expected
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func select(_ button: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
        #if os(tvOS)
        for _ in 0..<20 where !button.hasFocus {
            let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard focused.exists else { XCUIRemote.shared.press(.up); continue }
            let dx = button.frame.midX - focused.frame.midX
            let dy = button.frame.midY - focused.frame.midY
            XCUIRemote.shared.press(abs(dy) > 40 ? (dy > 0 ? .down : .up) : (dx > 0 ? .right : .left))
        }
        XCTAssertTrue(button.hasFocus, app.debugDescription)
        XCUIRemote.shared.press(.select)
        #else
        button.tap()
        #endif
    }

    private func backgroundAndReturn(_ app: XCUIApplication) {
        #if os(tvOS)
        XCUIRemote.shared.press(.home)
        #else
        XCUIDevice.shared.press(.home)
        #endif
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        let start = ContinuousClock.now
        waitUntil { start.duration(to: .now) >= .seconds(2) }
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 20), .completed)
    }
}
