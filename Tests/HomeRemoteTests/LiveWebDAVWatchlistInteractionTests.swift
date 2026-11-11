import XCTest

@MainActor
final class LiveWebDAVWatchlistInteractionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testLiveWebDAVWatchlistUserJourneys() throws {
        guard ProcessInfo.processInfo.environment["PLOZZ_WEBDAV_JOURNEY_RESTORE_ONLY"] != "1" else {
            throw XCTSkip("The restore-only phase must not change existing saved items.")
        }
        let app = try launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["webdav-watchlist-receipt"].waitForExistence(timeout: 45), app.debugDescription)
        let defaultProfile = app.buttons["profile-picker-com.plozz.profile.default"]
        waitUntil { app.buttons["Journey TV"].exists || defaultProfile.exists }
        if defaultProfile.exists { select(defaultProfile, in: app) }
        waitUntil { app.buttons["Journey TV"].exists }
        capture(app, "Cold WebDAV startup")
        openSeries(in: app)
        XCTAssertTrue(receipt(app).contains("saved=0 "), "Run the full journey on a fresh owned simulator.")
        let watchlist = app.buttons["detail-hero-watchlist"]
        XCTAssertEqual(watchlist.label, "Add to Watchlist")
        select(watchlist, in: app)
        waitUntil { self.receipt(app).contains("saved=1 ") }
        capture(app, "WebDAV series saved")
        XCUIRemote.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        waitUntil { self.receipt(app).contains("saved=1 ") }
        for cycle in 1...3 {
            app.terminate()
            app.launch()
            waitUntil { self.receipt(app).contains("saved=1 ") }
            openNavigation("Watchlist", in: app)
            waitUntil { app.otherElements["watchlist-grid"].buttons["Caminandes"].exists }
            capture(app, "WebDAV Watchlist after cold launch \(cycle)")
        }
        movieAddRemovePlaybackAndColdLaunch(in: app)
        profileSwitchKeepsWatchlistsSeparate(in: app)
        immediateExitAfterSaving(in: app)
    }

    func testPreviouslySavedItemsRestoreAfterDeviceRestart() throws {
        guard ProcessInfo.processInfo.environment["PLOZZ_WEBDAV_JOURNEY_RESTORE_ONLY"] == "1" else {
            throw XCTSkip("Run explicitly after the full journey and an owned simulator reboot.")
        }
        let app = try launch()
        defer { app.terminate() }
        waitUntil { self.receipt(app).contains("saved=2 ") }
        openNavigation("Watchlist", in: app)
        waitUntil {
            let grid = app.otherElements["watchlist-grid"]
            return grid.buttons.count == 2 && grid.buttons["Caminandes"].exists
        }
        capture(app, "Watchlist after simulator reboot")
    }

    private func movieAddRemovePlaybackAndColdLaunch(in app: XCUIApplication) {
        openMovie(in: app)
        let watchlist = app.buttons["detail-hero-watchlist"]
        XCTAssertEqual(watchlist.label, "Add to Watchlist")
        for count in [2, 1, 2] {
            select(watchlist, in: app)
            waitUntil { self.receipt(app).contains("saved=\(count) ") }
        }
        capture(app, "Movie added removed and readded")
        select(app.buttons["detail-hero-play"], in: app)
        let time = app.staticTexts["player-timeline-current-time"]
        XCTAssertTrue(time.waitForExistence(timeout: 30), app.debugDescription)
        let before = time.value as? String
        XCTAssertNotNil(before)
        capture(app, "Real WebDAV playback started")
        waitUntil {
            guard time.exists, let current = time.value as? String, !current.isEmpty else { return false }
            return current != before
        }
        XCUIRemote.shared.press(.playPause)
        capture(app, "Real WebDAV playback progressed and paused")
        for _ in 0..<3 {
            XCUIRemote.shared.press(.menu)
            if app.buttons["detail-hero-play"].isHittable { break }
        }
        app.terminate()
        app.launch()
        waitUntil { self.receipt(app).contains("saved=2 ") }
        openNavigation("Watchlist", in: app)
        waitUntil { app.otherElements["watchlist-grid"].buttons.count == 2 }
        capture(app, "Movie and series restored after playback")
    }

    private func profileSwitchKeepsWatchlistsSeparate(in app: XCUIApplication) {
        waitUntil { self.receipt(app).contains("saved=2 ") }
        XCUIRemote.shared.press(.menu)
        select(app.buttons["Navigation"], in: app)
        select(app.buttons["Journey Other"], in: app)
        waitUntil { self.receipt(app).contains("saved=0 ") }
        XCTAssertFalse(app.buttons["Watchlist"].exists)
        capture(app, "Other profile has its own empty Watchlist")
        openSeries(in: app)
        XCTAssertEqual(app.buttons["detail-hero-watchlist"].label, "Add to Watchlist")
        select(app.buttons["detail-hero-watchlist"], in: app)
        waitUntil { self.receipt(app).contains("saved=1 ") }
        app.terminate()
        app.launch()
        waitUntil { self.receipt(app).contains("saved=1 ") }
        openNavigation("Watchlist", in: app)
        waitUntil { app.buttons["Caminandes"].exists }
        capture(app, "Other profile saved series survives cold launch")
        XCUIRemote.shared.press(.menu)
        select(app.buttons["Navigation"], in: app)
        select(app.buttons["profile-picker-com.plozz.profile.default"], in: app)
        waitUntil { self.receipt(app).contains("saved=2 ") }
        openNavigation("Watchlist", in: app)
        waitUntil { app.otherElements["watchlist-grid"].buttons.count == 2 }
        capture(app, "Original profile retains both saved titles")
    }

    private func immediateExitAfterSaving(in app: XCUIApplication) {
        openMovie(in: app)
        let watchlist = app.buttons["detail-hero-watchlist"]
        XCTAssertEqual(watchlist.label, "Remove from Watchlist")
        select(watchlist, in: app)
        waitUntil { self.receipt(app).contains("saved=1 ") }
        select(watchlist, in: app)
        // Do not wait for the receipt or toast before terminating this process.
        app.terminate()
        app.launch()
        waitUntil { self.receipt(app).contains("saved=2 ") }
        openNavigation("Watchlist", in: app)
        waitUntil { app.otherElements["watchlist-grid"].buttons.count == 2 }
        capture(app, "Immediate exit after save retains both titles")
    }

    private func openSeries(in app: XCUIApplication) {
        openNavigation("Journey TV", in: app)
        openPoster(app.cells.matching(NSPredicate(format: "label == 'Caminandes'")).firstMatch, in: app)
    }

    private func openMovie(in app: XCUIApplication) {
        openNavigation("Journey Movies", in: app)
        openPoster(app.cells.matching(identifier: "native-library-poster-composited").firstMatch, in: app)
    }

    private func openPoster(_ poster: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(poster.waitForExistence(timeout: 30), app.debugDescription)
        for _ in 0..<4 {
            if poster.hasFocus { break }
            XCUIRemote.shared.press(.down)
        }
        XCTAssertTrue(poster.hasFocus, app.debugDescription)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.buttons["detail-hero-watchlist"].waitForExistence(timeout: 30), app.debugDescription)
    }

    private func launch() throws -> XCUIApplication {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This journey requires an owned simulator.")
        #else
        guard let broker = ProcessInfo.processInfo.environment["PLOZZ_WEBDAV_JOURNEY_BROKER"] else {
            throw XCTSkip("Requires an owned simulator and private WebDAV journey broker.")
        }
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--live-webdav-watchlist-fixture"]
        app.launchEnvironment["PLOZZ_WEBDAV_JOURNEY_BROKER"] = broker
        app.launch()
        return app
        #endif
    }

    private func openNavigation(_ title: String, in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["webdav-watchlist-receipt"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 30), app.debugDescription)
        if !app.buttons[title].isEnabled { XCUIRemote.shared.press(.menu) }
        select(app.buttons[title], in: app)
        XCUIRemote.shared.press(.right)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " hierarchy"
        tree.lifetime = .keepAlways
        add(tree)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func select(_ button: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(button.waitForExistence(timeout: 20), app.debugDescription)
        for _ in 0..<20 {
            if button.hasFocus { break }
            let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard focused.exists else { XCUIRemote.shared.press(.down); continue }
            let dx = button.frame.midX - focused.frame.midX
            let dy = button.frame.midY - focused.frame.midY
            XCUIRemote.shared.press(abs(dy) > 40 ? (dy > 0 ? .down : .up) : (dx > 0 ? .right : .left))
        }
        XCTAssertTrue(button.hasFocus, app.debugDescription)
        XCUIRemote.shared.press(.select)
    }

    private func receipt(_ app: XCUIApplication) -> String {
        let label = app.staticTexts["webdav-watchlist-receipt"]
        return label.exists ? label.label : ""
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 30), .completed)
    }
}
