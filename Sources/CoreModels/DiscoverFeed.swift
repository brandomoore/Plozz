import Foundation
import os

public enum DiscoverFeed: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case trending, popularMovies, upcomingMovies, popularSeries, upcomingSeries

    public var id: String { rawValue }
    public static let defaultOrder = allCases

    public var title: LocalizedStringResource {
        switch self {
        case .trending: "Trending"
        case .popularMovies: "Popular Movies"
        case .upcomingMovies: "Upcoming Movies"
        case .popularSeries: "Popular Series"
        case .upcomingSeries: "Upcoming Series"
        }
    }

    public var kind: MediaItemKind? {
        switch self {
        case .trending: nil
        case .popularMovies, .upcomingMovies: .movie
        case .popularSeries, .upcomingSeries: .series
        }
    }
}

public struct DiscoverPage: Sendable {
    public let items: [MediaItem]
    public let nextPage: Int?

    public init(items: [MediaItem], nextPage: Int?) {
        self.items = items
        self.nextPage = nextPage
    }
}

public enum DiscoverFeedError: Error, Equatable, Sendable {
    case metadataUnavailable
    case service(AppError)

    public var userMessage: LocalizedStringResource {
        switch self {
        case .metadataUnavailable:
            "Discover is unavailable. Connect Seerr or check your metadata settings."
        case .service(let error):
            error.userMessage
        }
    }
}

public struct DiscoverFilters: Codable, Equatable, Sendable {
    public var availableNow: Bool
    public var hideWatched: Bool

    public init(availableNow: Bool = false, hideWatched: Bool = false) {
        self.availableNow = availableNow
        self.hideWatched = hideWatched
    }

    public var activeCount: Int { (availableNow ? 1 : 0) + (hideWatched ? 1 : 0) }

    public func includes(_ item: MediaItem) -> Bool {
        (!availableNow || item.locallyValidatedPlayableSource)
            && (!hideWatched || (!item.hasBeenPlayed && !item.isPlayed))
    }
}

public struct DiscoverFiltersStore {
    public static let storageKey = "com.plozz.discoverFilters"
    private static let logger = Logger(subsystem: "com.plozz.app", category: "settings")
    private let defaults: UserDefaults
    private let key: String

    public init(namespace: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = SettingsKey.scoped(Self.storageKey, namespace: namespace)
    }

    public func load() -> DiscoverFilters {
        guard let data = defaults.data(forKey: key) else { return .init() }
        do {
            return try JSONDecoder().decode(DiscoverFilters.self, from: data)
        } catch {
            Self.logger.error("Unable to read Discover filters")
            return .init()
        }
    }

    public func save(_ filters: DiscoverFilters) {
        do {
            defaults.set(try JSONEncoder().encode(filters), forKey: key)
        } catch {
            Self.logger.error("Unable to save Discover filters")
        }
    }
}
