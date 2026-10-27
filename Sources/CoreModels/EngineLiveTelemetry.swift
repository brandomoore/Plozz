import Foundation

/// Live, per-tick decode/render stats an engine can publish for the diagnostics
/// overlay. These complement AVPlayer metrics or describe software-only paths.
/// Encoded bitrate is a stream fact, not a network throughput measurement.
public struct EngineLiveTelemetry: Equatable, Sendable {
    /// Cumulative dropped video frames since playback started.
    public var droppedFrameCount: Int?
    /// Frames the engine is actually presenting right now (frames/sec).
    public var observedFps: Double?
    /// Instantaneous stream bitrate in bits/sec (overlay-normalised; engines that
    /// only know Mbps multiply by 1_000_000 before publishing).
    public var observedBitrate: Double?
    /// Contiguous media held by the engine, independent of AVPlayer's decode buffer.
    public var bufferedSecondsAhead: Double?
    /// Engine-owned label for the active audio pipeline, not a receiver-output
    /// measurement. Display verbatim; never parse it to make playback decisions.
    public var audioPipelineDescription: String?
    public var sessionCache: EngineSessionCache?

    public init(droppedFrameCount: Int? = nil, observedFps: Double? = nil, observedBitrate: Double? = nil,
                bufferedSecondsAhead: Double? = nil, audioPipelineDescription: String? = nil,
                sessionCache: EngineSessionCache? = nil) {
        self.droppedFrameCount = droppedFrameCount
        self.observedFps = observedFps
        self.observedBitrate = observedBitrate
        self.bufferedSecondsAhead = bufferedSecondsAhead
        self.audioPipelineDescription = audioPipelineDescription
        self.sessionCache = sessionCache
    }
}

/// The engine's active temporary cache and its effective budget.
/// Memory usage excludes purgeable played history; disk usage includes retained history.
/// The budget and requested duration are not promises of contiguous playable coverage.
public struct EngineSessionCache: Equatable, Sendable {
    public enum Storage: Equatable, Sendable {
        case memory, disk
    }
    public let residentBytes: Int64
    public let effectiveBudgetBytes: Int64
    public let storage: Storage
    public let targetSeconds: Double?
    public let byteLimitReached: Bool

    public init(residentBytes: Int64, effectiveBudgetBytes: Int64,
                storage: Storage = .disk, targetSeconds: Double? = nil, byteLimitReached: Bool = false) {
        self.residentBytes = residentBytes
        self.effectiveBudgetBytes = effectiveBudgetBytes
        self.storage = storage
        self.targetSeconds = targetSeconds
        self.byteLimitReached = byteLimitReached
    }
}
