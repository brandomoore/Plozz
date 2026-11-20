import Foundation

/// One line per HTTP transfer, emitted only when the process is launched with
/// `PLZNET_STDOUT=1`.
///
/// The existing request logs say *what* was requested and `HomeAgg` says *how
/// long a row took*, but nothing attributes a row's time to the transfers that
/// composed it. This ledger fills that gap: route, path, status, milliseconds,
/// bytes and whether the transfer was shared with another caller. It is
/// deliberately opt-in and content-free — no headers, tokens or query values.
public enum NetworkLedger {
    /// Read once at first use; a normal run pays nothing.
    public static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["PLZNET_STDOUT"] == "1"

    private static let writeLock = NSLock()
    private static let mirrorsThroughLogger =
        ProcessInfo.processInfo.environment["PLOZZ_LOG_STDOUT"] == "1"

    /// Compact, content-bounded view of the query parameters that identify a
    /// request's shape. Long id lists are truncated; tokens live in headers or
    /// non-allowlisted parameters and are never included.
    public static func querySummary(_ items: [URLQueryItem]) -> String {  // l10n:content — developer-facing diagnostic
        let allowed = ["ParentId", "IncludeItemTypes", "Filters", "Limit", "StartIndex", "SortBy", "Ids"]
        var parts: [String] = []
        for key in allowed {
            guard let value = items.first(where: {
                $0.name.caseInsensitiveCompare(key) == .orderedSame
            })?.value, !value.isEmpty else { continue }
            parts.append("\(key)=\(value.count > 28 ? String(value.prefix(28)) + "~" : value)")
        }
        return parts.joined(separator: ",")
    }

    /// Pure line builder so the field set is testable without stdout.
    public static func makeLine(
        method: String,
        path: String,
        status: Int?,
        milliseconds: Int,
        bytes: Int,
        coalesced: Bool,
        route: String,
        query: String = "",
        error: Int? = nil
    ) -> String {  // l10n:content — developer-facing diagnostic, never localized
        let statusText = status.map(String.init) ?? "-"
        let errorText = error.map { " error=\($0)" } ?? ""
        let queryText = query.isEmpty ? "" : " q=\(query)"
        return "\(method) path=\(path) status=\(statusText) ms=\(milliseconds) "
            + "bytes=\(bytes) coalesced=\(coalesced ? 1 : 0) route=\(route)\(queryText)\(errorText)"
    }

    /// Emits when enabled. Callers pass an autoclosure so formatting and string
    /// interpolation cost nothing in a normal run.
    public static func emit(_ line: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = "PLZNET " + line()
        // With PLOZZ_LOG_STDOUT the logger already mirrors to stdout; emitting
        // both would double every ledger line.
        if !mirrorsThroughLogger {
            PlozzLog.networking.info(text)
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        // Unbuffered so `devicectl --console` streams each line immediately.
        try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }
}
