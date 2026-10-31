import Foundation

/// Closed vocabulary only; never retain a URL, header, title, or error description.
public struct PlaybackFailureDiagnostic: Codable, Equatable, Sendable {
    public enum Layer: String, Codable, Sendable { case iptvProxy, liveEngine, plexLiveTune }
    public enum Content: String, Codable, Sendable { case live, onDemand }
    public enum Stage: String, Codable, Sendable { case response, body, manifest, load, playback, audioSession }
    public enum Format: String, Codable, Sendable {
        case unknown, hls, transportStream, html, json, xml, empty, other

        public init(mimeType: String?) {
            switch mimeType?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) {
            case nil: self = .unknown
            case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl":
                self = .hls
            case "video/mp2t": self = .transportStream
            case "text/html", "application/xhtml+xml": self = .html
            case "application/json", "application/problem+json": self = .json
            case "text/xml", "application/xml": self = .xml
            default: self = .other
            }
        }

        public var nonVideoMessage: LocalizedStringResource? {
            switch self {
            case .html: "The provider returned a web page instead of a video stream."
            case .json, .xml: "The provider returned a data document instead of a video stream."
            case .empty: "The provider returned an empty video response."
            default: nil
            }
        }
    }
    public enum Domain: String, Codable, Sendable {
        case none, url, avfoundation, coremedia, posix, other

        public init(_ domain: String?) {
            switch domain {
            case nil: self = .none
            case NSURLErrorDomain: self = .url
            case "AVFoundationErrorDomain": self = .avfoundation
            case "CoreMediaErrorDomain": self = .coremedia
            case NSPOSIXErrorDomain: self = .posix
            default: self = .other
            }
        }
    }
    public enum EngineFailure: String, Codable, Sendable {
        case none, unknown, sourceOpenFailed, sourceRefused, customSourceProbeFailed
        case liveSourceUnavailable, hlsPlaylistOnRawLivePath, dolbyVisionRequiresHardware
        case demuxedAudioLiveUnsupported, nativeItemFailed, noPlayableTrackWithinBudget
        case masterPlaylistRejected, vodSourceFailed, sourceRateLimited, softwarePipelineFailed
        case audioSessionFailed, reloadFailed, liveReloadNeverReady, audioTrackSwitchFailed
        case audioBridgeProducedNoOutput
        case sourceCertificateRejected, storageExhausted

        public var message: LocalizedStringResource? {
            switch self {
            case .sourceOpenFailed, .customSourceProbeFailed: "The player couldn’t open the playback source."
            case .sourceRefused: "The server refused the playback request."
            case .liveSourceUnavailable: "The player couldn’t open the live stream within its retry limit."
            case .hlsPlaylistOnRawLivePath: "The player received an HLS playlist on a path that does not support playlists."
            case .dolbyVisionRequiresHardware: "This Dolby Vision video requires a compatible hardware playback path."
            case .demuxedAudioLiveUnsupported: "This playback path does not support the live stream’s audio delivery."
            case .nativeItemFailed: "The system player reported a playback failure."
            case .noPlayableTrackWithinBudget: "The player did not find a playable track before the startup time limit."
            case .masterPlaylistRejected: "The system player rejected the HLS master playlist."
            case .vodSourceFailed: "The playback source stopped providing media."
            case .sourceRateLimited: "The streaming server is limiting requests."
            case .softwarePipelineFailed: "The player’s software decoding pipeline failed."
            case .audioSessionFailed: "The player could not start the audio session."
            case .reloadFailed: "The player could not reload the playback source."
            case .liveReloadNeverReady: "The player did not become ready after reloading the live stream."
            case .audioTrackSwitchFailed: "The player could not switch audio tracks."
            case .audioBridgeProducedNoOutput: "Audio conversion produced no encoded audio."
            case .sourceCertificateRejected: "The secure connection failed certificate authentication."
            case .storageExhausted: "The player ran out of space for temporary video data."
            case .none, .unknown: nil
            }
        }
    }

    public let layer: Layer
    public let content: Content
    public let stage: Stage
    public let reason: IPTVSetupDiagnostic.Failure.Reason
    public let engineFailure: EngineFailure
    public let domain: Domain
    public let code: Int?
    public let httpStatus: Int?
    public let format: Format
    public let elapsedMilliseconds: Int
    public let evidence: PlaybackFailureEvidence?

    public var isValid: Bool {
        reason != .cancelled
            && (0...86_400_000).contains(elapsedMilliseconds)
            && code.map { (Int(Int32.min)...Int(Int32.max)).contains($0) } != false
            && httpStatus.map { (100...599).contains($0) } != false
            && evidence?.isValid != false
    }
}

/// Consent generations fence retained players/proxies across opt-out and re-enablement.
public final class PlaybackFailureDiagnostics: @unchecked Sendable {
    public typealias Sink = @Sendable (PlaybackFailureDiagnostic) -> Void
    public static let shared = PlaybackFailureDiagnostics()
    private let lock = NSRecursiveLock()
    private var generation = UUID()
    private var sink: Sink?

    public init() {}

    public func start(sink: @escaping Sink) {
        lock.withLock {
            generation = UUID()
            self.sink = sink
        }
    }

    public func stop() {
        lock.withLock {
            generation = UUID()
            sink = nil
        }
    }

    public func begin(
        layer: PlaybackFailureDiagnostic.Layer, content: PlaybackFailureDiagnostic.Content,
        captureForPresentation: Bool = false
    ) -> PlaybackFailureAttempt? {
        let generation = lock.withLock { sink == nil ? nil : self.generation }
        guard captureForPresentation || generation != nil else { return nil }
        return PlaybackFailureAttempt(layer: layer, content: content) { [weak self] diagnostic in
            guard let self, let generation else { return }
            self.lock.withLock {
                guard self.generation == generation else { return }
                self.sink?(diagnostic)
            }
        }
    }
}

public final class PlaybackFailureAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private let layer: PlaybackFailureDiagnostic.Layer
    private let content: PlaybackFailureDiagnostic.Content
    private let sink: PlaybackFailureDiagnostics.Sink
    private let started = ProcessInfo.processInfo.systemUptime
    private var finished = false
    private var completedDiagnostic: PlaybackFailureDiagnostic?

    public var diagnostic: PlaybackFailureDiagnostic? { lock.withLock { completedDiagnostic } }

    fileprivate init(
        layer: PlaybackFailureDiagnostic.Layer, content: PlaybackFailureDiagnostic.Content,
        sink: @escaping PlaybackFailureDiagnostics.Sink
    ) {
        self.layer = layer
        self.content = content
        self.sink = sink
    }

    @discardableResult
    public func fail(
        stage: PlaybackFailureDiagnostic.Stage, reason: IPTVSetupDiagnostic.Failure.Reason = .other,
        engineFailure: PlaybackFailureDiagnostic.EngineFailure = .none,
        domain: PlaybackFailureDiagnostic.Domain = .none, code: Int? = nil,
        httpStatus: Int? = nil, format: PlaybackFailureDiagnostic.Format = .unknown,
        evidence: PlaybackFailureEvidence? = nil
    ) -> PlaybackFailureDiagnostic? {
        guard reason != .cancelled else { return nil }
        let diagnostic = PlaybackFailureDiagnostic(
            layer: layer, content: content, stage: stage, reason: reason, engineFailure: engineFailure,
            domain: domain, code: code.flatMap { (Int(Int32.min)...Int(Int32.max)).contains($0) ? $0 : nil },
            httpStatus: httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }, format: format,
            elapsedMilliseconds: min(86_400_000, max(0, Int((ProcessInfo.processInfo.systemUptime - started) * 1_000))),
            evidence: evidence
        )
        let emit = lock.withLock {
            guard !finished else { return false }
            finished = true
            completedDiagnostic = diagnostic
            return true
        }
        if emit { sink(diagnostic) }
        return diagnostic
    }
}
