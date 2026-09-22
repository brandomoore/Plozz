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
        guard supportsHEVC else { return ["h264"] }
        switch self {
        case .automatic: return ["hevc", "h264"]
        case .preferHEVC: return ["hevc"]
        case .preferH264: return ["h264"]
        }
    }

    public var explanation: LocalizedStringResource {
        switch self {
        case .automatic: "Lets the server choose HEVC or H.264 when converting video."
        case .preferHEVC: "Tries HEVC first when supported, with H.264 fallback at the same quality limit."
        case .preferH264: "Requests H.264 when converting video."
        }
    }
}

public enum StreamingCodecRetryPolicy {
    public static func next(
        preference: StreamingCodecPreference,
        selectedCodec: DirectPlayVideoCodec?,
        supportsHEVC: Bool,
        alreadyRetried: Bool
    ) -> StreamingCodecPreference? {
        guard !alreadyRetried else { return nil }
        switch preference {
        case .preferH264: return nil
        case .preferHEVC: return selectedCodec == .h264 ? nil : .preferH264
        case .automatic:
            if selectedCodec == .h264 { return supportsHEVC ? .preferHEVC : nil }
            return .preferH264
        }
    }
}

public enum StreamingNetwork: Sendable, Equatable {
    case unknown, offline, wifi, cellular, wired

    /// Cost is not an interface type: Wi-Fi/Ethernet can be expensive too.
    /// Keep those paths eligible for the user's local/remote settings.
    public static func classify(
        isSatisfied: Bool, usesCellular: Bool, usesWiFi: Bool, usesEthernet: Bool
    ) -> Self {
        guard isSatisfied else { return .offline }
        if usesCellular { return .cellular }
        if usesWiFi { return .wifi }
        if usesEthernet { return .wired }
        return .unknown
    }
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

public enum StreamingQualityError: Error, Equatable, Sendable {
    case unavailable, unsupported
    case permissionDenied, noCompatibleStream, sourceUnavailable, malformedResponse, negotiationFailed
    case serverHTTP(Int)
    case plexDecision(Int)
    case codecUnavailable(DirectPlayVideoCodec)
    case playback(StreamingPlaybackFailure)
    case startupTimedOut

    public var allowsCodecFallback: Bool {
        switch self {
        case .unavailable, .noCompatibleStream, .codecUnavailable: true
        case .playback(let failure): failure.allowsCodecFallback
        default: false
        }
    }

    public var userMessage: LocalizedStringResource {
        switch self {
        case .unavailable:
            "The server didn’t offer a converted stream for these settings. It didn’t report a specific reason. Try another quality, or ask the server owner to check the transcoding log."
        case .unsupported:
            "This source plays original files and doesn’t support quality conversion."
        case .permissionDenied:
            "The server refused permission to play or convert this title. Ask the server owner to check your account’s playback and transcoding permissions."
        case .noCompatibleStream:
            "The server reported that no compatible stream is available. Check its supported encoders and transcoding settings, or choose another quality."
        case .sourceUnavailable:
            "The selected version is no longer available on the server. Go back and choose an available version."
        case .malformedResponse:
            "The server’s playback response couldn’t be read. Check the server’s logs and try again."
        case .negotiationFailed:
            "The server couldn’t prepare playback and didn’t report a specific cause. Check the server’s logs and try again."
        case .serverHTTP(let status):
            "The server returned HTTP \(status) while preparing playback. Check its transcoding log for the cause. Changing codec may not resolve a server error."
        case .plexDecision:
            "Plex refused the conversion. Check the server’s transcoding settings and log."
        case .codecUnavailable(let codec):
            "The server didn’t provide \(PlaybackDiagnostics.friendlyCodecName(codec.rawValue) ?? codec.rawValue) for these settings. Check its encoder support and transcoding settings, or choose another quality."
        case .playback(let failure):
            failure.userMessage
        case .startupTimedOut:
            "The server supplied a stream, but playback made no progress before the startup timeout. This doesn’t confirm a codec restriction. Check the server’s transcoding activity and network connection, or try another quality."
        }
    }

    /// Codes only: never display raw server/AVFoundation descriptions or URLs.
    public var diagnosticCode: String? {
        switch self {
        case .permissionDenied: "NotAllowed"
        case .noCompatibleStream: "NoCompatibleStream"
        case .sourceUnavailable: "MediaSourceUnavailable"
        case .malformedResponse: "InvalidPlaybackResponse"
        case .negotiationFailed: "PlaybackNegotiationFailed"
        case .serverHTTP(let status): "HTTP \(status)"
        case .plexDecision(let code): "Plex decision \(code)"
        case .codecUnavailable(let codec): "CodecUnavailable(\(codec.rawValue))"
        case .startupTimedOut: "PlaybackStartupTimeout"
        case .playback(let failure): failure.diagnosticCode
        default: nil
        }
    }
}

public struct StreamingPlaybackFailure: Equatable, Sendable {
    public enum Kind: Sendable {
        case network, timedOut, accessDenied, unavailable, unsupportedFormat
        case hdrConversion, hdrConversionUnconfirmed, server, unknown
    }
    public enum Domain: String, Sendable { case avFoundation = "AVFoundation", url = "URL", coreMedia = "CoreMedia" }
    public let kind: Kind
    public let domain: Domain?
    public let code: Int?
    public let httpStatus: Int?
    public let provider: ProviderKind?

    public init(
        kind: Kind, domain: Domain? = nil, code: Int? = nil, httpStatus: Int? = nil,
        provider: ProviderKind? = nil
    ) {
        self.kind = kind
        self.domain = domain
        self.code = code
        self.httpStatus = httpStatus
        self.provider = provider
    }

    public var allowsCodecFallback: Bool {
        kind == .unsupportedFormat || kind == .unknown || kind == .unavailable || kind == .hdrConversionUnconfirmed
    }
    public var diagnosticCode: String? {
        let components = [
            domain.flatMap { domain in code.map { "\(domain.rawValue) \($0)" } },
            httpStatus.map { "HTTP \($0)" }
        ].compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }
    public var userMessage: LocalizedStringResource {
        switch kind {
        case .network:
            "The connection to the playback stream was lost or couldn’t be established. Check your connection and the server’s availability."
        case .timedOut:
            "The playback stream stopped responding. Check the server’s transcoding activity and network connection."
        case .accessDenied:
            "Access to the playback stream was denied. Check your sign-in and the server account’s playback permissions."
        case .unavailable:
            "The playback stream is no longer available. Retry to create a new playback session."
        case .unsupportedFormat:
            "The player couldn’t decode the stream the server returned. Try H.264 or check the server’s encoder settings."
        case .hdrConversion where provider == .emby:
            "Emby returned incompatible HDR video. Enable HDR-to-SDR tone mapping in the server’s transcoding settings (requires Emby Premiere), or choose an SDR version."
        case .hdrConversion:
            "The server returned incompatible HDR video. Enable HDR-to-SDR tone mapping in the server’s transcoding settings, or choose an SDR version."
        case .hdrConversionUnconfirmed where provider == .emby:
            "This HDR conversion couldn’t be played. HDR-to-SDR tone mapping may be needed; Emby requires Premiere for it. Check the server’s transcoding settings or choose an SDR version."
        case .hdrConversionUnconfirmed:
            "This HDR conversion couldn’t be played. Check HDR-to-SDR tone mapping in the server’s transcoding settings or choose an SDR version."
        case .server:
            "The server returned an error while serving the playback stream. Its transcoding log can explain why conversion failed."
        case .unknown:
            "The server supplied a stream, but the player couldn’t play it. No specific cause was reported. Check the server’s transcoding log or try another quality."
        }
    }
}

public enum StreamingPreparationPhase: Sendable {
    case requesting, opening, waitingForVideo

    public func message(
        provider: String, transcoding: Bool, usingH264Fallback: Bool,
        usingHEVCFallback: Bool = false
    ) -> LocalizedStringResource {
        switch self {
        case .requesting where usingHEVCFallback:
            "Trying HEVC…"
        case .requesting where usingH264Fallback:
            "Trying H.264…"
        case .requesting:
            "Connecting to \(provider)…"
        case .opening where transcoding:
            "Transcoding…"
        case .opening:
            "Opening video…"
        case .waitingForVideo:
            "Buffering…"
        }
    }
}
