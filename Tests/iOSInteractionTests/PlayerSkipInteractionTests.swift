import UIKit
import XCTest

/// The in-player Skip button must move playback past the WHOLE active segment on
/// a single native press, and then leave the screen. A press that only nudges a
/// ±skip interval (or needs a second tap) means the touch layer is eating the
/// button's touch.
@MainActor
final class PlayerSkipInteractionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication(bundleIdentifier: "com.thatcube.Plozz.PresentationHost")
        app.launchArguments = ["--rotation-player-fixture", "--skip-player-fixture", "--auto"]
        app.launch()
        XCTAssertTrue(app.buttons["Open rotation player"].waitForExistence(timeout: 10))
        app.buttons["Open rotation player"].tap()
    }

    override func tearDown() {
        if testRun?.failureCount ?? 0 > 0 { capture("skip-failure") }
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app = nil
        super.tearDown()
    }

    func testOnePressSkipsPastTheWholeIntroAndRemovesTheButton() {
        // The fixture intro is 60s → 90s and playback starts at 60s.
        let skip = app.buttons["Skip Intro"]
        XCTAssertTrue(skip.waitForExistence(timeout: 25), app.debugDescription)
        skip.tap()

        XCTAssertTrue(skip.waitForNonExistence(timeout: 3),
                      "The button must leave after its single press. \(app.debugDescription)")
        let position = seconds(of: app.buttons["player-timeline-current-time"].value as? String)
        XCTAssertNotNil(position, app.debugDescription)
        XCTAssertGreaterThanOrEqual(position ?? 0, 88,
                                    "One press must seek to the segment end (90s), not a ±skip interval.")
        XCTAssertLessThan(position ?? 999, 96)
        XCTAssertFalse(app.staticTexts["player-gesture-skip-total"].exists,
                       "The Skip button press must not also become a touch skip shortcut.")
        capture("skip-intro-once")
    }

    func testDoubleTapAwayFromTheButtonStillSkipsWhileItIsShown() {
        let skip = app.buttons["Skip Intro"]
        XCTAssertTrue(skip.waitForExistence(timeout: 25), app.debugDescription)

        // Forward side of the video, well clear of the bottom-trailing button.
        point(x: 0.8, y: 0.35).doubleTap()

        let feedback = app.staticTexts["player-gesture-skip-total"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertEqual(feedback.label, "+10", "Playback shortcuts stay live next to the Skip button.")
        // The jump itself lands deep inside the intro, so the existing deep-seek
        // rule may stand the button down; the shortcut must still have acted.
    }

    private func point(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func seconds(of time: String?) -> Double? {
        guard let time else { return nil }
        let parts = time.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
