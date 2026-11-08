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
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "watched")).firstMatch.exists)
        #if os(iOS)
        XCTAssertTrue(app.collectionViews.buttons["Close player"].isHittable,
                      "All native menu actions must fit on screen")
        #endif
        capture(app, "Menu actions")
        activate(app.buttons["Disc videos"], in: app)
        let playlist = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Playlist 00800")).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 10), "Actions must dismiss before the picker opens")
        activate(app.buttons["Close"].firstMatch, in: app)
        #if os(tvOS)
        XCTAssertTrue(app.buttons["disc-menu-select"].waitForExistence(timeout: 5))
        focus(app.buttons["disc-menu-select"], in: app)
        XCUIRemote.shared.press(.menu)
        #else
        app.buttons["disc-menu-control-opticaldisc"].tap()
        #endif
        XCTAssertTrue(app.buttons["Try another region"].waitForExistence(timeout: 5))
        #if os(tvOS)
        activate(app.buttons["Close"].firstMatch, in: app)
        #else
        activate(app.collectionViews.buttons["Close player"], in: app)
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["Try another region"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        #endif
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
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Playlist 00800")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.label.contains("2:00:00 \u{00B7} 18 chapters"),
                      "Duration and chapter count should form one compact metadata line")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "watched")).firstMatch.exists)
        #if os(tvOS)
        let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed)
        for id in ["00800", "00801", "00012"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Playlist \(id)"))
                .firstMatch.isHittable)
        }
        #endif
        capture(app, "Disc videos")
        activate(app.buttons["Close"].firstMatch, in: app)
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Playlist 00800")).firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
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
        let play = app.buttons["detail-hero-play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        capture(app, "Detail hero")
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

    #if os(iOS)
    func testResumePromptStaysBesidePlayButton() {
        let app = launch("detail-resume")
        let orientations: [UIDeviceOrientation] = UIDevice.current.userInterfaceIdiom == .pad
            ? [.portrait, .landscapeLeft] : [.portrait]
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    (app.frame.width > app.frame.height) == orientation.isLandscape
                },
                object: app
            )
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
            let play = app.buttons["detail-hero-play"]
            XCTAssertTrue(play.waitForExistence(timeout: 10))
            if !play.isHittable { app.swipeUp() }
            let playFrame = play.frame
            play.tap()
            let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Resume")).firstMatch
            XCTAssertTrue(resume.waitForExistence(timeout: 5))
            let restart = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Start Over")).firstMatch
            XCTAssertTrue(restart.exists)
            XCTAssertLessThan(abs(resume.frame.midY - playFrame.midY), 320,
                              "Resume choices must remain near the Play button.")
            capture(app, "Resume prompt \(orientation == .portrait ? "portrait" : "landscape")")
            restart.tap()
            XCTAssertTrue(resume.waitForNonExistence(timeout: 5))
        }
    }
    #endif

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
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Disc playback")).firstMatch
        let notice = app.staticTexts.matching(NSPredicate(
            format: "label == %@",
            "HDMV menus only. BD-J plays video.\nVideos played from disc menus don't update watch progress."
        )).firstMatch
        #if os(iOS)
        let contentTop = app.navigationBars.firstMatch.frame.maxY + 24
        let visibleFrame = CGRect(x: app.frame.minX, y: contentTop,
                                  width: app.frame.width, height: app.frame.maxY - contentTop - 24)
        for _ in 0..<20 {
            if picker.exists && picker.isHittable && notice.exists && notice.isHittable
                && visibleFrame.contains(picker.frame.union(notice.frame)) { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(visibleFrame.contains(picker.frame.union(notice.frame)),
                      "The setting and complete note must be visible below the navigation bar")
        #endif
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        #if os(tvOS)
        focus(picker, in: app)
        XCTAssertEqual(picker.value as? String, "Play video")
        XCTAssertFalse(app.segmentedControls.containing(.button, identifier: "Play video").firstMatch.exists)
        #endif
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        capture(app, "Playback setting")
        #if os(tvOS)
        XCUIRemote.shared.press(.select)
        #else
        picker.tap()
        #endif
        let openMenu = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Open disc menu")).firstMatch
        XCTAssertTrue(openMenu.waitForExistence(timeout: 5))
        capture(app, "Playback setting choices")
        #if os(tvOS)
        focus(openMenu, in: app)
        XCUIRemote.shared.press(.select)
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Open disc menu"), object: picker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        focus(picker, in: app)
        XCUIRemote.shared.press(.select)
        focus(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Play video")).firstMatch, in: app)
        XCUIRemote.shared.press(.select)
        XCTAssertEqual(picker.value as? String, "Play video")
        #endif
    }

    private func activate(_ button: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        #if os(tvOS)
        focus(button, in: app)
        XCUIRemote.shared.press(.select)
        #else
        button.tap()
        #endif
    }

    #if os(tvOS)
    private func focus(_ target: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<30 {
            if target.hasFocus || target.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch.exists { return }
            let current = app.descendants(matching: .any)
                .matching(NSPredicate(format: "hasFocus == true")).firstMatch
            if current.exists, current.elementType == .cell, current.frame.contains(target.frame) { return }
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
