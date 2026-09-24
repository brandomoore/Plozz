#if canImport(AVFoundation)
import XCTest

@testable import FeaturePlayback

/// Pins the engine→model clock reconciliation — the two fragile windows behind
/// "press right → snap back" (pending-seek hold) and the self-flashing pause icon
/// (resume-confirm suppression).
final class PlaybackClockReconcilerTests: XCTestCase {

    private func snapshot(
        currentTime: TimeInterval = 100,
        duration: TimeInterval = 3600,
        buffered: TimeInterval = 120,
        isPaused: Bool = false,
        isLoading: Bool = false
    ) -> PlaybackClockReconciler.EngineSnapshot {
        .init(
            currentTime: currentTime, duration: duration, bufferedPosition: buffered,
            isPaused: isPaused, isLoading: isLoading)
    }

    // MARK: Normal ticking

    func testNormalTickMirrorsEngine() {
        let r = PlaybackClockReconciler.reconcile(
            snapshot: snapshot(currentTime: 100, isPaused: false),
            isScrubbing: false, pendingSeekTarget: nil, isResumeConfirming: false)
        XCTAssertEqual(r.duration, 3600)
        XCTAssertEqual(r.currentSeconds, 100)
        XCTAssertEqual(r.bufferedSeconds, 120)
        XCTAssertEqual(r.isPaused, false)
        XCTAssertFalse(r.clearPendingSeek)
        XCTAssertTrue(r.shouldEvaluateSkip)
    }

    func testZeroDurationIsNotAdopted() {
        let r = PlaybackClockReconciler.reconcile(
            snapshot: snapshot(duration: 0),
            isScrubbing: false, pendingSeekTarget: nil, isResumeConfirming: false)
        XCTAssertNil(r.duration)
    }

    // MARK: Scrubbing holds everything but duration

    func testScrubbingHoldsClockAndSkipsEvaluation() {
        let r = PlaybackClockReconciler.reconcile(
            snapshot: snapshot(currentTime: 100, duration: 3600),
            isScrubbing: true, pendingSeekTarget: nil, isResumeConfirming: false)
        XCTAssertEqual(r.duration, 3600, "duration is still adopted while scrubbing")
        XCTAssertNil(r.currentSeconds)
        XCTAssertNil(r.bufferedSeconds)
        XCTAssertNil(r.isPaused)
        XCTAssertFalse(r.clearPendingSeek)
        XCTAssertFalse(r.shouldEvaluateSkip)
    }

    // MARK: Pending-seek hold window

    func testPendingSeekHeldWhileEngineFarFromTarget() {
        // Optimistic target 500; engine still at pre-seek 100 → hold (no snap-back).
        let r = PlaybackClockReconciler.reconcile(
            snapshot: snapshot(currentTime: 100),
            isScrubbing: false, pendingSeekTarget: 500, isResumeConfirming: false)
        XCTAssertNil(r.currentSeconds, "must hold the optimistic target, not snap back")
        XCTAssertFalse(r.clearPendingSeek)
    }

    func testPendingSeekReleasesWithinTolerance() {
        // Engine arrived within 1.25s of the target → release + adopt real time.
        let r = PlaybackClockReconciler.reconcile(
            snapshot: snapshot(currentTime: 500.9),
            isScrubbing: false, pendingSeekTarget: 500, isResumeConfirming: false)
        XCTAssertTrue(r.clearPendingSeek)
        XCTAssertEqual(r.currentSeconds, 500.9)
    }

    func testPendingSeekBoundaryJustOutsideToleranceStillHolds() {
        // Exactly 1.25s away → NOT < tolerance → still held (keyframe-snap headroom).
        let r = PlaybackClockReconciler.reconcile(
            snapshot: snapshot(currentTime: 501.25),
            isScrubbing: false, pendingSeekTarget: 500, isResumeConfirming: false)
        XCTAssertFalse(r.clearPendingSeek)
        XCTAssertNil(r.currentSeconds)
    }

    func testPendingSeekReleasesWhenEngineLandsAheadOnKeyframe() {
        // A seek can land up to ~1s AHEAD by snapping to the next keyframe.
        let r = PlaybackClockReconciler.reconcile(
            snapshot: snapshot(currentTime: 500.8),
            isScrubbing: false, pendingSeekTarget: 500, isResumeConfirming: false)
        XCTAssertTrue(r.clearPendingSeek)
        XCTAssertEqual(r.currentSeconds, 500.8)
    }

    // MARK: Resume-confirm pause suppression

    func testResumeConfirmingSuppressesTransientPause() {
        // Engine momentarily reports paused during a resume settle → don't mirror.
        let r = PlaybackClockReconciler.reconcile(
            snapshot: snapshot(isPaused: true),
            isScrubbing: false, pendingSeekTarget: nil, isResumeConfirming: true)
        XCTAssertNil(r.isPaused, "transient rate-0 must not leak while confirming resume")
    }

    func testNotResumeConfirmingMirrorsPause() {
        let r = PlaybackClockReconciler.reconcile(
            snapshot: snapshot(isPaused: true),
            isScrubbing: false, pendingSeekTarget: nil, isResumeConfirming: false)
        XCTAssertEqual(r.isPaused, true)
    }

    // MARK: Engine rebuild (issue #61)

    func testLoadingEngineHoldsLastPositionInsteadOfZeroedClock() {
        // The rebuild after the screensaver zeroes the engine clock and duration
        // until the new item lands. Mirroring that 0 let a scrub or skip start
        // from the beginning of the title.
        let r = PlaybackClockReconciler.reconcile(
            snapshot: snapshot(currentTime: 0, duration: 0, buffered: 0, isPaused: true, isLoading: true),
            isScrubbing: false, pendingSeekTarget: nil, isResumeConfirming: false)
        XCTAssertNil(r.currentSeconds, "the zeroed rebuild clock must not replace the last position")
        XCTAssertNil(r.bufferedSeconds)
        XCTAssertNil(r.duration)
        XCTAssertFalse(r.shouldEvaluateSkip, "auto-skip must not act on a held position")
        XCTAssertEqual(r.isPaused, true, "the paused mirror is unaffected")
    }

    func testLoadingEngineKeepsPendingSeekPinned() {
        let r = PlaybackClockReconciler.reconcile(
            snapshot: snapshot(currentTime: 0, isLoading: true),
            isScrubbing: false, pendingSeekTarget: 0.5, isResumeConfirming: false)
        XCTAssertFalse(r.clearPendingSeek, "a zeroed clock is not a seek landing")
        XCTAssertNil(r.currentSeconds)
    }

    func testReadyEngineResumesMirroringAfterRebuild() {
        let r = PlaybackClockReconciler.reconcile(
            snapshot: snapshot(currentTime: 1834, isLoading: false),
            isScrubbing: false, pendingSeekTarget: nil, isResumeConfirming: false)
        XCTAssertEqual(r.currentSeconds, 1834)
        XCTAssertTrue(r.shouldEvaluateSkip)
    }
}
#endif
