import Foundation
import Observation

/// Profile appearance, optional library-category overrides, and an independent
/// Live TV look. Live TV inherits the base until explicitly customized.
public struct SubtitleStylePreferences: Codable, Equatable, Sendable {
    /// The profile-wide appearance, applied to any category without an override.
    public var base: SubtitleStyle
    /// Per-content-type appearance overrides. Empty today (global-only); a present
    /// entry replaces `base` whole for that category.
    public var overrides: [SubtitleContentCategory: SubtitleStyle]
    public var liveTV: SubtitleStyle?

    public var resolvedLiveTV: SubtitleStyle { liveTV ?? base }

    public init(base: SubtitleStyle = .profileDefault,
                overrides: [SubtitleContentCategory: SubtitleStyle] = [:],
                liveTV: SubtitleStyle? = nil) {
        self.base = base
        self.overrides = overrides
        self.liveTV = liveTV
    }

    /// The appearance for a category: its override if present, else the base.
    public func resolved(for category: SubtitleContentCategory) -> SubtitleStyle {
        overrides[category] ?? base
    }

    public static let `default` = SubtitleStylePreferences()

    private enum CodingKeys: String, CodingKey { case base, overrides, liveTV }

    /// Tolerant decode so a blob written before `overrides` existed (or with a
    /// missing `base`) still decodes using the historical custom baseline.
    /// A saved blob is never treated as a newly created profile.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.base = try c.decodeIfPresent(SubtitleStyle.self, forKey: .base) ?? .default
        self.overrides = try c.decodeIfPresent([SubtitleContentCategory: SubtitleStyle].self, forKey: .overrides) ?? [:]
        self.liveTV = try c.decodeIfPresent(SubtitleStyle.self, forKey: .liveTV)
    }
}

/// Persists subtitle **appearance** (`SubtitleStyle`) per profile. The appearance
/// half extracted from the retired `CaptionSettingsStore`, and the source of
/// truth that drives the live renderer (`liveSubtitles.style`).
public protocol SubtitleStyleStoring: Sendable {
    func load() -> SubtitleStylePreferences
    func save(_ preferences: SubtitleStylePreferences)
}

public final class SubtitleStyleStore: SubtitleStyleStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let namespace: String?

    /// The `UserDefaults` base key subtitle appearance persists under.
    public static let storageKey = "com.plozz.subtitleStyle"
    public static let legacyLiveStyleStorageKey = "com.plozz.liveSubtitleStyle"
    public static let didChangeNotification = Notification.Name("com.plozz.subtitleStyle.changed")

    /// - Parameter namespace: per-profile scope. `nil` (the default/primary
    ///   profile) uses the un-suffixed key; other profiles pass their `Profile.id`.
    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        self.namespace = namespace
        self.key = SettingsKey.scoped(Self.storageKey, namespace: namespace)
        migrateFromLegacyIfNeeded()
        migrateLegacyLiveStyleIfNeeded()
    }

    public func load() -> SubtitleStylePreferences {
        guard let data = defaults.data(forKey: key) else { return .default }
        return (try? JSONDecoder().decode(SubtitleStylePreferences.self, from: data))
            ?? SubtitleStylePreferences(base: .default)
    }

    public func save(_ preferences: SubtitleStylePreferences) {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: key)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// One-time seed from the retired `CaptionSettings` blob: if this profile has
    /// no persisted appearance yet but did save the old combined model, adopt its
    /// custom look (size / colour / background / edge) as the base.
    private func migrateFromLegacyIfNeeded() {
        guard defaults.data(forKey: key) == nil,
              let legacy = LegacyCaptionSettings.load(from: defaults, namespace: namespace) else {
            return
        }
        save(SubtitleStylePreferences(base: SubtitleStyle(from: legacy)))
    }

    private func migrateLegacyLiveStyleIfNeeded() {
        let legacyKey = SettingsKey.scoped(Self.legacyLiveStyleStorageKey, namespace: namespace)
        guard let legacy = defaults.data(forKey: legacyKey) else { return }
        do {
            var preferences = try defaults.data(forKey: key).map {
                try JSONDecoder().decode(SubtitleStylePreferences.self, from: $0)
            } ?? .default
            if preferences.liveTV == nil {
                preferences.liveTV = try JSONDecoder().decode(SubtitleStyle.self, from: legacy)
                let data = try JSONEncoder().encode(preferences)
                defaults.set(data, forKey: key)
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            }
            // The canonical override wins, and disabling it must not revive the old key.
            defaults.removeObject(forKey: legacyKey)
        } catch {
            NSLog("Plozz: could not migrate the legacy Live TV subtitle style; retained the original settings.")
        }
    }
}

// MARK: - Observable model

/// Observable wrapper so the settings screen / in-player editor can two-way bind
/// the subtitle appearance and have changes persisted + broadcast to the live
/// renderer. `style` is the library base; Live TV can inherit it or use its own look.
@MainActor
@Observable
public final class SubtitleStyleModel {
    /// The profile-wide appearance (the base). Two-way bindable; edits persist and
    /// flow to any active player via the live overlay.
    public var style: SubtitleStyle {
        didSet { persist() }
    }
    /// Per-content-type overrides. Empty today; persisted alongside `style` so
    /// adding per-category editing later needs no store change.
    public private(set) var overrides: [SubtitleContentCategory: SubtitleStyle] {
        didSet { persist() }
    }
    public var liveTVStyle: SubtitleStyle? {
        didSet { persist() }
    }

    public var usesSeparateLiveTVStyle: Bool {
        get { liveTVStyle != nil }
        set {
            if newValue {
                if liveTVStyle == nil { liveTVStyle = style }
            } else {
                liveTVStyle = nil
            }
        }
    }

    public var resolvedLiveTVStyle: SubtitleStyle {
        get { liveTVStyle ?? style }
        set { liveTVStyle = newValue }
    }

    private let store: SubtitleStyleStoring
    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    @ObservationIgnored private var applyingStoredValues = false

    public init(store: SubtitleStyleStoring = SubtitleStyleStore()) {
        self.store = store
        let prefs = store.load()
        self.style = prefs.base
        self.overrides = prefs.overrides
        self.liveTVStyle = prefs.liveTV
        storeObserver = NotificationCenter.default.addObserver(
            forName: SubtitleStyleStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadStoredValues() }
        }
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    /// The appearance to render for a content category: its override if present,
    /// else the global base. Today always the base (overrides empty).
    public func resolved(for category: SubtitleContentCategory) -> SubtitleStyle {
        overrides[category] ?? style
    }

    private func persist() {
        guard !applyingStoredValues else { return }
        store.save(SubtitleStylePreferences(base: style, overrides: overrides, liveTV: liveTVStyle))
    }

    private func reloadStoredValues() {
        let preferences = store.load()
        guard preferences.base != style || preferences.overrides != overrides || preferences.liveTV != liveTVStyle else {
            return
        }
        applyingStoredValues = true
        defer { applyingStoredValues = false }
        style = preferences.base
        overrides = preferences.overrides
        liveTVStyle = preferences.liveTV
    }
}
