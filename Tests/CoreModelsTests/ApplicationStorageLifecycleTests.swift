import CoreModels
import XCTest

final class ApplicationStorageLifecycleTests: XCTestCase {
    func testSuspensionFencesAccessBeforeWaitingForOwnersAndForegroundDoesNotWait() async {
        let lifecycle = ApplicationStorageLifecycle()
        let entered = expectation(description: "Suspension entered owner")
        let barrier = StorageSuspensionBarrier()
        let owner = StorageParticipantProbe(lifecycle: lifecycle) {
            entered.fulfill()
            await barrier.wait()
        }
        lifecycle.register(owner)
        let suspension = Task { await lifecycle.setApplicationActive(false, revision: 1) }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertThrowsError(try lifecycle.checkAccess()) { XCTAssertTrue($0 is CancellationError) }
        let lateOwner = StorageParticipantProbe(lifecycle: lifecycle)
        lifecycle.register(lateOwner)
        XCTAssertThrowsError(try lifecycle.checkAccess())
        await lifecycle.setApplicationActive(true, revision: 2)
        XCTAssertNoThrow(try lifecycle.checkAccess())
        await barrier.release()
        await suspension.value
        let closes = await owner.closes
        XCTAssertEqual(closes, 0, "A stale cleanup must not close newly admitted foreground work.")
        await lifecycle.setApplicationActive(false, revision: 1)
        XCTAssertTrue(lifecycle.isActive)
    }

    func testExpirationCanRepeatTheSameSuspensionRevision() async {
        let lifecycle = ApplicationStorageLifecycle()
        let owner = StorageParticipantProbe(lifecycle: lifecycle)
        lifecycle.register(owner)
        await lifecycle.setApplicationActive(false, revision: 1)
        await lifecycle.setApplicationActive(false, revision: 1)
        let closes = await owner.closes
        XCTAssertEqual(closes, 2)
        await lifecycle.setApplicationActive(true, revision: 1)
        XCTAssertFalse(lifecycle.isActive, "Conflicting state at the same revision is stale.")
        await lifecycle.setApplicationActive(true, revision: 2)
        XCTAssertTrue(lifecycle.isActive)
    }

    func testRegistryDoesNotRetainRetiredStores() async {
        let lifecycle = ApplicationStorageLifecycle()
        var owner: StorageParticipantProbe? = StorageParticipantProbe(lifecycle: lifecycle)
        weak var weakOwner = owner
        if let owner { lifecycle.register(owner) }
        owner = nil
        XCTAssertNil(weakOwner)
        await lifecycle.setApplicationActive(false, revision: 1)
        XCTAssertFalse(lifecycle.isActive)
    }

    func testCancelledTransitionStillClosesStores() async {
        let lifecycle = ApplicationStorageLifecycle()
        let owner = StorageParticipantProbe(lifecycle: lifecycle)
        lifecycle.register(owner)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await lifecycle.setApplicationActive(false, revision: 1)
        }
        await operation.value
        let closes = await owner.closes
        XCTAssertEqual(closes, 1)
    }
}

private actor StorageParticipantProbe: ApplicationStorageParticipant {
    private let lifecycle: ApplicationStorageLifecycle
    private let beforeClose: @Sendable () async -> Void
    private(set) var closes = 0

    init(lifecycle: ApplicationStorageLifecycle, beforeClose: @escaping @Sendable () async -> Void = {}) {
        self.lifecycle = lifecycle
        self.beforeClose = beforeClose
    }

    func prepareForSuspension() async {
        await beforeClose()
        if !lifecycle.isActive { closes += 1 }
    }
}

private actor StorageSuspensionBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
