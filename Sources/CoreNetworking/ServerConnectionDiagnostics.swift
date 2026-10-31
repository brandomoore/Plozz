import CoreModels
import Foundation

/// Recent setup attempts, shared only through the user's explicit diagnostic submission.
public final class ServerConnectionDiagnostics: Sendable {
    public static let shared = ServerConnectionDiagnostics()

    public enum Stage: String, Encodable, Sendable {
        case addressValidation, passwordSignIn, quickConnectBegin, quickConnectApproval
    }

    private enum Scheme: String, Encodable, Sendable { case http, https, other }
    private enum Outcome: String, Encodable, Sendable { case succeeded, failed }

    private struct Facts: Encodable, Sendable {
        let provider: ProviderKind
        let stage: Stage
        let scheme: Scheme
        let explicitPort: Bool
        let basePath: Bool
        let candidate: Int?
        let outcome: Outcome
        let error: String?
        let elapsedMilliseconds: Int
        let requests: [ResponseRequestDiagnostic]
        let responses: [ResponseDecodingDiagnostic]
        let transport: [ResponseTransportDiagnostic]
        let http: [ResponseStatusDiagnostic]
    }

    private let recorder: DiagnosticRecordBuffer<Facts>

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        recorder = DiagnosticRecordBuffer(clock: clock)
    }

    public func capture<Value: Sendable>(
        provider: ProviderKind, stage: Stage, baseURL: URL?, candidate: Int? = nil,
        _ work: @Sendable () async throws -> Value
    ) async throws -> Value {
        let started = ProcessInfo.processInfo.systemUptime
        let captured = await HTTPResponseDiagnostics.$route.withValue(
            stage == .addressValidation ? .serverDiscovery : .serverAuthentication
        ) {
            await HTTPResponseDiagnostics.capture(retainingSuccessfulRequests: true, work)
        }
        if !captured.isCancelled, !Task.isCancelled {
            let outcome: Outcome
            let code: String?
            switch captured.result {
            case .success:
                outcome = .succeeded
                code = nil
            case .failure(let error):
                outcome = .failed
                code = error is HTTPServerTrustFailure ? "tlsTrustRejected"
                    : (error as? AppError).map(HandoffDiagnostics.errorCode) ?? "unknown"
            }
            recorder.append(Facts(
                provider: provider, stage: stage,
                scheme: Scheme(rawValue: baseURL?.scheme?.lowercased() ?? "") ?? .other,
                explicitPort: baseURL?.port != nil,
                basePath: baseURL.map { !$0.path.isEmpty && $0.path != "/" } ?? false,
                candidate: candidate.map { min(3, max(1, $0)) },
                outcome: outcome, error: code,
                elapsedMilliseconds: max(0, Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)),
                requests: captured.requests, responses: captured.responses,
                transport: captured.transport, http: captured.http
            ))
        }
        return try captured.result.get()
    }

    public struct Export: Encodable, Sendable {
        private let schema = 1
        private let dropped: Int
        private let entries: [ExportEntry]

        fileprivate init(source: ServerConnectionDiagnostics, scope: DiagnosticExportScope) {
            let snapshot = source.recorder.snapshot()
            dropped = snapshot.dropped
            entries = snapshot.entries.map {
                ExportEntry(ageMilliseconds: scope.ageMilliseconds(for: $0.timestamp),
                            attempt: scope.alias(for: $0.id.uuidString), facts: $0.value)
            }
        }
    }

    private struct ExportEntry: Encodable, Sendable {
        let ageMilliseconds: Int?
        let attempt: String
        let facts: Facts
    }

    public func export(scope: DiagnosticExportScope) -> Export {
        Export(source: self, scope: scope)
    }
}
