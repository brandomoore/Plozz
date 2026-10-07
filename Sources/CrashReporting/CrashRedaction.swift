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
        if event.tags?["report.kind"] == "iptv-setup" {
            guard let raw = event.context?["iptv_setup"], let data = setupData(raw),
                  data["outcome"] as? String == "failed",
                  let source = data["source"] as? String,
                  let stage = data["stage"] as? String,
                  let authentication = data["authentication"] as? String,
                  let entry = data["entry"] as? String,
                  let reason = data["reason"] as? String else { return nil }
            context["iptv_setup"] = data
            event.message = SentryMessage(formatted: "IPTV setup failed")
            event.fingerprint = [
                "iptv_setup", source, stage, reason,
                (data["http_status"] as? Int).map(String.init) ?? "none",
                (data["network_code"] as? Int).map(String.init) ?? "none"
            ]
            var tags = coarseSetupTags(event.tags ?? [:])
            tags.merge([
                "report.kind": "iptv-setup", "setup.source": source, "setup.stage": stage,
                "setup.failure": reason, "setup.authentication": authentication, "setup.entry": entry
            ]) { _, value in value }
            event.tags = tags
            if let status = data["http_status"] as? Int { event.tags?["setup.http_status"] = String(status) }
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
        if crumb.category == "plozz.iptv_setup" {
            guard let raw = crumb.data, let data = setupData(raw) else { return nil }
            crumb.type = "default"
            crumb.message = "IPTV setup"
            crumb.data = data
            return crumb
        }
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

    private static func setupData(_ raw: [String: Any]) -> [String: Any]? {
        guard let source = (raw["source"] as? String).flatMap(IPTVSetupDiagnostic.Source.init(rawValue:)),
              let authentication = (raw["authentication"] as? String).flatMap(IPTVSetupDiagnostic.Authentication.init(rawValue:)),
              let entry = (raw["entry"] as? String).flatMap(IPTVSetupDiagnostic.Entry.init(rawValue:)),
              let stage = (raw["stage"] as? String).flatMap(IPTVSetupDiagnostic.Stage.init(rawValue:)),
              let outcome = (raw["outcome"] as? String).flatMap(IPTVSetupDiagnostic.Outcome.init(rawValue:))
        else { return nil }
        var safe: [String: Any] = [
            "source": source.rawValue, "authentication": authentication.rawValue, "entry": entry.rawValue,
            "stage": stage.rawValue, "outcome": outcome.rawValue
        ]
        func copyInteger(_ key: String, range: ClosedRange<Int>) {
            guard let value = raw[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue.rounded(.down) == value.doubleValue,
                  value.doubleValue >= Double(range.lowerBound),
                  value.doubleValue <= Double(range.upperBound) else { return }
            safe[key] = value.intValue
        }
        for key in ["elapsed_ms", "stage_ms"] {
            copyInteger(key, range: 0...IPTVSetupAttempt.maximumMilliseconds)
        }
        for key in ["entries", "playlist_bytes", "skipped_entries", "requests"] {
            copyInteger(key, range: 0...IPTVSetupAttempt.maximumCount)
        }
        copyInteger("http_status", range: 100...599)
        if let response = (raw["response"] as? String).flatMap(IPTVSetupDiagnostic.Response.init(rawValue:)) {
            safe["response"] = response.rawValue
        }
        if outcome == .failed {
            guard let reason = (raw["reason"] as? String).flatMap(IPTVSetupDiagnostic.Failure.Reason.init(rawValue:)),
                  reason != .cancelled else { return nil }
            safe["reason"] = reason.rawValue
            copyInteger("network_code", range: -4_000 ... -1)
        }
        return safe
    }

    private static func coarseSetupTags(_ raw: [String: String]) -> [String: String] {
        var safe: [String: String] = [:]
        for key in ["app.version", "app.build", "os.version"] {
            if let value = raw[key],
               value.range(of: #"^[0-9]{1,8}(\.[0-9]{1,8}){0,2}$"#, options: .regularExpression) != nil {
                safe[key] = value
            }
        }
        if let model = raw["device.model"],
           ["arm64", "x86_64"].contains(model)
            || model.range(of: #"^(AppleTV|iPhone|iPad)[0-9]{1,3},[0-9]{1,3}$"#, options: .regularExpression) != nil {
            safe["device.model"] = model
        }
        if let screen = raw["last_screen"].flatMap(CrashReportScreen.init(rawValue:)) {
            safe["last_screen"] = screen.rawValue
        }
        return safe
    }
}
#endif
