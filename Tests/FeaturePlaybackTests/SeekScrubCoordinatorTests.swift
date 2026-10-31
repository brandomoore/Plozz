#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import XCTest
#if canImport(UIKit)
import UIKit
#endif

@testable import FeaturePlayback

@MainActor
final class SeekScrubCoordinatorTests: XCTestCase {

    /// Keeps spy hosts alive for the test's duration — the coordinator holds a
    /// *weak* host, so without this the seam would drop mid-test.
    private var retainedHosts: [SeekSpyHost] = []

    override func tearDown() {
        retainedHosts.removeAll()
        super.tearDown()
    }

    // MARK: Harness

    private func makeSUT(
        intendsPlayback: Bool = true,
        didStop: Bool = false,
        autoAdvance: Bool = false,
        commitDebounce: UInt64 = 1_000_000 // 1ms — keep tests fast
    ) -> (SeekScrubCoordinator, SeekSpyHost, SeekSpyEngine, PlayerControlsModel) {
        let engine = SeekSpyEngine()
        engine.autoAdvance = autoAdvance
        let controls = PlayerControlsModel()
        let host = SeekSpyHost(engine: engine, intendsPlayback: intendsPlayback, didStop: didStop)
        retainedHosts.append(host)
        let sut = SeekScrubCoordinator(host: host, controls: controls, commitDebounce: commitDebounce)
        host.onApplyPaused = { [weak controls] paused in
            // Mirror the real VM's setPaused funnel enough for the give-up path.
            controls?.isPaused = paused
            controls?.intendsPause = paused
            controls?.isResumeConfirming = false
        }
        return (sut, host, engine, controls)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        // Returning silently on timeout would leave the following assertions to
        // report some confusing downstream symptom instead of "the thing I waited
        // for never happened", and would do it `timeout` seconds later.
        XCTFail("condition never became true within \(timeout)s", file: file, line: line)
    }

    // MARK: End-guard clamp (network-file EOF-fault guard)

    func testCommittedSeekPastEndClampsBelowDuration() {
        // Scrubbing to the very end must not drop the engine exactly on EOF: a
        // network-file source faults its demuxer there. The committed target lands
        // one endGuard shy of duration so the stream plays out to a clean onEnded.
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: false)
        engine.duration = 1_000
        sut.requestSeek(to: 1_000)
        XCTAssertEqual(controls.pendingSeekTarget ?? -1, 999, accuracy: 0.0001)
        XCTAssertEqual(sut.clampedSeekTarget(1_000), 999, accuracy: 0.0001)
        XCTAssertEqual(sut.clampedSeekTarget(5_000), 999, accuracy: 0.0001,
                       "a target past the end still clamps to just below duration")
    }

    func testCommittedSeekWithinRangeIsUnchanged() {
        let (sut, _, engine, _) = makeSUT(intendsPlayback: false)
        engine.duration = 1_000
        XCTAssertEqual(sut.clampedSeekTarget(500), 500, accuracy: 0.0001)
        XCTAssertEqual(sut.clampedSeekTarget(0), 0, accuracy: 0.0001)
        XCTAssertEqual(sut.clampedSeekTarget(-42), 0, accuracy: 0.0001,
                       "still floored at zero")
    }

    func testUnknownDurationOnlyFloorsAtZero() {
        // Early bring-up: duration not yet known → only the lower bound applies,
        // preserving prior behaviour (no upper clamp against a bogus 0 duration).
        let (sut, _, engine, _) = makeSUT(intendsPlayback: false)
        engine.duration = 0
        XCTAssertEqual(sut.clampedSeekTarget(12_345), 12_345, accuracy: 0.0001)
        engine.duration = .infinity
        XCTAssertEqual(sut.clampedSeekTarget(12_345), 12_345, accuracy: 0.0001)
    }

    func testVeryShortDurationDoesNotProduceNegativeTarget() {
        let (sut, _, engine, _) = makeSUT(intendsPlayback: false)
        engine.duration = 0.5 // shorter than endGuard
        XCTAssertEqual(sut.clampedSeekTarget(0.4), 0.4, accuracy: 0.0001,
                       "sub-endGuard durations skip the upper clamp rather than go negative")
    }

    // MARK: isSeeking clear-on-return (forever-spinner guard)

    func testIsSeekingClearsAfterDrainReturns() async {
        // Pause-to-seek so we skip the (slow) resume-confirm loop; the drain still
        // must clear isSeeking exactly once it returns.
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: false)
        sut.requestSeek(to: 42)
        XCTAssertTrue(controls.isSeeking, "isSeeking is asserted synchronously on request")
        await waitUntil { !controls.isSeeking }
        XCTAssertFalse(controls.isSeeking, "isSeeking must clear when the drain returns")
        XCTAssertEqual(engine.lastSeekTarget, 42)
    }

    // MARK: duration-gate (DV·SMB "seek during load snaps to start" guard)

    func testCommittedSeekWaitsForDurationBeforeReachingEngine() async {
        // Engine has reported .ready (scrubber revealed) but hasn't published a
        // duration yet — AetherEngine would clamp min(target, 0) == 0 and snap
        // playback to the start. The coordinator must hold the engine seek until a
        // real duration is known, then issue it at the true target.
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: false)
        engine.duration = 0
        sut.requestSeek(to: 500)
        // Give the debounce + a few drain ticks time to run; no seek may reach the
        // engine while duration is unknown.
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(engine.seekLog.isEmpty, "no committed seek may reach the engine while duration is 0")
        XCTAssertTrue(controls.isSeeking, "the seek is still in flight, pinned on screen")
        XCTAssertEqual(controls.currentSeconds, 500, "the optimistic position holds the requested target")
        // Duration lands → the held seek fires at the true target, not clamped to 0.
        engine.duration = 1_000
        await waitUntil { !controls.isSeeking }
        XCTAssertEqual(engine.seekLog.count, 1, "exactly one committed seek once duration is known")
        XCTAssertEqual(engine.lastSeekTarget, 500, "the real target survives (never clamped to 0)")
    }

    // MARK: intendsPause phantom-.playing gate

    func testPauseToSeekReassertsPauseAndIntent() async {
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: false)
        sut.requestSeek(to: 30)
        await waitUntil { !controls.isSeeking }
        XCTAssertTrue(controls.isPaused, "a pause-to-seek must land paused")
        XCTAssertTrue(controls.intendsPause, "the intent gate must stay honest (intendsPause)")
        XCTAssertFalse(controls.isResumeConfirming, "no resume confirmation when not intending playback")
        XCTAssertTrue(engine.isPaused, "the engine must be re-paused on the landed frame")
    }

    // MARK: coalescing / latest-target-wins

    func testRapidPressesCollapseToSingleFinalExactSeek() async {
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: false, commitDebounce: 30_000_000)
        // A burst of presses inside the debounce window.
        sut.requestSeek(to: 10)
        sut.requestSeek(to: 20)
        sut.requestSeek(to: 90)
        await waitUntil { !controls.isSeeking }
        XCTAssertEqual(engine.seekLog.count, 1, "the burst must collapse to ONE committed seek")
        XCTAssertEqual(engine.seekLog.first?.target, 90, "the final target wins")
        XCTAssertEqual(engine.seekLog.first?.kind, .exact, "the final settle is exact")
    }

    func testNegativeRequestClampsToZero() async {
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: false)
        sut.requestSeek(to: -50)
        await waitUntil { !controls.isSeeking }
        XCTAssertEqual(engine.lastSeekTarget, 0)
        XCTAssertEqual(controls.currentSeconds, 0)
    }

    // MARK: resume confirmation

    func testResumeConfirmClearsWhenClockAdvances() async {
        // An engine whose clock advances while playing should resolve the
        // resume-confirm loop and leave playback running (never re-paused).
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: true, autoAdvance: true)
        sut.requestSeek(to: 15)
        await waitUntil(timeout: 5) { !controls.isResumeConfirming && !controls.isSeeking }
        XCTAssertFalse(controls.isResumeConfirming, "resume-confirm must clear once the clock advances")
        XCTAssertFalse(controls.isPaused, "a healthy resume stays playing")
        XCTAssertFalse(engine.isPaused)
    }

    func testResumeConfirmDoesNotKickBufferedPlayerAndAcceptsRecoveredClock() async {
        for status in [AVPlayer.TimeControlStatus.waitingToPlayAtSpecifiedRate, .playing] {
            let (sut, _, engine, controls) = makeSUT()
            defer { sut.cancelAll() }
            engine.nowPlayingPlayer = SeekTimeControlPlayer(status: status)
            sut.requestSeek(to: 15)
            await waitUntil { engine.playCount == 1 && !controls.isSeeking }
            // Observe multiple retry intervals while the buffered output is stationary.
            try? await Task.sleep(for: .seconds(1))
            XCTAssertEqual(engine.pauseCount, 0)
            XCTAssertEqual(engine.playCount, 1)
            XCTAssertTrue(controls.isResumeConfirming)
            engine.startAdvancingClock()
            await waitUntil { !controls.isResumeConfirming }
            XCTAssertEqual(engine.pauseCount, 0)
            XCTAssertEqual(engine.playCount, 1)
            XCTAssertFalse(controls.isPaused)
        }
    }

    func testResumeConfirmStillKicksAPausedNativePlayer() async {
        let (sut, _, engine, _) = makeSUT()
        defer { sut.cancelAll() }
        engine.nowPlayingPlayer = SeekTimeControlPlayer(status: .paused)
        sut.requestSeek(to: 15)
        await waitUntil { engine.pauseCount > 0 && engine.playCount > 1 }
    }

    func testResumeConfirmBoundsAnIndefinitelyWaitingPlayer() async {
        let (sut, _, engine, controls) = makeSUT()
        defer { sut.cancelAll() }
        engine.nowPlayingPlayer = SeekTimeControlPlayer(status: .waitingToPlayAtSpecifiedRate)
        let start = ContinuousClock.now
        sut.requestSeek(to: 15)
        await waitUntil(timeout: 20) { controls.intendsPause && !controls.isResumeConfirming }
        let elapsed = start.duration(to: ContinuousClock.now)
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(14))
        XCTAssertLessThan(elapsed, .seconds(20))
        XCTAssertTrue(controls.isPaused)
        XCTAssertEqual(engine.pauseCount, 0, "A waiting player must not receive disruptive retry kicks.")
        XCTAssertEqual(engine.playCount, 1)
    }

    func testCancellingBufferedResumeCannotPlayAgainOrGiveUpLater() async {
        let (sut, _, engine, controls) = makeSUT()
        defer { sut.cancelAll() }
        engine.nowPlayingPlayer = SeekTimeControlPlayer(status: .waitingToPlayAtSpecifiedRate)
        sut.requestSeek(to: 15)
        await waitUntil { engine.playCount == 1 && !controls.isSeeking }
        sut.cancelResumeConfirm()
        try? await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(controls.isResumeConfirming)
        XCTAssertFalse(controls.intendsPause)
        XCTAssertEqual(engine.playCount, 1)
        XCTAssertEqual(engine.pauseCount, 0)
    }

    // MARK: teardown

    func testCancelResumeConfirmClearsFlag() async {
        let (sut, _, _, controls) = makeSUT(intendsPlayback: true, autoAdvance: false)
        controls.isResumeConfirming = true
        sut.cancelResumeConfirm()
        XCTAssertFalse(controls.isResumeConfirming)
    }

    func testCancelAllStopsInFlightSeek() async {
        // With a stalled (non-advancing) engine and intendsPlayback, the drain
        // would enter the resume-confirm loop; cancelAll must tear it down and
        // clear the suppression flag.
        let (sut, _, _, controls) = makeSUT(intendsPlayback: true, autoAdvance: false)
        sut.requestSeek(to: 25)
        await waitUntil { !controls.isSeeking } // drain landed, resume-confirm running
        sut.cancelAll()
        await waitUntil { !controls.isResumeConfirming }
        XCTAssertFalse(controls.isResumeConfirming, "cancelAll clears the resume suppression")
    }

    // MARK: legacy direct seek

    func testLegacyDirectSeekTogglesIsSeeking() async {
        let (sut, _, engine, controls) = makeSUT()
        await sut.seek(to: 77)
        XCTAssertFalse(controls.isSeeking, "isSeeking must be cleared after the awaited seek returns")
        XCTAssertEqual(engine.lastSeekTarget, 77)
        XCTAssertEqual(controls.currentSeconds, 77)
        XCTAssertEqual(controls.pendingSeekTarget, 77)
    }
}

#if canImport(UIKit)
@MainActor
final class PlayerScrubInputTests: XCTestCase {
    func testInstalledPanRoutesTapWithoutCompetingTouchRecognizers() throws {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        let recognizers = controller.view.gestureRecognizers ?? []
        let pan = try XCTUnwrap(recognizers.compactMap { $0 as? PlayerSurfacePanGestureRecognizer }.first)
        let tap = try XCTUnwrap(pan.onStationaryTap)
        tap()
        XCTAssertFalse(model.timelineClock.isEnabled)
        XCTAssertTrue(model.controlsVisible)
        tap()
        XCTAssertTrue(model.timelineClock.isEnabled)
        tap()
        XCTAssertFalse(model.controlsVisible)
        #if os(tvOS)
        XCTAssertTrue(model.timelineClock.isEnabled, "The outgoing clock labels must survive the fade.")
        #else
        XCTAssertFalse(model.timelineClock.isEnabled)
        #endif
        XCTAssertTrue(recorder.targets.isEmpty)
        XCTAssertTrue(recognizers.compactMap { $0 as? UITapGestureRecognizer }.allSatisfy {
            $0.allowedTouchTypes.isEmpty
        }, "Touch taps must not install a recognizer that can delay the existing pan.")
    }

    func testLightTapsCycleControlsThenClockThenHiddenWithoutPausingOrSeeking() {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        model.isPaused = false
        controller.handleSurfaceTap()
        XCTAssertTrue(model.controlsVisible)
        XCTAssertFalse(model.timelineClock.isEnabled)
        XCTAssertFalse(model.isPaused)
        XCTAssertTrue(recorder.targets.isEmpty)
        controller.handleSurfaceTap()
        XCTAssertTrue(model.timelineClock.isEnabled)
        XCTAssertTrue(model.controlsVisible)
        controller.handleSurfaceTap()
        #if os(tvOS)
        XCTAssertTrue(model.timelineClock.isEnabled, "The third tap only fades the current labels.")
        #else
        XCTAssertFalse(model.timelineClock.isEnabled)
        #endif
        XCTAssertFalse(model.controlsVisible)
        controller.handleSurfaceTap()
        XCTAssertTrue(model.controlsVisible)
        XCTAssertFalse(model.timelineClock.isEnabled)
        XCTAssertFalse(model.isPaused)
    }

    func testClockModeDoesNotDelayFirstScrubSampleOrAllowTapDuringTraversal() {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        controller.handleSurfaceTap()
        controller.handleSurfaceTap()
        let gesture = ScrubInputPan()
        gesture.phase = .began
        gesture.travel = CGPoint(x: 100, y: 0)
        controller.handlePan(gesture)
        XCTAssertTrue(model.isScrubbing)
        XCTAssertEqual(model.scrubSeconds, 100 + (100 - 18) * 0.18, accuracy: 0.001)
        XCTAssertTrue(recorder.targets.isEmpty)
        controller.handleSurfaceTap()
        XCTAssertTrue(model.timelineClock.isEnabled, "A tap cannot change mode during a flick-bridged scrub.")
        gesture.phase = .ended
        controller.handlePan(gesture)
        XCTAssertEqual(recorder.targets.count, 1)
        XCTAssertFalse(model.isScrubbing)
    }

    func testBeganSampleMovesPreviewWhileAnEarlierSeekIsPending() {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        model.isSeeking = true
        let gesture = ScrubInputPan()
        gesture.phase = .began
        gesture.travel = CGPoint(x: 500, y: 0)
        controller.handlePan(gesture)
        XCTAssertTrue(model.isScrubbing)
        XCTAssertTrue(model.isSeeking)
        XCTAssertEqual(model.scrubSeconds, 100 + (500 - 18) * 0.18, accuracy: 0.001)
        XCTAssertTrue(recorder.targets.isEmpty, "Moving the preview must not commit a seek.")
    }

    func testShortPanWithoutChangedEventStillMovesAndCommits() {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        let gesture = ScrubInputPan()
        gesture.phase = .began
        gesture.travel = CGPoint(x: 10, y: 0)
        controller.handlePan(gesture)
        XCTAssertFalse(model.isScrubbing)
        gesture.phase = .ended
        gesture.travel = CGPoint(x: 100, y: 0)
        controller.handlePan(gesture)
        XCTAssertEqual(recorder.targets.count, 1)
        XCTAssertEqual(recorder.targets.first ?? -1, 100 + (100 - 18) * 0.18, accuracy: 0.001)
        XCTAssertFalse(model.isScrubbing)
    }

    func testEndedSampleIncludesTravelSinceTheLastChangedEvent() {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        let gesture = ScrubInputPan()
        gesture.phase = .began
        gesture.travel = CGPoint(x: 20, y: 0)
        controller.handlePan(gesture)
        gesture.phase = .changed
        gesture.travel = CGPoint(x: 40, y: 0)
        controller.handlePan(gesture)
        gesture.phase = .ended
        gesture.travel = CGPoint(x: 100, y: 0)
        controller.handlePan(gesture)
        XCTAssertEqual(recorder.targets.first ?? -1, 100 + (100 - 18) * 0.18, accuracy: 0.001)
        XCTAssertFalse(model.isScrubbing)
    }

    func testCancellationDoesNotApplyUncommittedTerminalTravel() {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        let gesture = ScrubInputPan()
        gesture.phase = .began
        gesture.travel = CGPoint(x: 40, y: 0)
        controller.handlePan(gesture)
        let preview = model.scrubSeconds
        gesture.phase = .cancelled
        gesture.travel = CGPoint(x: 1000, y: 0)
        controller.handlePan(gesture)
        XCTAssertEqual(recorder.targets, [preview])
    }

    func testFollowUpPanSuspendsFlickCommitBeforeAxisLock() async throws {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        let gesture = ScrubInputPan()
        gesture.phase = .began
        gesture.travel = CGPoint(x: 50, y: 0)
        gesture.speed = CGPoint(x: 2000, y: 0)
        controller.handlePan(gesture)
        gesture.phase = .ended
        controller.handlePan(gesture)
        XCTAssertTrue(model.isScrubbing)
        gesture.phase = .began
        gesture.travel = CGPoint(x: 5, y: 0)
        gesture.speed = .zero
        controller.handlePan(gesture)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(recorder.targets.isEmpty)
        XCTAssertTrue(model.isScrubbing)
        gesture.phase = .ended
        gesture.travel = CGPoint(x: 60, y: 0)
        controller.handlePan(gesture)
        XCTAssertEqual(recorder.targets.count, 1)
        XCTAssertEqual(recorder.targets.first, model.scrubSeconds)
    }

    func testTinyFollowUpPanRestartsCommitAfterLift() async throws {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        let gesture = ScrubInputPan()
        gesture.phase = .began
        gesture.travel = CGPoint(x: 50, y: 0)
        gesture.speed = CGPoint(x: 2000, y: 0)
        controller.handlePan(gesture)
        gesture.phase = .ended
        controller.handlePan(gesture)
        gesture.phase = .began
        gesture.travel = CGPoint(x: 5, y: 0)
        gesture.speed = .zero
        controller.handlePan(gesture)
        gesture.phase = .ended
        gesture.travel = CGPoint(x: 10, y: 0)
        controller.handlePan(gesture)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(recorder.targets.count, 1)
        XCTAssertFalse(model.isScrubbing)
    }

    func testRightSwipeWithDownwardFirstSampleScrubsWithoutOpeningInfo() {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        let gesture = ScrubInputPan()
        gesture.phase = .began
        gesture.travel = CGPoint(x: 8, y: 20)
        controller.handlePan(gesture)
        gesture.phase = .changed
        gesture.travel = CGPoint(x: 60, y: 26)
        controller.handlePan(gesture)
        XCTAssertFalse(model.controlBarVisible)
        XCTAssertTrue(model.isScrubbing)
        XCTAssertEqual(model.scrubSeconds, 100 + (60 - 18) * 0.18, accuracy: 0.001)
        XCTAssertTrue(recorder.targets.isEmpty)
    }

    func testDeliberateSwipeDownStillOpensInfo() {
        let (controller, model, _) = makeInput()
        defer { controller.viewDidDisappear(false) }
        let gesture = ScrubInputPan()
        gesture.phase = .began
        gesture.travel = CGPoint(x: 2, y: 20)
        controller.handlePan(gesture)
        XCTAssertFalse(model.controlBarVisible)
        gesture.phase = .changed
        gesture.travel = CGPoint(x: 4, y: 80)
        controller.handlePan(gesture)
        XCTAssertTrue(model.controlBarVisible)
        XCTAssertEqual(model.controlBar.entry, .info)
        XCTAssertFalse(model.isScrubbing)
    }

    func testHoldStartsPreviewAndReleaseKeepsScanningWithoutSeeking() {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        model.isPaused = false
        let hold = ScrubInputHold()
        hold.allowedPressTypes = [NSNumber(value: UIPress.PressType.rightArrow.rawValue)]
        hold.phase = .began
        controller.handleSeekHold(hold)
        XCTAssertTrue(model.isScrubbing)
        XCTAssertTrue(model.isPaused)
        XCTAssertTrue(model.controlsVisible)
        XCTAssertEqual(model.skipGesture.scanLevel, 1)
        hold.phase = .ended
        controller.handleSeekHold(hold)
        controller.advanceRemoteScan(elapsed: 1)
        XCTAssertEqual(model.scrubSeconds, 108)
        XCTAssertTrue(recorder.targets.isEmpty)
        controller.handleRight()
        XCTAssertEqual(model.skipGesture.scanLevel, 2)
        controller.advanceRemoteScan(elapsed: 1)
        XCTAssertEqual(model.scrubSeconds, 132)
        controller.handleLeft()
        XCTAssertEqual(model.skipGesture.scanLevel, 1)
        controller.handleLeft()
        XCTAssertEqual(model.skipGesture.scanLevel, -1)
        controller.advanceRemoteScan(elapsed: 1)
        XCTAssertEqual(model.scrubSeconds, 124)
        controller.handleSelect()
        XCTAssertEqual(recorder.targets, [124])
        XCTAssertFalse(model.isScrubbing)
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.skipGesture.scanLevel, 0)
    }

    func testRealScanTimerKeepsDeliveringThumbnailsThroughEverySpeed() async throws {
        for forward in [false, true] {
            let (controller, model, recorder) = makeInput()
            defer { controller.viewDidDisappear(false) }
            model.currentSeconds = 3_600
            let extractor = PacedScrubExtractor(delay: .milliseconds(80))
            controller.configureScrubPreview(nil, authenticatedHTTPResolver: nil, generatedStills: extractor)
            let hold = ScrubInputHold()
            hold.allowedPressTypes = [NSNumber(value: (forward
                ? UIPress.PressType.rightArrow : .leftArrow).rawValue)]
            hold.phase = .began
            controller.handleSeekHold(hold)
            hold.phase = .ended
            controller.handleSeekHold(hold)
            for level in 1...8 {
                if level > 1 {
                    if forward { controller.handleRight() } else { controller.handleLeft() }
                }
                let before = extractor.completions
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertEqual(model.skipGesture.scanLevel, forward ? level : -level)
                XCTAssertGreaterThan(extractor.completions, before, "Level \(level) must deliver during motion.")
                XCTAssertNotNil(model.previewImage)
                XCTAssertTrue(recorder.targets.isEmpty, "Scanning must not repeatedly seek the playback engine.")
            }
            let target = model.scrubSeconds
            controller.handleSelect()
            XCTAssertEqual(recorder.targets, [target])
            XCTAssertFalse(model.isScrubbing)
            XCTAssertNil(model.previewImage)
            XCTAssertEqual(extractor.maxInFlight, 1)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(extractor.inFlight, 0)
        }
    }

    func testScanSelectPreservesPauseAndPlayPauseResumes() {
        for playPause in [false, true] {
            let (controller, model, recorder) = makeInput()
            defer { controller.viewDidDisappear(false) }
            controller.advanceRemoteScan(forward: false)
            controller.advanceRemoteScan(elapsed: 1)
            if playPause { controller.handlePlayPause() } else { controller.handleSelect() }
            XCTAssertEqual(recorder.targets, [92])
            XCTAssertEqual(model.isPaused, !playPause)
            XCTAssertFalse(model.isScrubbing)
            XCTAssertEqual(model.skipGesture.scanLevel, 0)
        }
    }

    func testScanPlayPauseDoesNotPauseAnOriginallyPlayingSession() {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        model.isPaused = false
        controller.advanceRemoteScan(forward: true)
        controller.advanceRemoteScan(elapsed: 1)
        controller.handlePlayPause()
        XCTAssertEqual(recorder.targets, [108])
        XCTAssertFalse(model.isPaused)
    }

    func testScanCancellationRestoresPlaybackWithoutSeeking() {
        for interruption in [false, true] {
            let (controller, model, recorder) = makeInput()
            defer { controller.viewDidDisappear(false) }
            model.isPaused = false
            controller.advanceRemoteScan(forward: false)
            controller.advanceRemoteScan(elapsed: 1)
            if interruption { controller.interruptRemoteScan() } else { controller.handleMenu() }
            controller.advanceRemoteScan(elapsed: 10)
            XCTAssertTrue(recorder.targets.isEmpty)
            XCTAssertEqual(model.currentSeconds, 100)
            XCTAssertFalse(model.isPaused)
            XCTAssertFalse(model.isScrubbing)
            XCTAssertEqual(model.skipGesture.scanLevel, 0)
        }
    }

    func testScanStopsAtBoundaryAndCanReverseWithoutLosingPosition() {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        controller.advanceRemoteScan(forward: false)
        controller.advanceRemoteScan(elapsed: 20)
        XCTAssertEqual(model.scrubSeconds, 0)
        XCTAssertEqual(model.skipGesture.scanLevel, 0)
        XCTAssertTrue(model.isScrubbing)
        XCTAssertTrue(recorder.targets.isEmpty)
        controller.handleRight()
        controller.advanceRemoteScan(elapsed: 1)
        XCTAssertEqual(model.scrubSeconds, 8)
        controller.handleSelect()
        XCTAssertEqual(recorder.targets, [8])
    }

    func testScanBeginsAtLatestPendingSeekAndCancelsFlickCommit() async throws {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        model.pendingSeekTarget = 300
        let pan = ScrubInputPan()
        pan.phase = .began
        pan.travel = CGPoint(x: 50, y: 0)
        pan.speed = CGPoint(x: 2000, y: 0)
        controller.handlePan(pan)
        XCTAssertGreaterThan(model.scrubSeconds, 300)
        pan.phase = .ended
        controller.handlePan(pan)
        let preview = model.scrubSeconds
        controller.advanceRemoteScan(forward: true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.isScrubbing)
        XCTAssertGreaterThan(model.scrubSeconds, preview)
        XCTAssertTrue(recorder.targets.isEmpty)
    }

    func testHorizontalSwipeTakesOverFromScanAndCommitsOnLift() {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        controller.advanceRemoteScan(forward: true)
        controller.advanceRemoteScan(elapsed: 1)
        let pan = ScrubInputPan()
        pan.phase = .began
        pan.travel = CGPoint(x: 50, y: 0)
        controller.handlePan(pan)
        XCTAssertEqual(model.skipGesture.scanLevel, 0)
        pan.phase = .ended
        controller.handlePan(pan)
        XCTAssertFalse(model.isScrubbing)
        XCTAssertEqual(recorder.targets.count, 1)
        XCTAssertGreaterThan(recorder.targets[0], 108)
    }

    func testStationaryContactDoesNotCommitAnActiveScan() async throws {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        controller.advanceRemoteScan(forward: true)
        let pan = ScrubInputPan()
        pan.phase = .began
        controller.handlePan(pan)
        pan.phase = .ended
        controller.handlePan(pan)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.isScrubbing)
        XCTAssertTrue(recorder.targets.isEmpty)
    }

    func testShortClicksStillSkipAndInvalidDurationCannotScan() {
        let (controller, model, recorder) = makeInput()
        defer { controller.viewDidDisappear(false) }
        controller.handleRight()
        controller.handleLeft()
        XCTAssertEqual(recorder.targets, [110, 100])
        XCTAssertFalse(model.isScrubbing)
        for duration in [0, Double.infinity, Double.nan] {
            model.duration = duration
            controller.advanceRemoteScan(forward: true)
            XCTAssertFalse(model.isScrubbing)
            XCTAssertEqual(model.skipGesture.scanLevel, 0)
        }
    }

    #if os(tvOS)
    func testTouchpadEdgeHoldUsesTheSameScanAndCenterHoldDoesNot() throws {
        let (controller, model, _) = makeInput()
        defer { controller.viewDidDisappear(false) }
        let pan = try XCTUnwrap(controller.view.gestureRecognizers?.compactMap {
            $0 as? PlayerSurfacePanGestureRecognizer
        }.first)
        let holds = controller.view.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer } ?? []
        XCTAssertEqual(holds.count, 3)
        XCTAssertTrue(holds.allSatisfy { $0.minimumPressDuration == 0.4 && $0.allowedTouchTypes.isEmpty })
        let selectHold = try XCTUnwrap(holds.first {
            $0.allowedPressTypes.contains(NSNumber(value: UIPress.PressType.select.rawValue))
        })
        pan.click.selectBegan(position: nil)
        XCTAssertFalse(controller.gestureRecognizerShouldBegin(selectHold))
        pan.click.selectBegan(position: .init(x: -0.9, y: 0))
        XCTAssertTrue(controller.gestureRecognizerShouldBegin(selectHold))
        let hold = ScrubInputHold()
        hold.allowedPressTypes = selectHold.allowedPressTypes
        hold.phase = .began
        controller.handleSeekHold(hold)
        XCTAssertEqual(model.skipGesture.scanLevel, -1)
        XCTAssertTrue(pan.click.suppressesPan)
        hold.phase = .cancelled
        controller.handleSeekHold(hold)
        XCTAssertFalse(model.isScrubbing)
        XCTAssertEqual(model.skipGesture.scanLevel, 0)
    }
    #endif

    func testTeardownStopsTheScanTask() async throws {
        let (controller, model, recorder) = makeInput()
        controller.advanceRemoteScan(forward: true)
        controller.viewDidDisappear(false)
        let preview = model.scrubSeconds
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.scrubSeconds, preview)
        XCTAssertEqual(model.skipGesture.scanLevel, 0)
        XCTAssertTrue(recorder.targets.isEmpty)
    }

    private func makeInput() -> (PlayerInputViewController, PlayerControlsModel, ScrubInputRecorder) {
        let model = PlayerControlsModel()
        model.duration = 7200
        model.currentSeconds = 100
        model.isPaused = true
        let recorder = ScrubInputRecorder()
        let controller = PlayerInputViewController(
            engine: SeekSpyEngine(), model: model,
            actions: PlayerActions(
                seek: { recorder.targets.append($0); model.currentSeconds = $0 },
                togglePlayPause: { model.isPaused.toggle() }
            )
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return (controller, model, recorder)
    }
}

@MainActor
private final class ScrubInputRecorder {
    var targets: [TimeInterval] = []
}

private final class ScrubInputPan: UIPanGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    var travel: CGPoint = .zero
    var speed: CGPoint = .zero
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }

    override func translation(in view: UIView?) -> CGPoint { travel }
    override func velocity(in view: UIView?) -> CGPoint { speed }
}

private final class ScrubInputHold: UILongPressGestureRecognizer {
    var phase: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
}
#endif

// MARK: - Spies

private final class SeekTimeControlPlayer: AVPlayer, @unchecked Sendable {
    private let reportedStatus: AVPlayer.TimeControlStatus

    init(status: AVPlayer.TimeControlStatus) {
        reportedStatus = status
        super.init()
    }

    override var timeControlStatus: AVPlayer.TimeControlStatus { reportedStatus }
}

@MainActor
private final class SeekSpyHost: SeekScrubCoordinatorHost {
    private let engine: SeekSpyEngine
    var intendsPlaybackValue: Bool
    var didStopValue: Bool
    var onApplyPaused: (Bool) -> Void = { _ in }

    init(engine: SeekSpyEngine, intendsPlayback: Bool, didStop: Bool) {
        self.engine = engine
        self.intendsPlaybackValue = intendsPlayback
        self.didStopValue = didStop
    }

    var seekEngine: any VideoEngine { engine }
    var seekIntendsPlayback: Bool { intendsPlaybackValue }
    var seekDidStop: Bool { didStopValue }
    func seekApplyPaused(_ paused: Bool) { onApplyPaused(paused) }
}

@MainActor
private final class SeekSpyEngine: VideoEngine {
    struct SeekCall {
        let target: TimeInterval
        let kind: VideoSeekKind
    }

    let displayName = "seek-spy"
    var status: VideoEngineStatus = .idle
    var isPaused = false
    var preventsDisplaySleep = false
    var duration: TimeInterval = 1_000
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?

    var seekLog: [SeekCall] = []
    var lastSeekTarget: TimeInterval? { seekLog.last?.target }
    var playCount = 0
    var pauseCount = 0
    var nowPlayingPlayer: AVPlayer?

    /// When true, `currentTime` advances with wall-clock while playing, so the
    /// resume-confirm loop observes forward motion and resolves.
    var autoAdvance = false
    private var baseTime: TimeInterval = 0
    private var playStartedAt: Date?

    var currentTime: TimeInterval {
        if autoAdvance, !isPaused, let started = playStartedAt {
            return baseTime + Date().timeIntervalSince(started)
        }
        return baseTime
    }

    func startAdvancingClock() {
        autoAdvance = true
        playStartedAt = Date()
    }

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        status = .ready
        baseTime = startPosition
    }

    func play() {
        playCount += 1
        isPaused = false
        if autoAdvance { playStartedAt = Date() }
    }

    func pause() {
        pauseCount += 1
        baseTime = currentTime
        isPaused = true
        playStartedAt = nil
    }

    func reloadAfterForeground() async throws {}

    func seek(to seconds: TimeInterval) async {
        seekLog.append(SeekCall(target: seconds, kind: .exact))
        baseTime = seconds
        furthestObservedPosition = max(furthestObservedPosition, seconds)
    }

    func seek(to seconds: TimeInterval, kind: VideoSeekKind) async {
        seekLog.append(SeekCall(target: seconds, kind: kind))
        baseTime = seconds
        furthestObservedPosition = max(furthestObservedPosition, seconds)
    }

    func stop() {
        status = .idle
        duration = 0
    }

    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}

    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}
#endif
