import Foundation
import Synchronization

/// Explicit downloaded-only mode, not a conclusion drawn from internet reachability.
public final class OfflineMode: Sendable {
    public static let shared = OfflineMode()
    public static let preferenceKey = "plozz.device.offlineMode"
    public let isAvailable: Bool
    private let enabled = Mutex(false)

    public init(featureFlags: RuntimeFeatureFlags = .buildDefault) {
        isAvailable = featureFlags.isEnabled(.offlineMode)
    }

    public var isEnabled: Bool { enabled.withLock { $0 } }

    public func setEnabled(_ value: Bool) {
        enabled.withLock { $0 = value && isAvailable }
    }

    public func requireNetworkAccess() throws {
        try Task.checkCancellation()
        if isEnabled { throw OfflineModeError.networkUnavailable }
    }
}

public enum OfflineModeError: Error, LocalizedError, Sendable {
    case networkUnavailable

    public var errorDescription: String? {
        String(localized: "Unavailable in Offline Mode.") // l10n:content - LocalizedError resolves text when the error is presented.
    }
}
