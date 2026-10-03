import Foundation
import CoreModels

/// Process-scoped access to the local marker comparison, never a saved setting.
public enum PlayerMarkerPreviewRequest {
    public static let notification = Notification.Name("com.plozz.debug.markerPreview")

    public static var isAvailable: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public static func isRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        environment["PLOZZ_SKIP_MARKER_PREVIEW"] == "1"
        #else
        false
        #endif
    }

    @MainActor public static func open(developerMode: DeveloperModeModel) {
        guard isAvailable, developerMode.isEnabled else { return }
        NotificationCenter.default.post(name: notification, object: nil)
    }
}
