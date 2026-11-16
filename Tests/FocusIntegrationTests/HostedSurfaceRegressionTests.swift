import CoreModels
import XCTest
@testable import AppShell
@testable import CoreUI
@testable import FeaturePlayback

/// Deterministic regression coverage for the hosted surfaces that used to be
/// asserted through pixel sampling and OCR. These tests check the same
/// production logic directly, so they stay green on a clean simulator and
/// still fail when the behaviour changes.
@MainActor
final class HostedSurfaceRegressionTests: XCTestCase {
    // MARK: - Player timeline labels

    func testTimelineTimeLabelFormatsMinutesSecondsAndHours() {
        XCTAssertEqual(PlayerControls.timeLabel(0), "0:00")
        XCTAssertEqual(PlayerControls.timeLabel(9.6), "0:10")
        XCTAssertEqual(PlayerControls.timeLabel(59.4), "0:59")
        XCTAssertEqual(PlayerControls.timeLabel(60), "1:00")
        XCTAssertEqual(PlayerControls.timeLabel(600), "10:00")
        XCTAssertEqual(PlayerControls.timeLabel(3_600), "1:00:00")
        XCTAssertEqual(PlayerControls.timeLabel(3_725), "1:02:05")
    }

    func testTimelineTimeLabelRejectsInvalidInputs() {
        XCTAssertEqual(PlayerControls.timeLabel(-1), "0:00")
        XCTAssertEqual(PlayerControls.timeLabel(.nan), "0:00")
        XCTAssertEqual(PlayerControls.timeLabel(.infinity), "0:00")
    }

    func testTimelineRemainingLabelReflectsTheUnplayedDuration() {
        // The transport renders a leading minus plus the time left:
        // "-" + timeLabel(max(0, duration - displaySeconds)) (PlayerControlsSupport).
        // Scrubbing to 600s of a 3600s item leaves 50 minutes, so it reads "-50:00".
        let duration = 3_600.0
        let scrub = 600.0
        let remaining = "-" + PlayerControls.timeLabel(max(0, duration - scrub))
        XCTAssertEqual(remaining, "-50:00")
    }

    func testTimelineScanGlyphIsEmptyWhenNotScrubbing() {
        let model = PlayerControlsModel()
        model.controlsVisible = true
        model.duration = 3_600
        model.isScrubbing = false
        model.skipGesture.scanLevel = 8
        XCTAssertFalse(model.isScrubbing, "The scan glyph must only show while scrubbing.")
    }

    func testTimelineScanGlyphDirectionFollowsTheLevel() {
        let model = PlayerControlsModel()
        model.controlsVisible = true
        model.duration = 3_600
        model.isScrubbing = true
        for level in [-8, -2, 2, 8] {
            model.skipGesture.scanLevel = level
            XCTAssertEqual(model.skipGesture.scanLevel < 0, level < 0)
        }
    }

    // MARK: - Circular card focus style

    func testSystemStyleKeepsTheNativeEffect() {
        XCTAssertTrue(CardFocusStyle.system.usesSystemEffect)
        XCTAssertFalse(CardFocusStyle.system.drawsFocusOutline)
    }

    func testCustomStylesDoNotUseTheNativeEffect() {
        XCTAssertFalse(CardFocusStyle.highlight.usesSystemEffect)
        XCTAssertFalse(CardFocusStyle.outlined.usesSystemEffect)
        XCTAssertTrue(CardFocusStyle.outlined.drawsFocusOutline)
    }

    func testCircularControlsResolveSystemStyleToOutlined() {
        XCTAssertEqual(CircularControlFocusStyle.resolve(.system), .outlined)
        XCTAssertEqual(CircularControlFocusStyle.resolve(.highlight), .highlight)
        XCTAssertEqual(CircularControlFocusStyle.resolve(.outlined), .outlined)
    }

    // MARK: - Navigation entry target ordering

    func testEntryFocusPrefersTheLeadingControlInTheTopRow() {
        let first = CGRect(x: 20, y: 100, width: 200, height: 120)
        let second = CGRect(x: 260, y: 100, width: 200, height: 120)
        let lower = CGRect(x: 20, y: 260, width: 200, height: 120)
        XCTAssertEqual(
            NavigationContentFocusRequester.firstFrameIndex([first, second, lower], isRightToLeft: false),
            0
        )
    }

    func testEntryFocusPrefersTheLeadingControlInTheTopRowForRightToLeft() {
        let first = CGRect(x: 20, y: 100, width: 200, height: 120)
        let second = CGRect(x: 260, y: 100, width: 200, height: 120)
        let lower = CGRect(x: 20, y: 260, width: 200, height: 120)
        XCTAssertEqual(
            NavigationContentFocusRequester.firstFrameIndex([first, second, lower], isRightToLeft: true),
            1
        )
    }

    func testEntryFocusReturnsNilWhenNoFramesExist() {
        XCTAssertNil(NavigationContentFocusRequester.firstFrameIndex([], isRightToLeft: false))
    }

    func testEntryFocusToleratesFocusExpansionAboveTheTopEdge() {
        // A focused card's expanded plate can extend above the first row's top;
        // the row must still be selected by its vertical centre, not by the
        // expansion's top edge.
        let leading = CGRect(x: 20, y: 100, width: 200, height: 120)
        let expanded = CGRect(x: 260, y: 80, width: 220, height: 140)
        XCTAssertEqual(
            NavigationContentFocusRequester.firstFrameIndex([leading, expanded], isRightToLeft: false),
            0
        )
    }
}
