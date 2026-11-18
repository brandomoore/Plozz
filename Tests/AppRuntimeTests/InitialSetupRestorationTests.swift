import XCTest
import CoreModels
@testable import AppRuntime

@MainActor
final class InitialSetupRestorationTests: XCTestCase {
    private func makeModel(now: @escaping () -> ContinuousClock.Instant = { .now }) -> InitialSetupRestoration {
        let suite = "InitialSetupRestorationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return InitialSetupRestoration(flag: SyncSetupFeatureFlag(defaults: defaults), now: now)
    }

    func testProgressRemainsUntilRestoreFinishes() async {
        let model = makeModel()
        let gate = RestorationGate()
        XCTAssertEqual(model.phase, .hidden)
        model.start { await gate.wait() }
        XCTAssertEqual(model.phase, .checking)
        await gate.waitUntilStarted()
        model.showProgress()
        XCTAssertEqual(model.phase, .restoring)
        gate.finish(true)
        await model.waitForCompletion()
        XCTAssertEqual(model.phase, .hidden)
    }

    func testFastRestoreNeverNeedsProgressAndCompletesWithoutMinimumDelay() async {
        let model = makeModel()
        var completions = 0
        model.start(operation: { true }, onRestored: { completions += 1 })
        XCTAssertEqual(model.phase, .checking)
        await model.waitForCompletion()
        XCTAssertEqual(model.phase, .hidden)
        model.showProgress()
        model.offerManualSetup()
        XCTAssertEqual(model.phase, .hidden)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(InitialSetupRestoration.progressDelay, .milliseconds(250))
        XCTAssertEqual(InitialSetupRestoration.inactivityDelay, .seconds(60))
    }

    func testFailureOffersRetryWithoutClaimingSuccess() async {
        let model = makeModel()
        model.start { false }
        await model.waitForCompletion()
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertTrue(model.needsRestoration)
        model.start { true }
        XCTAssertEqual(model.phase, .checking)
        await model.waitForCompletion()
        XCTAssertEqual(model.phase, .hidden)
        XCTAssertFalse(model.needsRestoration)
    }

    func testInterruptedInitialRestoreKeepsRoutingGatedOnRelaunch() async throws {
        let suite = "InitialRestorationRelaunch.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flag = SyncSetupFeatureFlag(defaults: defaults)
        flag.isEnabled = true
        let model = InitialSetupRestoration(flag: flag)
        model.start { false }
        await model.waitForCompletion()
        let relaunched = InitialSetupRestoration(flag: flag)
        XCTAssertEqual(relaunched.phase, .checking)
        XCTAssertTrue(relaunched.needsRestoration)
        relaunched.start { true }
        await relaunched.waitForCompletion()
        XCTAssertFalse(relaunched.needsRestoration)
        XCTAssertEqual(InitialSetupRestoration(flag: flag).phase, .hidden)
    }

    func testManualSetupWaitsForPauseAndLateRestorationBeforeReleasingRouting() async {
        let clock = RestorationClock()
        let model = makeModel(now: { clock.now })
        let gate = RestorationGate()
        let pause = RestorationGate()
        model.start(operation: {
            let result = await gate.wait()
            XCTAssertTrue(Task.isCancelled)
            return result
        }, onRestored: { XCTFail("Cancelled restore must not restart automatic sync") })
        await gate.waitUntilStarted()
        model.setUpManually(pause: { XCTFail("Manual setup is not offered before the slow threshold") })
        XCTAssertEqual(model.phase, .checking)
        clock.advance(.seconds(60))
        model.offerManualSetup()
        XCTAssertEqual(model.phase, .slow)
        var manualRoutingPrepared = false
        model.setUpManually(pause: { _ = await pause.wait() }, onReady: {
            manualRoutingPrepared = true
        })
        XCTAssertEqual(model.phase, .stopping)
        XCTAssertFalse(manualRoutingPrepared)
        XCTAssertTrue(model.isManualSetupPending)
        XCTAssertFalse(model.needsRestoration)
        XCTAssertFalse(model.resumeAfterManualSetup(for: "profile"))
        await pause.waitUntilStarted()
        gate.finish(true)
        XCTAssertEqual(model.phase, .stopping)
        pause.finish(true)
        await model.waitForManualSetup()
        XCTAssertEqual(model.phase, .hidden)
        XCTAssertTrue(manualRoutingPrepared)
        model.start { XCTFail("Manual setup must keep automatic restoration paused"); return true }
        XCTAssertFalse(model.resumeAfterManualSetup(for: "profile"), "Partial restoration is not manual completion")
        model.completeManualSetup(for: "profile")
        XCTAssertFalse(model.resumeAfterManualSetup(for: "another-profile"))
        XCTAssertTrue(model.resumeAfterManualSetup(for: "profile"))
        XCTAssertFalse(model.resumeAfterManualSetup(for: "profile"))
    }

    func testManualPauseSurvivesRelaunchWithoutChangingConsent() async throws {
        let suite = "RestorationRelaunch.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flag = SyncSetupFeatureFlag(defaults: defaults)
        flag.isEnabled = true
        let model = InitialSetupRestoration(flag: flag)
        model.start { false }
        await model.waitForCompletion()
        model.setUpManually(pause: {})
        await model.waitForManualSetup()
        XCTAssertTrue(flag.isEnabled)
        XCTAssertFalse(flag.allowsAutomaticSync)
        XCTAssertFalse(flag.allowsAutomaticSignInSync)
        let restarted = InitialSetupRestoration(flag: flag)
        XCTAssertTrue(restarted.isManualSetupPending)
        XCTAssertEqual(restarted.phase, .hidden)
        XCTAssertFalse(restarted.resumeAfterManualSetup(for: "profile"))
        restarted.completeManualSetup(for: "profile")
        let completed = InitialSetupRestoration(flag: flag)
        XCTAssertEqual(completed.completedManualSetupProfileID, "profile")
        XCTAssertFalse(completed.resumeAfterManualSetup(for: "another-profile"))
        XCTAssertTrue(completed.resumeAfterManualSetup(for: "profile"))
        XCTAssertTrue(flag.allowsAutomaticSync)
        XCTAssertTrue(flag.allowsAutomaticSignInSync)
    }

    func testCancellationCannotExposeAnOldCompletionOverANewAttempt() async {
        let model = makeModel()
        let gate = RestorationGate()
        let finished = expectation(description: "Old attempt finished")
        model.start {
            let result = await gate.wait()
            finished.fulfill()
            return result
        }
        await gate.waitUntilStarted()
        model.cancel()
        model.start { false }
        await model.waitForCompletion()
        gate.finish(true)
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(model.phase, .unavailable)
    }

    func testRepeatedStartCannotOverlapRestoration() async {
        let model = makeModel()
        let gate = RestorationGate()
        model.start { await gate.wait() }
        await gate.waitUntilStarted()
        model.start { XCTFail("Must not start a second cloud activation"); return false }
        gate.finish(true)
        await model.waitForCompletion()
        XCTAssertEqual(model.phase, .hidden)
    }

    func testActivityClearsOnCompletionAndCancellation() async {
        let model = makeModel()
        let gate = RestorationGate()
        model.start { await gate.wait() }
        await gate.waitUntilStarted()
        let report = model.activityReporter()
        report(.servers)
        gate.finish(true)
        await model.waitForCompletion()
        XCTAssertNil(model.activity)
        report(.liveTVSources)
        XCTAssertNil(model.activity)

        let cancelled = RestorationGate()
        model.start { await cancelled.wait() }
        await cancelled.waitUntilStarted()
        let cancelledReport = model.activityReporter()
        cancelledReport(.servers)
        model.cancel()
        XCTAssertNil(model.activity)
        cancelledReport(.liveTVSources)
        XCTAssertNil(model.activity)
        cancelled.finish(false)
    }

    func testActivityIsRealWorkAndStaleReportsCannotOverwriteRetryOrManualSetup() async {
        let clock = RestorationClock()
        let model = makeModel(now: { clock.now })
        model.start { false }
        let oldReport = model.activityReporter()
        await model.waitForCompletion()
        oldReport(.servers)
        XCTAssertNil(model.activity)

        let gate = RestorationGate()
        model.start { await gate.wait() }
        await gate.waitUntilStarted()
        XCTAssertEqual(model.activity, .checkingICloud)
        let report = model.activityReporter()
        report(.profilesAndSettings)
        model.showProgress()
        XCTAssertEqual(model.activity, .profilesAndSettings)
        report(.liveTVSources)
        oldReport(.servers)
        XCTAssertEqual(model.activity, .liveTVSources)
        clock.advance(.seconds(60))
        model.offerManualSetup()
        XCTAssertEqual(model.activity, .liveTVSources, "Slowness must retain the actual unfinished work")
        model.setUpManually(pause: {})
        report(.servers)
        XCTAssertNil(model.activity)
        gate.finish(true)
        await model.waitForManualSetup()
        report(.checkingICloud)
        XCTAssertNil(model.activity)
    }

    func testRecoveryRequiresSixtySecondsWithoutProgressNotTotalElapsedTime() async {
        let clock = RestorationClock()
        let model = makeModel(now: { clock.now })
        let gate = RestorationGate()
        model.start { await gate.wait() }
        await gate.waitUntilStarted()
        model.showProgress()
        let report = model.activityReporter()

        clock.advance(.seconds(8))
        model.offerManualSetup()
        XCTAssertEqual(model.phase, .restoring, "Ordinary restoration must not promote manual setup")
        for _ in 0..<4 {
            clock.advance(.seconds(40))
            report(.liveTVSources)
            model.offerManualSetup()
            XCTAssertEqual(model.phase, .restoring, "Repeated batches count even when the label stays the same")
        }
        clock.advance(.seconds(59))
        model.offerManualSetup()
        XCTAssertEqual(model.phase, .restoring)
        clock.advance(.seconds(1))
        model.offerManualSetup()
        XCTAssertEqual(model.phase, .slow)

        report(.liveTVSources)
        XCTAssertEqual(model.phase, .restoring, "New data hides the escape route without another user action")
        model.offerManualSetup()
        XCTAssertEqual(model.phase, .restoring, "An old queued deadline cannot override fresh progress")
        clock.advance(.seconds(59))
        model.recordProgress()
        clock.advance(.seconds(59))
        model.offerManualSetup()
        XCTAssertEqual(model.phase, .restoring, "Provider work resets the same inactivity window")
        clock.advance(.seconds(1))
        model.offerManualSetup()
        XCTAssertEqual(model.phase, .slow)
        gate.finish(true)
        await model.waitForCompletion()
        XCTAssertEqual(model.phase, .hidden)
    }

    func testRetryStartsANewInactivityWindowAndIgnoresOldProgress() async {
        let clock = RestorationClock()
        let model = makeModel(now: { clock.now })
        model.start { false }
        let staleReport = model.activityReporter()
        await model.waitForCompletion()
        XCTAssertEqual(model.phase, .unavailable, "Failure offers recovery immediately, without a timeout")
        clock.advance(.seconds(120))
        let gate = RestorationGate()
        model.start { await gate.wait() }
        await gate.waitUntilStarted()
        model.showProgress()
        model.offerManualSetup()
        XCTAssertEqual(model.phase, .restoring)
        clock.advance(.seconds(59))
        staleReport(.servers)
        clock.advance(.seconds(1))
        model.offerManualSetup()
        XCTAssertEqual(model.phase, .slow, "Stale progress must not postpone recovery for the retry")
        model.cancel()
        model.recordProgress()
        clock.advance(.seconds(60))
        model.offerManualSetup()
        XCTAssertEqual(model.phase, .hidden)
        gate.finish(false)
    }
}

@MainActor
private final class RestorationClock {
    var now = ContinuousClock.now
    func advance(_ duration: Duration) { now += duration }
}

@MainActor
private final class RestorationGate {
    private var result: CheckedContinuation<Bool, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func wait() async -> Bool {
        await withCheckedContinuation {
            result = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ value: Bool) {
        result?.resume(returning: value)
        result = nil
    }
}
