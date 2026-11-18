import Foundation
import XCTest
@testable import FeatureSyncCloud

@MainActor
final class CloudSyncReloadStatusTests: XCTestCase {
    func testConcurrentWriteRetryShowsSyncingAndClearsOnlyAfterSuccess() async throws {
        let status = CloudSyncStatus()
        status.setPhase(.idle, syncedNow: true)
        let synced = status.lastSyncedAt
        status.setError("Concurrent write", diagnostic: "zone busy", retryGrace: .milliseconds(50))
        XCTAssertEqual(status.phase, .syncing)
        XCTAssertEqual(status.lastSyncedAt, synced)
        XCTAssertEqual(status.lastDiagnostic, "zone busy")
        status.setPhase(.idle, syncedNow: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(status.phase, .idle)
        XCTAssertNil(status.lastErrorMessage)
        XCTAssertNil(status.lastDiagnostic)
    }

    func testRepeatedRetryEventsDoNotHidePersistentFailuresIndefinitely() async throws {
        let status = CloudSyncStatus()
        status.setPhase(.idle)
        status.setError("Busy", diagnostic: "first", retryGrace: .milliseconds(50))
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            status.setError("Still busy", diagnostic: "latest", retryGrace: .milliseconds(50))
        }
        XCTAssertEqual(status.phase, .error)
        XCTAssertEqual(status.lastDiagnostic, "latest")
        XCTAssertNil(status.lastSyncedAt)
        status.setPhase(.disabled)
    }

    func testLocalDataFailureUsesReadableSummaryWithoutDiscardingTheDiagnostic() {
        let status = CloudSyncStatus()
        status.setPhase(.error)
        status.setError("Underlying error", diagnostic: "capture zone", reason: .localDataUnavailable)
        XCTAssertEqual(String(localized: status.summary),
                       "Some local data could not be prepared for sync. Saved data has not been removed.")
        XCTAssertEqual(status.lastDiagnostic, "capture zone")
    }

    func testTemporaryAccountSummaryPreservesDiagnosticsAndClearsAfterRecovery() {
        let status = CloudSyncStatus()
        status.setPhase(.error)
        status.setError("CKErrorDomain error 36", diagnostic: "Cloud account verification: 36",
                        reason: .accountTemporarilyUnavailable)
        XCTAssertEqual(String(localized: status.summary),
                       "iCloud is temporarily unavailable. Try again shortly.")
        XCTAssertEqual(status.lastErrorMessage, "CKErrorDomain error 36")
        XCTAssertEqual(status.lastDiagnostic, "Cloud account verification: 36")
        status.setError("Network unavailable", diagnostic: nil)
        XCTAssertNil(status.lastErrorReason)
        XCTAssertTrue(String(localized: status.summary).contains("Network unavailable"))
        status.setError("CKErrorDomain error 36", diagnostic: nil, reason: .accountTemporarilyUnavailable)
        status.setPhase(.idle, syncedNow: true)
        XCTAssertNil(status.lastErrorReason)
        XCTAssertNil(status.lastErrorMessage)
        XCTAssertNil(status.lastDiagnostic)
    }

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
