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

    /// Seeds an in-flight entry directly so the join path is deterministic:
    /// the test never races a real transfer to observe concurrency.
    private func seed(
        _ coalescer: HTTPRequestCoalescer,
        key: HTTPRequestCoalescer.Key
    ) async {
        let task = Task<HTTPRequestCoalescer.Payload, Error> { makeCoalescedPayload("seed") }
        await coalescer.seedForTesting(key: key, task: task)
    }

    func testAJoinerReceivesTheInFlightPayloadWithoutRunningItsOwnTransfer() async throws {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()
        await seed(coalescer, key: key)

        let joined = try await coalescer.perform(key: key) {
            _ = await counter.increment()
            return makeCoalescedPayload("should not run")
        }

        XCTAssertTrue(joined.joined)
        XCTAssertEqual(joined.payload.data, Data("seed".utf8))
        let transfers = await counter.value
        XCTAssertEqual(transfers, 0, "The joined caller must not issue a second transfer")
    }

    func testDifferentKeysDoNotShare() async throws {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()
        await seed(coalescer, key: key)

        let other = HTTPRequestCoalescer.Key(
            method: "GET", url: "https://example.test/other", headers: "authorization=token"
        )
        let own = try await coalescer.perform(key: other) {
            _ = await counter.increment()
            return makeCoalescedPayload("own")
        }

        XCTAssertFalse(own.joined)
        XCTAssertEqual(own.payload.data, Data("own".utf8))
        let transfers = await counter.value
        XCTAssertEqual(transfers, 1)
    }

    func testDifferentAuthorizationHeadersDoNotShare() async throws {
        // Multi-server safety: the same URL under two accounts must never share
        // a response, even when the lane and URL are identical.
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()
        await seed(coalescer, key: key)

        let otherAccount = HTTPRequestCoalescer.Key(
            method: "GET", url: "https://example.test/Items", headers: "authorization=other-token"
        )
        let own = try await coalescer.perform(key: otherAccount) {
            _ = await counter.increment()
            return makeCoalescedPayload("other")
        }

        XCTAssertFalse(own.joined)
        XCTAssertEqual(own.payload.data, Data("other".utf8))
        let transfers = await counter.value
        XCTAssertEqual(transfers, 1, "Different tokens must never share a response")
    }

    func testDifferentLanesDoNotShareEvenForTheSameURL() async throws {
        let coalescer = HTTPRequestCoalescer()
        let counter = Counter()
        await seed(
            coalescer,
            key: HTTPRequestCoalescer.Key(
                method: "GET", url: "https://example.test/same", headers: "", lane: "default"
            )
        )

        let discovery = HTTPRequestCoalescer.Key(
            method: "GET", url: "https://example.test/same", headers: "", lane: "discovery"
        )
        let own = try await coalescer.perform(key: discovery) {
            _ = await counter.increment()
            return makeCoalescedPayload("discovery")
        }

        XCTAssertFalse(own.joined)
        let transfers = await counter.value
        XCTAssertEqual(transfers, 1, "Lanes have different timeouts and pools")
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
