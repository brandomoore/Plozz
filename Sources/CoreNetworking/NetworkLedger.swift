import CoreModels
import Foundation

/// One line per HTTP transfer, emitted only when the process is launched with
/// `PLZNET_STDOUT=1`.
///
/// The existing request logs say *what* was requested and `HomeAgg` says *how
/// long a row took*, but nothing attributes a row's time to the transfers that
/// composed it. This ledger fills that gap: route, status, milliseconds,
/// bytes and whether the transfer was shared with another caller. It is
/// deliberately opt-in and content-free — no headers, tokens or query values.
public enum NetworkLedger {
    /// Read once at first use; a normal run pays nothing.
    public static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["PLZNET_STDOUT"] == "1"

    private static let writeLock = NSLock()
    private static let mirrorsThroughLogger =
        ProcessInfo.processInfo.environment["PLOZZ_LOG_STDOUT"] == "1"

    /// Query shape only: arbitrary server IDs, filters and names are never copied.
    public static func querySummary(_ items: [URLQueryItem]) -> String {  // l10n:content — developer-facing diagnostic
        let allowed = ["ParentId", "IncludeItemTypes", "Filters", "Limit", "StartIndex", "SortBy", "Ids"]
        var parts: [String] = []
        for key in allowed {
            guard let value = items.first(where: {
                $0.name.caseInsensitiveCompare(key) == .orderedSame
            })?.value, !value.isEmpty else { continue }
            if key == "Limit" || key == "StartIndex", let number = UInt(value) {
                parts.append("\(key)=\(number)")
            } else if key == "Ids" {
                parts.append("Ids=count:\(value.split(separator: ",").count)")
            } else {
                parts.append("\(key)=present")
            }
        }
        return parts.joined(separator: ",")
    }

    /// Pure line builder so the field set is testable without stdout.
    public static func makeLine(
        method: HTTPMethod,
        status: Int?,
        milliseconds: Int,
        bytes: Int,
        coalesced: Bool,
        route: ResponseDecodingDiagnostic.Route,
        query: [URLQueryItem] = [],
        error: Int? = nil
    ) -> String {  // l10n:content — developer-facing diagnostic, never localized
        let statusText = status.map(String.init) ?? "-"
        let errorText = error.map { " error=\($0)" } ?? ""
        let summary = querySummary(query)
        let queryText = summary.isEmpty ? "" : " q=\(summary)"
        return "\(method.rawValue) status=\(statusText) ms=\(milliseconds) "
            + "bytes=\(bytes) coalesced=\(coalesced ? 1 : 0) route=\(route.rawValue)\(queryText)\(errorText)"
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
        do {
            try FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
        } catch {
            PlozzLog.networking.error("Network ledger stdout write failed")
        }
    }
}
