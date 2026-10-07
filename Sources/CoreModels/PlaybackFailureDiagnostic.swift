import Foundation

/// Closed vocabulary only; never retain a URL, header, title, or error description.
public struct PlaybackFailureDiagnostic: Codable, Equatable, Sendable {
    public enum Layer: String, Codable, Sendable { case iptvProxy, liveEngine }
    public enum Content: String, Codable, Sendable { case live, onDemand }
    public enum Stage: String, Codable, Sendable { case response, body, manifest, load, playback, audioSession }
    public enum Format: String, Codable, Sendable {
        case unknown, hls, transportStream, html, other

        public init(mimeType: String?) {
            switch mimeType?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) {
            case nil: self = .unknown
            case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl":
                self = .hls
            case "video/mp2t": self = .transportStream
            case "text/html", "application/xhtml+xml": self = .html
            default: self = .other
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

    public var isValid: Bool {
        reason != .cancelled
            && (0...86_400_000).contains(elapsedMilliseconds)
            && code.map { (Int(Int32.min)...Int(Int32.max)).contains($0) } != false
            && httpStatus.map { (100...599).contains($0) } != false
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

    public func begin(layer: PlaybackFailureDiagnostic.Layer, content: PlaybackFailureDiagnostic.Content) -> PlaybackFailureAttempt? {
        let generation = lock.withLock { sink == nil ? nil : self.generation }
        guard let generation else { return nil }
        return PlaybackFailureAttempt(layer: layer, content: content) { [weak self] diagnostic in
            guard let self else { return }
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

    fileprivate init(
        layer: PlaybackFailureDiagnostic.Layer, content: PlaybackFailureDiagnostic.Content,
        sink: @escaping PlaybackFailureDiagnostics.Sink
    ) {
        self.layer = layer
        self.content = content
        self.sink = sink
    }

    public func fail(
        stage: PlaybackFailureDiagnostic.Stage, reason: IPTVSetupDiagnostic.Failure.Reason = .other,
        engineFailure: PlaybackFailureDiagnostic.EngineFailure = .none,
        domain: PlaybackFailureDiagnostic.Domain = .none, code: Int? = nil,
        httpStatus: Int? = nil, format: PlaybackFailureDiagnostic.Format = .unknown
    ) {
        guard reason != .cancelled else { return }
        let diagnostic = PlaybackFailureDiagnostic(
            layer: layer, content: content, stage: stage, reason: reason, engineFailure: engineFailure,
            domain: domain, code: code.flatMap { (Int(Int32.min)...Int(Int32.max)).contains($0) ? $0 : nil },
            httpStatus: httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }, format: format,
            elapsedMilliseconds: min(86_400_000, max(0, Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)))
        )
        let emit = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if emit { sink(diagnostic) }
    }
}
