import Foundation

/// Non-secret context attached to every crash report as tags. This is the
/// context data we deliberately send, alongside fixed screen categories and
/// the separate closed-vocabulary Live TV sync diagnostics.
/// It must never contain PII, auth tokens, server URLs/hostnames, media titles,
/// or profile names — just the coarse facts needed to triage a crash.
public struct CrashReportContext: Sendable {
    /// Sentry "release" identifier, e.g. `com.thatcube.Plozz@1.4.0+1004`.
    public var releaseName: String
    /// Marketing version, e.g. `1.4.0`.
    public var version: String
    /// Build number, e.g. `1004`.
    public var build: String
    /// `debug` | `testflight` | `production`.
    public var environment: String
    /// e.g. `tvOS 18.5` or `iOS 18.5`.
    public var systemVersion: String
    /// Hardware identifier, e.g. `AppleTV14,1`.
    public var deviceModel: String
    /// Which media backends are configured, e.g. `["Jellyfin", "Plex"]`. Names
    /// of the *provider kinds*, never server names/URLs.
    public var providers: [String]

    public init(
        releaseName: String,
        version: String,
        build: String,
        environment: String,
        systemVersion: String,
        deviceModel: String,
        providers: [String]
    ) {
        self.releaseName = releaseName
        self.version = version
        self.build = build
        self.environment = environment
        self.systemVersion = systemVersion
        self.deviceModel = deviceModel
        self.providers = providers
    }

    /// Builds a context from the running process. The caller supplies the detected
    /// binary environment, so UI and reporting share one channel decision.
    public static func make(
        bundleIdentifier: String,
        version: String,
        build: String,
        providers: [String],
        environment: String
    ) -> CrashReportContext {
        CrashReportContext(
            releaseName: "\(bundleIdentifier)@\(version)+\(build)",
            version: version,
            build: build,
            environment: environment,
            systemVersion: currentSystemVersion(),
            deviceModel: deviceModelIdentifier(),
            providers: providers
        )
    }

    static func currentSystemVersion() -> String {  // l10n:content — crash-report tag metadata, never displayed to users
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(tvOS)
        let platform = "tvOS"
        #elseif os(iOS)
        let platform = "iOS"
        #else
        let platform = "Apple OS"
        #endif
        return "\(platform) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func deviceModelIdentifier() -> String {
        var system = utsname()
        uname(&system)
        let mirror = Mirror(reflecting: system.machine)
        let identifier = mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "unknown" : identifier
    }
}

/// Fixed screen categories only. Never send a route, library ID, title, or
/// other free-form view context to the crash-reporting service.
public enum CrashReportScreen: String, Sendable {
    case startup, home, library, detail, settings, watchlist, search
    case music, liveTV, downloads, playback, profiles, unknown

    public init(context: String) {
        switch context {
        case "startup": self = .startup
        case "home": self = .home
        case "library", "allLibraries": self = .library
        case "detail": self = .detail
        case "settings": self = .settings
        case "watchlist": self = .watchlist
        case "search": self = .search
        case "music": self = .music
        case "liveTV": self = .liveTV
        case "downloads": self = .downloads
        case "playback": self = .playback
        case "profiles": self = .profiles
        default: self = context.hasPrefix("library:") ? .library : .unknown
        }
    }
}

/// Abstraction so the app can hold a reporter without importing Sentry directly,
/// and so builds without a DSN transparently do nothing.
@MainActor
public protocol CrashReporter: AnyObject {
    var isActive: Bool { get }
    func start(context: CrashReportContext)
    func update(context: CrashReportContext)
    func setScreen(_ screen: CrashReportScreen)
    func stop()
}

/// The reporter used when no DSN is baked in (local/dev builds, forks) — does
/// nothing at all.
@MainActor
public final class NoopCrashReporter: CrashReporter {
    public init() {}
    public private(set) var isActive = false
    public func start(context: CrashReportContext) {}
    public func update(context: CrashReportContext) {}
    public func setScreen(_ screen: CrashReportScreen) {}
    public func stop() {}
}

/// Owns the concrete reporter and gates it behind (a) a DSN being present in the
/// build and (b) the user's opt-in consent. Safe to call `apply` repeatedly.
@MainActor
public final class CrashReportingController {
    private let reporter: CrashReporter
    private var screen: CrashReportScreen = .startup

    /// True when this build shipped with a crash-reporting endpoint (a non-empty
    /// DSN was baked into Info.plist). When false the opt-in UI is shown disabled
    /// with an explanatory note, because there is nowhere to send reports.
    public let isConfigured: Bool

    public init(dsn: String = CrashReportingController.bundleDSN()) {
        let trimmed = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        let isUnresolvedBuildSetting =
            trimmed.hasPrefix("$(") && trimmed.hasSuffix(")")
        #if canImport(Sentry)
        if trimmed.isEmpty || isUnresolvedBuildSetting {
            self.reporter = NoopCrashReporter()
            self.isConfigured = false
        } else {
            self.reporter = SentryCrashReporter(dsn: trimmed)
            self.isConfigured = true
        }
        #else
        self.reporter = NoopCrashReporter()
        self.isConfigured = false
        #endif
    }

    /// Test seam: inject a reporter directly.
    init(reporter: CrashReporter, isConfigured: Bool) {
        self.reporter = reporter
        self.isConfigured = isConfigured
    }

    /// Reconcile the live reporter with the user's current consent. Starts on the
    /// first opt-in, stops on opt-out, and is a no-op when nothing changed or when
    /// the build has no DSN.
    public func apply(enabled: Bool, context: CrashReportContext) {
        guard isConfigured else { return }
        if enabled {
            if reporter.isActive {
                reporter.update(context: context)
            } else {
                reporter.start(context: context)
                reporter.setScreen(screen)
            }
        } else if reporter.isActive {
            reporter.stop()
        }
    }

    /// Cache the current category even before consent, so enabling reporting
    /// mid-session tags the active screen without collecting prior navigation.
    public func setScreen(_ screen: CrashReportScreen) {
        guard self.screen != screen else { return }
        self.screen = screen
        if isConfigured && reporter.isActive {
            reporter.setScreen(screen)
        }
    }

    /// Reads the DSN baked into Info.plist (`PlozzSentryDSN`, injected at project
    /// generation time from the `PLOZZ_SENTRY_DSN` env var). Empty for any build
    /// that wasn't configured with one.
    public static nonisolated func bundleDSN() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "PlozzSentryDSN") as? String) ?? ""
    }
}
