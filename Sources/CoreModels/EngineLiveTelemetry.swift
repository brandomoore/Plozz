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

    public init(droppedFrameCount: Int? = nil, observedFps: Double? = nil, observedBitrate: Double? = nil,
                bufferedSecondsAhead: Double? = nil) {
        self.droppedFrameCount = droppedFrameCount
        self.observedFps = observedFps
        self.observedBitrate = observedBitrate
        self.bufferedSecondsAhead = bufferedSecondsAhead
    }
}
