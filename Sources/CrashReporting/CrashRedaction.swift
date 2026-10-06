#if canImport(Sentry)
import CoreModels
import Foundation
import Sentry

/// Scrubs outgoing Sentry events and breadcrumbs so nothing that could identify
/// a user or reveal what they were watching leaves the device. Runs in Sentry's
/// `beforeSend`/`beforeBreadcrumb` hooks — the last gate before upload.
enum CrashRedaction {
    /// Drop PII-bearing containers from an event and scrub its breadcrumbs.
    static func scrub(_ event: Event) -> Event? {
        // Identity / network provenance we never want.
        event.user = nil
        event.request = nil
        event.serverName = nil
        // Retain numerical memory evidence, never device names, IDs, or arbitrary
        // integration context. Coarse app/platform identity already lives in tags.
        var context: [String: [String: Any]] = [:]
        for (category, keys) in [
            "device": ["memory_size", "free_memory", "usable_memory"],
            "app": ["app_memory"]
        ] {
            var safe: [String: Any] = [:]
            for key in keys {
                if let value = event.context?[category]?[key] as? NSNumber,
                   CFGetTypeID(value) != CFBooleanGetTypeID(),
                   value.doubleValue.isFinite, value.doubleValue >= 0 {
                    safe[key] = value
                }
            }
            if category == "device",
               let value = event.context?[category]?["low_memory"] as? Bool {
                safe["low_memory"] = value
            }
            if !safe.isEmpty { context[category] = safe }
        }
        if event.tags?["report.kind"] == "playlist-import-limit",
           let limit = event.tags?["import.limit"],
           LiveTVPlaylistLimitDiagnostic.Limit(rawValue: limit) != nil {
            var counts: [String: Any] = [:]
            for key in ["observed", "maximum"] {
                if let value = event.context?["playlist_import"]?[key] as? NSNumber,
                   CFGetTypeID(value) != CFBooleanGetTypeID(),
                   value.doubleValue.isFinite, value.doubleValue > 0,
                   value.doubleValue.rounded(.down) == value.doubleValue,
                   value.doubleValue <= Double(Int64.max) {
                    counts[key] = value
                }
            }
            if !counts.isEmpty { context["playlist_import"] = counts }
        }
        event.context = context.isEmpty ? nil : context
        event.extra = nil

        if let crumbs = event.breadcrumbs {
            event.breadcrumbs = crumbs.compactMap { scrub($0) }
        }
        return event
    }

    /// Only our closed-vocabulary diagnostics survive, including SDK integrations
    /// enabled in future. Free-form messages/data are never forwarded.
    static func scrub(_ crumb: Breadcrumb) -> Breadcrumb? {
        if crumb.category == "plozz.screen",
           let message = crumb.message, let screen = CrashReportScreen(rawValue: message) {
            crumb.type = "navigation"
            crumb.message = screen.rawValue
            crumb.data = nil
            return crumb
        }
        guard crumb.category == "plozz.live_tv_sync",
              let data = crumb.data,
              let operation = (data["operation"] as? String).flatMap(LiveTVSyncDiagnostic.Operation.init(rawValue:)),
              let stage = (data["stage"] as? String).flatMap(LiveTVSyncDiagnostic.Stage.init(rawValue:)),
              let outcome = (data["outcome"] as? String).flatMap(LiveTVSyncDiagnostic.Outcome.init(rawValue:))
        else { return nil }
        var cleaned: [String: Any] = [
            "operation": operation.rawValue, "stage": stage.rawValue, "outcome": outcome.rawValue
        ]
        if outcome == .failed {
            guard let reason = (data["reason"] as? String).flatMap(LiveTVSyncDiagnostic.Failure.Reason.init(rawValue:))
            else { return nil }
            cleaned["reason"] = reason.rawValue
            if let code = data["code"] as? Int { cleaned["code"] = code }
        }
        crumb.type = "default"
        crumb.message = "Live TV sync"
        crumb.data = cleaned
        return crumb
    }
}
#endif
