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

    private actor UncancellableGate {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private let key = HTTPRequestCoalescer.Key(
        method: "GET", url: "https://example.test/Items", headers: "authorization=token"
    )

    func testOverlappingConsumersShareOneTransfer() async throws {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let key = key
        let first = Task {
            try await coalescer.perform(key: key) {
                _ = await counter.increment()
                for await _ in gate.stream {}
                return makeCoalescedPayload("shared")
            }
        }
        await waitForConsumers(1, in: coalescer, key: key)

        let second = Task {
            try await coalescer.perform(key: key) {
                _ = await counter.increment()
                return makeCoalescedPayload("should not run")
            }
        }
        await waitForConsumers(2, in: coalescer, key: key)
        gate.continuation.finish()
        let own = try await first.value
        let joined = try await second.value
        XCTAssertFalse(own.joined)
        XCTAssertTrue(joined.joined)
        XCTAssertEqual(own.payload.data, Data("shared".utf8))
        XCTAssertEqual(joined.payload.data, own.payload.data)
        let transfers = await counter.value
        XCTAssertEqual(transfers, 1)
    }

    func testURLAccountLaneAndRedirectPoliciesIsolateOverlappingTransfers() async throws {
        let variants = [
            HTTPRequestCoalescer.Key(method: "GET", url: "https://example.test/other", headers: "authorization=token"),
            HTTPRequestCoalescer.Key(method: "GET", url: key.url, headers: "authorization=other-token"),
            HTTPRequestCoalescer.Key(method: "GET", url: key.url, headers: key.headers, lane: "discovery"),
            HTTPRequestCoalescer.Key(
                method: "GET", url: key.url, headers: key.headers, redirectPolicy: .sameOrigin
            )
        ]
        for other in variants {
            let coalescer = HTTPRequestCoalescer()
            let gate = AsyncStream<Void>.makeStream()
            defer { gate.continuation.finish() }
            let key = key
            let first = Task {
                try await coalescer.perform(key: key) {
                    for await _ in gate.stream {}
                    return makeCoalescedPayload("original")
                }
            }
            await waitForConsumers(1, in: coalescer, key: key)
            let own = try await coalescer.perform(key: other) { makeCoalescedPayload("isolated") }
            XCTAssertFalse(own.joined)
            XCTAssertEqual(own.payload.data, Data("isolated".utf8))
            gate.continuation.finish()
            _ = try await first.value
        }
    }

    func testCancellingEitherConsumerFinishesPromptlyWithoutCancellingTheOther() async throws {
        for cancelOwner in [true, false] {
            let coalescer = HTTPRequestCoalescer()
            let gate = AsyncStream<Void>.makeStream()
            defer { gate.continuation.finish() }
            let key = key
            let first = Task {
                try await coalescer.perform(key: key) {
                    for await _ in gate.stream {}
                    try Task.checkCancellation()
                    return makeCoalescedPayload("survivor")
                }
            }
            await waitForConsumers(1, in: coalescer, key: key)
            let second = Task {
                try await coalescer.perform(key: key) { makeCoalescedPayload("unexpected") }
            }
            await waitForConsumers(2, in: coalescer, key: key)
            let cancelled = cancelOwner ? first : second
            let survivor = cancelOwner ? second : first
            let finished = expectation(description: "Cancelled waiter finishes while transfer is blocked")
            cancelled.cancel()
            let observer = Task {
                do {
                    _ = try await cancelled.value
                    XCTFail("Cancelled consumer must throw")
                } catch {
                    XCTAssertTrue(error is CancellationError)
                }
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 2)
            await waitForConsumers(1, in: coalescer, key: key)
            gate.continuation.finish()
            let result = try await survivor.value
            XCTAssertEqual(result.payload.data, Data("survivor".utf8))
            await observer.value
        }
    }

    func testLastConsumerCancellationStopsTransferAndAllowsImmediateReplacement() async throws {
        let coalescer = HTTPRequestCoalescer()
        let stopped = expectation(description: "Unused transfer cancelled")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let key = key
        let first = Task {
            try await coalescer.perform(key: key) {
                for await _ in gate.stream {}
                XCTAssertTrue(Task.isCancelled)
                stopped.fulfill()
                throw CancellationError()
            }
        }
        await waitForConsumers(1, in: coalescer, key: key)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Cancelled consumer must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        let replacement = try await coalescer.perform(key: key) { makeCoalescedPayload("fresh") }
        XCTAssertFalse(replacement.joined)
        XCTAssertEqual(replacement.payload.data, Data("fresh".utf8))
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testPrecancelledConsumerDoesNotStartTransfer() async {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()
        let key = key
        let first = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coalescer.perform(key: key) {
                _ = await counter.increment()
                return makeCoalescedPayload("unexpected")
            }
        }
        do {
            _ = try await first.value
            XCTFail("Cancelled consumer must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        let transfers = await counter.value
        XCTAssertEqual(transfers, 0)
    }

    func testLateCancelledTransferCannotCompleteItsStillRunningReplacement() async throws {
        let coalescer = HTTPRequestCoalescer()
        let oldGate = UncancellableGate()
        let replacementGate = AsyncStream<Void>.makeStream()
        defer { replacementGate.continuation.finish() }
        let oldFinished = expectation(description: "Old operation ignores cancellation and finishes late")
        let key = key
        let first = Task {
            try await coalescer.perform(key: key) {
                await oldGate.wait()
                oldFinished.fulfill()
                return makeCoalescedPayload("stale")
            }
        }
        await waitForConsumers(1, in: coalescer, key: key)
        first.cancel()
        _ = await first.result
        let replacement = Task {
            try await coalescer.perform(key: key) {
                for await _ in replacementGate.stream {}
                return makeCoalescedPayload("replacement")
            }
        }
        await waitForConsumers(1, in: coalescer, key: key)
        await oldGate.release()
        await fulfillment(of: [oldFinished], timeout: 2)
        let joined = Task {
            try await coalescer.perform(key: key) { makeCoalescedPayload("unexpected") }
        }
        await waitForConsumers(2, in: coalescer, key: key)
        replacementGate.continuation.finish()
        let ownerValue = try await replacement.value
        let joinedValue = try await joined.value
        XCTAssertEqual(ownerValue.payload.data, Data("replacement".utf8))
        XCTAssertEqual(joinedValue.payload.data, ownerValue.payload.data)
        XCTAssertTrue(joinedValue.joined)
    }

    func testCompletionCancellationRaceReleasesEntryExactlyOnce() async throws {
        let key = key
        for _ in 0..<100 {
            let coalescer = HTTPRequestCoalescer()
            let gate = AsyncStream<Void>.makeStream()
            let first = Task {
                try await coalescer.perform(key: key) {
                    for await _ in gate.stream {}
                    return makeCoalescedPayload("racing")
                }
            }
            await waitForConsumers(1, in: coalescer, key: key)
            async let cancellation: Void = Task.detached { first.cancel() }.value
            gate.continuation.finish()
            _ = await first.result
            await cancellation
            let retry = try await coalescer.perform(key: key) { makeCoalescedPayload("new") }
            XCTAssertFalse(retry.joined)
            XCTAssertEqual(retry.payload.data, Data("new".utf8))
            let count = await coalescer.inFlightCount()
            XCTAssertEqual(count, 0)
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

        let retry = try await coalescer.perform(key: key) {
            makeCoalescedPayload("recovered")
        }
        XCTAssertFalse(retry.joined)
        XCTAssertEqual(retry.payload.data, Data("recovered".utf8))
    }

    private func waitForConsumers(
        _ count: Int, in coalescer: HTTPRequestCoalescer, key: HTTPRequestCoalescer.Key
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await coalescer.waiterCount(for: key) != count, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let actual = await coalescer.waiterCount(for: key)
        XCTAssertEqual(actual, count)
    }
}

final class NetworkLedgerTests: XCTestCase {
    func testLineIsContentFreeAndComposable() {
        let line = NetworkLedger.makeLine(
            method: "GET",
            path: "/Users/redacted/Items",
            status: 200,
            milliseconds: 123,
            bytes: 4567,
            coalesced: true,
            route: "continueWatching"
        )
        XCTAssertEqual(
            line,
            "GET path=/Users/redacted/Items status=200 ms=123 bytes=4567 coalesced=1 route=continueWatching"
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
            "ParentId=abc123,IncludeItemTypes=Episode,Limit=100,Ids=" + String(repeating: "f", count: 28) + "~"
        )
        XCTAssertFalse(summary.contains("secret"))
        XCTAssertFalse(summary.contains("api_key"))
    }

    func testFailureLineCarriesNetworkCode() {
        let line = NetworkLedger.makeLine(
            method: "GET",
            path: "/Users/redacted/Items",
            status: nil,
            milliseconds: 90,
            bytes: 0,
            coalesced: false,
            route: "itemDetail",
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
