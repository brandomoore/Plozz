import Foundation

/// Streaming limits, independent of offline download renditions.
public enum StreamingQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case original, hd1080High, hd1080, hd720High, hd720, sd480, low

    public var id: Self { self }
    public var maximumBitrate: Int? {
        switch self {
        case .original: nil
        case .hd1080High: 20_000_000
        case .hd1080: 8_000_000
        case .hd720High: 4_000_000
        case .hd720: 2_000_000
        case .sd480: 1_000_000
        case .low: 500_000
        }
    }
    public var maximumHeight: Int? {
        switch self {
        case .original: nil
        case .hd1080High, .hd1080: 1080
        case .hd720High, .hd720: 720
        case .sd480: 480
        case .low: 240
        }
    }
    public var maximumWidth: Int? { maximumHeight.map { ($0 * 16 / 9) / 2 * 2 } }
    public var audioBitrate: Int { 128_000 }
    public var videoBitrate: Int? { maximumBitrate.map { $0 - audioBitrate } }
    public var title: LocalizedStringResource {
        switch self {
        case .original: "Maximum"
        case .hd1080High: "1080p · 20 Mbps"
        case .hd1080: "1080p · 8 Mbps"
        case .hd720High: "720p · 4 Mbps"
        case .hd720: "720p · 2 Mbps"
        case .sd480: "480p · 1 Mbps"
        case .low: "240p · 500 Kbps"
        }
    }
    public var estimatedBytesPerHour: Int64? { maximumBitrate.map { Int64($0) * 3_600 / 8 } }

    /// Unknown source facts are not evidence that an original fits a data limit.
    public func permitsOriginal(bitrate: Int?, width: Int?, height: Int?) -> Bool {
        guard let maximumBitrate, let maximumWidth, let maximumHeight else { return true }
        guard let bitrate, bitrate > 0, let width, width > 0, let height, height > 0 else { return false }
        return bitrate <= maximumBitrate && width <= maximumWidth && height <= maximumHeight
    }
}

public enum StreamingCodecPreference: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic, preferHEVC, preferH264
    public var id: Self { self }
    public var title: LocalizedStringResource {
        switch self {
        case .automatic: "Automatic"
        case .preferHEVC: "Prefer HEVC (H.265)"
        case .preferH264: "Prefer H.264"
        }
    }
    public func codecs(supportsHEVC: Bool) -> [String] {
        if supportsHEVC && self != .preferH264 { return ["hevc", "h264"] }
        return ["h264"]
    }
}

public enum StreamingNetwork: Sendable, Equatable {
    case unknown, offline, wifi, cellular, wired
}

public enum StreamingConnection: String, Sendable, Equatable {
    case local, remote, cellular
    public static func resolve(network: StreamingNetwork, locality: SourceLocality) -> Self {
        // Unknown/tunneled paths use the conservative mobile policy until proven otherwise.
        if network == .cellular || network == .unknown || network == .offline { return .cellular }
        return locality == .local ? .local : .remote
    }
    public var title: LocalizedStringResource {
        switch self {
        case .local: "Local network"
        case .remote: "Remote Wi-Fi / Ethernet"
        case .cellular: "Cellular"
        }
    }
}

public struct StreamingQualitySettings: Codable, Equatable, Sendable {
    public var local: StreamingQuality = .original
    public var remote: StreamingQuality = .original
    public var cellular: StreamingQuality = .hd720
    public var codec: StreamingCodecPreference = .automatic
    public var forceTranscoding = false
    public static let `default` = Self()
    public init() {}

    public func options(for connection: StreamingConnection) -> StreamingPlaybackOptions {
        let quality: StreamingQuality
        switch connection {
        case .local: quality = local
        case .remote: quality = remote
        case .cellular: quality = cellular
        }
        return .init(quality: quality, codec: codec, forceTranscoding: forceTranscoding)
    }

    private enum CodingKeys: String, CodingKey { case local, remote, cellular, codec, forceTranscoding }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        local = (try? c.decode(StreamingQuality.self, forKey: .local)) ?? .original
        remote = (try? c.decode(StreamingQuality.self, forKey: .remote)) ?? .original
        cellular = (try? c.decode(StreamingQuality.self, forKey: .cellular)) ?? .hd720
        codec = (try? c.decode(StreamingCodecPreference.self, forKey: .codec)) ?? .automatic
        forceTranscoding = (try? c.decode(Bool.self, forKey: .forceTranscoding)) ?? false
    }
}

public struct StreamingPlaybackOptions: Hashable, Sendable {
    public var quality: StreamingQuality
    public var codec: StreamingCodecPreference
    public var forceTranscoding: Bool
    public var preferredAudioLanguages: [String] = []
    public var audioTrack: MediaTrack?
    public var subtitleTrack: MediaTrack?
    public var subtitlesOff = false
    public var subtitleMode: SubtitleMode?
    public var subtitleLanguage: String?

    public init(
        quality: StreamingQuality, codec: StreamingCodecPreference = .automatic,
        forceTranscoding: Bool = false
    ) {
        self.quality = quality
        self.codec = codec
        self.forceTranscoding = forceTranscoding
    }

    public var requiresConversionPolicy: Bool { quality != .original || forceTranscoding }
    public func matchesSelection(_ other: Self) -> Bool {
        quality == other.quality && codec == other.codec && forceTranscoding == other.forceTranscoding
    }

    public func selectedAudio(in tracks: [MediaTrack]) -> MediaTrack? {
        if let audioTrack {
            if let exact = tracks.first(where: { $0.id == audioTrack.id && $0.language == audioTrack.language }) {
                return exact
            }
            if let sameLanguage = tracks.first(where: {
                LanguageMatch.matches($0.language, audioTrack.language)
                    && $0.isCommentary == audioTrack.isCommentary
            }) { return sameLanguage }
        }
        return AudioLanguagePolicy.fallbackTrackID(preferredLanguages: preferredAudioLanguages, tracks: tracks)
            .flatMap { id in tracks.first { $0.id == id } }
            ?? tracks.first(where: \.isDefault) ?? tracks.first
    }

    public func selectedSubtitle(in tracks: [MediaTrack]) -> MediaTrack? {
        guard !subtitlesOff else { return nil }
        if let subtitleTrack {
            return tracks.first { $0.id == subtitleTrack.id && $0.language == subtitleTrack.language }
                ?? tracks.first {
                    LanguageMatch.matches($0.language, subtitleTrack.language)
                        && $0.isForced == subtitleTrack.isForced && $0.isBitmapSubtitle == subtitleTrack.isBitmapSubtitle
                }
        }
        guard let subtitleMode else { return tracks.first(where: \.isDefault) }
        return tracks.defaultSubtitleSelection(mode: subtitleMode, preferredLanguage: subtitleLanguage)
    }
}

/// Only real server adapters opt in. A file-share provider must not ignore a limit.
public protocol StreamingQualityProviding: MediaProvider {
    func playbackInfo(
        for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
        streaming: StreamingPlaybackOptions
    ) async throws -> PlaybackRequest
    func releaseStreamingSession(_ request: PlaybackRequest) async
}

public enum StreamingQualityError: Error, Sendable {
    case unavailable, unsupported
    public var userMessage: LocalizedStringResource {
        switch self {
        case .unavailable:
            "The server couldn’t provide this streaming quality. Choose another quality or check the server’s transcoding settings."
        case .unsupported:
            "This source plays original files and doesn’t support quality conversion."
        }
    }
}
