import CoreUI
import FeatureSyncCloud
import XCTest
@testable import AppRuntime

@MainActor
final class CloudSyncRecoveryFeedbackTests: XCTestCase {
    func testBothActionsUseSharedProgressThenCompletionToast() async {
        for action in [CloudSyncRecoveryAction.reload, .reset] {
            let presenter = TransientStatusPresenter(announcement: { _ in })
            let status = CloudSyncStatus()
            let gate = RecoveryFeedbackGate()
            let started = expectation(description: "Recovery started")
            let task = Task {
                await CloudSyncRecoveryFeedback.run(action, status: status, presenter: presenter) {
                    await gate.run(started: started)
                }
            }
            await fulfillment(of: [started], timeout: 2)
            XCTAssertTrue(status.isRecovering)
            XCTAssertEqual(presenter.message?.isProgress, true)
            XCTAssertEqual(presenter.message?.text, action.progressMessage)
            XCTAssertEqual(presenter.message?.placement, .root)

            await CloudSyncRecoveryFeedback.run(.reset, status: status, presenter: presenter) {
                XCTFail("Reload and reset must not overlap")
                return .completed
            }
            XCTAssertEqual(presenter.message?.text, action.progressMessage)
            await gate.complete(.completed)
            await task.value
            XCTAssertFalse(status.isRecovering)
            XCTAssertEqual(presenter.message?.isProgress, false)
            XCTAssertEqual(presenter.message?.icon, "checkmark.circle")
            XCTAssertEqual(presenter.message?.text, action.message(for: .completed))
            presenter.dismiss()
        }
    }

    func testEveryFailureProducesWarningRatherThanSuccess() async {
        for action in [CloudSyncRecoveryAction.reload, .reset] {
            for result in [CloudSyncRecoveryResult.failed, .unavailable, .interrupted] {
                let presenter = TransientStatusPresenter(announcement: { _ in })
                let status = CloudSyncStatus()
                await CloudSyncRecoveryFeedback.run(action, status: status, presenter: presenter) { result }
                XCTAssertEqual(status.recoveryResult, result)
                XCTAssertFalse(status.isRecovering)
                XCTAssertEqual(presenter.message?.isProgress, false)
                XCTAssertEqual(presenter.message?.icon, "exclamationmark.triangle")
                XCTAssertEqual(presenter.message?.text, action.message(for: result))
                presenter.dismiss()
            }
        }
    }
}

private actor RecoveryFeedbackGate {
    private var continuation: CheckedContinuation<CloudSyncRecoveryResult, Never>?

    func run(started: XCTestExpectation) async -> CloudSyncRecoveryResult {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func complete(_ result: CloudSyncRecoveryResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
