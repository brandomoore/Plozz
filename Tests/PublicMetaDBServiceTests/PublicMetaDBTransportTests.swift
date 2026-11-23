import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import PublicMetaDBService
@testable import TestSupportNetworking

final class PublicMetaDBTransportTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testPrivateRequestsBoundResponseAndDisableCaching() async throws {
        let http = EndpointInspector()
        let api = try PublicMetaDBClient(key: "pm-" + String(repeating: "D", count: 60), http: http, gate: .init())
        try await api.deleteWatch(id: "exact-record")
        let endpoint = try XCTUnwrap(http.endpoint.get())
        XCTAssertEqual(endpoint.redirectPolicy, .sameOrigin)
        XCTAssertTrue(endpoint.redactsURLForLogging)
        XCTAssertTrue(endpoint.reportsUndeliveredRequests)
        XCTAssertEqual(endpoint.maximumResponseBytes, 8 * 1_024 * 1_024)
        XCTAssertEqual(endpoint.method, .delete)
    }

    func testMutationTransactionSerializesOtherClientsButAllowsReadOnlyRequests() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/watched/first", json: #"{"success":true}"#)
        http.stub(pathSuffix: "/watched/last", json: #"{"success":true}"#)
        http.stub(pathSuffix: "/watched/other", json: #"{"success":true}"#)
        http.stub(pathSuffix: "/lists", json: #"{"items":[],"total":0,"page":1,"perPage":100,"totalPages":0}"#)
        let gate = PublicMetaDBRequestGate()
        let first = try PublicMetaDBClient(key: "pm-" + String(repeating: "D", count: 60), http: http, gate: gate)
        let second = try PublicMetaDBClient(key: "pm-" + String(repeating: "D", count: 60), http: http, gate: gate)
        let entered = expectation(description: "Transaction entered")
        let readFinished = expectation(description: "Unrelated read remains available")
        let release = AsyncStream<Void>.makeStream()
        let transaction = Task {
            try await first.withMutationTransaction {
                try await first.deleteWatch(id: "first")
                entered.fulfill()
                for await _ in release.stream { break }
                try await first.deleteWatch(id: "last")
            }
        }
        defer { release.continuation.finish(); transaction.cancel() }
        await fulfillment(of: [entered], timeout: 5)
        let competing = Task { try await second.deleteWatch(id: "other") }
        let reader = Task {
            _ = try await second.lists()
            readFinished.fulfill()
        }
        defer { competing.cancel(); reader.cancel() }
        await fulfillment(of: [readFinished], timeout: 5)
        XCTAssertFalse(http.sentPaths.contains("/api/external/watched/other"))
        release.continuation.yield(())
        release.continuation.finish()
        try await transaction.value
        try await competing.value
        try await reader.value
        XCTAssertEqual(
            http.sentPaths.filter { $0.contains("/watched/") },
            ["/api/external/watched/first", "/api/external/watched/last", "/api/external/watched/other"]
        )
    }

    func testCancelledMutationWaiterNeverDispatchesAndDoesNotLeakTheLease() async throws {
        let http = RecordingHTTPClient()
        http.stub(pathSuffix: "/watched/after", json: #"{"success":true}"#)
        let client = try PublicMetaDBClient(
            key: "pm-" + String(repeating: "D", count: 60), http: http, gate: .init()
        )
        let release = AsyncStream<Void>.makeStream()
        let entered = expectation(description: "Mutation lease held")
        let holder = Task {
            try await client.withMutationTransaction {
                entered.fulfill()
                for await _ in release.stream { break }
            }
        }
        defer { release.continuation.finish(); holder.cancel() }
        await fulfillment(of: [entered], timeout: 5)
        let cancelled = Task { try await client.deleteWatch(id: "cancelled") }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancelled mutation dispatched") }
        catch { XCTAssertTrue(error is CancellationError) }
        release.continuation.finish()
        try await holder.value
        try await client.deleteWatch(id: "after")
        XCTAssertEqual(http.sentPaths, ["/api/external/watched/after"])
    }

    func testExplicitUndeliveredEvidenceDoesNotBecomeUncertain() async throws {
        let api = try PublicMetaDBClient(
            key: "pm-" + String(repeating: "D", count: 60), http: UndeliveredHTTPClient(), gate: .init()
        )
        do { try await api.deleteWatch(id: "play1"); XCTFail("Undelivered request succeeded") }
        catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
    }

    func testExactByteBudgetAndUnboundedLegacyBehavior() async throws {
        let session = URLSession(configuration: StubURLProtocol.makeEphemeralSession())
        defer { session.invalidateAndCancel() }
        let http = URLSessionHTTPClient(session: session)
        let url = try XCTUnwrap(URL(string: "https://example.test/bounded"))
        for (limit, count, succeeds) in [(Optional(4), 4, true), (4, 5, false), (nil, 5, true)] {
            StubURLProtocol.queue(.init(statusCode: 200, body: Data(repeating: 1, count: count)), for: url)
            var endpoint = Endpoint(path: "/bounded")
            endpoint.maximumResponseBytes = limit
            do {
                let (data, _) = try await http.sendRaw(endpoint, baseURL: try XCTUnwrap(URL(string: "https://example.test")))
                XCTAssertTrue(succeeds)
                XCTAssertEqual(data.count, count)
            } catch {
                XCTAssertFalse(succeeds)
                XCTAssertEqual(error as? AppError, .invalidResponse)
            }
        }
    }

    func testContentLengthOverBudgetIsRejected() async throws {
        let session = URLSession(configuration: StubURLProtocol.makeEphemeralSession())
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://example.test/large"))
        StubURLProtocol.queue(.init(statusCode: 200, headers: ["Content-Length": "1000"], body: Data([1])), for: url)
        var endpoint = Endpoint(path: "/large")
        endpoint.maximumResponseBytes = 4
        do {
            _ = try await URLSessionHTTPClient(session: session).sendRaw(endpoint, baseURL: try XCTUnwrap(URL(string: "https://example.test")))
            XCTFail("Oversized response accepted")
        } catch { XCTAssertEqual(error as? AppError, .invalidResponse) }
    }

    func testPathComponentsAreEncodedOnceByProductionTransport() async throws {
        let session = URLSession(configuration: StubURLProtocol.makeEphemeralSession())
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://publicmetadb.com/api/external/watched/r%C3%A9cord"))
        StubURLProtocol.queue(.init(statusCode: 200, body: Data(#"{"success":true}"#.utf8)), for: url)
        let api = try PublicMetaDBClient(
            key: "pm-" + String(repeating: "D", count: 60),
            http: URLSessionHTTPClient(session: session), gate: .init()
        )
        try await api.deleteWatch(id: "récord")
        XCTAssertEqual(StubURLProtocol.requests(for: url).count, 1)
    }
}

private struct EndpointInspector: HTTPClient {
    let endpoint = LockedValue<Endpoint?>(nil)
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        self.endpoint.set(endpoint)
        return (Data(#"{"success":true}"#.utf8), try XCTUnwrap(HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

private struct UndeliveredHTTPClient: HTTPClient {
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        throw HTTPRequestNotSentError(underlying: .serverUnreachable)
    }
}
