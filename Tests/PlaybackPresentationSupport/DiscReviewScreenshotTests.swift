import XCTest
#if os(iOS)
import UIKit
#endif

@MainActor
final class DiscReviewScreenshotTests: XCTestCase {
    private func launch(_ scenario: String) -> XCUIApplication {
        #if os(tvOS)
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        #else
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        #endif
        app.launchArguments = ["--disc-review-fixture", scenario]
        app.launch()
        addTeardownBlock { @MainActor in app.terminate() }
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        // Wait for native menu/rotation animation, then capture the screen rather
        // than cropping with an application's potentially stale rotated bounds.
        Thread.sleep(forTimeInterval: 0.8)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Disc review - \(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testCaptureDiscNavigationAndActions() {
        let app = launch("menu")
        #if os(tvOS)
        XCTAssertTrue(app.buttons["disc-menu-select"].waitForExistence(timeout: 10))
        capture(app, "Navigation")
        XCUIRemote.shared.press(.menu)
        #else
        XCTAssertTrue(app.buttons["disc-menu-control-circle"].waitForExistence(timeout: 10))
        capture(app, "Navigation")
        app.buttons["disc-menu-control-opticaldisc"].tap()
        #endif
        XCTAssertTrue(app.buttons["Try another region"].waitForExistence(timeout: 5))
        capture(app, "Menu actions")
    }

    func testCaptureMenuFailure() {
        let app = launch("failure")
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 10))
        capture(app, "Menu unavailable")
    }

    func testCaptureMenuLoading() {
        let app = launch("loading")
        XCTAssertTrue(app.activityIndicators.firstMatch.waitForExistence(timeout: 10))
        capture(app, "Loading")
    }

    func testCaptureVideoPicker() {
        let app = launch("videos")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Playlist 00800"))
            .firstMatch.waitForExistence(timeout: 10))
        capture(app, "Disc videos")
    }

    func testCaptureAudioNotice() {
        let app = launch("notice")
        XCTAssertTrue(app.staticTexts["The disc's selected audio track is unavailable."]
            .waitForExistence(timeout: 10))
        capture(app, "Shared audio toast")
    }

    func testCaptureTransportAction() {
        let app = launch("transport")
        let button = app.buttons["player-control-opticaldisc"]
        #if os(tvOS)
        XCUIRemote.shared.press(.playPause)
        #endif
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        capture(app, "Player disc action")
    }

    private func detail(_ scenario: String, _ title: String) {
        let app = launch(scenario)
        let play = app.buttons["disc-review-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        #if os(tvOS)
        focus(play, in: app)
        XCUIRemote.shared.press(.select, forDuration: 1.2)
        #else
        play.press(forDuration: 1.2)
        #endif
        let expected = scenario == "detail-unavailable" ? "This disc's menu format is not supported."
            : scenario == "detail-menu-default" ? "Play video" : "Open disc menu"
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", expected))
            .firstMatch.waitForExistence(timeout: 5))
        capture(app, title)
    }

    func testCaptureDetailMenuAlternative() { detail("detail-video-default", "Play menu - open disc menu") }
    func testCaptureDetailVideoAlternative() { detail("detail-menu-default", "Play menu - play video") }
    func testCaptureUnsupportedMenuExplanation() { detail("detail-unavailable", "Play menu - unsupported Java") }

    func testCapturePlaybackSetting() {
        #if os(tvOS)
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.FocusHost")
        app.launchArguments = ["--read-ahead-settings-fixture", "--playback-settings-workspace"]
        #else
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .phone ? .portrait : .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--playback-settings-fixture", "--share-only-playback"]
        #endif
        app.launch()
        defer { app.terminate() }
        #if os(tvOS)
        let picker = app.segmentedControls.containing(.button, identifier: "Play video").firstMatch
        #else
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Disc playback")).firstMatch
        for _ in 0..<5 {
            if picker.exists && picker.isHittable { break }
            app.swipeUp()
        }
        #endif
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        #if os(tvOS)
        focus(picker, in: app)
        #endif
        capture(app, "Playback setting")
        #if os(iOS)
        picker.tap()
        XCTAssertTrue(app.buttons["Open disc menu"].waitForExistence(timeout: 5))
        capture(app, "Playback setting choices")
        #endif
    }

    #if os(tvOS)
    private func focus(_ target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<30 {
            if target.hasFocus || target.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists { return }
            let current = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch
            let direction: XCUIRemote.Button
            if !current.exists { direction = .down }
            else if target.frame.minX > current.frame.maxX { direction = .right }
            else if target.frame.maxX < current.frame.minX { direction = .left }
            else { direction = target.frame.midY < current.frame.midY ? .up : .down }
            XCUIRemote.shared.press(direction)
        }
        XCTFail("Could not focus \(target.label)")
    }
    #endif
}
