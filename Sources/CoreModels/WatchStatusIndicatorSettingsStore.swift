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
    func loadShowsProgressBars() -> Bool
    func saveShowsProgressBars(_ enabled: Bool)
    func loadEpisodeCountStyle() -> EpisodeCountBadgeStyle
    func saveEpisodeCountStyle(_ style: EpisodeCountBadgeStyle)
    func loadColor() -> WatchIndicatorColor
    func saveColor(_ color: WatchIndicatorColor)
}

public final class WatchStatusIndicatorSettingsStore: WatchStatusIndicatorSettingsStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let episodeCountKey: String
    private let progressBarsKey: String
    private let episodeCountStyleKey: String
    private let colorKey: String
    public static let episodeCountStorageKey = "com.plozz.showsUnwatchedEpisodeCount"
    public static let progressBarsStorageKey = "com.plozz.showsProgressBars"
    public static let episodeCountStyleStorageKey = "com.plozz.episodeCountBadgeStyle"
    public static let colorStorageKey = "com.plozz.watchIndicatorColor"
    public static let defaultShowsUnwatchedEpisodeCount = true
    public static let defaultShowsProgressBars = true

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the legacy un-suffixed key; other profiles pass their
    ///   `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.key = SettingsKey.scoped("com.plozz.watchStatusIndicator", namespace: namespace)
        self.episodeCountKey = SettingsKey.scoped(Self.episodeCountStorageKey, namespace: namespace)
        self.progressBarsKey = SettingsKey.scoped(Self.progressBarsStorageKey, namespace: namespace)
        self.episodeCountStyleKey = SettingsKey.scoped(Self.episodeCountStyleStorageKey, namespace: namespace)
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

    public func loadEpisodeCountStyle() -> EpisodeCountBadgeStyle {
        if let raw = defaults.string(forKey: episodeCountStyleKey) {
            return EpisodeCountBadgeStyle(rawValue: raw) ?? .default
        }

        // Preserve the old appearance once, then keep it independent of watch marks.
        let migrated: EpisodeCountBadgeStyle = load() == .watched ? .floating : .attached
        saveEpisodeCountStyle(migrated)
        return migrated
    }

    public func saveEpisodeCountStyle(_ style: EpisodeCountBadgeStyle) {
        defaults.set(style.rawValue, forKey: episodeCountStyleKey)
    }

    public func loadShowsProgressBars() -> Bool {
        defaults.object(forKey: progressBarsKey) as? Bool ?? Self.defaultShowsProgressBars
    }

    public func saveShowsProgressBars(_ enabled: Bool) {
        defaults.set(enabled, forKey: progressBarsKey)
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
    public var showsProgressBars: Bool {
        didSet { store.saveShowsProgressBars(showsProgressBars) }
    }
    public var color: WatchIndicatorColor {
        didSet { store.saveColor(color) }
    }
    public var episodeCountStyle: EpisodeCountBadgeStyle {
        didSet { store.saveEpisodeCountStyle(episodeCountStyle) }
    }

    private let store: WatchStatusIndicatorSettingsStoring

    public init(store: WatchStatusIndicatorSettingsStoring = WatchStatusIndicatorSettingsStore()) {
        self.store = store
        self.indicator = store.load()
        self.showsUnwatchedEpisodeCount = store.loadShowsUnwatchedEpisodeCount()
        self.showsProgressBars = store.loadShowsProgressBars()
        self.color = store.loadColor()
        self.episodeCountStyle = store.loadEpisodeCountStyle()
    }
}
