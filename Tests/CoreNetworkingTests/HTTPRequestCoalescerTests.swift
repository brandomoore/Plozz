import Foundation
import XCTest
@testable import CoreNetworking

final class HTTPRequestCoalescerTests: XCTestCase {
    private actor Counter {
        private(set) var value = 0

        func increment() -> Int {
            value += 1
            return value
        }
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
                _ = await counter.increment()
                return makeCoalescedPayload("should not run")
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
        XCTAssertEqual(transfers, 0, "The joined caller must not issue a second transfer")
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

    func testCancellingOneReaderFinishesPromptlyWithoutCancellingAnother() async throws {
        try await checkCancellation(cancelOwner: true)
        try await checkCancellation(cancelOwner: false)
    }

    private func checkCancellation(cancelOwner: Bool) async throws {
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
                return makeCoalescedPayload("wrong")
            }
        }
        try await waitUntil { await coalescer.waitingReaderCount() == 2 }
        await newGate.release()
        let values = try await [replacement.value, joiner.value]
        XCTAssertEqual(values.map(\.joined), [false, true])
    }

    func testAlreadyCancelledReaderDoesNotStartATransfer() async throws {
        let coalescer = HTTPRequestCoalescer()
        let gate = TransferGate()
        let counter = Counter()
        let key = key
        let reader = Task {
            _ = try await gate.wait()
            return try await coalescer.perform(key: key) {
                _ = await counter.increment()
                return makeCoalescedPayload("unexpected")
            }
        }
        try await waitUntil { await gate.started == 1 }
        reader.cancel()
        await gate.release()
        do { _ = try await reader.value; XCTFail("Cancelled reader succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let transfers = await counter.value
        let inFlight = await coalescer.inFlightCount()
        XCTAssertEqual(transfers, 0)
        XCTAssertEqual(inFlight, 0)
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
            return makeCoalescedPayload("transfer")
        }

        func release() {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    func testCompletedKeyIsReleasedForTheNextRequest() async throws {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()

        let first = try await coalescer.perform(key: key) {
            _ = await counter.increment()
            return makeCoalescedPayload("one")
        }
        XCTAssertFalse(first.joined)

        // A reload must not receive the finished transfer; it starts a new one.
        let second = try await coalescer.perform(key: key) {
            _ = await counter.increment()
            return makeCoalescedPayload("two")
        }
        XCTAssertFalse(second.joined)
        XCTAssertEqual(second.payload.data, Data("two".utf8))
        let transfers = await counter.value
        XCTAssertEqual(transfers, 2)
    }

    func testOwnerFailureIsRetryable() async throws {
        let coalescer = HTTPRequestCoalescer()
        do {
            _ = try await coalescer.perform(key: key) {
                throw URLError(.timedOut)
            }
            XCTFail("The owner must surface the transport failure")
        } catch {
            XCTAssertTrue(error is URLError)
        }

        // Cleanup is asynchronous; wait on the observable in-flight count
        // instead of assuming a fixed delay.
        for _ in 0..<200 where await coalescer.inFlightCount() > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let retry = try await coalescer.perform(key: key) {
            makeCoalescedPayload("recovered")
        }
        XCTAssertFalse(retry.joined)
        XCTAssertEqual(retry.payload.data, Data("recovered".utf8))
    }
}

final class NetworkLedgerTests: XCTestCase {
    func testLineIsContentFreeAndComposable() {
        let line = NetworkLedger.makeLine(
            method: .get,
            status: 200,
            milliseconds: 123,
            bytes: 4567,
            coalesced: true,
            route: .continueWatching
        )
        XCTAssertEqual(
            line,
            "GET status=200 ms=123 bytes=4567 coalesced=1 route=continueWatching"
        )
        XCTAssertFalse(line.contains("Authorization"))
        XCTAssertFalse(line.contains("token"))
    }

    func testQuerySummaryOnlyShowsShapeParameters() {
        let summary = NetworkLedger.querySummary([
            URLQueryItem(name: "ParentId", value: "abc123"),
            URLQueryItem(name: "IncludeItemTypes", value: "Episode"),
            URLQueryItem(name: "Limit", value: "100"),
            URLQueryItem(name: "api_key", value: "secret"),
            URLQueryItem(name: "Ids", value: String(repeating: "f", count: 60))
        ])
        XCTAssertEqual(
            summary,
            "ParentId=present,IncludeItemTypes=present,Limit=100,Ids=count:1"
        )
        XCTAssertFalse(summary.contains("secret"))
        XCTAssertFalse(summary.contains("api_key"))
        XCTAssertFalse(summary.contains("abc123"))
        XCTAssertFalse(summary.contains(String(repeating: "f", count: 28)))
    }

    func testFailureLineCarriesNetworkCode() {
        let line = NetworkLedger.makeLine(
            method: .get,
            status: nil,
            milliseconds: 90,
            bytes: 0,
            coalesced: false,
            route: .itemDetail,
            error: -1009
        )
        XCTAssertTrue(line.contains("status=-"))
        XCTAssertTrue(line.contains("error=-1009"))
        XCTAssertTrue(line.contains("coalesced=0"))
    }
}

private func makeCoalescedPayload(_ text: String) -> HTTPRequestCoalescer.Payload {
    HTTPRequestCoalescer.Payload(
        data: Data(text.utf8),
        response: URLResponse(
            url: URL(string: "https://example.test/Items")!,
            mimeType: "application/json",
            expectedContentLength: text.utf8.count,
            textEncodingName: nil
        )
    )
}
