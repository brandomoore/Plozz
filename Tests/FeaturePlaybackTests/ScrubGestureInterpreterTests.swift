#if canImport(AVFoundation)
import XCTest

@testable import FeaturePlayback

/// Pins the scrub gesture state machine that historically broke silently on a
/// TV: an axis lock that let a vertical drift move the head, a pause-to-seek gate
/// that leaked a seek, a flick misread as a landing (seek + rebuffer churn), or a
/// multi-swipe traversal that reset its momentum on each swipe. All pure, so the
/// whole gesture is driven here without UIKit.
final class ScrubGestureInterpreterTests: XCTestCase {

    private func makeInterpreter() -> ScrubGestureInterpreter {
        ScrubGestureInterpreter(axisDeadZone: 18, speedSmoothing: 0.25, flickCommitThreshold: 1000)
    }

    // MARK: Axis lock + dead-zone

    func testBelowDeadZoneIsIgnoredAndLeavesAxisUndecided() {
        var g = makeInterpreter()
        g.begin()
        let outcome = g.changed(translationX: 10, translationY: 4, velocityX: 0,
                                isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        XCTAssertEqual(outcome, .ignore)
        XCTAssertEqual(g.axis, .undecided)
    }

    func testHorizontalPastDeadZoneKeepsTheTravelBeyondTheDeadZone() {
        var g = makeInterpreter()
        g.begin()
        // The threshold consumes 18 points, not the whole first delivered sample.
        let outcome = g.changed(translationX: 20, translationY: 3, velocityX: 800,
                                isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        guard case let .advance(delta, smoothed, beginScrub, continueTraversal) = outcome else {
            return XCTFail("expected advance, got \(outcome)")
        }
        XCTAssertEqual(delta, 2, accuracy: 0.0001)
        XCTAssertTrue(beginScrub)
        XCTAssertFalse(continueTraversal)
        // Fresh scrub resets smoothing to 0 first, then EMA: 800 * 0.25 = 200.
        XCTAssertEqual(smoothed, 200, accuracy: 0.0001)
        XCTAssertEqual(g.axis, .horizontal)
    }

    func testVerticalDownEntersControlBarAndLocksVertical() {
        var g = makeInterpreter()
        g.begin()
        let outcome = g.changed(translationX: 3, translationY: 25, velocityX: 0,
                                isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        XCTAssertEqual(outcome, .enterControlBar)
        XCTAssertEqual(g.axis, .verticalIgnored)
        // Subsequent samples in the same gesture do nothing (locked vertical).
        let next = g.changed(translationX: 60, translationY: 40, velocityX: 500,
                             isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        XCTAssertEqual(next, .ignore)
    }

    func testCoalescedInitialTravelIsNotDiscardedInEitherDirection() {
        for x in [178.719, 333.251, 764.738, 1501.275, -178.719, -1501.275] {
            var gesture = makeInterpreter()
            gesture.begin()
            let outcome = gesture.changed(
                translationX: x, translationY: 0, velocityX: 0,
                isScrubbing: false, seekWithoutPausing: true, isPaused: true
            )
            guard case let .advance(delta, _, began, _) = outcome else {
                return XCTFail("Expected captured horizontal travel to advance the scrubber.")
            }
            XCTAssertTrue(began)
            XCTAssertEqual(delta, x - (x < 0 ? -18 : 18), accuracy: 0.001)
            let next = gesture.changed(
                translationX: x + 10, translationY: 0, velocityX: 0,
                isScrubbing: true, seekWithoutPausing: true, isPaused: true
            )
            guard case let .advance(nextDelta, _, _, _) = next else {
                return XCTFail("Expected incremental movement after the initial sample.")
            }
            XCTAssertEqual(nextDelta, 10, accuracy: 0.001)
        }
    }

    func testVerticalUpMovesUpAndLocksVertical() {
        var g = makeInterpreter()
        g.begin()
        let outcome = g.changed(translationX: 3, translationY: -25, velocityX: 0,
                                isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        XCTAssertEqual(outcome, .moveUp)
        XCTAssertEqual(g.axis, .verticalIgnored)
        let next = g.changed(translationX: 60, translationY: -40, velocityX: 500,
                             isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        XCTAssertEqual(next, .ignore)
    }

    func testVerticalNavigationDoesNotRequirePausing() {
        for (translationY, expected) in [(25.0, ScrubGestureInterpreter.PanOutcome.enterControlBar),
                                         (-25.0, .moveUp)] {
            var g = makeInterpreter()
            g.begin()
            XCTAssertEqual(
                g.changed(translationX: 3, translationY: translationY, velocityX: 0,
                          isScrubbing: false, seekWithoutPausing: false, isPaused: false),
                expected)
            XCTAssertEqual(g.ended(gestureEnded: true, velocityX: 0, isScrubbing: false), .none)
        }
    }

    func testAxisLockKeepsScrubbingDespiteVerticalDrift() {
        var g = makeInterpreter()
        g.begin()
        _ = g.changed(translationX: 20, translationY: 0, velocityX: 400,
                      isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        // A later sample drifts more vertically than horizontally, but the axis is
        // already locked horizontal → it must still advance, never bleed vertical.
        let outcome = g.changed(translationX: 25, translationY: 90, velocityX: 400,
                                isScrubbing: true, seekWithoutPausing: true, isPaused: true)
        guard case let .advance(delta, _, beginScrub, _) = outcome else {
            return XCTFail("expected advance, got \(outcome)")
        }
        XCTAssertEqual(delta, 5, accuracy: 0.0001)
        XCTAssertFalse(beginScrub)
    }

    // MARK: Pause-to-seek gate

    func testPauseToSeekGateFlashesAndSuppressesWhilePlaying() {
        var g = makeInterpreter()
        g.begin()
        // seekWithoutPausing off AND playing → horizontal swipe must NOT scrub.
        let outcome = g.changed(translationX: 30, translationY: 2, velocityX: 900,
                                isScrubbing: false, seekWithoutPausing: false, isPaused: false)
        XCTAssertEqual(outcome, .flashAndSuppress)
        XCTAssertEqual(g.axis, .verticalIgnored)
        // Rest of the gesture is suppressed.
        let next = g.changed(translationX: 120, translationY: 2, velocityX: 900,
                             isScrubbing: false, seekWithoutPausing: false, isPaused: false)
        XCTAssertEqual(next, .ignore)
    }

    func testPauseToSeekGateDoesNotFireWhenAlreadyPaused() {
        var g = makeInterpreter()
        g.begin()
        // Paused → scrub engages even with seekWithoutPausing off.
        let outcome = g.changed(translationX: 30, translationY: 2, velocityX: 400,
                                isScrubbing: false, seekWithoutPausing: false, isPaused: true)
        guard case .advance(_, _, let beginScrub, _) = outcome else {
            return XCTFail("expected advance, got \(outcome)")
        }
        XCTAssertTrue(beginScrub)
    }

    // MARK: Velocity smoothing (EMA)

    func testSmoothedSpeedCarriesMomentumAcrossSamples() {
        var g = makeInterpreter()
        g.begin()
        // Begin: reset to 0 then EMA → 1000*0.25 = 250.
        _ = g.changed(translationX: 20, translationY: 0, velocityX: 1000,
                      isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        // Next: 250 + (2000-250)*0.25 = 687.5.
        let outcome = g.changed(translationX: 40, translationY: 0, velocityX: 2000,
                                isScrubbing: true, seekWithoutPausing: true, isPaused: true)
        guard case let .advance(_, smoothed, _, _) = outcome else {
            return XCTFail("expected advance, got \(outcome)")
        }
        XCTAssertEqual(smoothed, 687.5, accuracy: 0.0001)
    }

    func testSmoothingRespondsEquallyAt24And60Hz() {
        func speed(after intervals: [Double]) -> Double {
            var gesture = makeInterpreter()
            gesture.begin()
            var result = 0.0
            for (index, elapsed) in intervals.enumerated() {
                let outcome = gesture.changed(
                    translationX: 20 + Double(index), translationY: 0, velocityX: 2000,
                    isScrubbing: index > 0, seekWithoutPausing: true, isPaused: true,
                    elapsed: elapsed
                )
                if case let .advance(_, speed, _, _) = outcome { result = speed }
            }
            return result
        }
        let sixtyHz = speed(after: Array(repeating: 1.0 / 60.0, count: 10))
        let twentyFourHz = speed(after: Array(repeating: 1.0 / 24.0, count: 4))
        XCTAssertEqual(twentyFourHz, sixtyHz, accuracy: 0.0001)
    }

    func testCoalescedSampleUsesElapsedTimeRatherThanOneFilterStep() {
        var gesture = makeInterpreter()
        gesture.begin()
        let outcome = gesture.changed(
            translationX: 500, translationY: 0, velocityX: 2000,
            isScrubbing: false, seekWithoutPausing: true, isPaused: true,
            elapsed: 0.1
        )
        guard case let .advance(delta, speed, _, _) = outcome else {
            return XCTFail("Expected coalesced input to advance immediately.")
        }
        XCTAssertEqual(delta, 482)
        XCTAssertEqual(speed, 2000 * (1 - pow(0.75, 6)), accuracy: 0.0001)
    }

    // MARK: Multi-swipe traversal continuation

    func testContinueTraversalWhenAlreadyScrubbing() {
        var g = makeInterpreter()
        g.begin()
        // A fresh gesture whose first horizontal sample lands while a prior flick
        // left isScrubbing true → continue the session (no begin), and momentum
        // is preserved (smoothing not reset to 0).
        // Prime some momentum on a first gesture.
        _ = g.changed(translationX: 20, translationY: 0, velocityX: 4000,
                      isScrubbing: false, seekWithoutPausing: true, isPaused: true)
        g.begin()
        let outcome = g.changed(translationX: 30, translationY: 0, velocityX: 0,
                                isScrubbing: true, seekWithoutPausing: true, isPaused: true)
        guard case let .advance(delta, smoothed, beginScrub, continueTraversal) = outcome else {
            return XCTFail("expected advance, got \(outcome)")
        }
        XCTAssertEqual(delta, 12, accuracy: 0.0001)
        XCTAssertTrue(continueTraversal)
        XCTAssertFalse(beginScrub)
        // Momentum from the first gesture (1000) decays but was NOT reset to 0:
        // 1000 + (0-1000)*0.25 = 750.
        XCTAssertEqual(smoothed, 750, accuracy: 0.0001)
    }

    // MARK: Flick vs. deliberate landing on lift

    func testFastFlickLiftBridgesCommit() {
        var g = makeInterpreter()
        g.begin()
        _ = g.changed(translationX: 20, translationY: 0, velocityX: 400,
                      isScrubbing: true, seekWithoutPausing: true, isPaused: true)
        let end = g.ended(gestureEnded: true, velocityX: 1500, isScrubbing: true)
        XCTAssertEqual(end, .bridgeCommit)
        XCTAssertEqual(g.axis, .undecided)
    }

    func testSlowLandingCommitsImmediately() {
        var g = makeInterpreter()
        g.begin()
        _ = g.changed(translationX: 20, translationY: 0, velocityX: 400,
                      isScrubbing: true, seekWithoutPausing: true, isPaused: true)
        let end = g.ended(gestureEnded: true, velocityX: 200, isScrubbing: true)
        XCTAssertEqual(end, .commit)
    }

    func testCancelledGestureCommitsRatherThanBridges() {
        var g = makeInterpreter()
        g.begin()
        _ = g.changed(translationX: 20, translationY: 0, velocityX: 400,
                      isScrubbing: true, seekWithoutPausing: true, isPaused: true)
        // .cancelled/.failed (gestureEnded == false) must never bridge, even at a
        // flick-speed lift — a cancel should settle, not leave a session dangling.
        let end = g.ended(gestureEnded: false, velocityX: 5000, isScrubbing: true)
        XCTAssertEqual(end, .commit)
    }

    func testEndWithoutHorizontalScrubIsNoOp() {
        var g = makeInterpreter()
        g.begin()
        // Never locked horizontal → nothing to commit.
        let end = g.ended(gestureEnded: true, velocityX: 5000, isScrubbing: false)
        XCTAssertEqual(end, .none)
    }
}
#endif
