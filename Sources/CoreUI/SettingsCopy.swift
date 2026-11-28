import Foundation

/// Copy that appears in more than one Settings surface, so tvOS and iOS can never
/// drift apart on the wording — and, now that it is localized, so the string is
/// translated once rather than once per shell.
///
/// `LocalizedStringResource` rather than `String`: `Text(aString)` renders
/// verbatim, so copy typed as `String` is invisible to both the String Catalog and
/// the compiler's string extraction, and would silently stay English.
public enum SettingsCopy {
    public static let sources: LocalizedStringResource = "Sources"
    public static let addSource: LocalizedStringResource = "Add Source"
    public static let tvSources: LocalizedStringResource = "TV Sources"
    public static let addTVSource: LocalizedStringResource = "Add TV Source"

    public static let libraries = LocalizedStringResource(
        "settings.nav.libraries",
        defaultValue: "Libraries",
        comment: "Navigation row and page heading for the screen listing the user's media libraries."
    )
    public static let attributions = LocalizedStringResource(
        "settings.nav.attributions",
        defaultValue: "Attributions",
        comment: "Navigation row for the screen crediting third-party software and data sources."
    )

    public static let shareDiagnostics: LocalizedStringResource = "Share Diagnostics"
    public static let enableDiagnosticSharing: LocalizedStringResource = "Enable Sharing"
    public static let diagnosticSharingRequired: LocalizedStringResource =
        "Turn on Share Diagnostics to send a report."
    public static let diagnosticSharingUnavailable: LocalizedStringResource =
        "Diagnostic sharing is unavailable in this build."
    public static let diagnosticSubmissionFailed: LocalizedStringResource =
        "Couldn't submit diagnostics. Check that Share Diagnostics is on and try again."

    public static let automaticDiagnostics: LocalizedStringResource =
        "Automatically share crash reports, technical errors, app and device information, screen categories, and performance diagnostics with the developer through Sentry."

    public static let automaticDiagnosticsExclusions: LocalizedStringResource =
        "Automatic reports exclude logins, server addresses, and media titles."

    public static let manualDiagnostics: LocalizedStringResource =
        "Send recent activity, search, playback and connection diagnostics, and your message to the developer through Sentry."

    public static let diagnosticsMessage: LocalizedStringResource = "Message (required)"
    public static let diagnosticsDescriptionRequired: LocalizedStringResource = "Add a short description of what happened."

    // MARK: - Scope headers

    /// App management, separate from the active profile's personal preferences.
    public static let everyone = LocalizedStringResource(
        "Manage Plozz",
        comment: "Settings section heading for managing sources, profiles, parental protection, sync, and metadata providers, separate from personal profile preferences. Plozz is the app name and must remain unchanged."
    )

    /// Reach clause for the active profile's own settings, when iCloud Sync is on.
    public static let profileScopeSynced = LocalizedStringResource(
        "settings.scope.profile.synced",
        defaultValue: "Saved to your profile, on all your devices.",
        comment: "Subtitle under a profile's name in Settings, explaining that the settings below belong to this profile and follow the user to their other devices."
    )

    /// Reach clause for the active profile's own settings, when iCloud Sync is off.
    /// - Parameter deviceName: the device the app is running on, e.g. "Apple TV" or "iPhone".
    public static func profileScopeLocal(deviceName: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "settings.scope.profile.local",
            defaultValue: "Saved to your profile on this \(deviceName).",
            comment: "Subtitle under a profile's name in Settings when iCloud Sync is off, so the settings stay on this one device. The placeholder is the device kind, e.g. 'Apple TV' or 'iPhone'."
        )
    }

    /// Reach clause for the shared settings, when iCloud Sync is on.
    public static let everyoneScopeSynced = LocalizedStringResource(
        "settings.scope.everyone.synced",
        defaultValue: "Shared across every profile, on all your devices.",
        comment: "Subtitle for the group of settings shared by every profile, explaining that they also follow the user to their other devices."
    )

    /// Reach clause for the shared settings, when iCloud Sync is off.
    /// - Parameter deviceName: the device the app is running on, e.g. "Apple TV" or "iPhone".
    public static func everyoneScopeLocal(deviceName: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "settings.scope.everyone.local",
            defaultValue: "Shared across every profile on this \(deviceName).",
            comment: "Subtitle for the group of settings shared by every profile when iCloud Sync is off, so they stay on this one device. The placeholder is the device kind, e.g. 'Apple TV' or 'iPhone'."
        )
    }

    /// Reach clause for the active profile's own settings.
    ///
    /// - Parameters:
    ///   - syncEnabled: whether iCloud Sync is on.
    ///   - deviceName: the device kind, e.g. "Apple TV" or "iPhone". Only used
    ///     when sync is off — with sync on, the whole point is that the device
    ///     doesn't matter.
    public static func profileScope(
        syncEnabled: Bool,
        deviceName: String
    ) -> LocalizedStringResource {
        syncEnabled ? profileScopeSynced : profileScopeLocal(deviceName: deviceName)
    }

    /// Reach clause for the shared settings.
    ///
    /// - Parameters:
    ///   - syncEnabled: whether iCloud Sync is on.
    ///   - deviceName: the device kind, e.g. "Apple TV" or "iPhone". Only used
    ///     when sync is off.
    public static func everyoneScope(
        syncEnabled: Bool,
        deviceName: String
    ) -> LocalizedStringResource {
        syncEnabled ? everyoneScopeSynced : everyoneScopeLocal(deviceName: deviceName)
    }
}
