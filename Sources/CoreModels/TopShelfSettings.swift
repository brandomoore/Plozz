import Foundation
import Observation
import OSLog

public struct TopShelfSettings: Codable, Equatable, Sendable {
    public static let itemCountRange = 1...20
    public static let `default` = TopShelfSettings()

    public var isEnabled: Bool
    public var usesFullScreen: Bool
    public var continueWatchingItems: Int {
        didSet { continueWatchingItems = Self.bounded(continueWatchingItems) }
    }
    public var recentlyAddedItems: Int {
        didSet { recentlyAddedItems = Self.bounded(recentlyAddedItems) }
    }

    public init(
        isEnabled: Bool = true, usesFullScreen: Bool = false,
        continueWatchingItems: Int = 4, recentlyAddedItems: Int = 4
    ) {
        self.isEnabled = isEnabled
        self.usesFullScreen = usesFullScreen
        self.continueWatchingItems = Self.bounded(continueWatchingItems)
        self.recentlyAddedItems = Self.bounded(recentlyAddedItems)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, usesFullScreen, continueWatchingItems, recentlyAddedItems
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? Self.default.isEnabled,
            usesFullScreen: try values.decodeIfPresent(Bool.self, forKey: .usesFullScreen)
                ?? Self.default.usesFullScreen,
            continueWatchingItems: try values.decodeIfPresent(Int.self, forKey: .continueWatchingItems)
                ?? Self.default.continueWatchingItems,
            recentlyAddedItems: try values.decodeIfPresent(Int.self, forKey: .recentlyAddedItems)
                ?? Self.default.recentlyAddedItems
        )
    }

    private static func bounded(_ count: Int) -> Int {
        guard itemCountRange.contains(count) else {
            Logger(subsystem: "com.plozz.app", category: "settings")
                .warning("Top Shelf item count was outside the supported range; clamping.")
            return min(max(count, itemCountRange.lowerBound), itemCountRange.upperBound)
        }
        return count
    }
}

/// The current Apple TV system user's preferences: tvOS partitions `.standard`
/// under the User Management entitlement. Plozz viewers do not own or sync these.
@MainActor
@Observable
public final class TopShelfSettingsModel {
    public static let shared = TopShelfSettingsModel()
    public static let storageKey = "com.plozz.deviceTopShelf"

    public var settings: TopShelfSettings {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private static let logger = Logger(subsystem: "com.plozz.app", category: "settings")

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = .default
        if let data = defaults.data(forKey: Self.storageKey) {
            do {
                settings = try JSONDecoder().decode(TopShelfSettings.self, from: data)
            } catch {
                Self.logger.error("Unable to restore device Top Shelf settings; using defaults.")
            }
        }
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Self.storageKey)
        } catch {
            Self.logger.error("Unable to save device Top Shelf settings.")
        }
    }
}
