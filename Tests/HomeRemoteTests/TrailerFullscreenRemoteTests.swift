import XCTest

@MainActor
final class TrailerFullscreenRemoteTests: XCTestCase {
    func testFailedTrailerUsesArtworkDwellInsteadOfTrailerDuration() {
        continueAfterFailure = false
        let app = launch(style: "--pinned-home", extraArguments: ["--hero-trailer-failure"])
        defer { app.terminate() }
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 30))
        let initialLabel = hero.label
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                hero.exists && hero.label != initialLabel
            }, object: nil)
        ], timeout: 20), .completed, "An unplayable 140-second trailer must not hold its artwork for 140 seconds.")
    }

    func testUpOpensPinnedHomeTrailerAndBackRestoresHeroFocus() {
        checkHome(style: "--pinned-home", opensPlayer: true)
    }

    func testUpKeepsTopBarNavigationInsteadOfOpeningHomeTrailer() {
        checkHome(style: "--top-bar-home", opensPlayer: false)
    }

    func testUpKeepsNativeSidebarNavigationInsteadOfOpeningHomeTrailer() {
        checkHome(style: "--native-sidebar-home", opensPlayer: false)
    }

    private func checkHome(style: String, opensPlayer: Bool) {
        continueAfterFailure = false
        let app = launch(style: style)
        defer { app.terminate() }
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 30))
        if !hero.hasFocus { XCUIRemote.shared.press(style == "--top-bar-home" ? .down : .right) }
        wait { hero.hasFocus }
        wait { app.staticTexts["hero-trailer-state"].label == "playing" }
        let originalLabel = hero.label
        XCUIRemote.shared.press(.up)
        let player = app.otherElements["trailer-fullscreen-player"]
        if opensPlayer {
            for round in 0..<3 {
                if round > 0 { XCUIRemote.shared.press(.up) }
                XCTAssertTrue(player.waitForExistence(timeout: 8), app.debugDescription)
                XCUIRemote.shared.press(.playPause)
                XCUIRemote.shared.press(.right)
                XCUIRemote.shared.press(.left)
                for _ in 0..<2 where player.exists { XCUIRemote.shared.press(.menu) }
                wait { !player.exists && hero.hasFocus }
                XCTAssertEqual(hero.label, originalLabel)
            }
        } else {
            if style == "--native-sidebar-home", hero.hasFocus {
                XCUIRemote.shared.press(.left)
            }
            wait { !hero.hasFocus }
            XCTAssertFalse(player.exists)
        }
    }

    func testDetailUpOpensTrailerAndShowsTheDelayedHint() {
        continueAfterFailure = false
        let app = launch(style: "--top-bar-home")
        defer { app.terminate() }
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 30))
        if !hero.hasFocus { XCUIRemote.shared.press(.down) }
        wait { hero.hasFocus }
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        let play = app.buttons["detail-hero-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), app.debugDescription)
        wait { play.hasFocus }
        XCTAssertTrue(app.staticTexts["Up for playback controls"].waitForExistence(timeout: 12))
        capture(app, name: "Detail trailer playback hint")
        XCUIRemote.shared.press(.up)
        let player = app.otherElements["trailer-fullscreen-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 8), app.debugDescription)
        capture(app, name: "Plozz full-screen trailer controls")
        for _ in 0..<2 where player.exists { XCUIRemote.shared.press(.menu) }
        wait { !player.exists && play.hasFocus }
    }

    func testTrailerButtonReusesTheActiveTrailerPlayer() {
        checkTrailerButton(ambient: true)
    }

    func testTrailerButtonKeepsItsRegularRouteWithoutAmbientPlayback() {
        checkTrailerButton(ambient: false)
    }

    private func checkTrailerButton(ambient: Bool) {
        continueAfterFailure = false
        let app = launch(style: "--top-bar-home", extraArguments:
            ["--continue-watching-action-probe"] + (ambient ? [] : ["--ambient-trailers-off"])
        )
        defer { app.terminate() }
        let hero = app.buttons["home-hero-action-row"]
        XCTAssertTrue(hero.waitForExistence(timeout: 30))
        if !hero.hasFocus { XCUIRemote.shared.press(.down) }
        wait { hero.hasFocus }
        if ambient { wait { app.staticTexts["hero-trailer-state"].label == "playing" } }
        XCUIRemote.shared.press(.right)
        XCUIRemote.shared.press(.select)
        let play = app.buttons["detail-hero-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        wait { play.hasFocus }
        let trailer = app.buttons["detail-hero-trailer"]
        XCTAssertTrue(trailer.waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.right)
        wait { trailer.hasFocus }
        XCUIRemote.shared.press(.select)
        let player = app.otherElements["trailer-fullscreen-player"]
        if ambient {
            XCTAssertTrue(player.waitForExistence(timeout: 8), app.debugDescription)
            for _ in 0..<2 where player.exists { XCUIRemote.shared.press(.menu) }
            XCTAssertEqual(XCTWaiter.wait(for: [
                XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !player.exists && trailer.hasFocus
                }, object: nil)
            ], timeout: 10), .completed, app.debugDescription)
            XCTAssertTrue(app.staticTexts["home-playback-probe"].label.hasPrefix("0:"))
        } else {
            wait { app.staticTexts["home-playback-probe"].label.hasPrefix("1:trailer-") }
            XCTAssertFalse(player.exists)
        }
    }

    private func launch(style: String, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", style, "--hero-showcase-home",
            "--cached-home-hero", "--home-performance-fixture", "--hero-trailer-controls"
        ] + extraArguments
        app.launch()
        return app
    }

    private func wait(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(XCTWaiter.wait(for: [
            XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        ], timeout: 10), .completed, file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
