import Foundation
import os

public enum SpatialAudioLayout: String, CaseIterable, Codable, Sendable {
    case fiveOneTwo = "5.1.2"
    case fiveOneFour = "5.1.4"
    case sevenOneTwo = "7.1.2"
    case sevenOneFour = "7.1.4"
    case nineOneSix = "9.1.6"

    public static let `default`: Self = .nineOneSix

    public var supportsDTSXHeights: Bool {
        self == .sevenOneFour || self == .nineOneSix
    }
}

public struct SpatialAudioLayoutStore {
    public static let storageKey = "com.plozz.spatialAudioLayout"
    private static let logger = Logger(subsystem: "com.plozz.app", category: "settings")
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SpatialAudioLayout {
        guard let stored = defaults.object(forKey: Self.storageKey) else { return .default }
        guard let rawValue = stored as? String, let layout = SpatialAudioLayout(rawValue: rawValue) else {
            Self.logger.error("Invalid spatial audio layout; using the default")
            return .default
        }
        return layout
    }

    public func save(_ layout: SpatialAudioLayout) {
        defaults.set(layout.rawValue, forKey: Self.storageKey)
    }
}
