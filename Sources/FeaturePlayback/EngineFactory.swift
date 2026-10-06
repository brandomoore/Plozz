#if canImport(AVFoundation)
import Foundation
import CoreModels

/// Builds the concrete `VideoEngine`s the `PlayerViewModel` routes between.
///
/// This is the seam that keeps `FeaturePlayback` from depending on the heavy
/// on-device decode binaries: `FeaturePlayback` knows only how to make the native
/// (AVPlayer) engine, and the composition root (`AppShell`, which *can* depend on
/// `EnginePlozzigen`) injects a `makePlozzigen` closure that constructs the
/// Plozzigen (AetherEngine) engine. The view model picks a
/// ``CoreModels/PlaybackEngineKind`` via ``CoreModels/EngineRouter`` and calls the
/// matching closure here.
///
/// The default value (``native``) supplies only the native engine, so existing
/// call sites that don't pass a factory keep their byte-for-byte current
/// behaviour (always `NativeVideoEngine`).
public struct EngineFactory {
    /// Builds the AVPlayer-backed engine. Always present.
    public var makeNative: @MainActor (SubtitleStyle) -> any VideoEngine
    /// Builds the Plozzigen engine (FFmpeg demux → HLS-fMP4 → AVPlayer), or `nil`
    /// when the engine isn't linked. This is the sole on-device decode engine:
    /// it plays AVPlayer-incompatible sources (MKV, DoVi/Atmos MKV, HEVC `hev1`,
    /// AV1, DTS/TrueHD, …) and decodes embedded + bitmap (PGS/DVB/DVD) subtitles
    /// itself, so no server transcode/burn-in is needed for them.
    public var makePlozzigen: (@MainActor () -> (any VideoEngine)?)?
    /// Bounded header probe for an already-resolved episode handoff target.
    /// This gives handoff policy provider-independent range truth before stopping
    /// the outgoing engine, without consulting catalogs or metadata APIs.
    public var probeSourceDynamicRange:
        (@Sendable (PlaybackRequest) async -> SourceDynamicRange?)?
    /// Builds an on-device scrub-still extractor over an item's original file,
    /// used when the server has no pre-generated previews. The closure argument
    /// returns whichever engine is playing at extraction time, so the extractor
    /// can share that engine's source and defer to it while playback is starved.
    /// `nil` when no on-device decoder is linked (no generated previews).
    public var makeScrubStillExtractor:
        (@MainActor (PlaybackSource, @escaping @MainActor () -> (any VideoEngine)?)
            -> (any ScrubStillExtracting)?)?

    public init(
        makeNative: @escaping @MainActor (SubtitleStyle) -> any VideoEngine = { NativeVideoEngine(style: $0) },
        makePlozzigen: (@MainActor () -> (any VideoEngine)?)? = nil,
        probeSourceDynamicRange:
            (@Sendable (PlaybackRequest) async -> SourceDynamicRange?)? = nil,
        makeScrubStillExtractor:
            (@MainActor (PlaybackSource, @escaping @MainActor () -> (any VideoEngine)?)
                -> (any ScrubStillExtracting)?)? = nil
    ) {
        self.makeNative = makeNative
        self.makePlozzigen = makePlozzigen
        self.probeSourceDynamicRange = probeSourceDynamicRange
        self.makeScrubStillExtractor = makeScrubStillExtractor
    }

    /// Whether the Plozzigen (on-device decode) engine is wired in. Drives the
    /// router's `hybridAvailable` and the cross-engine fallback so advertise ⇔
    /// route stays in lockstep.
    public var plozzigenAvailable: Bool { makePlozzigen != nil }

    /// Native-only factory: the conservative default that preserves today's
    /// behaviour everywhere the Plozzigen engine isn't injected.
    public static let native = EngineFactory()
}
#endif
