import Foundation

/// Facts read from the active rendition, never copied from the original file
/// or inferred from a requested quality/codec preference.
public struct PlaybackStreamDetails: Equatable, Sendable {
    public var metadata: MediaSourceMetadata
    /// HLS variant's advertised bitrate, not measured network throughput.
    public var declaredBitrate: Double?

    public init(metadata: MediaSourceMetadata = .init(), declaredBitrate: Double? = nil) {
        self.metadata = metadata
        self.declaredBitrate = declaredBitrate
    }

    public var diagnostics: PlaybackDiagnostics {
        var result = PlaybackDiagnostics.base(from: metadata, mode: .transcode)
        result.indicatedBitrate = declaredBitrate
        return result
    }

    public var technicalBadges: [MediaBadge] {
        var badges: [MediaBadge] = []
        if let resolution = diagnostics.resolution {
            badges.append(.init(resolution.displayString, style: .prominent))
        }
        if let codec = metadata.videoCodecBadge { badges.append(codec) }
        badges += metadata.dynamicRangeBadges
        if let audio = metadata.audio,
           let format = TrackLabeling.audioFormatHint(codec: audio.codec, channels: audio.channels, isAtmos: false) {
            badges.append(.init(format))
        }
        return badges
    }
}
