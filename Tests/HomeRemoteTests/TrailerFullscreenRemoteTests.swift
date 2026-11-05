import XCTest

@MainActor
final class TrailerFullscreenRemoteTests: XCTestCase {
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
        capture(app, name: "Native full-screen trailer controls")
        for _ in 0..<2 where player.exists { XCUIRemote.shared.press(.menu) }
        wait { !player.exists && play.hasFocus }
    }

    private func launch(style: String) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = [
            "--production-home-fixture", style, "--hero-showcase-home",
            "--cached-home-hero", "--home-performance-fixture", "--hero-trailer-controls"
        ]
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
