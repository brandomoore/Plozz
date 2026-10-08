import Foundation
import os

public enum CardCaptionView: String, CaseIterable, Codable, Sendable {
    case home, recommended, browse, collections, playlists, search, watchlist
    case related, episodes, extras, filmography

    public static var customizableCases: [Self] {
        allCases
    }

    public var customizationChoices: [CardCaptionOverride] {
        self == .home || self == .recommended ? [.show, .hide, .mixed] : [.show, .hide]
    }

    public var displayName: LocalizedStringResource {
        switch self {
        case .home: "Home rows"
        case .recommended: "Recommended"
        case .browse: "Browse"
        case .collections: "Collections"
        case .playlists: "Playlists"
        case .search: "Search results"
        case .watchlist: "Watchlist page"
        case .related: "Related titles"
        case .episodes: "Episode browser"
        case .extras: "Extras"
        case .filmography: "Filmography"
        }
    }
}

public enum CardCaptionOverride: String, CaseIterable, Identifiable, Sendable {
    case automatic, show, hide, mixed
    public var id: Self { self }

    public var displayName: LocalizedStringResource {
        switch self {
        case .automatic: "Default"
        case .show:
            LocalizedStringResource("cardLabels.on", defaultValue: "On", comment: "Per-view setting: show card labels.")
        case .hide:
            LocalizedStringResource("cardLabels.off", defaultValue: "Off", comment: "Per-view setting: hide card labels.")
        case .mixed:
            LocalizedStringResource(
                "cardLabels.mixed", defaultValue: "Mixed",
                comment: "Per-view label value: labels are shown except in Showcase and on series artwork."
            )
        }
    }
}

public enum CardCaptionPreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case recommended, show, hide

    public var id: Self { self }

    public var displayName: LocalizedStringResource {
        switch self {
        case .recommended: "App default"
        case .show: "Show labels everywhere"
        case .hide: "Hide labels everywhere"
        }
    }
}

public struct CardCaptionSettings: Codable, Equatable, Sendable {
    public var preference: CardCaptionPreference
    public private(set) var overrides: [CardCaptionView: Bool]
    public private(set) var mixedOverrides: Set<CardCaptionView> = []

    public static let `default` = CardCaptionSettings()

    public var selectedPreset: CardCaptionPreference? {
        overrides.isEmpty && mixedOverrides.isEmpty ? preference : nil
    }

    public mutating func applyPreset(_ preset: CardCaptionPreference) {
        self = Self(preference: preset)
    }

    public mutating func toggleCustomization(in view: CardCaptionView) {
        let choices = view.customizationChoices
        guard let index = choices.firstIndex(of: customization(in: view)) else {
            preconditionFailure("Label customization must be one of the view's supported choices.")
        }
        setOverride(choices[(index + 1) % choices.count], for: view)
    }

    public func customization(in view: CardCaptionView) -> CardCaptionOverride {
        if view.customizationChoices.contains(.mixed),
           mixedOverrides.contains(view) || (preference == .recommended && overrides[view] == nil) {
            return .mixed
        }
        return showsLabels(in: view) ? .show : .hide
    }

    public var showsLabels: Bool {
        get { preference != .hide }
        set { preference = newValue ? .show : .hide }
    }

    public init(preference: CardCaptionPreference = .recommended, overrides: [CardCaptionView: Bool] = [:]) {
        self.preference = preference
        self.overrides = overrides
    }

    public init(showsLabels: Bool, overrides: [CardCaptionView: Bool] = [:]) {
        preference = showsLabels ? .show : .hide
        self.overrides = overrides
    }

    public func inheritedShowsLabels(
        in view: CardCaptionView = .browse,
        isShowcase: Bool = false,
        hasArtworkTitle: Bool = false
    ) -> Bool {
        guard preference == .recommended else { return showsLabels }
        return view == .episodes || !(isShowcase || hasArtworkTitle)
    }

    public func showsLabels(
        in view: CardCaptionView, isShowcase: Bool = false, hasArtworkTitle: Bool = false
    ) -> Bool {
        if mixedOverrides.contains(view) { return !(isShowcase || hasArtworkTitle) }
        return overrides[view] ?? inheritedShowsLabels(
            in: view, isShowcase: isShowcase, hasArtworkTitle: hasArtworkTitle
        )
    }

    public func override(for view: CardCaptionView) -> CardCaptionOverride {
        if mixedOverrides.contains(view) { return .mixed }
        guard let value = overrides[view] else { return .automatic }
        return value ? .show : .hide
    }

    public mutating func setOverride(_ value: CardCaptionOverride, for view: CardCaptionView) {
        mixedOverrides.remove(view)
        switch value {
        case .automatic: overrides.removeValue(forKey: view)
        case .show: overrides[view] = true
        case .hide: overrides[view] = false
        case .mixed:
            precondition(view.customizationChoices.contains(.mixed))
            overrides.removeValue(forKey: view)
            mixedOverrides.insert(view)
        }
    }

    public mutating func resetOverrides() {
        overrides.removeAll()
        mixedOverrides.removeAll()
    }

    private enum CodingKeys: String, CodingKey {
        case preference, showsLabels, overrides, mixedOverrides, homeDefaultVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedPreference = try container.decodeIfPresent(CardCaptionPreference.self, forKey: .preference)
        if let storedPreference {
            preference = storedPreference
        } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .showsLabels) {
            preference = legacy ? .show : .hide
        } else {
            preference = .recommended
        }
        let stored = try container.decodeIfPresent([String: Bool].self, forKey: .overrides) ?? [:]
        overrides = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            CardCaptionView(rawValue: key).map { ($0, value) }
        })
        let mixed = try container.decodeIfPresent([String].self, forKey: .mixedOverrides) ?? []
        mixedOverrides = Set(mixed.compactMap(CardCaptionView.init(rawValue:)).filter {
            $0.customizationChoices.contains(.mixed) && overrides[$0] == nil
        })
        if try container.decodeIfPresent(Int.self, forKey: .homeDefaultVersion) == nil,
           mixed.isEmpty,
           stored == [CardCaptionView.home.rawValue: false],
           preference == .recommended || (storedPreference == nil && preference == .hide) {
            // Older migration persisted the default-off Home flag as a customization.
            // Its Home-only shape is ambiguous; reset it once, not explicit presets or other customizations.
            preference = .recommended
            overrides.removeValue(forKey: .home)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preference, forKey: .preference)
        try container.encode(showsLabels, forKey: .showsLabels)
        try container.encode(1, forKey: .homeDefaultVersion)
        try container.encode(
            Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) }),
            forKey: .overrides
        )
        if !mixedOverrides.isEmpty {
            try container.encode(mixedOverrides.map(\.rawValue).sorted(), forKey: .mixedOverrides)
        }
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
            // Legacy Home labels defaulted off. Only an opt-in should become
            // an override; all other profiles inherit the current app default.
            if let data = defaults.data(forKey: legacyKey) {
                struct LegacyCaptions: Decodable { let showsCardCaptions: Bool? }
                let legacy = try JSONDecoder().decode(LegacyCaptions.self, from: data)
                if legacy.showsCardCaptions == true {
                    let migrated = CardCaptionSettings(overrides: [.home: true])
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
