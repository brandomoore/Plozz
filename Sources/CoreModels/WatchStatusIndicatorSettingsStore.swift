import Foundation
import Observation

/// Persists the selected `WatchStatusIndicator` across launches in standard
/// `UserDefaults`.
///
/// Mirrors `CardStyleSettingsStore` exactly. The choice is stored **per profile**
/// (key `com.plozz.watchStatusIndicator`, scoped by namespace); the primary
/// profile keeps the legacy un-suffixed key so existing installs upgrade cleanly.
public protocol WatchStatusIndicatorSettingsStoring: Sendable {
    func load() -> WatchStatusIndicator
    func save(_ indicator: WatchStatusIndicator)
    func loadShowsUnwatchedEpisodeCount() -> Bool
    func saveShowsUnwatchedEpisodeCount(_ enabled: Bool)
    func loadColor() -> WatchIndicatorColor
    func saveColor(_ color: WatchIndicatorColor)
}

public final class WatchStatusIndicatorSettingsStore: WatchStatusIndicatorSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let episodeCountKey: String
    private let colorKey: String
    public static let episodeCountStorageKey = "com.plozz.showsUnwatchedEpisodeCount"
    public static let colorStorageKey = "com.plozz.watchIndicatorColor"
    public static let defaultShowsUnwatchedEpisodeCount = true

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key; other profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.watchStatusIndicator", namespace: namespace)
        self.episodeCountKey = SettingsKey.scoped(Self.episodeCountStorageKey, namespace: namespace)
        self.colorKey = SettingsKey.scoped(Self.colorStorageKey, namespace: namespace)
    }

    public func load() -> WatchStatusIndicator {
        guard let raw = defaults.string(forKey: key),
              let indicator = WatchStatusIndicator(rawValue: raw) else {
            return .default
        }
        return indicator
    }

    public func save(_ indicator: WatchStatusIndicator) {
        defaults.set(indicator.rawValue, forKey: key)
    }

    public func loadShowsUnwatchedEpisodeCount() -> Bool {
        defaults.object(forKey: episodeCountKey) as? Bool ?? Self.defaultShowsUnwatchedEpisodeCount
    }

    public func saveShowsUnwatchedEpisodeCount(_ enabled: Bool) {
        defaults.set(enabled, forKey: episodeCountKey)
    }

    public func loadColor() -> WatchIndicatorColor {
        defaults.string(forKey: colorKey).flatMap(WatchIndicatorColor.init(rawValue:)) ?? .default
    }

    public func saveColor(_ color: WatchIndicatorColor) {
        defaults.set(color.rawValue, forKey: colorKey)
    }
}

/// Observable wrapper so SwiftUI settings screens can two-way bind and have the
/// chosen indicator persisted + broadcast to the view tree. Mirrors
/// `CardStyleSettingsModel`.
@MainActor
@Observable
public final class WatchStatusIndicatorSettingsModel {
    public var indicator: WatchStatusIndicator {
        didSet { store.save(indicator) }
    }
    public var showsUnwatchedEpisodeCount: Bool {
        didSet { store.saveShowsUnwatchedEpisodeCount(showsUnwatchedEpisodeCount) }
    }
    public var color: WatchIndicatorColor {
        didSet { store.saveColor(color) }
    }

    private let store: WatchStatusIndicatorSettingsStoring

    public init(store: WatchStatusIndicatorSettingsStoring = WatchStatusIndicatorSettingsStore()) {
        self.store = store
        self.indicator = store.load()
        self.showsUnwatchedEpisodeCount = store.loadShowsUnwatchedEpisodeCount()
        self.color = store.loadColor()
    }
}
