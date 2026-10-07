import Foundation
import XCTest
@testable import FeatureSyncCloud

@MainActor
final class CloudSyncReloadStatusTests: XCTestCase {
    func testRepeatedFailuresKeepLatestDiagnosticWithoutAdvancingSuccessfulSyncTime() {
        let status = CloudSyncStatus()
        status.setPhase(.idle, syncedNow: true)
        let successfulSync = status.lastSyncedAt
        status.setPhase(.syncing)
        status.setError("First failure", diagnostic: "zone save")
        status.setError("Latest failure", diagnostic: "record save")
        XCTAssertEqual(status.lastSyncedAt, successfulSync)
        XCTAssertEqual(status.lastErrorMessage, "Latest failure")
        XCTAssertEqual(status.lastDiagnostic, "record save")
        status.setPhase(.idle, syncedNow: true)
        XCTAssertNil(status.lastErrorMessage)
        XCTAssertNil(status.lastDiagnostic)
    }

    func testRecoveryStaysBusyThroughIntermediateEnginePhasesAndRejectsDuplicateRequests() async {
        let status = CloudSyncStatus()
        let gate = ReloadGate()
        let started = expectation(description: "Reload started")
        let task = Task {
            await status.recover { await gate.run(started: started) }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(status.isRecovering)
        XCTAssertNil(status.recoveryResult)

        status.setPhase(.idle, syncedNow: true)
        XCTAssertTrue(status.isRecovering)
        let duplicate = await status.recover {
            XCTFail("An in-flight reload must not reset the sync engine again")
            return .failed
        }
        XCTAssertNil(duplicate)
        XCTAssertTrue(status.isRecovering)
        XCTAssertNil(status.recoveryResult)

        await gate.complete(.completed)
        await task.value
        XCTAssertFalse(status.isRecovering)
        XCTAssertEqual(status.recoveryResult, .completed)
    }

    func testEveryResultIsRetainedIndependentlyOfAutomaticSync() async {
        let status = CloudSyncStatus()
        XCTAssertNil(status.recoveryResult)
        for result in [CloudSyncRecoveryResult.completed, .failed, .unavailable, .interrupted] {
            let completed = await status.recover { result }
            XCTAssertEqual(completed, result)
            XCTAssertFalse(status.isRecovering)
            XCTAssertEqual(status.recoveryResult, result)
            status.setPhase(.syncing)
            status.setPhase(.idle, syncedNow: true)
            XCTAssertEqual(status.recoveryResult, result)
        }
    }

    func testRetryClearsPreviousResultUntilTheNewOperationCompletes() async {
        let status = CloudSyncStatus()
        await status.recover { .failed }
        let gate = ReloadGate()
        let started = expectation(description: "Retry started")
        let task = Task {
            await status.recover { await gate.run(started: started) }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(status.isRecovering)
        XCTAssertNil(status.recoveryResult)
        await gate.complete(.completed)
        await task.value
        XCTAssertEqual(status.recoveryResult, .completed)
    }
}

private actor ReloadGate {
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
