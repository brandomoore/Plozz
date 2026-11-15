import UIKit
import XCTest

@MainActor
final class TouchFeedbackInteractionTests: XCTestCase {
    func testUpcomingActualPullHoldsThenSpringsAndPops() throws {
        let previousOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--upcoming-capture-fixture", "--capture-elasticity"]
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = previousOrientation
        }
        let evidence = app.staticTexts["upcoming-gesture-evidence"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 15), app.debugDescription)
        let agenda = app.scrollViews["upcoming-gesture-agenda"]
        XCTAssertTrue(agenda.exists, app.debugDescription)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: agenda.frame.midX, dy: max(220, agenda.frame.minY + 180)))
        func pull(_ distance: CGFloat) {
            start.press(
                forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                withVelocity: .slow, thenHoldForDuration: 0.3
            )
        }
        func snapshot() throws -> [String: Double] {
            let json = try XCTUnwrap(evidence.value as? String)
            let attachment = XCTAttachment(string: json)
            attachment.name = "Upcoming native gesture evidence"
            attachment.lifetime = .keepAlways
            add(attachment)
            return try JSONDecoder().decode([String: Double].self, from: Data(json.utf8))
        }
        pull(240)
        let caught = expectation(
            for: NSPredicate(format: "value CONTAINS %@", "\"catches\":1"), evaluatedWith: evidence
        )
        wait(for: [caught], timeout: 3)
        let held = try snapshot()
        XCTAssertGreaterThan(try XCTUnwrap(held["pull"]), 200, "The real recognizer must see a substantial pull")
        XCTAssertGreaterThan(try XCTUnwrap(held["held"]), 45, "The agenda must visibly stretch, not remain pinned")
        XCTAssertLessThan(try XCTUnwrap(held["held"]), 76)
        XCTAssertEqual(try XCTUnwrap(held["pops"]), 0, "The former threshold must no longer unlock history")
        XCTAssertEqual(try XCTUnwrap(held["catches"]), 1)
        XCTAssertEqual(try XCTUnwrap(held["offset"]), 0, accuracy: 1)
        XCTAssertGreaterThan(try XCTUnwrap(held["returnFrames"]), 3)
        XCTAssertGreaterThan(try XCTUnwrap(held["returnTravel"]), 20)
        XCTAssertLessThan(try XCTUnwrap(held["returnModelDrift"]), 1,
                          "Actual native deceleration must not fight the return spring")
        attachScrub(app, name: "Upcoming returns after a real resisted pull")

        pull(420)
        let released = try snapshot()
        XCTAssertEqual(try XCTUnwrap(released["pops"]), 1)
        XCTAssertEqual(try XCTUnwrap(released["catches"]), 1, "Released history must not be recaptured")
        XCTAssertLessThan(try XCTUnwrap(released["offset"]), -95)
        XCTAssertGreaterThan(try XCTUnwrap(released["tensionCount"]), 5)
        XCTAssertGreaterThan(try XCTUnwrap(released["minimumTension"]), 0.4)
        XCTAssertGreaterThan(try XCTUnwrap(released["maximumTension"]), 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(released["releaseFrames"]), 3,
                             "The pop must visibly animate while the finger remains down")
        attachScrub(app, name: "Upcoming history after a real release pop")
    }

    func testHeroWatchlistAcknowledgesImmediatelyAndOnlyFailureAddsFeedback() {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--watchlist-feedback-fixture"]
        app.launch()
        defer { app.terminate() }
        let add = app.buttons["Add to Watchlist"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertEqual(app.staticTexts["watchlist-taps"].label, "Taps 1")
        XCTAssertEqual(app.staticTexts["watchlist-confirmations"].label, "Confirmations 0")
        let errors = app.staticTexts["watchlist-errors"]
        XCTAssertEqual(errors.label, "Errors 0")
        let complete = app.buttons["Complete save"]
        XCTAssertTrue(complete.waitForExistence(timeout: 10))
        complete.tap()
        let confirmed = app.staticTexts["watchlist-confirmations"]
        let success = expectation(
            for: NSPredicate(format: "label == %@", "Saved yes"),
            evaluatedWith: app.staticTexts["watchlist-saved"]
        )
        wait(for: [success], timeout: 5)
        XCTAssertEqual(confirmed.label, "Confirmations 0")
        XCTAssertEqual(errors.label, "Errors 0")
        XCTAssertEqual(app.staticTexts["watchlist-taps"].label, "Taps 1")

        app.buttons["Remove from Watchlist"].firstMatch.tap()
        XCTAssertEqual(app.staticTexts["watchlist-taps"].label, "Taps 2")
        let fail = app.buttons["Fail save"]
        XCTAssertTrue(fail.waitForExistence(timeout: 10))
        fail.tap()
        let failure = expectation(for: NSPredicate(format: "label == %@", "Errors 1"), evaluatedWith: errors)
        wait(for: [failure], timeout: 5)
        XCTAssertTrue(app.buttons["Remove from Watchlist"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(confirmed.label, "Confirmations 0", "Failure must not emit a success haptic")
        XCTAssertEqual(app.staticTexts["watchlist-taps"].label, "Taps 2")
    }

    func testScrubGivesOneTickPerCommitAndPlaybackUpdatesStaySilent() throws {
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--touch-feedback-fixture"]
        app.launch()
        defer { app.terminate() }
        let scrubber = app.otherElements["touch-scrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        let start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let end = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertEqual(app.staticTexts["feedback-count"].label, "Feedback 1")
        XCTAssertEqual(app.staticTexts["commit-count"].label, "Commits 1")
        let previews = try XCTUnwrap(Int(app.staticTexts["preview-count"].label.split(separator: " ").last ?? ""))
        XCTAssertGreaterThan(previews, 2, "The drag must cover multiple previews, not just a tap")
        app.buttons["Playback tick"].tap()
        XCTAssertEqual(app.staticTexts["feedback-count"].label, "Feedback 1")
        end.press(forDuration: 0.1, thenDragTo: start)
        XCTAssertEqual(app.staticTexts["feedback-count"].label, "Feedback 2")
        app.buttons["Unknown duration"].tap()
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertEqual(app.staticTexts["feedback-count"].label, "Feedback 2")
    }

    func testPortraitSegmentedScrubDragsAcrossSuppressedCutsAndCommitsExactPosition() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native Liquid Glass requires iOS 26.") }
        try XCTSkipIf(UIAccessibility.isReduceTransparencyEnabled, "Native glass needs Reduce Transparency off.")
        let previousOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--touch-feedback-fixture", "--segmented-touch-feedback"]
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = previousOrientation
        }
        let scrubber = app.otherElements["touch-scrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        XCTAssertTrue(scrubber.isHittable)
        XCTAssertEqual(scrubber.label, "Playback position")
        let frame = scrubber.frame
        XCTAssertEqual(frame.width, 240, accuracy: 1)
        XCTAssertEqual(frame.height, 44, accuracy: 1)
        attachScrub(app, name: "Native portrait markers before dragging")

        let start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        let end = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertEqual(app.staticTexts["commit-count"].label, "Commits 1")
        XCTAssertEqual(app.staticTexts["feedback-count"].label, "Feedback 1")
        XCTAssertEqual(app.staticTexts["scrubbing-active"].label, "no")
        XCTAssertEqual(try number(app, "committed-position"), 210, accuracy: 1.5)
        XCTAssertLessThan(try number(app, "gesture-minimum"), 75)
        XCTAssertGreaterThan(try number(app, "gesture-maximum"), 174.375)
        XCTAssertGreaterThan(try XCTUnwrap(Int(app.staticTexts["preview-count"].label.split(separator: " ").last ?? "")), 2)
        XCTAssertEqual(scrubber.frame, frame, "Dragging must preserve the timeline's hit area.")
        attachScrub(app, name: "Native portrait markers after forward commit")

        let insideTinyMarker = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.27, dy: 0.5))
        end.press(forDuration: 0.1, thenDragTo: insideTinyMarker)
        XCTAssertEqual(app.staticTexts["commit-count"].label, "Commits 2")
        XCTAssertEqual(app.staticTexts["feedback-count"].label, "Feedback 2")
        XCTAssertEqual(try number(app, "committed-position"), 81, accuracy: 1.5,
                       "A suppressed visual marker must not snap seeking to either of its endpoints.")
        XCTAssertEqual(app.staticTexts["scrubbing-active"].label, "no")
        attachScrub(app, name: "Native portrait commit inside suppressed marker")
        app.buttons["Playback tick"].tap()
        XCTAssertEqual(app.staticTexts["commit-count"].label, "Commits 2")
        XCTAssertEqual(app.staticTexts["feedback-count"].label, "Feedback 2")

        let rightEdge = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
        insideTinyMarker.press(forDuration: 0.1, thenDragTo: rightEdge)
        XCTAssertEqual(try number(app, "committed-position"), 300, accuracy: 1.5)
        XCTAssertEqual(app.staticTexts["commit-count"].label, "Commits 3")
        XCTAssertEqual(app.staticTexts["feedback-count"].label, "Feedback 3")
        attachScrub(app, name: "Native portrait fill at 100 percent without a playhead")

        let leftEdge = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        end.press(forDuration: 0.1, thenDragTo: leftEdge)
        XCTAssertEqual(try number(app, "committed-position"), 0, accuracy: 1.5)
        XCTAssertEqual(app.staticTexts["commit-count"].label, "Commits 4")
        XCTAssertEqual(app.staticTexts["feedback-count"].label, "Feedback 4")
        XCTAssertEqual(app.staticTexts["scrubbing-active"].label, "no")
        XCTAssertEqual(scrubber.frame, frame)
        attachScrub(app, name: "Native portrait fill at zero without a playhead")
    }

    private func number(_ app: XCUIApplication, _ identifier: String) throws -> Double {
        try XCTUnwrap(Double(app.staticTexts[identifier].label), identifier)
    }

    private func attachScrub(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
