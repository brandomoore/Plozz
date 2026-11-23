import Foundation
import Observation
import Synchronization

/// The channel of the installed app, shared by feature gates and diagnostics.
public enum AppReleaseChannel: Sendable {
    case debug
    case testflight
    case production

    /// Info.plist key holding the channel baked in at build time by
    /// `tools/generate-project.sh` (from `$PLOZZ_RELEASE_CHANNEL`, which the
    /// fastlane `beta`/`release` lanes set). Empty for local builds.
    static let bundleKey = "PlozzReleaseChannel"

    /// The channel baked into this binary, or `nil` when none was (local builds,
    /// or an unresolved `$(...)` build setting).
    static func baked(
        _ raw: String? = Bundle.main.object(forInfoDictionaryKey: bundleKey) as? String
    ) -> AppReleaseChannel? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !(trimmed.hasPrefix("$(") && trimmed.hasSuffix(")")) else { return nil }
        switch trimmed.lowercased() {
        case "testflight": return .testflight
        case "production": return .production
        case "debug": return .debug
        default: return nil
        }
    }

    package static let installation: InstallChannel = {
        #if DEBUG
        InstallChannel(initial: .debug)
        #else
        let receipt = Bundle.main.appStoreReceiptURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0.lastPathComponent : nil
        }
        return InstallChannel(archive: baked(), receipt: receipt)
        #endif
    }()

    public static var current: AppReleaseChannel { installation.resolved ?? .production }

    /// Debug + TestFlight are "beta": builds still under active testing. The App
    /// Store / production build is not.
    public var isBeta: Bool { self != .production }

    /// Stable Sentry environment name for this distribution channel.
    public var crashReportEnvironment: String {
        switch self {
        case .debug: "debug"
        case .testflight: "testflight"
        case .production: "production"
        }
    }
}

/// Process-local: a store update can replace a TestFlight installation while
/// keeping both its build number and its preferences.
package final class InstallChannel: Sendable {
    private let value: Mutex<AppReleaseChannel?>
    package var resolved: AppReleaseChannel? { value.withLock { $0 } }

    init(initial: AppReleaseChannel?) { value = Mutex(initial) }

    convenience init(archive: AppReleaseChannel?, receipt: String?) {
        switch receipt {
        case "receipt": self.init(initial: .production)
        case "sandboxReceipt": self.init(initial: .testflight)
        default:
            // Only distribution archives need StoreKit when the receipt is absent.
            self.init(initial: archive == .testflight || archive == .production ? nil : .production)
        }
    }

    package func finish(verifiedChannel: AppReleaseChannel?) {
        value.withLock { if $0 == nil { $0 = verifiedChannel ?? .production } }
    }
}

/// Opt-in consent for sending anonymised crash reports off-device.
///
/// All builds require the current consent choice before reporting can start.
/// Legacy preferences are retained but cannot authorize reporting.
///
/// This is an **app-wide / household** setting, deliberately NOT per-profile:
/// crash reporting is about the app and the device, and a profile is non-secret
/// presentation metadata that must never gate privacy-sensitive plumbing (same
/// reasoning as the app-wide Transparency preference — see AGENTS.local.md
/// "Per-profile vs app-wide settings").
public struct CrashReportingSettings: Codable, Equatable, Sendable {
    public static let currentConsentVersion = 1

    /// Whether the user has opted in to sending crash reports.
    public var isEnabled: Bool
    public let consentVersion: Int?

    public init(isEnabled: Bool = false, consentVersion: Int? = nil) {
        self.isEnabled = isEnabled
        self.consentVersion = consentVersion
    }

    /// Hand-written so older settings containing the retired manual device marker
    /// continue to decode without affecting the user's crash-reporting choice.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        consentVersion = try container.decodeIfPresent(Int.self, forKey: .consentVersion)
    }

    public static let `default` = CrashReportingSettings()
}

/// Persists `CrashReportingSettings`. Uses a single un-namespaced key so the
/// choice is shared by the whole household (never scoped to a profile).
public protocol CrashReportingSettingsStoring: Sendable {
    func load() -> CrashReportingSettings
    /// The persisted value, or `nil` when the user has never made a choice. Lets
    /// callers distinguish "unset" (ask for consent) from an explicit
    /// opt-out that must be respected.
    func loadStored() -> CrashReportingSettings?
    func save(_ settings: CrashReportingSettings)
}

public final class CrashReportingSettingsStore: CrashReportingSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "com.plozz.crashReportingSettings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> CrashReportingSettings {
        loadStored() ?? .default
    }

    public func loadStored() -> CrashReportingSettings? {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(CrashReportingSettings.self, from: data) else {
            return nil
        }
        return settings
    }

    public func save(_ settings: CrashReportingSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Observable wrapper so the Settings toggle can two-way bind and the app root
/// can react to opt-in/opt-out to start or stop the reporter.
@MainActor
@Observable
public final class CrashReportingSettingsModel {
    public private(set) var settings: CrashReportingSettings

    public var needsConsent: Bool {
        settings.consentVersion != CrashReportingSettings.currentConsentVersion
    }

    public var isEnabled: Bool {
        get { !needsConsent && settings.isEnabled }
        set {
            settings = CrashReportingSettings(
                isEnabled: newValue,
                consentVersion: CrashReportingSettings.currentConsentVersion
            )
            store.save(settings)
        }
    }

    private let store: CrashReportingSettingsStoring

    public init(
        store: CrashReportingSettingsStoring = CrashReportingSettingsStore()
    ) {
        self.store = store
        self.settings = store.loadStored() ?? .default
    }
}
