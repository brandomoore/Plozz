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
    public var statistics: EnginePlaybackStatistics?

    public init(droppedFrameCount: Int? = nil, observedFps: Double? = nil, observedBitrate: Double? = nil,
                bufferedSecondsAhead: Double? = nil, audioPipelineDescription: String? = nil,
                sessionCache: EngineSessionCache? = nil, statistics: EnginePlaybackStatistics? = nil) {
        self.droppedFrameCount = droppedFrameCount
        self.observedFps = observedFps
        self.observedBitrate = observedBitrate
        self.bufferedSecondsAhead = bufferedSecondsAhead
        self.audioPipelineDescription = audioPipelineDescription
        self.sessionCache = sessionCache
        self.statistics = statistics
    }
}

/// Cached engine measurements, not source metadata or a measurement of speaker/display output.
public struct EnginePlaybackStatistics: Equatable, Sendable {
    public enum Delivery: Equatable, Sendable {
        case source, local
    }

    public var decoder: String?
    /// Played video + audio bytes over media time (recent ~10 seconds and session mean).
    /// Never populated from a remote playlist's declared bandwidth.
    public var recentBitrate: Double?
    public var averageBitrate: Double?
    public var audioBridgeBitrate: Double?
    public var delivery: Delivery
    public var deliveryBitrate: Double?
    public var deliveredBytes: Int64?
    /// Producer audio/video timestamp gap, not measured lip sync at the output.
    public var muxAVGapMilliseconds: Double?
    public var cachedBytes: Int64?
    public var sourceBytes: Int64?
    public var producerRestarts: Int?
    public var muxedBytes: Int64?
    public var servedBytes: Int64?
    public var serverRequests: Int?
    public var audioBridgeBytes: Int64?
    public var residentMemoryBytes: Int64?

    public init(
        decoder: String? = nil, recentBitrate: Double? = nil, averageBitrate: Double? = nil,
        audioBridgeBitrate: Double? = nil, delivery: Delivery = .source,
        deliveryBitrate: Double? = nil, deliveredBytes: Int64? = nil,
        muxAVGapMilliseconds: Double? = nil, cachedBytes: Int64? = nil, sourceBytes: Int64? = nil,
        producerRestarts: Int? = nil, muxedBytes: Int64? = nil, servedBytes: Int64? = nil,
        serverRequests: Int? = nil, audioBridgeBytes: Int64? = nil, residentMemoryBytes: Int64? = nil
    ) {
        self.decoder = decoder
        self.recentBitrate = recentBitrate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.averageBitrate = averageBitrate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.audioBridgeBitrate = audioBridgeBitrate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.delivery = delivery
        self.deliveryBitrate = deliveryBitrate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.deliveredBytes = deliveredBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.muxAVGapMilliseconds = muxAVGapMilliseconds.flatMap { $0.isFinite ? $0 : nil }
        self.cachedBytes = cachedBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.sourceBytes = sourceBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.producerRestarts = producerRestarts.flatMap { $0 >= 0 ? $0 : nil }
        self.muxedBytes = muxedBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.servedBytes = servedBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.serverRequests = serverRequests.flatMap { $0 >= 0 ? $0 : nil }
        self.audioBridgeBytes = audioBridgeBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.residentMemoryBytes = residentMemoryBytes.flatMap { $0 >= 0 ? $0 : nil }
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
