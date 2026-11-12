import XCTest
@testable import AppRuntime

@MainActor
final class InitialSetupRestorationTests: XCTestCase {
    func testProgressRemainsUntilRestoreFinishes() async {
        let model = InitialSetupRestoration()
        let gate = RestorationGate()
        XCTAssertEqual(model.phase, .hidden)
        model.start { await gate.wait() }
        XCTAssertEqual(model.phase, .restoring)
        await gate.waitUntilStarted()
        XCTAssertEqual(model.phase, .restoring)
        gate.finish(true)
        await model.waitForCompletion()
        XCTAssertEqual(model.phase, .hidden)
    }

    func testFailureOffersRetryWithoutClaimingSuccess() async {
        let model = InitialSetupRestoration()
        model.start { false }
        await model.waitForCompletion()
        XCTAssertEqual(model.phase, .unavailable)
        model.start { true }
        XCTAssertEqual(model.phase, .restoring)
        await model.waitForCompletion()
        XCTAssertEqual(model.phase, .hidden)
    }

    func testContinueDoesNotCancelSyncOrReopenAfterFailure() async {
        let model = InitialSetupRestoration()
        let gate = RestorationGate()
        var completed = false
        model.start {
            let result = await gate.wait()
            XCTAssertFalse(Task.isCancelled)
            completed = true
            return result
        }
        await gate.waitUntilStarted()
        model.dismiss()
        XCTAssertEqual(model.phase, .hidden)
        gate.finish(false)
        await model.waitForCompletion()
        XCTAssertTrue(completed)
        XCTAssertEqual(model.phase, .hidden)
    }

    func testRepeatedStartCannotOverlapRestoration() async {
        let model = InitialSetupRestoration()
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
