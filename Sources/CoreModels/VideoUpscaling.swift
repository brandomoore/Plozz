import Foundation
import os

public enum VideoUpscaling: String, CaseIterable, Codable, Sendable {
    case off
    case automatic
    case animation

    public static let `default`: Self = .automatic

    public var title: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .automatic: "Automatic"
        case .animation: "Animation"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            let rawValue = try container.decode(String.self)
            if let selection = Self(rawValue: rawValue) {
                self = selection
                return
            }
        } catch is DecodingError {
            // Preserve the rest of the profile when this one preference is invalid.
        }
        Logger(subsystem: "com.plozz.app", category: "settings")
            .error("Invalid video upscaling preference; using Automatic")
        self = .default
    }
}
