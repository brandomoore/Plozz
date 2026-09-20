import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import SeerService
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Gates native status operations without observing task cancellation. Tests
/// explicitly release every gate, including requests retired by the service.
final class SeerDiscoveryStatusHTTPClient: HTTPClient, @unchecked Sendable {
    struct Request: Sendable {
        let id: Int
        let baseURL: URL
    }

    struct Snapshot {
        let requests: [Request]
        let active: Int
        let maximumActive: Int
    }

    private struct Signal {
        let count: Int
        let expectation: XCTestExpectation
    }

    private let lock = NSLock()
    private var requests: [Request] = []
    private var active = 0
    private var maximumActive = 0
    private var returns = 0
    private var startSignals: [Signal] = []
    private var returnSignals: [Signal] = []
    private var gates: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedIDs: Set<Int> = []
    private var allReleased = false
    private let failures: Set<Int>
    private let bodies: [Int: String]

    init(failures: Set<Int> = [], bodies: [Int: String] = [:]) {
        self.failures = failures
        self.bodies = bodies
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(requests: requests, active: active, maximumActive: maximumActive)
        }
    }

    func started(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(count) status operations started")
        let ready = lock.withLock {
            if requests.count >= count { return true }
            startSignals.append(Signal(count: count, expectation: expectation))
            return false
        }
        if ready { expectation.fulfill() }
        return expectation
    }

    func returned(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "\(count) native status operations returned")
        let ready = lock.withLock {
            if returns >= count { return true }
            returnSignals.append(Signal(count: count, expectation: expectation))
            return false
        }
        if ready { expectation.fulfill() }
        return expectation
    }

    func release(_ id: Int) {
        let continuations = lock.withLock {
            releasedIDs.insert(id)
            return gates.removeValue(forKey: id) ?? []
        }
        continuations.forEach { $0.resume() }
    }

    func releaseAll() {
        let continuations = lock.withLock {
            allReleased = true
            let continuations = gates.values.flatMap { $0 }
            gates = [:]
            return continuations
        }
        continuations.forEach { $0.resume() }
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        if endpoint.path == "/api/v1/status" {
            return (Data(#"{"version":"test"}"#.utf8), response)
        }
        guard let component = endpoint.path.split(separator: "/").last,
              let id = Int(component) else { throw AppError.notFound }
        await withCheckedContinuation { continuation in
            let (ready, signals) = lock.withLock {
                requests.append(Request(id: id, baseURL: baseURL))
                active += 1
                maximumActive = max(maximumActive, active)
                let ready = allReleased || releasedIDs.contains(id)
                if !ready { gates[id, default: []].append(continuation) }
                let signals = startSignals.filter { $0.count <= requests.count }
                startSignals.removeAll { $0.count <= requests.count }
                return (ready, signals)
            }
            signals.forEach { $0.expectation.fulfill() }
            if ready { continuation.resume() }
        }
        let signals = lock.withLock {
            active -= 1
            returns += 1
            let signals = returnSignals.filter { $0.count <= returns }
            returnSignals.removeAll { $0.count <= returns }
            return signals
        }
        signals.forEach { $0.expectation.fulfill() }
        if failures.contains(id) { throw AppError.serverUnreachable }
        let json = bodies[id] ?? #"{"mediaInfo":{"status":2}}"#
        return (Data(json.utf8), response)
    }
}

@MainActor
final class ObservedSeerStatusCall {
    let started = XCTestExpectation(description: "Status batch started")
    let finished = XCTestExpectation(description: "Status batch returned")
    private(set) var result: [MediaItem]?
    private var task: Task<Void, Never>?

    init(service: SeerService, items: [MediaItem]) {
        task = Task { [weak self] in
            self?.started.fulfill()
            let result = await service.availabilityUpdates(for: items)
            self?.result = result
            self?.finished.fulfill()
        }
    }

    func cancel() { task?.cancel() }
}
