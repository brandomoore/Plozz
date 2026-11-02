#if canImport(AVFoundation)
import CoreGraphics
import CoreModels
import Foundation

/// Live status is supplied by the engine, never reconstructed from AVPlayer hints.
public enum LiveChannelEnginePhase: Equatable, Sendable {
    case idle, loading, playing, paused, seeking, rebuffering
    case stalled(reconnecting: Bool)
    case ended, failed

    public var diagnosticCode: String {
        switch self {
        case .idle: "idle"
        case .loading: "loading"
        case .playing: "playing"
        case .paused: "paused"
        case .seeking: "seeking"
        case .rebuffering: "rebuffering"
        case .stalled(let reconnecting): reconnecting ? "reconnecting" : "stalled"
        case .ended: "ended"
        case .failed: "failed"
        }
    }
}

public enum LiveChannelEngineRoute: String, Equatable, Sendable {
    case none, nativeHLS, localHLS, software, audio

    var diagnosticsMode: PlaybackDiagnostics.PlaybackMode {
        switch self {
        case .nativeHLS: .directPlay
        case .localHLS, .software: .plozzigen
        case .none, .audio: .unknown
        }
    }

    /// Playback Info's name for the route. Developer-facing, so not translated.
    public var diagnosticName: String? { // l10n:content — engine route names
        switch self {
        case .none: nil
        case .nativeHLS: "Native HLS (AVPlayer)"
        case .localHLS: "Ingest → loopback HLS"
        case .software: "Software decode"
        case .audio: "Audio only"
        }
    }
}

public struct LiveChannelEngineSnapshot: Equatable, Sendable {
    public var phase: LiveChannelEnginePhase
    public var firstFrameReady: Bool
    public var position: TimeInterval
    public var bufferedPosition: TimeInterval
    public var seekableRange: ClosedRange<TimeInterval>?
    public var behindLiveSeconds: TimeInterval?
    public var route: LiveChannelEngineRoute
    public var isAtLiveEdge: Bool?

    public init(
        phase: LiveChannelEnginePhase = .idle,
        firstFrameReady: Bool = false,
        position: TimeInterval = 0,
        bufferedPosition: TimeInterval = 0,
        seekableRange: ClosedRange<TimeInterval>? = nil,
        behindLiveSeconds: TimeInterval? = nil,
        route: LiveChannelEngineRoute = .none,
        isAtLiveEdge: Bool? = nil
    ) {
        self.phase = phase
        self.firstFrameReady = firstFrameReady
        self.position = position
        self.bufferedPosition = bufferedPosition
        self.seekableRange = seekableRange
        self.behindLiveSeconds = behindLiveSeconds
        self.route = route
        self.isAtLiveEdge = isAtLiveEdge
    }
}

/// Process-wide audio and display ownership for independently retained live players.
public struct LiveChannelOutputPolicy: Equatable, Sendable {
    public var isAudible: Bool
    public var sharesAudioSession: Bool
    public var suppressesDisplayMatching: Bool

    public init(
        isAudible: Bool = true,
        sharesAudioSession: Bool = false,
        suppressesDisplayMatching: Bool = false
    ) {
        self.isAudible = isAudible
        self.sharesAudioSession = sharesAudioSession
        self.suppressesDisplayMatching = suppressesDisplayMatching
    }
}

/// Implemented in EnginePlozzigen and injected by the app to avoid a feature/engine dependency cycle.
@MainActor
public protocol LiveChannelEngine: VideoEngine {
    var liveSnapshot: LiveChannelEngineSnapshot { get }
    /// Confirmed audio-only output can become audible without a video frame.
    var isAudioOnlyPlaybackReady: Bool { get }
    var onLiveOutputReadinessChanged: (@MainActor () -> Void)? { get set }
    /// The cushion applied to this load; the host allows that time in addition to its startup deadline.
    var liveStartupBuffer: LivePlaybackBuffer { get }
    var livePlaybackFailureDiagnostic: PlaybackFailureDiagnostic? { get }
    /// The engine will publish its terminal failure after a bounded diagnostic read.
    var isCapturingLiveFailureDiagnostic: Bool { get }
    var onLiveSourceReset: (@MainActor () -> Void)? { get set }
    /// A scheduled media boundary resets tracks/cues, not the channel or decoder owner.
    var onProgrammeChanged: (@MainActor () -> Void)? { get set }
    var supportsConcurrentPlayback: Bool { get }
    var recoverableProgrammeIssue: LibraryChannelError? { get }
    var currentLibraryItem: LibraryChannelItem? { get }
    func configureLiveOutput(_ policy: LiveChannelOutputPolicy)
    func setWatching(_ isWatching: Bool)
    func loadChannel(_ input: LiveChannelInput) async throws
    func loadLive(url: URL, httpHeaders: [String: String]) async
    func seekToLiveEdge() async
    /// A scrub preview `seconds` into the seekable window (from its oldest end),
    /// or nil when the engine can't produce one.
    func liveScrubThumbnail(secondsIntoWindow seconds: TimeInterval, maxWidth: Int) async -> CGImage?
}

public extension LiveChannelEngine {
    var isAudioOnlyPlaybackReady: Bool { false }
    var onLiveOutputReadinessChanged: (@MainActor () -> Void)? {
        get { nil }
        set {}
    }
    var liveStartupBuffer: LivePlaybackBuffer { .automatic }
    var livePlaybackFailureDiagnostic: PlaybackFailureDiagnostic? { nil }
    var isCapturingLiveFailureDiagnostic: Bool { false }
    var supportsConcurrentPlayback: Bool { false }
    var recoverableProgrammeIssue: LibraryChannelError? { nil }
    var currentLibraryItem: LibraryChannelItem? { nil }
    var onProgrammeChanged: (@MainActor () -> Void)? {
        get { nil }
        set {}
    }
    func configureLiveOutput(_ policy: LiveChannelOutputPolicy) {}
    func setWatching(_ isWatching: Bool) {}
    func liveScrubThumbnail(secondsIntoWindow seconds: TimeInterval, maxWidth: Int) async -> CGImage? { nil }
    func loadChannel(_ input: LiveChannelInput) async throws {
        switch input {
        case .stream(let url, let headers):
            await loadLive(url: url, httpHeaders: headers)
        case .libraryChannel:
            throw LiveChannelInputError.unsupportedSource
        }
    }
}
#endif
