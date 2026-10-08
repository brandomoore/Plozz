import Foundation
import os

public enum ArtworkPreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case recommended, library, online

    public var id: Self { self }

    public var displayName: LocalizedStringResource {
        switch self {
        case .recommended: "Recommended"
        case .library: "Prefer my library's artwork"
        case .online: "Prefer artwork from metadata providers"
        }
    }

    public var detail: LocalizedStringResource {
        switch self {
        case .recommended: "Plozz chooses artwork to suit each part of the app."
        case .library: "Always use local artwork from your libraries, only using metadata providers when none is provided locally"
        case .online: "Always use metadata-provider artwork, unless unavailable—then use library artwork. Generally worse performance."
        }
    }
}

public enum ArtworkArea: String, CaseIterable, Codable, Identifiable, Sendable {
    case home, homeRows, recommendedHero, recommended, browse, collections, playlists
    case continueWatching, search, watchlist, details, episodes
    case playback, music, topShelf, downloads

    public var id: Self { self }

    public var customizationChoices: [ArtworkOverride] {
        self == .details ? [.library, .online, .mixed] : [.library, .online]
    }

    public var displayName: LocalizedStringResource {
        switch self {
        case .home: "Showcase / hero"
        case .homeRows: "Other Home rows"
        case .recommendedHero: "Recommended hero"
        case .recommended: "Recommended rows"
        case .continueWatching: "Continue Watching rows"
        case .browse: "Browse"
        case .collections: "Collections"
        case .playlists: "Playlists"
        case .search: "Search results"
        case .watchlist: "Watchlist page"
        case .details: "Title detail pages"
        case .episodes: "Episode browser"
        case .playback: "Video player artwork"
        case .music: "Music"
        case .topShelf: "Top Shelf"
        case .downloads: "Downloads"
        }
    }

    public var detail: LocalizedStringResource? {
        switch self {
        case .home: "The large background, carousel images, and title logo at the top of Home."
        case .homeRows: "Home's rows below the hero, including Watchlist and Recently Added."
        case .recommendedHero: "The Showcase background and title logo in each library's Recommended tab."
        case .recommended: "Artwork in the rows of each library's Recommended tab."
        case .continueWatching: "Continue Watching on Home and in libraries; metadata providers favor images without text."
        case .browse: "The Browse tab in every library, plus titles inside collections and playlists."
        case .collections: "The collection covers, rather than the titles inside them."
        case .playlists: "The playlist covers, rather than the titles inside them."
        case .search: "Posters and thumbnails for titles found in Search."
        case .watchlist: "Posters on the Watchlist page, rather than Home's Watchlist row."
        case .details: "Movie and show backgrounds, logos, and related-title posters."
        case .episodes: "Episode thumbnails in a show's detail page, rather than the video player."
        case .playback: "Video player Info, episode and playlist menus, Up Next, and system Now Playing."
        case .music: "Covers, artist images, and the music player."
        case .topShelf: "The large preview above Plozz on the Apple TV Home Screen."
        case .downloads: "Artwork saved with new downloads; existing downloads keep their images."
        }
    }
}

public enum ArtworkOverride: String, CaseIterable, Identifiable, Sendable {
    case automatic, library, online, mixed

    public var id: Self { self }

    public var displayName: LocalizedStringResource {
        switch self {
        case .automatic: "Use default"
        case .library: "Library"
        case .online: "Metadata providers"
        case .mixed: "Mixed"
        }
    }
}

public struct ArtworkSettings: Codable, Equatable, Sendable {
    public var preference: ArtworkPreference
    public private(set) var overrides: [ArtworkArea: ArtworkPreference]

    public static let `default` = ArtworkSettings()

    public var selectedPreset: ArtworkPreference? {
        overrides.isEmpty ? preference : nil
    }

    public mutating func applyPreset(_ preset: ArtworkPreference) {
        self = Self(preference: preset)
    }

    public mutating func toggleCustomization(in area: ArtworkArea) {
        let choices = area.customizationChoices
        guard let index = choices.firstIndex(of: customization(in: area)) else {
            preconditionFailure("Artwork customization must be one of the area's supported choices.")
        }
        setOverride(choices[(index + 1) % choices.count], for: area)
    }

    public func customization(in area: ArtworkArea) -> ArtworkOverride {
        if area == .details, preference(in: area) == .recommended { return .mixed }
        return prefersOnlineArtwork(in: area) ? .online : .library
    }

    public init(
        preference: ArtworkPreference = .recommended,
        overrides: [ArtworkArea: ArtworkPreference] = [:]
    ) {
        self.preference = preference
        self.overrides = overrides.filter { $0.value != .recommended || $0.key == .details }
    }

    public func preference(in area: ArtworkArea) -> ArtworkPreference {
        overrides[area] ?? preference
    }

    public func prefersOnlineArtwork(in area: ArtworkArea, placement: ArtworkPlacement? = nil) -> Bool {
        switch preference(in: area) {
        case .library: false
        case .online: true
        case .recommended:
            area == .home || area == .recommendedHero || area == .continueWatching
                || (area == .details && [.homeHero, .detailBackdrop, .logo].contains(placement))
        }
    }

    public func artworkReferences(
        for item: MediaItem, placement: ArtworkPlacement, in area: ArtworkArea
    ) -> [ArtworkReference] {
        let preference = preference(in: area)
        let variesBackground = preference == .recommended
            && area == .details && placement == .detailBackdrop
        let preservesLibrarySelection = preference == .library
            || (preference == .recommended && area != .continueWatching && !variesBackground)
        let references = item.artworkReferences(
            for: placement,
            preferringLibrarySelection: preservesLibrarySelection
        )
        guard variesBackground,
              let home = artworkReferences(for: item, placement: .homeHero, in: .home).first else {
            return references
        }
        // Vary artwork already supplied with the item; do not wait on another lookup.
        return references.filter { $0 != home } + references.filter { $0 == home }
    }

    public func prefersTextlessArtwork(in area: ArtworkArea) -> Bool {
        area == .continueWatching && prefersOnlineArtwork(in: area)
    }

    public func inheritedPreference(in area: ArtworkArea) -> ArtworkPreference {
        ArtworkSettings(preference: preference).prefersOnlineArtwork(in: area) ? .online : .library
    }

    public func override(for area: ArtworkArea) -> ArtworkOverride {
        switch overrides[area] {
        case .library: .library
        case .online: .online
        case .recommended: .mixed
        default: .automatic
        }
    }

    public mutating func setOverride(_ value: ArtworkOverride, for area: ArtworkArea) {
        switch value {
        case .automatic: overrides.removeValue(forKey: area)
        case .library: overrides[area] = .library
        case .online: overrides[area] = .online
        case .mixed:
            precondition(area.customizationChoices.contains(.mixed))
            overrides[area] = .recommended
        }
    }

    public mutating func resetOverrides() { overrides.removeAll() }

    private enum CodingKeys: CodingKey { case preference, overrides, scopeVersion }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preference = try values.decodeIfPresent(String.self, forKey: .preference)
            .flatMap(ArtworkPreference.init(rawValue:)) ?? .recommended
        let stored = try values.decodeIfPresent([String: String].self, forKey: .overrides) ?? [:]
        overrides = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            guard let area = ArtworkArea(rawValue: key),
                  let preference = ArtworkPreference(rawValue: value),
                  preference != .recommended || area == .details else { return nil }
            return (area, preference)
        })
        if try values.decodeIfPresent(Int.self, forKey: .scopeVersion) == nil {
            // Split existing choices once; future edits to the new scopes are independent.
            for area in [ArtworkArea.homeRows, .recommendedHero, .recommended] {
                if overrides[area] == nil { overrides[area] = overrides[.home] }
            }
            for area in [ArtworkArea.collections, .playlists] {
                if overrides[area] == nil { overrides[area] = overrides[.browse] }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(preference.rawValue, forKey: .preference)
        try values.encode(1, forKey: .scopeVersion)
        try values.encode(
            Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value.rawValue) }),
            forKey: .overrides
        )
    }
}

public protocol ArtworkSettingsStoring: Sendable {
    func load() -> ArtworkSettings
    func save(_ settings: ArtworkSettings)
}

public final class ArtworkSettingsStore: ArtworkSettingsStoring, @unchecked Sendable {
    public static let storageKey = "com.plozz.artworkSettings"
    private static let logger = Logger(subsystem: "com.plozz.app", category: "settings")
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, namespace: String? = nil) {
        self.defaults = defaults
        key = SettingsKey.scoped(Self.storageKey, namespace: namespace)
    }

    public func load() -> ArtworkSettings {
        do {
            if let data = defaults.data(forKey: key) {
                let settings = try JSONDecoder().decode(ArtworkSettings.self, from: data)
                defaults.set(true, forKey: key + ".migrated")
                return settings
            }
            guard !defaults.bool(forKey: key + ".migrated") else { return .default }
            let legacy = defaults.data(forKey: "com.plozz.metadataProviderSettings")
            let preference = try legacy.map {
                try JSONDecoder().decode(MetadataProviderSettings.self, from: $0)
            }
            let settings = ArtworkSettings(
                preference: preference?.preferOnlineArtwork == false ? .library : .recommended
            )
            save(settings)
            return settings
        } catch {
            Self.logger.error("Unable to read artwork preferences: \(String(describing: error))")
            return .default
        }
    }

    public func save(_ settings: ArtworkSettings) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(try encoder.encode(settings), forKey: key)
            defaults.set(true, forKey: key + ".migrated")
        } catch {
            Self.logger.error("Unable to save artwork preferences: \(String(describing: error))")
        }
    }
}
