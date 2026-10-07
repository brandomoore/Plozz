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
    case home, continueWatching, browse, search, watchlist, details, episodes
    case playback, music, topShelf, downloads

    public var id: Self { self }

    public var displayName: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .continueWatching: "Continue Watching"
        case .browse: "Browse"
        case .search: "Search"
        case .watchlist: "Watchlist"
        case .details: "Details"
        case .episodes: "Episodes"
        case .playback: "Playback"
        case .music: "Music"
        case .topShelf: "Top Shelf"
        case .downloads: "Downloads"
        }
    }

    public var detail: LocalizedStringResource? {
        switch self {
        case .home: "Backgrounds, logos, and Home rows."
        case .continueWatching: "Metadata providers favor images without text. Library artwork keeps your chosen images."
        case .browse: "Libraries, collections, and playlists."
        case .search, .watchlist: nil
        case .details: "Backdrops, logos, and related titles. Recommended can use a different background from Home."
        case .episodes: "Episode thumbnails."
        case .playback: "Player menus and Now Playing."
        case .music: "Covers, artist images, and the music player."
        case .topShelf: "Apple TV Home Screen."
        case .downloads: "Applies when you queue new downloads. Existing downloads keep their artwork."
        }
    }
}

public enum ArtworkOverride: String, CaseIterable, Identifiable, Sendable {
    case automatic, library, online

    public var id: Self { self }

    public var displayName: LocalizedStringResource {
        switch self {
        case .automatic: "Use default"
        case .library: ArtworkPreference.library.displayName
        case .online: ArtworkPreference.online.displayName
        }
    }
}

public struct ArtworkSettings: Codable, Equatable, Sendable {
    public var preference: ArtworkPreference
    public private(set) var overrides: [ArtworkArea: ArtworkPreference]

    public static let `default` = ArtworkSettings()

    public init(
        preference: ArtworkPreference = .recommended,
        overrides: [ArtworkArea: ArtworkPreference] = [:]
    ) {
        self.preference = preference
        self.overrides = overrides.filter { $0.value != .recommended }
    }

    public func preference(in area: ArtworkArea) -> ArtworkPreference {
        overrides[area] ?? preference
    }

    public func prefersOnlineArtwork(in area: ArtworkArea) -> Bool {
        switch preference(in: area) {
        case .library: false
        case .online: true
        case .recommended: area == .continueWatching
        }
    }

    public func artworkReferences(
        for item: MediaItem, placement: ArtworkPlacement, in area: ArtworkArea
    ) -> [ArtworkReference] {
        let preference = preference(in: area)
        let variesBackground = preference == .recommended
            && area == .details && placement == .detailBackdrop
        let references = item.artworkReferences(
            for: placement,
            preferringLibrarySelection: !prefersOnlineArtwork(in: area) && !variesBackground
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
        default: .automatic
        }
    }

    public mutating func setOverride(_ value: ArtworkOverride, for area: ArtworkArea) {
        switch value {
        case .automatic: overrides.removeValue(forKey: area)
        case .library: overrides[area] = .library
        case .online: overrides[area] = .online
        }
    }

    public mutating func resetOverrides() { overrides.removeAll() }

    private enum CodingKeys: CodingKey { case preference, overrides }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preference = try values.decodeIfPresent(String.self, forKey: .preference)
            .flatMap(ArtworkPreference.init(rawValue:)) ?? .recommended
        let stored = try values.decodeIfPresent([String: String].self, forKey: .overrides) ?? [:]
        overrides = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            guard let area = ArtworkArea(rawValue: key),
                  let preference = ArtworkPreference(rawValue: value),
                  preference != .recommended else { return nil }
            return (area, preference)
        })
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(preference.rawValue, forKey: .preference)
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
