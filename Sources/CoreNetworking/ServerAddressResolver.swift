import Foundation
import Synchronization
import CoreModels
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Routes an already-authorized sign-in without changing its persistent identity.
/// Probes must be credential-free; approving an address belongs to onboarding.
public final class ServerAddressResolver: Sendable {
    public typealias Probe = @Sendable (URL) async throws -> Void

    private struct State {
        var addresses: [URL]
        var current: URL
        var confirmedAt: Date?
        var flight: Flight?
        var generation = UUID()
    }

    private struct Flight {
        let id: UUID
        let excluded: URL?
        let task: Task<URL, Error>
    }

    private let baseURL: URL
    public var addresses: [URL] { state.withLock { $0.addresses } }
    private let probe: Probe
    private let state: Mutex<State>

    public init(baseURL: URL, alternatives: [URL], probe: @escaping Probe) {
        var seen = Set<URL>()
        let addresses = ([baseURL] + alternatives).filter { seen.insert($0).inserted }
        self.baseURL = baseURL
        self.probe = probe
        state = Mutex(State(addresses: addresses, current: baseURL))
    }

    public var current: URL { state.withLock { $0.current } }
    public var confirmed: URL? {
        state.withLock { $0.confirmedAt == nil ? nil : $0.current }
    }

    public func reportFailure(_ address: URL) {
        state.withLock {
            if $0.current == address { $0.confirmedAt = nil }
        }
    }

    fileprivate func confirmSuccessfulRequest(_ address: URL) {
        state.withLock {
            if $0.current == address, $0.confirmedAt == nil { $0.confirmedAt = Date() }
        }
    }

    public func resolved(excluding failed: URL? = nil) async throws -> URL {
        while true {
            let generation = state.withLock { $0.generation }
            do {
                let result = try await resolveSnapshot(excluding: failed)
                guard state.withLock({ $0.generation == generation }) else { continue }
                return result
            } catch {
                try Task.checkCancellation()
                guard state.withLock({ $0.generation == generation }) else { continue }
                throw error
            }
        }
    }

    public func updateAlternatives(_ alternatives: [URL]) {
        var seen = Set<URL>()
        let addresses = ([baseURL] + alternatives).filter { seen.insert($0).inserted }
        let previous = state.withLock { state -> Task<URL, Error>? in
            guard state.addresses != addresses else { return nil }
            let previous = state.flight?.task
            state = State(addresses: addresses, current: baseURL)
            return previous
        }
        previous?.cancel()
    }

    private func resolveSnapshot(excluding failed: URL?) async throws -> URL {
        try Task.checkCancellation()
        let task = state.withLock { state -> Task<URL, Error> in
            if state.addresses.count == 1, failed == nil {
                return Task { self.baseURL }
            }
            if failed == nil, let confirmedAt = state.confirmedAt,
               Date().timeIntervalSince(confirmedAt) < 30 {
                let current = state.current
                return Task { current }
            }
            if let flight = state.flight, failed == nil || flight.excluded == failed {
                return flight.task
            }
            let id = UUID()
            let candidates = state.addresses.filter { $0 != failed }
            let flight = Task {
                do {
                    let selected = try await self.select(candidates)
                    self.state.withLock {
                        guard $0.flight?.id == id else { return }
                        $0.current = selected
                        $0.confirmedAt = Date()
                        $0.flight = nil
                    }
                    return selected
                } catch {
                    self.state.withLock {
                        if $0.flight?.id == id { $0.flight = nil }
                    }
                    throw error
                }
            }
            state.flight = Flight(id: id, excluded: failed, task: flight)
            return flight
        }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }

    private func select(_ candidates: [URL]) async throws -> URL {
        return try await withThrowingTaskGroup(of: URL?.self) { group in
            for address in candidates {
                group.addTask { [probe] in
                    do {
                        // Give a reachable LAN route a short head start, not a
                        // full timeout that would delay every remote connection.
                        if SourceLocalityClassifier.classify(url: address) != .local {
                            try await Task.sleep(for: .milliseconds(300))
                        }
                        try Task.checkCancellation()
                        try await HTTPResponseDiagnostics.$route.withValue(.serverDiscovery) {
                            try await probe(address)
                        }
                        return address
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        return nil
                    }
                }
            }
            while let result = try await group.next() {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            PlozzLog.networking.info("No approved server address is reachable")
            throw AppError.serverUnreachable
        }
    }

}

/// All API requests share the same selected route, including interactive reads.
/// Mutations are never replayed after an ambiguous transport failure.
public struct ServerAddressHTTPClient: HTTPClient {
    private let wrapped: any HTTPClient
    private let resolver: ServerAddressResolver

    public init(wrapped: any HTTPClient, resolver: ServerAddressResolver) {
        self.wrapped = wrapped
        self.resolver = resolver
    }

    public func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(endpoint, raw: false)
    }

    public func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await send(endpoint, raw: true)
    }

    private func send(_ endpoint: Endpoint, raw: Bool) async throws -> (Data, HTTPURLResponse) {
        var request = endpoint
        request.redirectPolicy = .sameOrigin
        let address: URL
        do {
            address = try await resolver.resolved()
        } catch {
            // Resolution sends no authenticated request. Preserve that proof
            // for one-time exchanges such as Silo's rotating refresh token.
            if request.reportsUndeliveredRequests {
                if let failure = error as? AppError { throw HTTPRequestNotSentError(underlying: failure) }
                if error is CancellationError { throw HTTPRequestNotSentError(underlying: .cancelled) }
            }
            throw error
        }
        do {
            return try await perform(request, baseURL: address, raw: raw)
        } catch {
            let underlying = (error as? HTTPRequestNotSentError)?.underlying ?? error as? AppError
            guard underlying == .serverUnreachable else { throw error }
            resolver.reportFailure(address)
            guard request.method == .get, request.allowsAutomaticAddressRetry else { throw error }
            let next = try await resolver.resolved(excluding: address)
            do {
                return try await perform(request, baseURL: next, raw: raw)
            } catch {
                let underlying = (error as? HTTPRequestNotSentError)?.underlying ?? error as? AppError
                if underlying == .serverUnreachable { resolver.reportFailure(next) }
                throw error
            }
        }
    }

    private func perform(_ endpoint: Endpoint, baseURL: URL, raw: Bool) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, HTTPURLResponse)
        if raw { result = try await wrapped.sendRaw(endpoint, baseURL: baseURL) }
        else { result = try await wrapped.send(endpoint, baseURL: baseURL) }
        if (200..<300).contains(result.1.statusCode) { resolver.confirmSuccessfulRequest(baseURL) }
        return result
    }
}
