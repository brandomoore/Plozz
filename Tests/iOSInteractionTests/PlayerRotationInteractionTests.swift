import XCTest

@MainActor
final class PlayerRotationInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
    }

    override func tearDown() {
        if let testRun, testRun.failureCount > 0 {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app = nil
        super.tearDown()
    }

    func testAutoRotatesExistingPlayerWithoutPlayerOrientationControls() {
        launch("--auto")
        openPlayer()
        assertNoPlayerOrientationControls()
        rotate(.landscapeLeft)
        rotate(.landscapeRight)
        rotate(.portrait)
        XCTAssertEqual(app.staticTexts["rotation-load-count"].label, "Loads 1")
        closePlayer()
        XCTAssertEqual(app.staticTexts["saved-orientation"].label, "auto")
        openPlayer()
        rotate(.landscapeLeft)
        XCTAssertEqual(app.staticTexts["rotation-load-count"].label, "Loads 2")
    }

    func testLandscapeDefaultAllowsBothSidesAndPersistsOnReopen() {
        launch()
        openPlayer()
        if UIDevice.current.userInterfaceIdiom == .pad {
            assertOrientation(landscape: false)
            rotate(.landscapeLeft)
            rotate(.landscapeRight)
            rotate(.portrait)
            assertNoPlayerOrientationControls()
            closePlayer()
            XCTAssertEqual(app.staticTexts["saved-orientation"].label, "landscape")
            return
        }
        assertOrientation(landscape: true)
        assertNoPlayerOrientationControls()
        rotate(.landscapeLeft)
        rotate(.landscapeRight)
        XCUIDevice.shared.orientation = .portrait
        assertStaysLandscape(true)
        XCTAssertEqual(app.staticTexts["rotation-load-count"].label, "Loads 1")
        closePlayer()
        XCTAssertEqual(app.staticTexts["saved-orientation"].label, "landscape")
        assertOrientation(landscape: false, player: false)
        openPlayer()
        assertOrientation(landscape: true)
        XCTAssertEqual(app.staticTexts["rotation-load-count"].label, "Loads 2")
    }

    func testPortraitPreferenceDoesNotLockBrowsingAfterDismissal() {
        launch("--portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertOrientation(landscape: true, player: false)
        openPlayer()
        if UIDevice.current.userInterfaceIdiom == .pad {
            assertOrientation(landscape: true)
            rotate(.portrait)
            rotate(.landscapeRight)
            assertNoPlayerOrientationControls()
            closePlayer()
            XCTAssertEqual(app.staticTexts["saved-orientation"].label, "portrait")
            return
        }
        assertOrientation(landscape: false)
        assertNoPlayerOrientationControls()
        XCUIDevice.shared.orientation = .landscapeRight
        assertStaysLandscape(false)
        closePlayer()
        XCUIDevice.shared.orientation = .portrait
        rotate(.landscapeLeft, player: false)
        XCTAssertEqual(app.staticTexts["saved-orientation"].label, "portrait")
    }

    func testPlayerXClosesFromNestedNavigationAndReopens() {
        launch("--nested-player-presentation")
        openPlayer()
        closePlayer()
        openPlayer()
        closePlayer()
    }

    func testFailedPlayerBackClosesFromNestedNavigationAndReopens() {
        launch("--failed-player-fixture", "--nested-player-presentation", "--portrait")
        for _ in 0..<2 {
            app.buttons["Open rotation player"].tap()
            let back = app.buttons["player-failed-back"]
            XCTAssertTrue(back.waitForExistence(timeout: 15), app.debugDescription)
            if !back.isHittable { app.swipeUp() }
            back.tap()
            XCTAssertTrue(app.buttons["Open rotation player"].wait(
                for: \.isHittable, toEqual: true, timeout: 10
            ), app.debugDescription)
            XCTAssertFalse(back.exists)
        }
    }

    func testPlayerXClosesWithEmbyStreamingQualityAndAutomaticRotation() {
        launch("--emby-streaming-fixture", "--auto")
        openPlayer()
        rotate(.landscapeLeft)
        rotate(.portrait)
        closePlayer()
        openPlayer()
        closePlayer()
    }

    func testFailedConversionExplainsForceTranscodingOnlyWhenEnabled() {
        for enabled in [false, true] {
            app.launchArguments = [
                "--rotation-player-fixture", "--failed-conversion-fixture", "--portrait",
                "--large-player-text", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
            ] + (enabled ? ["--force-transcoding"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["Open rotation player"].waitForExistence(timeout: 10))
            app.buttons["Open rotation player"].tap()
            let message = app.staticTexts["playback-failure-message"]
            XCTAssertTrue(message.waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertEqual(message.label, "The server didn’t offer a converted stream for these settings.")
            let hint = app.staticTexts["playback-failure-hint"]
            if enabled {
                XCTAssertTrue(hint.waitForExistence(timeout: 5), app.debugDescription)
                XCTAssertEqual(hint.label, "Force transcoding is on. Try turning it off in Streaming quality.")
                XCTAssertGreaterThanOrEqual(hint.frame.minX, app.windows.firstMatch.frame.minX)
                XCTAssertLessThanOrEqual(hint.frame.maxX, app.windows.firstMatch.frame.maxX)
                let image = XCTAttachment(screenshot: app.screenshot())
                image.name = "forced-transcoding-failure"
                image.lifetime = .keepAlways
                add(image)
            } else {
                XCTAssertFalse(hint.exists)
            }
            let back = app.buttons["player-failed-back"]
            for _ in 0..<6 {
                if back.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(back.isHittable, app.debugDescription)
            back.tap()
            XCTAssertTrue(app.buttons["Open rotation player"].waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    func testEmbyQualitySheetDoesNotReplacePlayerAndXStillCloses() {
        launch("--emby-streaming-fixture")
        openPlayer()
        revealControls()
        app.buttons["Playback options"].tap()
        XCTAssertTrue(app.buttons["Quality"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Quality"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["rotation-load-count"].label, "Loads 1",
                       "Opening and cancelling quality must not recreate the player.")
        revealControls()
        app.buttons["Playback options"].tap()
        XCTAssertTrue(app.buttons["Quality"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Quality"].tap()
        XCTAssertTrue(app.buttons["Advanced"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Advanced"].tap()
        app.switches["Force transcoding"].switches.firstMatch.tap()
        XCTAssertEqual(app.switches["Force transcoding"].value as? String, "1", app.debugDescription)
        app.buttons["Apply"].tap()
        XCTAssertTrue(app.buttons["Apply"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(app.staticTexts["rotation-load-count"].wait(
            for: \.label, toEqual: "Loads 2", timeout: 10
        ), "Changing quality must reload exactly once without reopening the player: \(app.staticTexts["rotation-load-count"].label)")
        closePlayer()
    }

    private func launch(_ arguments: String...) {
        app.launchArguments = ["--rotation-player-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["Open rotation player"].waitForExistence(timeout: 10))
    }

    private func openPlayer() {
        app.buttons["Open rotation player"].tap()
        XCTAssertTrue(app.otherElements["rotation-video-surface"].firstMatch.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 25), app.debugDescription)
    }

    private func revealControls() {
        if !app.buttons["Playback options"].isHittable {
            app.otherElements["rotation-video-surface"].firstMatch.tap()
        }
    }

    private func assertNoPlayerOrientationControls() {
        revealControls()
        app.buttons["Playback options"].tap()
        XCTAssertTrue(app.buttons["Playback Speed"].waitForExistence(timeout: 5), app.debugDescription)
        for title in ["Lock rotation", "Unlock rotation", "Orientation", "Player orientation"] {
            XCTAssertFalse(app.buttons[title].exists, app.debugDescription)
        }
        app.otherElements["rotation-video-surface"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Playback Speed"].waitForNonExistence(timeout: 5))
    }

    private func closePlayer() {
        revealControls()
        app.buttons["Close player"].tap()
        XCTAssertTrue(app.buttons["Open rotation player"].wait(
            for: \.isHittable, toEqual: true, timeout: 10
        ), app.debugDescription)
    }

    private func rotate(_ orientation: UIDeviceOrientation, player: Bool = true) {
        XCUIDevice.shared.orientation = orientation
        assertOrientation(landscape: orientation.isLandscape, player: player)
        if player {
            let expected: String
            switch orientation {
            case .landscapeLeft: expected = String(UIInterfaceOrientation.landscapeRight.rawValue)
            case .landscapeRight: expected = String(UIInterfaceOrientation.landscapeLeft.rawValue)
            default: expected = String(UIInterfaceOrientation.portrait.rawValue)
            }
            XCTAssertTrue(app.staticTexts["rotation-interface-orientation"].wait(
                for: \.label, toEqual: expected, timeout: 10
            ))
        }
    }

    private func assertOrientation(landscape: Bool, player: Bool = true) {
        let predicate = NSPredicate { [self] _, _ in
            MainActor.assumeIsolated {
                let window = app.windows.firstMatch.frame
                guard (window.width > window.height) == landscape else { return false }
                guard player else { return true }
                let surface = app.otherElements["rotation-video-surface"].firstMatch.frame
                return (surface.width > surface.height) == landscape
                    && surface.width > window.width * 0.85 && surface.height > window.height * 0.85
            }
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10),
            .completed, app.debugDescription
        )
    }

    private func assertStaysLandscape(_ landscape: Bool) {
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            MainActor.assumeIsolated {
                let frame = app.windows.firstMatch.frame
                return (frame.width > frame.height) != landscape
            }
        }, object: nil)
        rotated.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 2), .completed)
    }
}
