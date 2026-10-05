import Foundation
import XCTest
@testable import FeatureSyncCloud

@MainActor
final class CloudSyncReloadStatusTests: XCTestCase {
    func testReloadStaysBusyThroughIntermediateEnginePhasesAndRejectsDuplicateRequests() async {
        let status = CloudSyncStatus()
        let gate = ReloadGate()
        let started = expectation(description: "Reload started")
        let task = Task {
            await status.reload { await gate.run(started: started) }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(status.isReloading)
        XCTAssertNil(status.reloadResult)
        XCTAssertNotNil(status.reloadSummary)

        status.setPhase(.idle, syncedNow: true)
        XCTAssertTrue(status.isReloading)
        await status.reload {
            XCTFail("An in-flight reload must not reset the sync engine again")
            return .failed
        }
        XCTAssertTrue(status.isReloading)
        XCTAssertNil(status.reloadResult)

        await gate.complete(.completed)
        await task.value
        XCTAssertFalse(status.isReloading)
        XCTAssertEqual(status.reloadResult, .completed)
        XCTAssertNotNil(status.reloadSummary)
    }

    func testEveryResultIsRetainedIndependentlyOfAutomaticSync() async {
        let status = CloudSyncStatus()
        XCTAssertNil(status.reloadSummary)
        for result in [CloudSyncReloadResult.completed, .failed, .unavailable, .interrupted] {
            await status.reload { result }
            XCTAssertFalse(status.isReloading)
            XCTAssertEqual(status.reloadResult, result)
            status.setPhase(.syncing)
            status.setPhase(.idle, syncedNow: true)
            XCTAssertEqual(status.reloadResult, result)
            XCTAssertNotNil(status.reloadSummary)
        }
    }

    func testRetryClearsPreviousResultUntilTheNewOperationCompletes() async {
        let status = CloudSyncStatus()
        await status.reload { .failed }
        let gate = ReloadGate()
        let started = expectation(description: "Retry started")
        let task = Task {
            await status.reload { await gate.run(started: started) }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(status.isReloading)
        XCTAssertNil(status.reloadResult)
        await gate.complete(.completed)
        await task.value
        XCTAssertEqual(status.reloadResult, .completed)
    }
}

private actor ReloadGate {
    private var continuation: CheckedContinuation<CloudSyncReloadResult, Never>?

    func run(started: XCTestExpectation) async -> CloudSyncReloadResult {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func complete(_ result: CloudSyncReloadResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
