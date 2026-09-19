import Foundation
import XCTest
@testable import CoreModels

final class ConcurrencyLimiterCancellationTests: XCTestCase {
    private actor Gate {
        private var entered = false
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var exitWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            if !released { await withCheckedContinuation { exitWaiters.append($0) } }
        }

        func waitForEntry() async {
            if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
        }

        func release() {
            released = true
            exitWaiters.forEach { $0.resume() }
            exitWaiters.removeAll()
        }
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    func testCancelledQueuedThrowingWorkLeavesBeforeTheOccupiedPermitIsReleased() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        let gate = Gate()
        let counter = Counter()
        let occupied = Task { await limiter.run { await gate.wait() } }
        await gate.waitForEntry()
        let returned = expectation(description: "Cancelled waiter leaves the queue")
        let queued = Task {
            defer { returned.fulfill() }
            return try await limiter.runUnlessCancelled { () async throws -> Int in
                await counter.increment()
                return 1
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while await limiter.pendingWaiterCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let before = await limiter.pendingWaiterCount
        XCTAssertEqual(before, 1)
        queued.cancel()
        await fulfillment(of: [returned], timeout: 2)
        let after = await limiter.pendingWaiterCount
        XCTAssertEqual(after, 0)
        await gate.release()
        await occupied.value
        do {
            _ = try await queued.value
            XCTFail("Cancelled queued work must not start.")
        } catch is CancellationError {}
        let invocations = await counter.value
        XCTAssertEqual(invocations, 0)
        let next = try await limiter.runUnlessCancelled { () async throws -> Int in 42 }
        XCTAssertEqual(next, 42)
    }

    func testAlreadyCancelledWorkDoesNotConsumeAnAvailablePermit() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        let gate = Gate()
        let counter = Counter()
        let task = Task {
            await gate.wait()
            return try await limiter.runUnlessCancelled { () async throws -> Int in
                await counter.increment()
                return 1
            }
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Already-cancelled work must not start.")
        } catch is CancellationError {}
        let invocations = await counter.value
        XCTAssertEqual(invocations, 0)
        let next = try await limiter.runUnlessCancelled { () async throws -> Int in 42 }
        XCTAssertEqual(next, 42)
    }

    func testThrowingWorkReleasesItsPermit() async throws {
        enum Failure: Error { case expected }
        let limiter = ConcurrencyLimiter(limit: 1)
        do {
            _ = try await limiter.runUnlessCancelled { () async throws -> Int in
                throw Failure.expected
            }
            XCTFail("Expected the operation's error.")
        } catch Failure.expected {}
        let next = try await limiter.runUnlessCancelled { () async throws -> Int in 42 }
        XCTAssertEqual(next, 42)
    }
}
