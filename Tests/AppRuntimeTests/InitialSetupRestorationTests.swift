import XCTest
import CoreModels
@testable import AppRuntime

@MainActor
final class InitialSetupRestorationTests: XCTestCase {
    private func makeModel() -> InitialSetupRestoration {
        let suite = "InitialSetupRestorationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return InitialSetupRestoration(flag: SyncSetupFeatureFlag(defaults: defaults))
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
        XCTAssertEqual(InitialSetupRestoration.manualSetupDelay, .seconds(8))
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
        let model = makeModel()
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
