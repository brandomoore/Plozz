import Foundation

/// Numeric engine evidence for explicit diagnostic submissions. Engine descriptions
/// are deliberately excluded: they are display text, not an export contract.
public struct PlaybackPipelineSnapshot: Codable, Equatable, Sendable {
    public let droppedFrames: Int?
    public let framesPerSecond: Double?
    public let bitrate: Double?
    public let bufferedSeconds: Double?
    public let cacheBytes: Int64?
    public let cacheBudgetBytes: Int64?
    public let cacheLimitReached: Bool?

    public init?(_ telemetry: EngineLiveTelemetry?) {
        guard let telemetry else { return nil }
        droppedFrames = telemetry.droppedFrameCount.flatMap { (0...Int(Int32.max)).contains($0) ? $0 : nil }
        framesPerSecond = Self.number(telemetry.observedFps, maximum: 1_000)
        bitrate = Self.number(telemetry.observedBitrate, maximum: 1_000_000_000_000)
        bufferedSeconds = Self.number(telemetry.bufferedSecondsAhead, maximum: 172_800)
        cacheBytes = Self.bytes(telemetry.sessionCache?.residentBytes)
        cacheBudgetBytes = Self.bytes(telemetry.sessionCache?.effectiveBudgetBytes)
        cacheLimitReached = telemetry.sessionCache?.byteLimitReached
    }

    var isValid: Bool {
        droppedFrames.map { (0...Int(Int32.max)).contains($0) } != false
            && Self.valid(framesPerSecond, maximum: 1_000)
            && Self.valid(bitrate, maximum: 1_000_000_000_000)
            && Self.valid(bufferedSeconds, maximum: 172_800)
            && (cacheBytes == nil || Self.bytes(cacheBytes) != nil)
            && (cacheBudgetBytes == nil || Self.bytes(cacheBudgetBytes) != nil)
    }

    private static func number(_ value: Double?, maximum: Double) -> Double? {
        value.flatMap { $0.isFinite && (0...maximum).contains($0) ? $0 : nil }
    }

    private static func valid(_ value: Double?, maximum: Double) -> Bool {
        value == nil || number(value, maximum: maximum) != nil
    }

    private static func bytes(_ value: Int64?) -> Int64? {
        value.flatMap { (0...(1 << 50)).contains($0) ? $0 : nil }
    }
}
