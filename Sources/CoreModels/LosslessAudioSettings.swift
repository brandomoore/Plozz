import Foundation
import os

/// Output compatibility belongs to this device, not a profile or synced server.
public struct LosslessAudioSettingsStore {
    public static let storageKey = "com.plozz.losslessSurround"
    public static let defaultEnabled = true
    private static let logger = Logger(subsystem: "com.plozz.app", category: "settings")
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Bool {
        guard let stored = defaults.object(forKey: Self.storageKey) else { return Self.defaultEnabled }
        guard let enabled = stored as? Bool else {
            Self.logger.error("Invalid lossless surround preference; using the default")
            return Self.defaultEnabled
        }
        return enabled
    }

    public func save(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.storageKey)
    }
}
