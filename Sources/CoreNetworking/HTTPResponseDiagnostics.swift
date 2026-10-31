import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Opt-in, task-scoped evidence; the provider's thrown errors and fallback behavior stay unchanged.
public enum HTTPResponseDiagnostics {
    public struct CapturedResult<Value: Sendable>: Sendable {
        public let result: Result<Value, Error>
        public let responses: [ResponseDecodingDiagnostic]
        public let paging: [LibraryPagingDiagnostic]
        public let transport: [ResponseTransportDiagnostic]
        public let http: [ResponseStatusDiagnostic]
        public let requests: [ResponseRequestDiagnostic]
        public let validation: [ResponseValidationDiagnostic]

        public var isCancelled: Bool {
            guard case .failure(let error) = result else { return false }
            let underlying = LibrarySourceFailure.underlying(error)
            return underlying is CancellationError || (underlying as? AppError) == .cancelled
        }
    }

    @TaskLocal private static var recorder: Recorder?
    @TaskLocal public static var route: ResponseDecodingDiagnostic.Route = .other

    public static var effectiveRoute: ResponseDecodingDiagnostic.Route {
        route == .other && SearchDiagnosticJournal.currentSource != nil ? .search : route
    }

    public static func capture<Value: Sendable>(
        retainingSuccessfulRequests: Bool = false,
        _ operation: @Sendable () async throws -> Value
    ) async -> CapturedResult<Value> {
        let recorder = Recorder()
        return await $recorder.withValue(recorder) {
            do {
                let value = try await operation()
                return CapturedResult(
                    result: .success(value), responses: [], paging: [], transport: [], http: [],
                    requests: retainingSuccessfulRequests ? recorder.snapshot().requests : [], validation: []
                )
            } catch {
                let evidence = recorder.snapshot()
                return CapturedResult(
                    result: .failure(error), responses: evidence.responses, paging: evidence.paging,
                    transport: evidence.transport, http: evidence.http,
                    requests: evidence.requests, validation: evidence.validation
                )
            }
        }
    }

    public static func recordPagingFailure(_ diagnostic: LibraryPagingDiagnostic) {
        recorder?.append(diagnostic)
    }

    public static var isCapturing: Bool { recorder != nil || SearchDiagnosticJournal.currentSource != nil }

    public static func recordRequest(_ diagnostic: ResponseRequestDiagnostic) {
        recorder?.append(diagnostic)
        SearchDiagnosticJournal.currentSource?.request(diagnostic)
    }

    public static func recordValidationFailure(
        _ reason: ResponseValidationDiagnostic.Reason,
        route: ResponseDecodingDiagnostic.Route, sourceCount: Int? = nil
    ) {
        recorder?.append(ResponseValidationDiagnostic(route: route, reason: reason, sourceCount: sourceCount))
    }

    public static func recordHTTPFailure(status: Int) {
        guard !(200...299).contains(status) else { return }
        let diagnostic = ResponseStatusDiagnostic(route: effectiveRoute, httpStatus: status)
        recorder?.append(diagnostic)
        SearchDiagnosticJournal.currentSource?.http(diagnostic)
    }

    public static func recordTransportFailure(_ error: URLError) {
        guard isCapturing, error.code != .cancelled else { return }
        let diagnostic = ResponseTransportDiagnostic(
            route: effectiveRoute, urlErrorCode: error.errorCode,
            underlying: Array(PlaybackFailureEvidence.ErrorCode.chain(error as NSError).dropFirst())
        )
        recorder?.append(diagnostic)
        SearchDiagnosticJournal.currentSource?.transport(diagnostic)
    }

    public static func recordDecodeFailure(
        _ error: Error, data: Data, response: HTTPURLResponse
    ) {
        guard isCapturing else { return }
        let payload: ResponseDecodingDiagnostic.Payload
        if data.isEmpty { payload = .empty }
        else if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            payload = json is [Any] ? .array : json is [String: Any] ? .object : .scalar
        } else { payload = .nonJSON }
        let diagnostic = ResponseDecodingDiagnostic(
            route: effectiveRoute, httpStatus: response.statusCode, bytes: data.count,
            payload: payload, error: error
        )
        recorder?.append(diagnostic)
        SearchDiagnosticJournal.currentSource?.decoding(diagnostic)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [ResponseDecodingDiagnostic] = []
        private var paging: [LibraryPagingDiagnostic] = []
        private var transport: [ResponseTransportDiagnostic] = []
        private var http: [ResponseStatusDiagnostic] = []
        private var requests: [ResponseRequestDiagnostic] = []
        private var validation: [ResponseValidationDiagnostic] = []

        func append(_ diagnostic: ResponseRequestDiagnostic) {
            lock.lock()
            defer { lock.unlock() }
            requests.append(diagnostic)
            if requests.count > 4 { requests.removeFirst() }
        }

        func append(_ diagnostic: ResponseValidationDiagnostic) {
            lock.lock()
            defer { lock.unlock() }
            validation.append(diagnostic)
            if validation.count > 4 { validation.removeFirst() }
        }

        func append(_ response: ResponseDecodingDiagnostic) {
            lock.lock()
            defer { lock.unlock() }
            responses.append(response)
            if responses.count > 4 { responses.removeFirst() }
        }

        func append(_ diagnostic: LibraryPagingDiagnostic) {
            lock.lock()
            defer { lock.unlock() }
            paging.append(diagnostic)
            if paging.count > 4 { paging.removeFirst() }
        }

        func append(_ diagnostic: ResponseTransportDiagnostic) {
            lock.lock()
            defer { lock.unlock() }
            transport.append(diagnostic)
            if transport.count > 4 { transport.removeFirst() }
        }

        func snapshot() -> (
            responses: [ResponseDecodingDiagnostic], paging: [LibraryPagingDiagnostic],
            transport: [ResponseTransportDiagnostic], http: [ResponseStatusDiagnostic],
            requests: [ResponseRequestDiagnostic], validation: [ResponseValidationDiagnostic]
        ) {
            lock.lock()
            defer { lock.unlock() }
            return (responses, paging, transport, http, requests, validation)
        }

        func append(_ diagnostic: ResponseStatusDiagnostic) {
            lock.lock()
            defer { lock.unlock() }
            http.append(diagnostic)
            if http.count > 4 { http.removeFirst() }
        }
    }
}
