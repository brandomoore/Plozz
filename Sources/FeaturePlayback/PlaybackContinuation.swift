#if canImport(AVFoundation)
import CoreModels
import Foundation

/// In-session intent carried to an explicitly selected alternate file.
public struct PlaybackContinuation: Sendable {
    public let position: TimeInterval
    public let streamingOptions: StreamingPlaybackOptions?
    let intendsPlayback: Bool
    let speed: Double
    let tracks: SubtitleTrackController.StreamSnapshot
}
#endif
