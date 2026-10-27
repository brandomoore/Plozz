import Foundation

/// Per-profile background theme music preferences for movie and series details.
public struct ThemeMusicSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var volume: ThemeMusicVolume

    public init(
        isEnabled: Bool = false,
        volume: ThemeMusicVolume = .default
    ) {
        self.isEnabled = isEnabled
        self.volume = volume
    }

    public static let `default` = ThemeMusicSettings()

    public var shouldPlay: Bool {
        isEnabled && volume != .off
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, volume
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ThemeMusicSettings.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        volume = try container.decodeIfPresent(ThemeMusicVolume.self, forKey: .volume) ?? defaults.volume
    }
}

/// Linear player gain, from silence to the device's full playback level.
/// The old named levels retain their exact gain when a profile is upgraded.
public struct ThemeMusicVolume: Codable, Equatable, Hashable, Sendable {
    public let level: Double

    public init(_ level: Double) {
        self.level = level.isFinite ? min(1, max(0, level)) : Self.default.level
    }

    public static let `default` = Self(0.25)
    public static let off = Self(0)
    public static let low = Self(0.15)
    public static let medium = Self(0.35)
    public static let high = Self(0.6)

    public var gain: Float { Float(level) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let legacy = try? container.decode(String.self) {
            switch legacy {
            case "off": self = .off
            case "low": self = .low
            case "medium": self = .medium
            case "high": self = .high
            default: self = .default
            }
        } else {
            self.init(try container.decode(Double.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(level)
    }
}
