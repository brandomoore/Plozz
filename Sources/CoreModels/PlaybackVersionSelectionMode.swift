import Foundation

public enum PlaybackVersionSelectionMode: String, Codable, CaseIterable, Sendable {
    case askEveryTime
    case automatic
    case serverOrder

    public var title: LocalizedStringResource {
        switch self {
        case .askEveryTime: "Ask every time"
        case .automatic: "Choose automatically"
        case .serverOrder: "Use first from server"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "rememberChoice" {
            self = .automatic
        } else if let mode = Self(rawValue: value) {
            self = mode
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown version selection mode")
        }
    }
}
