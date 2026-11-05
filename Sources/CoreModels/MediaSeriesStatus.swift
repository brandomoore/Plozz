import Foundation

/// Confirmed production status, independent of episode availability or schedules.
public enum MediaSeriesStatus: String, Codable, Hashable, Sendable {
    case returning
    case ended
    case canceled

    public init?(providerValue: String) {
        switch providerValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "returning series", "continuing": self = .returning
        case "ended": self = .ended
        case "canceled", "cancelled": self = .canceled
        default: return nil
        }
    }

    public var displayName: LocalizedStringResource {
        switch self {
        case .returning: LocalizedStringResource("Returning", comment: "Confirmed production status of a TV series.")
        case .ended: LocalizedStringResource("Ended", comment: "Confirmed production status of a TV series.")
        case .canceled: LocalizedStringResource("Canceled", comment: "Confirmed production status of a TV series.")
        }
    }
}
