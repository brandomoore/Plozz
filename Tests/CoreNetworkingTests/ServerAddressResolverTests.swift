import Foundation
import XCTest
import CoreModels
@testable import CoreNetworking

final class ServerAddressResolverTests: XCTestCase {
    private let local = URL(string: "http://192.168.1.50:8096/local")!
    private let remote = URL(string: "https://media.test/remote")!

    func testReachableLANWinsAndConcurrentRequestsShareProbe() async throws {
        let probes = AddressRequests()
        let resolver = ServerAddressResolver(baseURL: remote, alternatives: [local]) { url in
            await probes.record(url)
        }
        async let first = resolver.resolved()
        async let second = resolver.resolved()
        let results = try await [first, second]
        XCTAssertEqual(results, [local, local])
        XCTAssertEqual(resolver.confirmed, local)
        let calls = await probes.urls
        XCTAssertEqual(calls, [local])
    }

    func testUnavailableLANFallsBackWithoutLosingSavedIdentity() async throws {
        let local = local
        let resolver = ServerAddressResolver(baseURL: remote, alternatives: [local]) { url in
            if url == local { throw AppError.serverUnreachable }
        }
        let selected = try await resolver.resolved()
        XCTAssertEqual(selected, remote)
        XCTAssertEqual(resolver.addresses, [remote, local])
    }

    func testNoReachableAddressThrowsAndDoesNotClaimReachability() async {
        let resolver = ServerAddressResolver(baseURL: remote, alternatives: [local]) { _ in
            throw AppError.serverUnreachable
        }
        do {
            _ = try await resolver.resolved()
            XCTFail("Offline is not a successful resolution")
        } catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        XCTAssertNil(resolver.confirmed)
    }

    func testDiscoveryFailuresAreNotMisattributedToTheInventoryRequest() async {
        let resolver = ServerAddressResolver(baseURL: remote, alternatives: [local]) { _ in
            HTTPResponseDiagnostics.recordTransportFailure(URLError(.cannotConnectToHost))
            throw AppError.serverUnreachable
        }
        let captured = await HTTPResponseDiagnostics.$route.withValue(.playbackInventory) {
            await HTTPResponseDiagnostics.capture { try await resolver.resolved() }
        }
        guard case .failure(let error) = captured.result else {
            return XCTFail("Unreachable addresses must remain a failure.")
        }
        XCTAssertEqual(error as? AppError, .serverUnreachable)
        XCTAssertEqual(captured.transport.map(\.route), [.serverDiscovery, .serverDiscovery])
    }

    func testReadRetriesAnotherAddressButMutationDoesNotReplay() async throws {
        for method in [HTTPMethod.get, .post, .delete, .patch] {
            let local = local
            let resolver = ServerAddressResolver(baseURL: remote, alternatives: [local]) { _ in }
            let transport = AddressTransport(failing: local)
            let client = ServerAddressHTTPClient(wrapped: transport, resolver: resolver)
            do {
                _ = try await client.send(Endpoint(method: method, path: "/request"), baseURL: remote)
                XCTAssertEqual(method, .get)
            } catch {
                XCTAssertNotEqual(method, .get)
                XCTAssertEqual(error as? AppError, .serverUnreachable)
                XCTAssertNil(resolver.confirmed)
            }
            let calls = await transport.calls
            XCTAssertEqual(calls.map(\.0), method == .get ? [local, remote] : [local])
            XCTAssertTrue(calls.allSatisfy { $0.1.redirectPolicy == .sameOrigin })
        }
    }

    func testAuthenticationAndCancellationDoNotTriggerFallback() async throws {
        for failure in [AppError.unauthorized, .cancelled] {
            let resolver = ServerAddressResolver(baseURL: remote, alternatives: [local]) { _ in }
            let transport = AddressTransport(failing: local, failure: failure)
            let client = ServerAddressHTTPClient(wrapped: transport, resolver: resolver)
            do {
                _ = try await client.send(Endpoint(path: "/request"), baseURL: remote)
                XCTFail("Must preserve the request failure")
            } catch { XCTAssertEqual(error as? AppError, failure) }
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testProbeCapableGETDoesNotReplayOnAnotherServerAddress() async {
        let resolver = ServerAddressResolver(baseURL: remote, alternatives: [local]) { _ in }
        let transport = AddressTransport(failing: local)
        let client = ServerAddressHTTPClient(wrapped: transport, resolver: resolver)
        do {
            _ = try await client.send(
                Endpoint(path: "/Items/movie/PlaybackInfo", allowsAutomaticAddressRetry: false),
                baseURL: remote
            )
            XCTFail("An ambiguous probe failure must reach the caller.")
        } catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.0), [local])
    }

    func testRetryDoesNotJoinSweepThatStillIncludesTheFailedAddress() async throws {
        let local = local
        let gate = HeldAddressProbe()
        let resolver = ServerAddressResolver(baseURL: local, alternatives: [remote]) { url in
            if url == local { await gate.hold() }
        }
        let first = Task { try await resolver.resolved() }
        await gate.waitUntilHeld()
        let completed = expectation(description: "Excluded-address retry finishes independently")
        let retry = Task {
            defer { completed.fulfill() }
            return try await resolver.resolved(excluding: local)
        }
        await fulfillment(of: [completed], timeout: 2)
        await gate.release()
        _ = try await first.value
        let selected = try await retry.value
        XCTAssertEqual(selected, remote)
        XCTAssertEqual(resolver.confirmed, remote)
    }

    func testCancelledWaiterDoesNotCancelAnotherCallersResolution() async throws {
        let gate = HeldAddressProbe()
        let local = local
        let resolver = ServerAddressResolver(baseURL: local, alternatives: [remote]) { url in
            if url == local { await gate.hold() }
            else { throw AppError.serverUnreachable }
        }
        let cancelled = Task { try await resolver.resolved() }
        await gate.waitUntilHeld()
        let survivor = Task { try await resolver.resolved() }
        cancelled.cancel()
        await gate.release()
        do { _ = try await cancelled.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        let selected = try await survivor.value
        XCTAssertEqual(selected, local)
    }

    func testRemovingAddressDuringProbeCannotPublishOrReturnTheRemovedRoute() async throws {
        let gate = HeldAddressProbe()
        let local = local
        let resolver = ServerAddressResolver(baseURL: remote, alternatives: [local]) { url in
            if url == local { await gate.hold() }
            else { throw AppError.serverUnreachable }
        }
        let resolving = Task { try await resolver.resolved() }
        await gate.waitUntilHeld()
        resolver.updateAlternatives([])
        await gate.release()
        let result = try await resolving.value
        XCTAssertEqual(result, remote)
        XCTAssertEqual(resolver.addresses, [remote])
        XCTAssertNil(resolver.confirmed)
    }
}

private actor HeldAddressProbe {
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation {
            pending = $0
            observer?.resume()
            observer = nil
        }
    }
    func waitUntilHeld() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { pending?.resume(); pending = nil }
}

private actor AddressRequests {
    var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

private actor AddressTransport: HTTPClient {
    let failing: URL
    let failure: AppError
    var calls: [(URL, Endpoint)] = []

    init(failing: URL, failure: AppError = .serverUnreachable) {
        self.failing = failing
        self.failure = failure
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        calls.append((baseURL, endpoint))
        if baseURL == failing { throw failure }
        return (Data(), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
