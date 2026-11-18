import Foundation
import XCTest
@testable import CoreNetworking

final class HTTPRequestCoalescerTests: XCTestCase {
    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private let key = HTTPRequestCoalescer.Key(
        method: "GET", url: "https://example.test/Items", headers: "authorization=token"
    )

    func testAJoinerReceivesTheInFlightPayloadWithoutRunningItsOwnTransfer() async throws {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()
        let gate = TransferGate()
        let key = key
        let owner = Task {
            try await coalescer.perform(key: key) { try await gate.wait() }
        }
        try await waitUntil { await gate.started == 1 }
        let joiner = Task {
            try await coalescer.perform(key: key) {
                await counter.increment()
                return makePayload("should not run")
            }
        }
        try await waitUntil { await coalescer.waitingReaderCount() == 2 }
        await gate.release()
        let joined = try await joiner.value
        let original = try await owner.value
        XCTAssertFalse(original.joined)
        XCTAssertTrue(joined.joined)
        XCTAssertEqual(joined.payload.data, original.payload.data)
        let transfers = await counter.value
        XCTAssertEqual(transfers, 0)
    }

    func testDifferentURLsAccountsLanesAndRedirectPoliciesDoNotShare() async throws {
        let coalescer = HTTPRequestCoalescer()
        let gate = TransferGate()
        let keys = [
            key,
            .init(method: "GET", url: "https://example.test/other", headers: key.headers),
            .init(method: "GET", url: key.url, headers: "authorization=other-token"),
            .init(method: "GET", url: key.url, headers: key.headers, lane: "discovery"),
            .init(method: "GET", url: key.url, headers: key.headers, redirectPolicy: .sameOrigin)
        ]
        let tasks = keys.map { key in
            Task { try await coalescer.perform(key: key) { try await gate.wait() } }
        }
        try await waitUntil { await gate.started == keys.count }
        await gate.release()
        for task in tasks {
            let result = try await task.value
            XCTAssertFalse(result.joined)
        }
    }

    func testCancellingEitherReaderFinishesWithoutCancellingAnother() async throws {
        for cancelOwner in [true, false] {
            let coalescer = HTTPRequestCoalescer()
            let gate = TransferGate()
            let key = key
            let owner = Task {
                try await coalescer.perform(key: key) { try await gate.wait() }
            }
            try await waitUntil { await gate.started == 1 }
            let joiner = Task {
                try await coalescer.perform(key: key) { try await gate.wait() }
            }
            try await waitUntil { await coalescer.waitingReaderCount() == 2 }
            let cancelled = expectation(description: "Cancelled reader returns before transfer completion")
            let cancelledTask = cancelOwner ? owner : joiner
            let retainedTask = cancelOwner ? joiner : owner
            cancelledTask.cancel()
            let observer = Task {
                do { _ = try await cancelledTask.value; XCTFail("Cancelled reader succeeded") }
                catch { XCTAssertTrue(error is CancellationError) }
                cancelled.fulfill()
            }
            await fulfillment(of: [cancelled], timeout: 2)
            await gate.release()
            await observer.value
            let result = try await retainedTask.value
            XCTAssertEqual(result.joined, cancelOwner)
            let cancellations = await gate.cancellations
            XCTAssertEqual(cancellations, [false])
        }
    }

    func testLastCancellationRetiresWorkAndLateCompletionCannotRemoveReplacement() async throws {
        let coalescer = HTTPRequestCoalescer()
        let oldGate = TransferGate()
        let newGate = TransferGate()
        let key = key
        let old = Task {
            try await coalescer.perform(key: key) { try await oldGate.wait() }
        }
        try await waitUntil { await oldGate.started == 1 }
        old.cancel()
        try await waitUntil { await coalescer.inFlightCount() == 0 }
        do { _ = try await old.value; XCTFail("Cancelled reader succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let replacement = Task {
            try await coalescer.perform(key: key) { try await newGate.wait() }
        }
        try await waitUntil { await newGate.started == 1 }
        await oldGate.release()
        try await waitUntil { await oldGate.cancellations == [true] }
        let joiner = Task {
            try await coalescer.perform(key: key) {
                XCTFail("Late completion removed the replacement")
                return makePayload("wrong")
            }
        }
        try await waitUntil { await coalescer.waitingReaderCount() == 2 }
        await newGate.release()
        let values = try await [replacement.value, joiner.value]
        XCTAssertEqual(values.map(\.joined), [false, true])
    }

    func testAlreadyCancelledReaderDoesNotStartATransfer() async throws {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()
        let key = key
        let reader = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coalescer.perform(key: key) {
                await counter.increment()
                return makePayload("unexpected")
            }
        }
        do { _ = try await reader.value; XCTFail("Cancelled reader succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let transfers = await counter.value
        let inFlight = await coalescer.inFlightCount()
        XCTAssertEqual(transfers, 0)
        XCTAssertEqual(inFlight, 0)
    }

    func testCompletionCancellationRaceReleasesEntryExactlyOnce() async throws {
        let key = key
        for _ in 0..<100 {
            let coalescer = HTTPRequestCoalescer()
            let gate = AsyncStream<Void>.makeStream()
            defer { gate.continuation.finish() }
            let first = Task {
                try await coalescer.perform(key: key) {
                    for await _ in gate.stream {}
                    return makePayload("racing")
                }
            }
            try await waitUntil { await coalescer.waitingReaderCount() == 1 }
            async let cancellation: Void = Task.detached { first.cancel() }.value
            gate.continuation.finish()
            _ = await first.result
            await cancellation
            let retry = try await coalescer.perform(key: key) { makePayload("new") }
            XCTAssertFalse(retry.joined)
            XCTAssertEqual(retry.payload.data, Data("new".utf8))
            let count = await coalescer.inFlightCount()
            XCTAssertEqual(count, 0)
        }
    }

    func testCompletedAndFailedKeysAreReleasedForFreshRequests() async throws {
        let coalescer = HTTPRequestCoalescer()
        _ = try await coalescer.perform(key: key) { makePayload("one") }
        do {
            _ = try await coalescer.perform(key: key) { throw URLError(.timedOut) }
            XCTFail("The owner must surface the transport failure")
        } catch { XCTAssertTrue(error is URLError) }
        let retry = try await coalescer.perform(key: key) { makePayload("fresh") }
        XCTAssertFalse(retry.joined)
        XCTAssertEqual(retry.payload.data, Data("fresh".utf8))
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Controlled transfer did not reach the expected state")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private actor TransferGate {
        private(set) var started = 0
        private(set) var cancellations: [Bool] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async throws -> HTTPRequestCoalescer.Payload {
            started += 1
            await withCheckedContinuation { waiters.append($0) }
            cancellations.append(Task.isCancelled)
            return makePayload("transfer")
        }

        func release() {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }
}

private func makePayload(_ text: String) -> HTTPRequestCoalescer.Payload {
    HTTPRequestCoalescer.Payload(
        data: Data(text.utf8),
        response: URLResponse(
            url: URL(string: "https://example.test/Items")!, mimeType: "application/json",
            expectedContentLength: text.utf8.count, textEncodingName: nil
        )
    )
}
