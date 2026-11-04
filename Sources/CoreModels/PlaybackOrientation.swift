import Foundation

public enum PlaybackOrientation: String, Codable, CaseIterable, Sendable {
    case auto
    case portrait
    case landscape
    case landscapeLeft
    case landscapeRight

    public var title: LocalizedStringResource {
        switch self {
        case .auto:
            return LocalizedStringResource(
                "playback.orientation.followDevice", defaultValue: "Follow device orientation",
                comment: "Playback orientation preference. Follow device rotation and the system rotation lock."
            )
        case .landscape:
            return LocalizedStringResource(
                "playback.orientation.landscapeAuto", defaultValue: "Landscape auto",
                comment: "Playback orientation preference. Stay sideways and automatically follow the landscape direction, even with system rotation lock enabled."
            )
        case .portrait:
            return LocalizedStringResource(
                "playback.orientation.portrait", defaultValue: "Portrait",
                comment: "Playback orientation preference. Keep the full-screen video player upright."
            )
        case .landscapeLeft:
            return LocalizedStringResource(
                "playback.orientation.landscapeLeft", defaultValue: "Landscape left",
                comment: "Playback orientation preference. Lock the player to the landscape orientation with the top of the phone on the left."
            )
        case .landscapeRight:
            return LocalizedStringResource(
                "playback.orientation.landscapeRight", defaultValue: "Landscape right",
                comment: "Playback orientation preference. Lock the player to the landscape orientation with the top of the phone on the right."
            )
        }
    }
}
