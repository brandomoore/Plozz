import XCTest

@MainActor
final class PlaybackFailureInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        #if os(tvOS)
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        #else
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        #endif
    }

    override func tearDown() {
        if let testRun, testRun.failureCount > 0 {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.lifetime = .keepAlways
            add(tree)
            capture("failure")
        }
        app.terminate()
        app = nil
        super.tearDown()
    }

    func testDetailsAreOptionalAndReturnToRetryAndBack() {
        launch(["--failure-light"])
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'http_status'")).firstMatch.exists)
        capture("summary")
        activate(app.buttons["playback-failure-details"])
        let report = app.descendants(matching: .any).matching(identifier: "playback-diagnostic-report").firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(report.label.contains("http_status=410"), report.label)
        XCTAssertTrue(report.label.contains("engine_failure=sourceRefused"))
        XCTAssertFalse(report.label.contains("expired"))
        capture("details")
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        #else
        activate(app.buttons["playback-diagnostics-close"])
        #endif
        XCTAssertTrue(app.buttons["playback-failure-details"].waitForExistence(timeout: 5))
        activate(app.buttons["playback-failure-retry"])
        XCTAssertTrue(app.staticTexts["Retried"].waitForExistence(timeout: 5))
        activate(app.buttons["player-failed-back"])
        XCTAssertTrue(app.staticTexts["failure-fixture-closed"].waitForExistence(timeout: 5))
    }

    func testLongCopyKeepsOnlyDetailsRetryAndBack() {
        launch(["--failure-long", "--failure-reduced"])
        let message = app.staticTexts["playback-failure-message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(message.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(message.frame.minX, app.frame.minX)
        XCTAssertEqual(app.buttons.count, 3, app.debugDescription)
        XCTAssertFalse(app.buttons["Playback options"].exists)
        XCTAssertFalse(app.buttons["player-failed-streaming-quality"].exists)
        capture("long-summary")
        activate(app.buttons["playback-failure-retry"])
        XCTAssertTrue(app.staticTexts["Retried"].waitForExistence(timeout: 5))
        activate(app.buttons["player-failed-back"])
        XCTAssertTrue(app.staticTexts["failure-fixture-closed"].waitForExistence(timeout: 5))
    }

    func testLiveFailureUsesTheSameDetailsAndNativeActions() {
        launch(["--failure-live", "--failure-reduced"])
        capture("live")
        activate(app.buttons["playback-failure-details"])
        let report = app.descendants(matching: .any).matching(identifier: "playback-diagnostic-report").firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        XCTAssertTrue(report.label.contains("failure=startupTimedOut"))
        capture("live-details")
    }

    #if os(iOS)
    func testLargeTextAndRightToLeftLayoutCanScrollToDetailsAndBack() {
        launch(["--failure-long", "--failure-large", "--failure-rtl"])
        capture("accessibility-rtl-top")
        activate(app.buttons["playback-failure-details"])
        XCTAssertTrue(app.staticTexts["playback-diagnostic-report"].waitForExistence(timeout: 5))
        activate(app.buttons["playback-diagnostics-close"])
        activate(app.buttons["player-failed-back"])
        XCTAssertTrue(app.staticTexts["failure-fixture-closed"].waitForExistence(timeout: 5))
    }

    func testLandscapeActionsRemainReachable() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        launch(["--failure-long"])
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { [self] _, _ in
            MainActor.assumeIsolated {
                let frame = app.windows.firstMatch.frame
                return frame.width > frame.height
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: landscape, object: nil)
        ], timeout: 10), .completed, app.debugDescription)
        let message = app.staticTexts["playback-failure-message"]
        XCTAssertGreaterThanOrEqual(message.frame.minX, app.windows.firstMatch.frame.minX)
        XCTAssertLessThanOrEqual(message.frame.maxX, app.windows.firstMatch.frame.maxX)
        activate(app.buttons["playback-failure-retry"])
        XCTAssertTrue(app.staticTexts["Retried"].waitForExistence(timeout: 5))
        capture("landscape")
        activate(app.buttons["player-failed-back"])
        XCTAssertTrue(app.staticTexts["failure-fixture-closed"].waitForExistence(timeout: 5))
    }
    #endif

    private func launch(_ arguments: [String]) {
        app.launchArguments = ["--playback-failure-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["playback-failure-details"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func activate(_ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: 5), app.debugDescription)
        #if os(tvOS)
        for _ in 0..<12 {
            if hasFocus(target) { break }
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            let dx = target.frame.midX - focused.frame.midX
            let dy = target.frame.midY - focused.frame.midY
            XCUIRemote.shared.press(abs(dy) > abs(dx) ? (dy > 0 ? .down : .up) : (dx > 0 ? .right : .left))
        }
        XCTAssertTrue(hasFocus(target), app.debugDescription)
        XCUIRemote.shared.press(.select)
        #else
        for _ in 0..<8 {
            if target.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(target.isHittable, app.debugDescription)
        target.tap()
        #endif
    }

    #if os(tvOS)
    private func hasFocus(_ target: XCUIElement) -> Bool {
        target.hasFocus || target.descendants(matching: .any)
            .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists
    }
    #endif

    private func capture(_ name: String) {
        #if os(iOS)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        #else
        let image = XCTAttachment(screenshot: app.screenshot())
        #endif
        image.name = "playback-failure-\(name)"
        image.lifetime = .keepAlways
        add(image)
    }
}
