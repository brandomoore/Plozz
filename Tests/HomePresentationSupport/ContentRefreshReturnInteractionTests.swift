import XCTest

@MainActor
final class ContentRefreshReturnInteractionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testMovieProgressUpdatesAfterRealBackgroundReturn() throws {
        try exercise(series: false)
    }

    func testSeriesPlayTargetAdvancesAfterRealBackgroundReturn() throws {
        try exercise(series: true)
    }

    func testMovieProgressUpdatesAfterNavigationReturn() throws {
        try exercise(series: false, navigation: true)
    }

    func testSeriesPlayTargetAdvancesAfterNavigationReturn() throws {
        try exercise(series: true, navigation: true)
    }

    private func exercise(series: Bool, navigation: Bool = false) throws {
        #if os(tvOS)
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        #else
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        #endif
        app.launchArguments = ["--content-refresh-return-fixture"]
        if series { app.launchArguments.append("--refresh-series") }
        app.launch()
        defer { app.terminate() }
        let play = playButton(in: app)
        XCTAssertTrue(play.waitForExistence(timeout: 20), app.debugDescription)
        if series { waitUntil { play.label.contains("E1") } }
        let before = play.label
        capture(app, name: "refresh-before-\(series ? "series" : "movie")")
        if navigation {
            #if os(tvOS)
            select(play)
            #else
            select(app.buttons["refresh-cover"])
            #endif
            XCTAssertTrue(app.buttons["refresh-return"].waitForExistence(timeout: 10))
            awaitReturnDelay()
            select(app.buttons["refresh-return"])
        } else {
            #if os(tvOS)
            XCUIRemote.shared.press(.home)
            #else
            XCUIDevice.shared.press(.home)
            #endif
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
            // The fixture uses a one-second threshold, not a synthetic notification.
            awaitReturnDelay()
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        }
        waitUntil {
            play.exists && play.label != before
                && play.label.contains(series ? "E2" : "15m")
        }
        XCTAssertTrue(app.staticTexts["Refresh verification"].exists)
        capture(app, name: "refresh-after-\(series ? "series" : "movie")")
    }

    private func playButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["detail-hero-play"]
    }

    private func select(_ button: XCUIElement) {
        #if os(tvOS)
        for _ in 0..<5 where !button.hasFocus { XCUIRemote.shared.press(.up) }
        for _ in 0..<5 where !button.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(button.hasFocus)
        XCUIRemote.shared.press(.select)
        #else
        button.tap()
        #endif
    }

    private func awaitReturnDelay() {
        let start = ContinuousClock.now
        let delay = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in start.duration(to: .now) >= .seconds(2) },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [delay], timeout: 5), .completed)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
