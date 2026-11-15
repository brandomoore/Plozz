import Foundation

/// The viewer's framing choice, not a saved detector rectangle.
public struct VideoZoomPreference: Codable, Equatable, Sendable {
    public enum Mode: Int, Codable, CaseIterable, Sendable {
        case fit, fill, stretch, custom, picture
    }

    public static let customPercentRange = 50...200
    public static let onDemandDefault = VideoZoomPreference(mode: .picture)
    public var mode: Mode
    public let customPercent: Int

    public init(mode: Mode = .fit, customPercent: Int = 100) {
        self.mode = mode
        self.customPercent = min(max(customPercent, Self.customPercentRange.lowerBound),
                                 Self.customPercentRange.upperBound)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(mode: try values.decode(Mode.self, forKey: .mode),
                  customPercent: try values.decodeIfPresent(Int.self, forKey: .customPercent) ?? 100)
    }
}
