import Foundation

public struct StreamingQualitySupport: Equatable, Sendable {
    public let heights: [Int]
    public let minimumBitrateKbps: Int
    public let maximumBitrateKbps: Int
    public let codecs: [StreamingCodecPreference]
    public let notice: LocalizedStringResource?

    public static let standard = Self(
        heights: CustomStreamingQuality.supportedHeights,
        minimumBitrateKbps: 129,
        maximumBitrateKbps: CustomStreamingQuality.maximumBitrateKbps,
        codecs: StreamingCodecPreference.allCases,
        notice: nil
    )

    public static let silo = Self(
        heights: [480, 720, 1080, 2160],
        minimumBitrateKbps: 292,
        maximumBitrateKbps: 1_000_192,
        codecs: [.automatic, .preferH264],
        notice: "Silo currently converts to H.264 at 480p, 720p, 1080p, or 4K. Resolution limits use the video height. Unsupported choices are unavailable."
    )

    public func validationMessage(for quality: StreamingQuality) -> LocalizedStringResource? {
        if let error = quality.validationError { return error.userMessage }
        if let height = quality.maximumHeight, !heights.contains(height) {
            return "This server doesn’t support that resolution limit. Choose an available resolution."
        }
        if let bitrate = quality.maximumBitrate.map({ $0 / 1_000 }),
           bitrate < minimumBitrateKbps || bitrate > maximumBitrateKbps {
            return "Choose a total bitrate from \(minimumBitrateKbps.formatted()) to \(maximumBitrateKbps.formatted()) Kbps for this server."
        }
        return nil
    }
}
