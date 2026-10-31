import Foundation
import os

public enum WatchlistMediaFilter: String, CaseIterable, Codable, Sendable {
    case all, movies, shows

    public var displayName: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .movies: "Movies"
        case .shows: "TV Shows"
        }
    }

    public func includes(_ item: MediaItem) -> Bool {
        switch self {
        case .all: true
        case .movies: item.kind == .movie
        case .shows: item.kind == .series
        }
    }
}

public struct WatchlistBrowsePreferences: Codable, Equatable, Sendable {
    public static let sortFields: [SortField] = [.dateAdded, .releaseDate, .name]
    public static let `default` = Self()
    public var filter: WatchlistMediaFilter
    public var sort: SortDescriptor

    public init(
        filter: WatchlistMediaFilter = .all,
        sort: SortDescriptor = .init(field: .dateAdded, direction: .descending)
    ) {
        self.filter = filter
        self.sort = sort
    }

    public func items(from items: [MediaItem]) -> [MediaItem] {
        items.enumerated().filter { filter.includes($0.element) }.sorted { lhs, rhs in
            if sort.field == .dateAdded {
                switch (lhs.element.watchlistAddedAt, rhs.element.watchlistAddedAt) {
                case let (left?, right?) where left != right:
                    return sort.direction == .ascending ? left < right : left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    // Missing/tied Watchlist dates retain the provider's order.
                    return lhs.offset < rhs.offset
                }
            }
            return MediaItemSortOrder.isOrderedBefore(lhs.element, rhs.element, sort: sort)
        }.map(\.element)
    }
}

public struct WatchlistBrowsePreferencesStore {
    public static let storageKey = "com.plozz.watchlistBrowsePreferences"
    private static let logger = Logger(subsystem: "com.plozz.app", category: "settings")
    private let defaults: UserDefaults
    private let key: String

    public init(namespace: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = SettingsKey.scoped(Self.storageKey, namespace: namespace)
    }

    public func load() -> WatchlistBrowsePreferences {
        guard let data = defaults.data(forKey: key) else { return .default }
        do {
            let value = try JSONDecoder().decode(WatchlistBrowsePreferences.self, from: data)
            guard WatchlistBrowsePreferences.sortFields.contains(value.sort.field) else {
                Self.logger.error("Unsupported Watchlist sort preference")
                return .init(filter: value.filter)
            }
            return value
        } catch {
            Self.logger.error("Unable to read Watchlist browse preferences: \(String(describing: error))")
            return .default
        }
    }

    public func save(_ preferences: WatchlistBrowsePreferences) {
        do {
            defaults.set(try JSONEncoder().encode(preferences), forKey: key)
        } catch {
            Self.logger.error("Unable to save Watchlist browse preferences: \(String(describing: error))")
        }
    }
}
