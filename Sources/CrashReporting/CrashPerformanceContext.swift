#if canImport(Sentry)
import CoreModels
import Foundation
import Sentry

/// Explicit reconstruction, never a pass-through of arbitrary event dictionaries.
enum CrashPerformanceContext {
    static let key = "performance_operations"

    static func scrub(_ raw: [String: Any]) -> [String: Any]? {
        guard integer(raw["schema"], in: 1...1) != nil,
              let elapsed = integer(raw["elapsedMilliseconds"], in: 0...PerformanceDiagnostics.maximumMilliseconds),
              let maxActive = integer(raw["maxActive"], in: 0...PerformanceDiagnostics.maximumActive),
              let dropped = integer(raw["dropped"], in: 0...PerformanceDiagnostics.maximumCount),
              let active = raw["active"] as? [Any], active.count <= PerformanceDiagnostics.maximumActive,
              active.count <= maxActive,
              let recent = raw["recent"] as? [Any], recent.count <= PerformanceDiagnostics.maximumRecent,
              let slow = raw["slow"] as? [Any], slow.count <= PerformanceDiagnostics.maximumSlow
        else { return nil }
        var safe: [String: Any] = [
            "schema": 1, "elapsedMilliseconds": elapsed, "maxActive": maxActive, "dropped": dropped,
            "active": active.compactMap { record($0, active: true, slow: false, elapsed: elapsed, maxActive: maxActive) },
            "recent": recent.compactMap { record($0, active: false, slow: false, elapsed: elapsed, maxActive: maxActive) },
            "slow": slow.compactMap { record($0, active: false, slow: true, elapsed: elapsed, maxActive: maxActive) }
        ]
        for (key, isSlow, capacity) in [
            ("homeRecent", false, PerformanceDiagnostics.maximumRecent),
            ("homeSlow", true, PerformanceDiagnostics.maximumSlow)
        ] {
            if let value = raw[key] {
                guard let entries = value as? [Any], entries.count <= capacity else { return nil }
                safe[key] = entries.compactMap { value -> [String: Any]? in
                    guard let entry = record(value, active: false, slow: isSlow, elapsed: elapsed, maxActive: maxActive),
                          let operation = (entry["operation"] as? String).flatMap(PerformanceDiagnostics.Operation.init(rawValue:)),
                          operation.isHomePresentation else { return nil }
                    return entry
                }
            }
        }
        for key in ["homeDropped", "homeUIDropped"] {
            if let value = raw[key] {
                guard let count = integer(value, in: 0...PerformanceDiagnostics.maximumCount) else { return nil }
                safe[key] = count
            }
        }
        if let value = raw["homeUI"] {
            guard let entries = value as? [Any], entries.count <= PerformanceDiagnostics.maximumHomeUI else { return nil }
            safe["homeUI"] = entries.compactMap { homeUI($0, elapsed: elapsed) }
        }
        return safe
    }

    private static func homeUI(_ value: Any, elapsed: Int) -> [String: Any]? {
        guard let raw = value as? [String: Any],
              let started = integer(raw["startedMilliseconds"], in: 0...elapsed),
              let duration = integer(raw["elapsedMilliseconds"], in: 0...elapsed),
              elapsed == PerformanceDiagnostics.maximumMilliseconds || duration <= elapsed - started,
              let metrics = raw["metrics"] as? [String: Any],
              let samples = integer(metrics["samples"], in: 1...PerformanceDiagnostics.maximumCount),
              let delay = integer(metrics["maximumDelayMilliseconds"], in: 0...duration)
        else { return nil }
        var safeMetrics: [String: Any] = ["samples": samples, "maximumDelayMilliseconds": delay]
        for key in ["delayedSamples", "scrollingSamples", "loadingSamples"] {
            guard let value = integer(metrics[key], in: 0...samples) else { return nil }
            safeMetrics[key] = value
        }
        for key in ["heightChanges", "maximumHeightDeltaPoints", "maximumActiveScans", "maximumActiveListers"] {
            guard let value = integer(metrics[key], in: 0...PerformanceDiagnostics.maximumCount) else { return nil }
            safeMetrics[key] = value
        }
        return [
            "startedMilliseconds": started, "elapsedMilliseconds": duration, "metrics": safeMetrics
        ]
    }

    private static func record(
        _ value: Any, active: Bool, slow: Bool, elapsed: Int, maxActive: Int
    ) -> [String: Any]? {
        guard let raw = value as? [String: Any],
              let operation = (raw["operation"] as? String).flatMap(PerformanceDiagnostics.Operation.init(rawValue:)),
              let started = integer(raw["startedMilliseconds"], in: 0...elapsed),
              let duration = integer(raw["elapsedMilliseconds"], in: 0...elapsed),
              let main = raw["startedOnMain"] as? NSNumber, CFGetTypeID(main) == CFBooleanGetTypeID(),
              let overlap = integer(raw["activeAtStart"], in: 1...PerformanceDiagnostics.maximumActive),
              overlap <= maxActive,
              let metrics = raw["metrics"] as? [String: Any]
        else { return nil }
        // Once uptime saturates, separate valid durations can no longer be summed.
        guard elapsed == PerformanceDiagnostics.maximumMilliseconds || duration <= elapsed - started else { return nil }
        var safe: [String: Any] = [
            "operation": operation.rawValue, "startedMilliseconds": started, "elapsedMilliseconds": duration,
            "startedOnMain": main.boolValue, "activeAtStart": overlap
        ]
        if let provider = raw["provider"] {
            // Deliberately explicit: a future provider kind needs a privacy review before export.
            guard let provider = provider as? String,
                  ["jellyfin", "plex", "emby", "silo", "iptv", "mediaShare"].contains(provider) else { return nil }
            safe["provider"] = provider
        }
        if active {
            guard raw["outcome"] == nil, raw["httpStatus"] == nil, raw["networkCode"] == nil else { return nil }
        } else {
            guard let outcome = (raw["outcome"] as? String).flatMap(PerformanceDiagnostics.Outcome.init(rawValue:)),
                  slow ? duration >= PerformanceDiagnostics.slowMilliseconds : duration < PerformanceDiagnostics.slowMilliseconds
            else { return nil }
            safe["outcome"] = outcome.rawValue
        }
        var safeMetrics: [String: Any] = [:]
        for key in ["items", "bytes", "rows", "credits", "accounts", "requests"] {
            if let value = metrics[key] {
                guard let count = integer(value, in: 0...PerformanceDiagnostics.maximumCount) else { return nil }
                safeMetrics[key] = count
            }
        }
        safe["metrics"] = safeMetrics
        for (key, range) in [("httpStatus", 100...599), ("networkCode", -4_000 ... -1)] {
            if let value = raw[key] {
                guard let code = integer(value, in: range) else { return nil }
                safe[key] = code
            }
        }
        return safe
    }

    private static func integer(_ raw: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded(.down) == value.doubleValue,
              value.doubleValue >= Double(range.lowerBound), value.doubleValue <= Double(range.upperBound)
        else { return nil }
        return value.intValue
    }
}
#endif
