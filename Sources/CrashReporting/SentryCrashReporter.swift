#if canImport(Sentry)
import CoreModels
import Foundation
import Sentry

/// Sentry-backed crash reporter. Configured for **maximum privacy**: crash and
/// hang captures and typed sync/setup failures, with automatic UI/network telemetry disabled and a
/// hard scrub of anything that could carry PII before it leaves the device.
///
/// What is sent (only when the user has opted in AND a DSN is baked in):
///   • Crash stack traces (the whole point) and watchdog/hang signals.
///   • Coarse tags: app version/build, OS version, device model, provider kinds,
///     and the last observed fixed screen category (never a route or content name).
///   • Fixed screen-category history and typed Live TV sync stages/error codes.
///   • Temporary, bounded IPTV setup stages, counts, and handled failure categories.
///   • Bounded IPTV transport and live-engine failure categories and numeric codes.
///   • Numerical memory-pressure evidence when supplied by the SDK.
/// What is NOT sent: user identity, IP, server URLs/hostnames, media titles,
/// profile names, automatic network/UI breadcrumbs, or performance traces.
@MainActor
public final class SentryCrashReporter: CrashReporter {
    private let dsn: String
    private var diagnosticObservers: [NSObjectProtocol] = []
    private let playlistDiagnosticGate = PlaylistDiagnosticGate()
    private let syncLimitDiagnosticGate = SyncLimitDiagnosticGate()
    private var setupDiagnosticsActive = false
    public private(set) var isActive = false

    public init(dsn: String) {
        self.dsn = dsn
    }

    public func start(context: CrashReportContext) {
        guard !isActive else { return }

        SentrySDK.start { options in
            options.dsn = self.dsn
            options.releaseName = context.releaseName
            options.dist = context.build
            options.environment = context.environment

            // ---- Privacy hardening ----
            // Never attach the device's default PII (IP address, etc.).
            options.sendDefaultPii = false
            // Killing swizzling removes Sentry's automatic UI/network breadcrumbs,
            // which are the main vector for leaking titles/URLs. Crashes are still
            // captured via the signal/mach-exception handlers, not swizzling.
            options.enableSwizzling = false
            // Stack traces on crashes are exactly what we want.
            options.attachStacktrace = true

            // No performance, tracing, or session telemetry.
            options.enableAutoPerformanceTracing = false
            options.tracesSampleRate = NSNumber(value: 0)
            options.enableAutoSessionTracking = false
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableCaptureFailedRequests = false
            options.maxBreadcrumbs = 100

            // Keep the two crash-adjacent signals that are genuinely useful on an
            // Apple TV, where MetricKit is unavailable:
            options.enableWatchdogTerminationTracking = true // approximates jetsam/OOM kills
            options.enableAppHangTracking = true

            // Final belt-and-suspenders scrub of every outgoing event/breadcrumb.
            options.beforeSend = { event in CrashRedaction.scrub(event) }
            options.beforeBreadcrumb = { crumb in CrashRedaction.scrub(crumb) }
        }

        applyScope(context)
        diagnosticObservers.append(NotificationCenter.default.addObserver(
            forName: LiveTVSyncDiagnostic.notification, object: nil, queue: nil
        ) { notification in
            guard let diagnostic = notification.object as? LiveTVSyncDiagnostic else { return }
            Self.record(diagnostic)
        })
        let syncLimitGate = syncLimitDiagnosticGate
        diagnosticObservers.append(NotificationCenter.default.addObserver(
            forName: LiveTVSyncLimitDiagnostic.notification, object: nil, queue: nil
        ) { notification in
            guard SentrySDK.isEnabled,
                  let diagnostic = notification.object as? LiveTVSyncLimitDiagnostic,
                  syncLimitGate.accept(diagnostic.limit) else { return }
            SentrySDK.addBreadcrumb(Self.syncLimitBreadcrumb(diagnostic))
        })
        let gate = playlistDiagnosticGate
        diagnosticObservers.append(NotificationCenter.default.addObserver(
            forName: LiveTVPlaylistLimitDiagnostic.notification, object: nil, queue: nil
        ) { notification in
            guard SentrySDK.isEnabled,
                  let diagnostic = notification.object as? LiveTVPlaylistLimitDiagnostic,
                  diagnostic.maximum > 0, diagnostic.observed > diagnostic.maximum,
                  gate.accept(diagnostic.limit) else { return }
            SentrySDK.capture(event: Self.playlistLimitEvent(diagnostic))
        })

        isActive = true
        configureSetupDiagnostics(context)
    }

    public func update(context: CrashReportContext) {
        guard isActive else { return }
        applyScope(context)
        configureSetupDiagnostics(context)
    }

    public func setScreen(_ screen: CrashReportScreen) {
        guard isActive else { return }
        SentrySDK.configureScope { scope in
            scope.setTag(value: screen.rawValue, key: "last_screen")
        }
        let breadcrumb = Breadcrumb(level: .info, category: "plozz.screen")
        breadcrumb.type = "navigation"
        breadcrumb.message = screen.rawValue
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    public func stop() {
        guard isActive else { return }
        for observer in diagnosticObservers { NotificationCenter.default.removeObserver(observer) }
        diagnosticObservers.removeAll()
        playlistDiagnosticGate.reset()
        syncLimitDiagnosticGate.reset()
        if setupDiagnosticsActive {
            IPTVSetupDiagnostics.shared.stop()
            PlaybackFailureDiagnostics.shared.stop()
        }
        setupDiagnosticsActive = false
        SentrySDK.close()
        isActive = false
    }

    private nonisolated static func record(_ diagnostic: LiveTVSyncDiagnostic) {
        guard SentrySDK.isEnabled else { return }
        let breadcrumb = Breadcrumb(level: .info, category: "plozz.live_tv_sync")
        breadcrumb.data = [
            "operation": diagnostic.operation.rawValue,
            "stage": diagnostic.stage.rawValue,
            "outcome": diagnostic.outcome.rawValue
        ]
        if let failure = diagnostic.failure {
            breadcrumb.level = .error
            breadcrumb.data?["reason"] = failure.reason.rawValue
            if let code = failure.code { breadcrumb.data?["code"] = code }
        }
        SentrySDK.addBreadcrumb(breadcrumb)

        guard diagnostic.outcome == .failed, let failure = diagnostic.failure else { return }
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "Live TV sync failed")
        event.fingerprint = [
            "live_tv_sync", diagnostic.operation.rawValue, diagnostic.stage.rawValue,
            failure.reason.rawValue, failure.code.map(String.init) ?? "none"
        ]
        event.tags = [
            "report.kind": "live-tv-sync",
            "sync.operation": diagnostic.operation.rawValue,
            "sync.stage": diagnostic.stage.rawValue,
            "sync.failure": failure.reason.rawValue
        ]
        if let code = failure.code { event.tags?["sync.error_code"] = String(code) }
        SentrySDK.capture(event: event)
    }

    nonisolated static func playlistLimitEvent(_ diagnostic: LiveTVPlaylistLimitDiagnostic) -> Event {
        let event = Event(level: .warning)
        event.message = SentryMessage(formatted: "Live TV playlist import reached a safety limit")
        event.fingerprint = ["live_tv_playlist_limit", diagnostic.limit.rawValue]
        event.tags = [
            "report.kind": "playlist-import-limit",
            "import.limit": diagnostic.limit.rawValue
        ]
        event.context = [
            "playlist_import": ["observed": diagnostic.observed, "maximum": diagnostic.maximum]
        ]
        return event
    }

    nonisolated static func syncLimitBreadcrumb(_ diagnostic: LiveTVSyncLimitDiagnostic) -> Breadcrumb {
        let breadcrumb = Breadcrumb(level: .error, category: "plozz.live_tv_sync_limit")
        breadcrumb.data = [
            "limit": diagnostic.limit.rawValue, "observed": diagnostic.observed, "maximum": diagnostic.maximum
        ]
        return breadcrumb
    }

    private func configureSetupDiagnostics(_ context: CrashReportContext) {
        let enabled = IPTVSetupDiagnostic.isEnabled(environment: context.environment)
        guard enabled != setupDiagnosticsActive else { return }
        setupDiagnosticsActive = enabled
        guard enabled else {
            IPTVSetupDiagnostics.shared.stop()
            PlaybackFailureDiagnostics.shared.stop()
            return
        }
        let gate = IPTVSetupReportGate()
        IPTVSetupDiagnostics.shared.start { diagnostic in
            guard SentrySDK.isEnabled else { return }
            let breadcrumb = Breadcrumb(level: .info, category: "plozz.iptv_setup")
            breadcrumb.data = Self.setupData(diagnostic)
            SentrySDK.addBreadcrumb(breadcrumb)
            guard gate.accept(diagnostic), let event = Self.setupEvent(diagnostic) else { return }
            SentrySDK.capture(event: event)
        }
        let playbackGate = PlaybackFailureReportGate()
        PlaybackFailureDiagnostics.shared.start { diagnostic in
            guard SentrySDK.isEnabled, playbackGate.accept(diagnostic),
                  let event = Self.playbackEvent(diagnostic) else { return }
            SentrySDK.capture(event: event)
        }
    }

    nonisolated static func playbackData(_ diagnostic: PlaybackFailureDiagnostic) -> [String: Any] {
        var data: [String: Any] = [
            "layer": diagnostic.layer.rawValue, "content": diagnostic.content.rawValue,
            "stage": diagnostic.stage.rawValue, "reason": diagnostic.reason.rawValue,
            "engineFailure": diagnostic.engineFailure.rawValue, "domain": diagnostic.domain.rawValue,
            "format": diagnostic.format.rawValue, "elapsedMilliseconds": diagnostic.elapsedMilliseconds
        ]
        if let value = diagnostic.code { data["code"] = value }
        if let value = diagnostic.httpStatus { data["httpStatus"] = value }
        return data
    }

    nonisolated static func playbackFingerprint(_ diagnostic: PlaybackFailureDiagnostic) -> [String] {
        [
            "playback_failure", diagnostic.layer.rawValue, diagnostic.content.rawValue,
            diagnostic.stage.rawValue, diagnostic.reason.rawValue, diagnostic.engineFailure.rawValue,
            diagnostic.domain.rawValue, diagnostic.code.map(String.init) ?? "none",
            diagnostic.httpStatus.map(String.init) ?? "none", diagnostic.format.rawValue
        ]
    }

    nonisolated static func playbackEvent(_ diagnostic: PlaybackFailureDiagnostic) -> Event? {
        let event = Event(level: .warning)
        event.tags = ["report.kind": "playback-failure"]
        event.context = ["playback_failure": playbackData(diagnostic)]
        return CrashRedaction.scrub(event)
    }

    nonisolated static func setupData(_ diagnostic: IPTVSetupDiagnostic) -> [String: Any] {
        var data: [String: Any] = [
            "source": diagnostic.source.rawValue, "authentication": diagnostic.authentication.rawValue,
            "entry": diagnostic.entry.rawValue, "stage": diagnostic.stage.rawValue,
            "outcome": diagnostic.outcome.rawValue, "elapsed_ms": diagnostic.elapsedMilliseconds,
            "stage_ms": diagnostic.stageMilliseconds, "requests": diagnostic.requestCount
        ]
        data["entries"] = diagnostic.entries
        data["playlist_bytes"] = diagnostic.playlistBytes
        data["skipped_entries"] = diagnostic.skippedEntries
        data["http_status"] = diagnostic.httpStatus
        data["response"] = diagnostic.response?.rawValue
        data["reason"] = diagnostic.failure?.reason.rawValue
        data["network_code"] = diagnostic.failure?.networkCode
        data["sqlite_code"] = diagnostic.failure?.sqliteCode
        return data
    }

    nonisolated static func setupEvent(_ diagnostic: IPTVSetupDiagnostic) -> Event? {
        let event = Event(level: .warning)
        event.tags = ["report.kind": "iptv-setup"]
        event.context = ["iptv_setup": setupData(diagnostic)]
        // The same allowlist reconstructs the message, grouping, and tags at final upload.
        return CrashRedaction.scrub(event)
    }

    private func applyScope(_ context: CrashReportContext) {
        SentrySDK.configureScope { scope in
            scope.setTag(value: context.version, key: "app.version")
            scope.setTag(value: context.build, key: "app.build")
            scope.setTag(value: context.systemVersion, key: "os.version")
            scope.setTag(value: context.deviceModel, key: "device.model")
            let providers = context.providers.isEmpty
                ? "none"
                : context.providers.joined(separator: "+")
            scope.setTag(value: providers, key: "providers")
        }
    }
}

final class IPTVSetupReportGate: @unchecked Sendable {
    static let maximumReports = 10
    private let lock = NSLock()
    private var reported: Set<String> = []

    func accept(_ diagnostic: IPTVSetupDiagnostic) -> Bool {
        guard diagnostic.outcome == .failed, let failure = diagnostic.failure else { return false }
        let key = [
            diagnostic.source.rawValue, diagnostic.authentication.rawValue, diagnostic.entry.rawValue, diagnostic.stage.rawValue,
            failure.reason.rawValue, diagnostic.httpStatus.map(String.init) ?? "none",
            failure.networkCode.map(String.init) ?? "none",
            failure.sqliteCode.map(String.init) ?? "none"
        ].joined(separator: ".")
        return lock.withLock {
            guard reported.count < Self.maximumReports else { return false }
            return reported.insert(key).inserted
        }
    }
}

final class PlaybackFailureReportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: Set<[String]> = []

    func accept(_ diagnostic: PlaybackFailureDiagnostic) -> Bool {
        guard diagnostic.isValid else { return false }
        let key = SentryCrashReporter.playbackFingerprint(diagnostic)
        return lock.withLock {
            guard reported.count < IPTVSetupReportGate.maximumReports else { return false }
            return reported.insert(key).inserted
        }
    }
}

final class SyncLimitDiagnosticGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastRecorded: [LiveTVSyncLimitDiagnostic.Limit: TimeInterval] = [:]

    func accept(_ limit: LiveTVSyncLimitDiagnostic.Limit, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock {
            if let previous = lastRecorded[limit], uptime - previous < 60 { return false }
            lastRecorded[limit] = uptime
            return true
        }
    }

    func reset() {
        lock.withLock { lastRecorded.removeAll() }
    }
}

final class PlaylistDiagnosticGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: Set<LiveTVPlaylistLimitDiagnostic.Limit> = []

    func accept(_ limit: LiveTVPlaylistLimitDiagnostic.Limit) -> Bool {
        lock.withLock { reported.insert(limit).inserted }
    }

    func reset() {
        lock.withLock { reported.removeAll() }
    }
}
#endif
