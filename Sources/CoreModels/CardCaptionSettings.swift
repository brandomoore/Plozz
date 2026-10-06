import Foundation
import os

public enum CardCaptionView: String, CaseIterable, Codable, Sendable {
    case home, recommended, browse, collections, playlists, search, watchlist
    case related, episodes, extras, filmography

    public static var customizableCases: [Self] {
        allCases.filter { $0 != .episodes }
    }

    public var displayName: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .recommended: "Recommended"
        case .browse: "Browse"
        case .collections: "Collections"
        case .playlists: "Playlists"
        case .search: "Search"
        case .watchlist: "Watchlist"
        case .related: "Related titles"
        case .episodes: "Episodes"
        case .extras: "Extras"
        case .filmography: "Filmography"
        }
    }
}

public enum CardCaptionOverride: String, CaseIterable, Identifiable, Sendable {
    case automatic, show, hide
    public var id: Self { self }

    public var displayName: LocalizedStringResource {
        switch self {
        case .automatic: "Default"
        case .show: "Labels"
        case .hide: "No labels"
        }
    }
}

public struct CardCaptionSettings: Codable, Equatable, Sendable {
    public var showsLabels: Bool
    public private(set) var overrides: [CardCaptionView: Bool]

    public static let `default` = CardCaptionSettings()

    public init(showsLabels: Bool = false, overrides: [CardCaptionView: Bool] = [:]) {
        self.showsLabels = showsLabels
        self.overrides = overrides
    }

    public func showsLabels(in view: CardCaptionView) -> Bool {
        // Episode stills alone do not identify an episode, even with a saved hide override.
        view == .episodes || (overrides[view] ?? showsLabels)
    }

    public func override(for view: CardCaptionView) -> CardCaptionOverride {
        guard let value = overrides[view] else { return .automatic }
        return value ? .show : .hide
    }

    public mutating func setOverride(_ value: CardCaptionOverride, for view: CardCaptionView) {
        switch value {
        case .automatic: overrides.removeValue(forKey: view)
        case .show: overrides[view] = true
        case .hide: overrides[view] = false
        }
    }

    public mutating func resetOverrides() {
        overrides.removeAll()
    }

    private enum CodingKeys: String, CodingKey { case showsLabels, overrides }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsLabels = try container.decodeIfPresent(Bool.self, forKey: .showsLabels) ?? false
        let stored = try container.decodeIfPresent([String: Bool].self, forKey: .overrides) ?? [:]
        overrides = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            CardCaptionView(rawValue: key).map { ($0, value) }
        })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showsLabels, forKey: .showsLabels)
        try container.encode(
            Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }),
            forKey: .overrides
        )
    }
}

public protocol CardCaptionSettingsStoring: Sendable {
    func load() -> CardCaptionSettings
    func save(_ settings: CardCaptionSettings)
}

public final class CardCaptionSettingsStore: CardCaptionSettingsStoring, @unchecked Sendable {
    public static let storageKey = "com.plozz.cardCaptionSettings"
    private static let logger = Logger(subsystem: "com.plozz.app", category: "settings")
    private let defaults: UserDefaults
    private let key: String
    private let legacyKey: String

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        key = SettingsKey.scoped(Self.storageKey, namespace: namespace)
        legacyKey = SettingsKey.scoped("com.plozz.heroSettings", namespace: namespace)
    }

    public func load() -> CardCaptionSettings {
        do {
            if let data = defaults.data(forKey: key) {
                defaults.set(true, forKey: key + ".migrated")
                return try JSONDecoder().decode(CardCaptionSettings.self, from: data)
            }
            guard !defaults.bool(forKey: key + ".migrated") else { return .default }
            defaults.set(true, forKey: key + ".migrated")
            // Preserve the old Home choice once, without turning an inherited
            // default into a permanent exception for a newly created profile.
            if let data = defaults.data(forKey: legacyKey) {
                struct LegacyCaptions: Decodable { let showsCardCaptions: Bool? }
                let legacy = try JSONDecoder().decode(LegacyCaptions.self, from: data)
                if let showsLabels = legacy.showsCardCaptions {
                    let migrated = CardCaptionSettings(overrides: [.home: showsLabels])
                    save(migrated)
                    return migrated
                }
            }
        } catch {
            Self.logger.error("Unable to read card label preferences: \(String(describing: error))")
        }
        return .default
    }

    public func save(_ settings: CardCaptionSettings) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(settings), forKey: key)
            defaults.set(true, forKey: key + ".migrated")
        } catch {
            Self.logger.error("Unable to save card label preferences: \(String(describing: error))")
        }
    }
}
