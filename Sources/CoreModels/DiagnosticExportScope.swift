import Foundation

/// One submission's correlation labels. Never persisted or shared between reports.
public final class DiagnosticExportScope: @unchecked Sendable {
    private let lock = NSLock()
    private var aliases: [String: String] = [:]
    private let now: Date
    private let namespace = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)

    public init(now: Date = Date()) {
        self.now = now
    }

    public func alias(for identifier: String) -> String {
        alias(forDigest: HandoffDiagnostics.correlationID(identifier))
    }

    /// Match identities already digested by the local source journal without exporting that digest.
    public func alias(forDigest digest: String) -> String {
        lock.withLock {
            if let existing = aliases[digest] { return existing }
            let alias = "entity-\(namespace)-\(aliases.count + 1)"
            aliases[digest] = alias
            return alias
        }
    }

    public func ageMilliseconds(for timestamp: Date) -> Int? {
        let elapsed = now.timeIntervalSince(timestamp) * 1_000
        guard elapsed.isFinite else { return nil }
        return Int(min(172_800_000, max(0, elapsed)))
    }
}
