import UIKit
import XCTest

@MainActor
final class PlayerGestureInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--rotation-player-fixture", "--gesture-player-fixture", "--auto"]
        app.launch()
        XCTAssertTrue(app.buttons["Open rotation player"].waitForExistence(timeout: 10))
        app.buttons["Open rotation player"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 25), app.debugDescription)
    }

    override func tearDown() {
        if testRun?.failureCount ?? 0 > 0 { capture("gesture-failure") }
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app = nil
        super.tearDown()
    }

    func testRapidTapsUseConfiguredIntervalsAndLeaveOnlyProgressVisible() {
        let timeline = app.otherElements["player-timeline"]
        let scrubBar = app.otherElements["player-timeline-scrubber"]
        XCTAssertTrue(timeline.exists, app.debugDescription)
        XCTAssertTrue(scrubBar.exists, app.debugDescription)
        let originalFrame = scrubBar.frame
        let forward = point(x: 0.8, y: 0.43)
        forward.doubleTap()
        let feedback = app.staticTexts["player-gesture-skip-total"]
        XCTAssertTrue(feedback.exists, app.debugDescription)
        XCTAssertEqual(feedback.label, "+5", "One double-tap starts feedback immediately.")
        for _ in 0..<3 { forward.tap() }
        XCTAssertTrue(feedback.exists, app.debugDescription)
        XCTAssertEqual(feedback.label, "+20", "The configured forward interval is five seconds.")
        XCTAssertFalse(app.buttons["Pause"].exists, "The main controls must hide during skip feedback.")
        XCTAssertTrue(timeline.exists, app.debugDescription)
        XCTAssertEqual(app.otherElements.matching(identifier: "player-timeline-scrubber").count, 1)
        XCTAssertEqual(scrubBar.frame.minX, originalFrame.minX, accuracy: 1)
        XCTAssertEqual(scrubBar.frame.minY, originalFrame.minY, accuracy: 1)
        XCTAssertEqual(scrubBar.frame.width, originalFrame.width, accuracy: 1)
        XCTAssertEqual(scrubBar.frame.height, 44, accuracy: 1)
        XCTAssertTrue(app.buttons["player-timeline-current-time"].exists)
        XCTAssertTrue(app.buttons["player-timeline-end-time"].exists)
        XCTAssertFalse(app.buttons["Playback options"].isHittable, app.debugDescription)
        XCTAssertFalse(app.buttons["Subtitles"].isHittable, app.debugDescription)
        capture("forward-cumulative")
        let backward = point(x: 0.2, y: 0.43)
        backward.doubleTap()
        backward.tap()
        XCTAssertTrue(feedback.exists, app.debugDescription)
        XCTAssertTrue(feedback.label.hasPrefix("-"), app.debugDescription)
        XCTAssertFalse(app.buttons["Pause"].exists)
        capture("backward-cumulative")
        scrubBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3),
                      "The retained timeline must still perform its real scrubbing action.")
    }

    func testSingleTapRevealsControlsAndNativeButtonsDoNotBecomeShortcuts() {
        let currentTime = app.buttons["player-timeline-current-time"]
        XCTAssertEqual(currentTime.label, "Elapsed time")
        currentTime.tap()
        XCTAssertEqual(currentTime.label, "Current time")
        XCTAssertFalse(app.staticTexts["player-gesture-skip-total"].exists)
        currentTime.tap()
        XCTAssertEqual(currentTime.label, "Elapsed time")
        point(x: 0.5, y: 0.28).tap()
        XCTAssertTrue(app.buttons["Pause"].waitForNonExistence(timeout: 3))
        point(x: 0.5, y: 0.28).tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["player-gesture-skip-total"].exists)
        app.buttons["Play"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        app.buttons["Playback options"].tap()
        XCTAssertTrue(app.buttons["Playback Speed"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["player-gesture-skip-total"].exists)
    }

    func testHoldAcceleratesAndReleaseRestoresRateWithoutLeavingControlsOpen() {
        XCTAssertTrue(app.staticTexts["gesture-rate"].wait(for: \.label, toEqual: "1.0", timeout: 5),
                      "Verify the actual renderer is playing at 1× before holding. \(app.debugDescription)")
        XCTAssertEqual(app.staticTexts["gesture-maximum-rate"].label, "1.0")
        point(x: 0.5, y: 0.28).press(forDuration: 0.85)
        XCTAssertEqual(app.staticTexts["gesture-maximum-rate"].label, "1.0",
                       "Releasing before one second must not activate the speed boost.")
        XCTAssertFalse(app.staticTexts["player-gesture-speed"].exists)
        point(x: 0.5, y: 0.28).press(forDuration: 1.4)
        XCTAssertTrue(app.staticTexts["gesture-maximum-rate"].wait(for: \.label, toEqual: "2.0", timeout: 3),
                      app.debugDescription)
        XCTAssertTrue(app.staticTexts["gesture-rate"].wait(for: \.label, toEqual: "1.0", timeout: 3),
                      app.debugDescription)
        XCTAssertFalse(app.staticTexts["player-gesture-speed"].exists)
        XCTAssertFalse(app.buttons["Pause"].exists)
        point(x: 0.5, y: 0.28).tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
    }

    func testPinchFillsThenFitsSafeAreaWithoutReloadingVideo() {
        let surface = app.otherElements["gesture-pinch-area"].firstMatch
        XCTAssertTrue(app.staticTexts["gesture-video-fit"].wait(for: \.label, toEqual: "safe", timeout: 5))
        point(x: 0.5, y: 0.28).tap()
        XCTAssertTrue(app.buttons["Pause"].waitForNonExistence(timeout: 3))
        surface.pinch(withScale: 1.6, velocity: 1)
        XCTAssertTrue(app.staticTexts["gesture-video-fit"].wait(for: \.label, toEqual: "cropped", timeout: 5),
                      app.debugDescription)
        capture("edge-to-edge-fill")
        surface.pinch(withScale: 0.6, velocity: -1)
        XCTAssertTrue(app.staticTexts["gesture-video-fit"].wait(for: \.label, toEqual: "safe", timeout: 5),
                      app.debugDescription)
        XCTAssertEqual(app.staticTexts["rotation-load-count"].label, "Loads 1")
        capture("safe-area-fit")
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.staticTexts["gesture-video-fit"].wait(for: \.label, toEqual: "safe", timeout: 5))
    }

    func testVerticalBrightnessSwipeShowsLevelWithoutSeekingOrRevealingTimeline() throws {
        let brightness = app.staticTexts["gesture-screen-brightness"]
        let initial = try XCTUnwrap(Double(brightness.label))
        point(x: 0.18, y: 0.42).press(
            forDuration: 0.05, thenDragTo: point(x: 0.18, y: initial > 0.4 ? 0.65 : 0.22)
        )
        XCTAssertTrue(app.otherElements["player-gesture-level-pill"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["player-gesture-level-unavailable"].exists)
        try assertLevel(initial + (initial > 0.4 ? -0.23 : 0.20))
        #if !targetEnvironment(simulator)
        let changed = NSPredicate { _, _ in
            guard let value = Double(brightness.label) else { return false }
            return abs(value - initial) > 0.1
        }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: changed, evaluatedWith: brightness)], timeout: 3), .completed)
        #endif
        XCTAssertFalse(app.otherElements["player-timeline"].exists)
        XCTAssertFalse(app.staticTexts["player-gesture-skip-total"].exists)
        XCTAssertEqual(app.staticTexts["rotation-load-count"].label, "Loads 1")
        capture("brightness-swipe")
    }

    func testVerticalVolumeSwipeUsesSystemOutputOrReportsUnavailable() throws {
        let volume = app.staticTexts["gesture-system-volume"]
        let initial = try XCTUnwrap(Double(volume.label))
        point(x: 0.82, y: 0.42).press(
            forDuration: 0.05, thenDragTo: point(x: 0.82, y: initial > 0.4 ? 0.65 : 0.22)
        )
        XCTAssertTrue(app.otherElements["player-gesture-level-pill"].exists, app.debugDescription)
        if app.staticTexts["player-gesture-level-unavailable"].exists {
            XCTAssertFalse(levelMeter.exists)
            XCTAssertEqual(Double(volume.label), initial)
        } else {
            try assertLevel(initial + (initial > 0.4 ? -0.23 : 0.20))
            #if !targetEnvironment(simulator)
            let changed = NSPredicate { _, _ in
                guard let value = Double(volume.label) else { return false }
                return abs(value - initial) > 0.1
            }
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: changed, evaluatedWith: volume)], timeout: 3), .completed)
            #endif
        }
        XCTAssertFalse(app.staticTexts["player-gesture-skip-total"].exists)
        XCTAssertFalse(app.otherElements["player-timeline"].exists)
        capture("system-volume-swipe")
    }

    func testCenterAndHorizontalSwipesDoNotChangeLevels() throws {
        let brightness = try XCTUnwrap(Double(app.staticTexts["gesture-screen-brightness"].label))
        let volume = try XCTUnwrap(Double(app.staticTexts["gesture-system-volume"].label))
        point(x: 0.5, y: 0.28).press(forDuration: 0.05, thenDragTo: point(x: 0.5, y: 0.48))
        point(x: 0.18, y: 0.28).press(forDuration: 0.05, thenDragTo: point(x: 0.38, y: 0.28))
        XCTAssertFalse(app.otherElements["player-gesture-level-pill"].exists)
        XCTAssertEqual(Double(app.staticTexts["gesture-screen-brightness"].label), brightness)
        XCTAssertEqual(Double(app.staticTexts["gesture-system-volume"].label), volume)
    }

    func testTimelineDragsWithVerticalMovementSeekWithoutChangingLevels() throws {
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 3))
        let brightness = try XCTUnwrap(Double(app.staticTexts["gesture-screen-brightness"].label))
        let volume = try XCTUnwrap(Double(app.staticTexts["gesture-system-volume"].label))
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation.isLandscape
            let rotated = NSPredicate { _, _ in
                (self.app.frame.width > self.app.frame.height) == landscape
            }
            XCTAssertEqual(
                XCTWaiter.wait(for: [expectation(for: rotated, evaluatedWith: app)], timeout: 5), .completed
            )
            let scrubber = app.otherElements["player-timeline-scrubber"]
            XCTAssertTrue(scrubber.waitForExistence(timeout: 3))
            for (start, end) in [(0.15, 0.25), (0.85, 0.75)] {
                let origin = scrubber.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5))
                let landing = scrubber.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5))
                    .withOffset(CGVector(dx: 0, dy: -120))
                origin.press(forDuration: 0.05, thenDragTo: landing)
                XCTAssertFalse(app.otherElements["player-gesture-level-pill"].exists, app.debugDescription)
                XCTAssertFalse(app.staticTexts["player-gesture-skip-total"].exists)
                XCTAssertEqual(Double(app.staticTexts["gesture-screen-brightness"].label), brightness)
                XCTAssertEqual(Double(app.staticTexts["gesture-system-volume"].label), volume)
                let target = end * 180
                let time = app.buttons["player-timeline-current-time"]
                let landed = NSPredicate { _, _ in
                    guard let text = time.value as? String else { return false }
                    let parts = text.split(separator: ":").compactMap { Double($0) }
                    guard parts.count == 2 else { return false }
                    return abs(parts[0] * 60 + parts[1] - target) < 3
                }
                XCTAssertEqual(
                    XCTWaiter.wait(for: [expectation(for: landed, evaluatedWith: time)], timeout: 10), .completed,
                    "A drag starting on either end of the timeline must remain a seek after leaving its bounds."
                )
                XCTAssertTrue(app.buttons["Play"].exists, "Seeking must preserve pause intent.")
                XCTAssertEqual(app.staticTexts["rotation-load-count"].label, "Loads 1")
            }
        }
    }

    func testRevealedBrightnessMeterAcceptsAbsoluteTapsAndDragsWithoutPlayerShortcuts() throws {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let revealStart = point(x: 0.18, y: 0.42)
        let revealEnd = point(x: 0.18, y: 0.60)
        revealStart.press(forDuration: 0.05, thenDragTo: revealEnd)
        let frame = try levelMeter.snapshot().frame
        XCTAssertGreaterThan(frame.minX, 44, "Landscape feedback must clear the Dynamic Island's unsafe edge.")
        let upper = origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + frame.height * 0.25))
        let lower = origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + frame.height * 0.75))
        let below = origin.withOffset(CGVector(dx: frame.midX, dy: frame.maxY + 28))
        // Prepare coordinates before revealing the 1.2-second HUD so accessibility
        // snapshots cannot consume its lifetime before the direct contact.
        revealStart.press(forDuration: 0.05, thenDragTo: revealEnd)
        upper.tap()
        try assertLevel(0.75)
        revealStart.press(forDuration: 0.05, thenDragTo: revealEnd)
        lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: .slow, thenHoldForDuration: 1.4)
        try assertLevel(0.75)
        revealStart.press(forDuration: 0.05, thenDragTo: revealEnd)
        upper.press(forDuration: 0.05, thenDragTo: below)
        try assertLevel(0)
        XCTAssertFalse(app.staticTexts["player-gesture-skip-total"].exists)
        XCTAssertFalse(app.otherElements["player-timeline"].exists)
        XCTAssertFalse(app.buttons["Pause"].exists)
        XCTAssertEqual(app.staticTexts["gesture-maximum-rate"].label, "1.0")
        XCTAssertEqual(app.staticTexts["rotation-load-count"].label, "Loads 1")
        capture("direct-brightness")
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.staticTexts["rotation-interface-orientation"].wait(
            for: \.label, toEqual: String(UIInterfaceOrientation.landscapeLeft.rawValue), timeout: 10
        ))
        let mirroredOrigin = app.coordinate(withNormalizedOffset: .zero)
        let mirroredStart = point(x: 0.18, y: 0.42)
        let mirroredEnd = point(x: 0.18, y: 0.60)
        mirroredStart.press(
            forDuration: 0.05, thenDragTo: mirroredEnd, withVelocity: .slow, thenHoldForDuration: 0.3
        )
        XCTAssertTrue(levelMeter.exists, app.debugDescription)
        let mirroredFrame = try levelMeter.snapshot().frame
        let mirroredLower = mirroredOrigin.withOffset(CGVector(
            dx: mirroredFrame.midX, dy: mirroredFrame.minY + mirroredFrame.height * 0.75
        ))
        mirroredStart.press(
            forDuration: 0.05, thenDragTo: mirroredEnd, withVelocity: .slow, thenHoldForDuration: 0.3
        )
        mirroredLower.tap()
        try assertLevel(0.25)
        XCTAssertFalse(app.staticTexts["player-gesture-skip-total"].exists)
    }

    func testRevealedVolumeMeterAcceptsAbsoluteTouchWhenSystemOutputIsAvailable() throws {
        point(x: 0.82, y: 0.42).press(forDuration: 0.05, thenDragTo: point(x: 0.82, y: 0.60))
        XCTAssertTrue(app.otherElements["player-gesture-level-pill"].exists, app.debugDescription)
        if app.staticTexts["player-gesture-level-unavailable"].exists {
            XCTAssertFalse(levelMeter.exists)
        } else {
            levelMeter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            try assertLevel(0.75)
        }
        XCTAssertFalse(app.staticTexts["player-gesture-skip-total"].exists)
        XCTAssertFalse(app.otherElements["player-timeline"].exists)
    }

    func testDisabledLevelGesturesPreserveTapSkipping() throws {
        app.terminate()
        app.launchArguments.append("--no-level-gestures")
        app.launch()
        XCTAssertTrue(app.buttons["Open rotation player"].waitForExistence(timeout: 10))
        app.buttons["Open rotation player"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 25))
        let brightness = try XCTUnwrap(Double(app.staticTexts["gesture-screen-brightness"].label))
        let volume = try XCTUnwrap(Double(app.staticTexts["gesture-system-volume"].label))
        for x in [0.18, 0.82] {
            point(x: x, y: 0.42).press(forDuration: 0.05, thenDragTo: point(x: x, y: 0.65))
        }
        XCTAssertFalse(app.otherElements["player-gesture-level-pill"].exists)
        XCTAssertEqual(Double(app.staticTexts["gesture-screen-brightness"].label), brightness)
        XCTAssertEqual(Double(app.staticTexts["gesture-system-volume"].label), volume)
        point(x: 0.8, y: 0.43).doubleTap()
        XCTAssertEqual(app.staticTexts["player-gesture-skip-total"].label, "+5")
    }

    private func assertLevel(_ expected: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let meter = try levelMeter.snapshot()
        let label = try XCTUnwrap(meter.value as? String, file: file, line: line)
        let percent = try XCTUnwrap(
            Double(label.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)),
            file: file, line: line
        )
        // UIKit's pan translation excludes the initial recognition slop.
        XCTAssertEqual(percent / 100, min(max(expected, 0), 1), accuracy: 0.04, file: file, line: line)
        XCTAssertEqual(meter.frame.width, 44, accuracy: 1, file: file, line: line)
        XCTAssertEqual(meter.frame.height, 156, accuracy: 1, file: file, line: line)
        XCTAssertEqual(
            app.otherElements["player-gesture-level-pill"].staticTexts.count, 0,
            "Successful level feedback must not display a percentage or any other text.", file: file, line: line
        )
    }

    private var levelMeter: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "player-gesture-level-value").firstMatch
    }

    private func point(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
