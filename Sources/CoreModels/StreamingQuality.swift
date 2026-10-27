import Foundation

/// Streaming limits, independent of offline download renditions.
public enum StreamingQuality: Hashable, CaseIterable, Codable, Sendable, Identifiable {
    case original, hd1080High, hd1080, hd720High, hd720, sd480, low
    case custom(CustomStreamingQuality)
    /// Retain a damaged saved limit until the user replaces it, never as Maximum.
    case invalid(StreamingQualityValidationError)

    /// Built-in choices; Custom is constructed with its own validated limits.
    public static let allCases: [Self] = [.original, .hd1080High, .hd1080, .hd720High, .hd720, .sd480, .low]

    public static func custom(maximumHeight: Int, bitrateKbps: Int) throws -> Self {
        .custom(try CustomStreamingQuality(maximumHeight: maximumHeight, bitrateKbps: bitrateKbps))
    }

    public var id: Self { self }
    public var validationError: StreamingQualityValidationError? {
        if case .invalid(let error) = self { return error }
        return nil
    }

    public func validate() throws {
        if let validationError { throw StreamingQualityError.invalidQuality(validationError) }
    }

    public var maximumBitrate: Int? {
        switch self {
        case .original, .invalid: nil
        case .hd1080High: 20_000_000
        case .hd1080: 8_000_000
        case .hd720High: 4_000_000
        case .hd720: 2_000_000
        case .sd480: 1_000_000
        case .low: 500_000
        case .custom(let value): value.bitrateKbps * 1_000
        }
    }
    public var maximumHeight: Int? {
        switch self {
        case .original, .invalid: nil
        case .hd1080High, .hd1080: 1080
        case .hd720High, .hd720: 720
        case .sd480: 480
        case .low: 240
        case .custom(let value): value.maximumHeight
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
        case .custom(let value): "Custom · \(String(value.maximumHeight))p · \(value.bitrateKbps.formatted()) Kbps"
        case .invalid: "Invalid custom quality"
        }
    }
    public var estimatedBytesPerHour: Int64? { maximumBitrate.map { Int64($0) * 450 } }

    public var diagnosticName: String {
        switch self {
        case .original: "original"
        case .hd1080High: "hd1080High"
        case .hd1080: "hd1080"
        case .hd720High: "hd720High"
        case .hd720: "hd720"
        case .sd480: "sd480"
        case .low: "low"
        case .custom(let value): "custom-\(value.maximumHeight)p-\(value.bitrateKbps)Kbps"
        case .invalid(let error): "invalid-\(error.rawValue)"
        }
    }

    private enum CodingKeys: String, CodingKey { case type, maximumHeight, bitrateKbps, error }

    public init(from decoder: any Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            if name == "custom" { throw StreamingQualityValidationError.malformedCustom }
            guard let preset = Self.allCases.first(where: { $0.diagnosticName == name }) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "Unknown streaming quality preset."
                ))
            }
            self = preset
            return
        }
        do {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "custom":
                self = try .custom(
                    maximumHeight: c.decode(Int.self, forKey: .maximumHeight),
                    bitrateKbps: c.decode(Int.self, forKey: .bitrateKbps)
                )
            case "invalid":
                self = .invalid(try c.decode(StreamingQualityValidationError.self, forKey: .error))
            default: throw StreamingQualityValidationError.malformedCustom
            }
        } catch let error as StreamingQualityValidationError {
            throw error
        } catch {
            throw StreamingQualityValidationError.malformedCustom
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .custom(let value):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("custom", forKey: .type)
            try c.encode(value.maximumHeight, forKey: .maximumHeight)
            try c.encode(value.bitrateKbps, forKey: .bitrateKbps)
        case .invalid(let error):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("invalid", forKey: .type)
            try c.encode(error, forKey: .error)
        default:
            var c = encoder.singleValueContainer()
            try c.encode(diagnosticName)
        }
    }

    /// Unknown source facts are not evidence that an original fits a data limit.
    public func permitsOriginal(bitrate: Int?, width: Int?, height: Int?) -> Bool {
        guard validationError == nil else { return false }
        guard let maximumBitrate, let maximumWidth, let maximumHeight else { return true }
        guard let bitrate, bitrate > 0, let width, width > 0, let height, height > 0 else { return false }
        return bitrate <= maximumBitrate && width <= maximumWidth && height <= maximumHeight
    }
}

public struct CustomStreamingQuality: Hashable, Sendable {
    public static let supportedHeights = [240, 480, 720, 1080, 1440, 2160]
    // Jellyfin/Emby's MaxStreamingBitrate is signed 32-bit bits per second.
    public static let maximumBitrateKbps = Int(Int32.max) / 1_000
    public let maximumHeight: Int
    /// Total audio + video budget, in decimal kilobits per second.
    public let bitrateKbps: Int

    public init(maximumHeight: Int, bitrateKbps: Int) throws {
        guard Self.supportedHeights.contains(maximumHeight) else {
            throw StreamingQualityValidationError.unsupportedResolution
        }
        guard bitrateKbps > 128 else { throw StreamingQualityValidationError.bitrateTooLow }
        let (bits, overflow) = bitrateKbps.multipliedReportingOverflow(by: 1_000)
        guard !overflow, bits <= Int(Int32.max) else { throw StreamingQualityValidationError.bitrateTooHigh }
        self.maximumHeight = maximumHeight
        self.bitrateKbps = bitrateKbps
    }
}

public enum StreamingQualityValidationError: String, Error, Hashable, Codable, Sendable {
    case invalidBitrate, bitrateTooLow, bitrateTooHigh, unsupportedResolution, malformedCustom

    public var userMessage: LocalizedStringResource {
        switch self {
        case .invalidBitrate: "Enter a whole number of Kbps, without decimals or separators."
        case .bitrateTooLow: "Enter more than 128 Kbps to leave room for video after the audio budget."
        case .bitrateTooHigh: "The server supports at most \(CustomStreamingQuality.maximumBitrateKbps.formatted()) Kbps."
        case .unsupportedResolution: "Choose a supported maximum resolution."
        case .malformedCustom: "This saved custom quality couldn’t be read. Choose a quality or enter a new custom limit."
        }
    }
}

/// Editing never mutates a saved quality until validation succeeds and Apply is chosen.
public struct StreamingQualityDraft: Equatable, Sendable {
    public var maximumHeight: Int
    public var bitrateKbps: String

    public init(quality: StreamingQuality) {
        maximumHeight = quality.maximumHeight ?? StreamingQuality.hd1080.maximumHeight!
        bitrateKbps = String((quality.maximumBitrate ?? StreamingQuality.hd1080.maximumBitrate!) / 1_000)
    }

    public func validatedQuality() throws -> StreamingQuality {
        let text = bitrateKbps.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw StreamingQualityValidationError.invalidBitrate
        }
        guard let bitrate = Int(text) else { throw StreamingQualityValidationError.bitrateTooHigh }
        return try .custom(maximumHeight: maximumHeight, bitrateKbps: bitrate)
    }

    public var validationError: StreamingQualityValidationError? {
        do { _ = try validatedQuality(); return nil }
        catch let error as StreamingQualityValidationError { return error }
        catch { return .malformedCustom }
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
        isSatisfied: Bool, usesCellular: Bool, usesWiFi: Bool, usesEthernet: Bool,
        interfacePreference: [Self] = []
    ) -> Self {
        guard isSatisfied else { return .offline }
        // A path can permit several interfaces. Eligibility is not preference.
        for network in interfacePreference {
            switch network {
            case .wifi where usesWiFi: return .wifi
            case .wired where usesEthernet: return .wired
            case .cellular where usesCellular: return .cellular
            default: continue
            }
        }
        if usesCellular { return .cellular }
        if usesWiFi { return .wifi }
        if usesEthernet { return .wired }
        return .unknown
    }
}

public enum StreamingConnection: String, Sendable, Equatable {
    case local, remote, cellular
    public static func resolve(
        network: StreamingNetwork, locality: SourceLocality, previousConnection: Self? = nil
    ) -> Self {
        // Losing a route is not a transition to cellular. Keep the current
        // session's selection until iOS reports a usable path again.
        if network == .offline, let previousConnection { return previousConnection }
        // An unresolved initial path still keeps the existing conservative limit.
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
        func quality(_ key: CodingKeys, fallback: StreamingQuality) -> StreamingQuality {
            guard c.contains(key), (try? c.decodeNil(forKey: key)) != true else { return fallback }
            do { return try c.decode(StreamingQuality.self, forKey: key) }
            catch let error as StreamingQualityValidationError { return .invalid(error) }
            catch { return fallback }
        }
        local = quality(.local, fallback: .original)
        remote = quality(.remote, fallback: .original)
        cellular = quality(.cellular, fallback: .hd720)
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
    public var hearingImpairedPreference: HearingImpairedPreference = .preferNonSDH
    /// Source-time resume intent for a server that prepares its output at that position.
    public var startPosition: TimeInterval?

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
                        && $0.isSDHSubtitle == subtitleTrack.isSDHSubtitle
                }
        }
        guard let subtitleMode else { return tracks.first(where: \.isDefault) }
        return tracks.defaultSubtitleSelection(
            mode: subtitleMode, preferredLanguage: subtitleLanguage,
            hearingImpairedPreference: hearingImpairedPreference
        )
    }
}

/// Only real server adapters opt in. A file-share provider must not ignore a limit.
public protocol StreamingQualityProviding: MediaProvider {
    var streamingQualitySupport: StreamingQualitySupport { get }
    func playbackInfo(
        for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
        streaming: StreamingPlaybackOptions
    ) async throws -> PlaybackRequest
    func releaseStreamingSession(_ request: PlaybackRequest) async
}

public extension StreamingQualityProviding {
    var streamingQualitySupport: StreamingQualitySupport { .standard }
}

/// Opt-in maintenance of an already-started server rendition, including while paused.
public protocol StreamingSessionMaintaining: MediaProvider {
    func maintainStreamingSession(_ request: PlaybackRequest) async throws
}

public enum StreamingQualityError: Error, Equatable, Sendable {
    public enum RefusalReason: String, Codable, Sendable {
        case sessionExpired = "session_expired"
        case transcodingDisabled = "transcoding_disabled"
        case conversionToolUnavailable = "conversion_tool_unavailable"
        case hdrTranscodeUnsupported = "hdr_transcode_unsupported"
        case sourceMismatch, unsupportedHeaders, unsupportedTimeline, nonSeekable, unsupportedDelivery
        case protocolUnsupported, providerUnavailable, conflictingState, unspecified
    }

    case invalidQuality(StreamingQualityValidationError)
    case unavailable, unsupported
    case authenticationRequired, permissionDenied, noCompatibleStream, sourceUnavailable, malformedResponse, negotiationFailed
    /// A successful inventory lookup explicitly reported no playable sources.
    case noStreams
    case serverHTTP(Int)
    case plexDecision(Int)
    case codecUnavailable(DirectPlayVideoCodec)
    case serverRefusal(LocalizedStringResource, reason: RefusalReason? = nil)
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
        case .serverRefusal(let message, _):
            message
        case .invalidQuality(let error):
            error.userMessage
        case .unavailable:
            "The server didn’t offer a converted stream for these settings."
        case .unsupported:
            "This source plays original files and doesn’t support quality conversion."
        case .authenticationRequired:
            "The server did not accept playback authorization."
        case .permissionDenied:
            "The server did not allow playback or conversion of this title."
        case .noCompatibleStream:
            "The server reported that no compatible stream is available."
        case .sourceUnavailable:
            "The server could not find the requested title or version."
        case .noStreams:
            "No streams found"
        case .malformedResponse:
            "Plozz couldn’t read the server’s playback response."
        case .negotiationFailed:
            "Plozz couldn’t prepare playback. No more specific cause was captured."
        case .serverHTTP(let status):
            "The server returned HTTP \(String(status)) while preparing playback."
        case .plexDecision:
            "Plex did not approve this playback conversion."
        case .codecUnavailable(let codec):
            "The server didn’t provide \(PlaybackDiagnostics.friendlyCodecName(codec.rawValue) ?? codec.rawValue) for these settings."
        case .playback(let failure):
            failure.userMessage
        case .startupTimedOut:
            "The player did not present video before the startup time limit."
        }
    }

    /// Codes only: never display raw server/AVFoundation descriptions or URLs.
    public var diagnosticCode: String? {
        switch self {
        case .invalidQuality(let error): "InvalidQuality(\(error.rawValue))"
        case .authenticationRequired: "PlaybackAuthorizationFailed"
        case .permissionDenied: "NotAllowed"
        case .noCompatibleStream: "NoCompatibleStream"
        case .sourceUnavailable: "MediaSourceUnavailable"
        case .noStreams: "NoStreamsFound"
        case .malformedResponse: "InvalidPlaybackResponse"
        case .negotiationFailed: "PlaybackNegotiationFailed"
        case .serverHTTP(let status): "HTTP \(status)"
        case .plexDecision(let code): "Plex decision \(code)"
        case .codecUnavailable(let codec): "CodecUnavailable(\(codec.rawValue))"
        case .startupTimedOut: "PlaybackStartupTimeout"
        case .playback(let failure): failure.diagnosticCode
        case .serverRefusal(_, let reason): reason?.rawValue
        case .unavailable: "ConvertedStreamUnavailable"
        case .unsupported: "ConversionUnsupported"
        }
    }
}

public struct StreamingPlaybackFailure: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case network, timedOut, accessDenied, unavailable, unsupportedFormat
        case hdrConversion, hdrConversionUnconfirmed, server, unknown
        case rateLimited, accessRestricted, storageExhausted, audioOutputFailed
        case readinessTimedOut, processingFailed
    }
    public enum Domain: String, Codable, Sendable { case avFoundation = "AVFoundation", url = "URL", coreMedia = "CoreMedia" }
    public let kind: Kind
    public let domain: Domain?
    public let code: Int?
    public let httpStatus: Int?
    public let provider: ProviderKind?
    public let engineFailure: PlaybackFailureDiagnostic.EngineFailure?
    public let underlyingErrors: [PlaybackFailureEvidence.ErrorCode]
    public let providerReason: StreamingQualityError.RefusalReason?

    public init(
        kind: Kind, domain: Domain? = nil, code: Int? = nil, httpStatus: Int? = nil,
        provider: ProviderKind? = nil,
        engineFailure: PlaybackFailureDiagnostic.EngineFailure? = nil,
        underlyingErrors: [PlaybackFailureEvidence.ErrorCode] = [],
        providerReason: StreamingQualityError.RefusalReason? = nil
    ) {
        self.kind = kind
        self.domain = domain
        self.code = code
        self.httpStatus = httpStatus
        self.provider = provider
        self.engineFailure = engineFailure
        self.underlyingErrors = Array(underlyingErrors.filter(\.isValid).prefix(8))
        self.providerReason = providerReason
    }

    public var allowsCodecFallback: Bool {
        if kind == .unavailable {
            // Native URL -1008 alone does not establish missing or expired media.
            // Keep bounded compatibility recovery unless stronger failure evidence exists.
            return domain == .url && code == URLError.resourceUnavailable.rawValue
                && httpStatus == nil && providerReason == nil
                && (engineFailure == nil || engineFailure == .nativeItemFailed)
                && underlyingErrors.allSatisfy {
                    $0.domain != .posix
                        && ($0.domain != .url || $0.code == URLError.resourceUnavailable.rawValue)
                }
        }
        return kind == .unsupportedFormat || kind == .processingFailed || kind == .unknown || kind == .hdrConversionUnconfirmed
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
        case .network where domain == .url && code == URLError.notConnectedToInternet.rawValue:
            "Your device is offline."
        case .network where domain == .url
            && code.map({ [URLError.cannotFindHost.rawValue, URLError.dnsLookupFailed.rawValue].contains($0) }) == true:
            "The streaming server’s address could not be resolved."
        case .network where domain == .url && code.map({ (-1206 ... -1200).contains($0) }) == true:
            "A secure connection to the streaming server could not be established."
        case .network:
            "The connection to the playback stream was lost or couldn’t be established."
        case .timedOut:
            "A request for the playback stream timed out."
        case .readinessTimedOut:
            "The player did not become ready before the startup time limit."
        case .accessDenied:
            "Access to the playback stream was denied."
        case .unavailable where providerReason == .sessionExpired:
            "The server reported that the playback session expired."
        case .unavailable where httpStatus == 404:
            "The server could not find the playback stream."
        case .unavailable where httpStatus == 410:
            "The server reported that the playback stream is no longer available."
        case .unavailable:
            "The playback stream is unavailable."
        case .unsupportedFormat:
            "The player couldn’t decode this video or audio."
        case .processingFailed:
            "The player couldn’t process this video or audio."
        case .hdrConversion:
            "The converted stream contains HDR video that this playback path cannot decode."
        case .hdrConversionUnconfirmed:
            "The converted video couldn’t be played. Its output HDR format could not be confirmed."
        case .server:
            "The streaming server returned an error."
        case .rateLimited:
            "The streaming server is limiting requests."
        case .accessRestricted:
            "The provider has restricted access to this stream."
        case .storageExhausted:
            "Your device ran out of space while preparing video."
        case .audioOutputFailed:
            "The player could not start the audio session."
        case .unknown:
            engineFailure?.message ?? "The player couldn’t play this video. No more specific cause was captured."
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
