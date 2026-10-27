import Foundation

/// Failure-only library evidence for explicit diagnostic submissions.
public final class LibraryDiagnosticJournal: Sendable {
    public static let shared = LibraryDiagnosticJournal()
    private let buffer = DiagnosticRecordBuffer<Facts>()

    public init() {}

    public func record(_ diagnostic: LibraryLoadDiagnostic) {
        guard !Task.isCancelled else { return }
        let failures = diagnostic.failures.filter { $0.error != .cancelled }
        guard !failures.isEmpty else { return }
        buffer.append(Facts(
            provider: diagnostic.provider, operation: diagnostic.operation,
            failures: failures.prefix(8).map(Failure.init),
            omittedFailures: max(0, failures.count - 8)
        ))
    }

    private struct Facts: Encodable, Sendable {
        let provider: ProviderKind
        let operation: LibraryLoadDiagnostic.Operation
        let failures: [Failure]
        let omittedFailures: Int
    }

    private struct Failure: Encodable, Sendable {
        let section: LibraryLoadDiagnostic.Section
        let reason: String
        let responses: [ResponseDecodingDiagnostic]
        let paging: [LibraryPagingDiagnostic]
        let transport: [ResponseTransportDiagnostic]
        let http: [ResponseStatusDiagnostic]

        init(_ failure: LibraryLoadDiagnostic.Failure) {
            section = failure.section
            reason = HandoffDiagnostics.errorCode(failure.error)
            responses = failure.responses
            paging = failure.paging
            transport = failure.transport
            http = failure.http
        }
    }

    public struct Export: Encodable, Sendable {
        private let schema = 1
        private let dropped: Int
        private let entries: [ExportEntry]

        fileprivate init(journal: LibraryDiagnosticJournal, scope: DiagnosticExportScope) {
            let snapshot = journal.buffer.snapshot()
            dropped = snapshot.dropped
            entries = snapshot.entries.map {
                ExportEntry(ageMilliseconds: scope.ageMilliseconds(for: $0.timestamp),
                            record: scope.alias(for: $0.id.uuidString), facts: $0.value)
            }
        }
    }

    private struct ExportEntry: Encodable, Sendable {
        let ageMilliseconds: Int?
        let record: String
        let facts: Facts
    }

    public func export(scope: DiagnosticExportScope) -> Export {
        Export(journal: self, scope: scope)
    }
}
