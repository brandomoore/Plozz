import Foundation

public enum XtreamLiveFormat: String, CaseIterable, Sendable {
    case hls
    case transportStream

    public var label: String { self == .hls ? "HLS" : "MPEG-TS" } // l10n:content — format names

    public func fileExtension(allowed: Set<String>) -> String {
        if self == .transportStream, allowed.contains("ts") { return "ts" }
        return allowed.contains("m3u8") ? "m3u8" : "ts"
    }
}

/// Read by the editor and again when resolving a live channel. A changed
/// preference neither rotates the credential nor interrupts current playback.
public struct XtreamLiveFormatPreference: Sendable {
    private let key: String

    public init(accountID: String, profileID: String) {
        let account = Data(accountID.utf8).base64EncodedString()
        key = SettingsKey.scoped("com.plozz.iptv.liveFormat.\(account)", namespace: profileID)
    }

    public func load(from defaults: UserDefaults = .standard) throws -> XtreamLiveFormat {
        guard let stored = defaults.object(forKey: key) else { return .hls }
        guard let raw = stored as? String, let format = XtreamLiveFormat(rawValue: raw) else {
            throw LiveTVPreferencesStoreError.invalidStoredValue
        }
        return format
    }

    public func save(_ format: XtreamLiveFormat, to defaults: UserDefaults = .standard) throws {
        defaults.set(format.rawValue, forKey: key)
        guard defaults.string(forKey: key) == format.rawValue else { throw LiveTVPreferencesStoreError.encodingFailed }
    }
}
