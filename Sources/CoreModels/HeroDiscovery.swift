import Foundation

public enum HeroDiscoverySource: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case tmdb, anilist, tvdb, tvmaze

    public var id: String { rawValue }
    public var usesTitleSeeds: Bool { false }

    /// Anime discovery is an explicit choice.
    public static let defaultSelection: [HeroDiscoverySource] = [.tmdb, .tvdb, .tvmaze]

    public var displayName: String {
        switch self {
        case .tmdb: return "TMDB"
        case .anilist: return "AniList"
        case .tvdb: return "TheTVDB"
        case .tvmaze: return "TVmaze"
        }
    }

    public var detail: LocalizedStringResource {
        switch self {
        case .tmdb: return "Recent popular movies and shows, weekly trends, and currently airing TV."
        case .anilist: return "Trending and seasonal anime."
        case .tvdb: return "Movies and shows from TheTVDB's catalog."
        case .tvmaze: return "TV premieres and returning shows."
        }
    }

    public var attributionURL: URL {
        switch self {
        case .tmdb: return URL(string: "https://www.themoviedb.org")!
        case .anilist: return URL(string: "https://anilist.co")!
        case .tvdb: return URL(string: "https://thetvdb.com")!
        case .tvmaze: return URL(string: "https://www.tvmaze.com")!
        }
    }

    public static func normalized(_ sources: [HeroDiscoverySource]) -> [HeroDiscoverySource] {
        var seen = Set<HeroDiscoverySource>()
        return sources.filter { seen.insert($0).inserted }
    }

    public func acceptsAttributionURL(_ url: URL) -> Bool {
        func normalizedHost(_ host: String?) -> String? {
            guard let host = host?.lowercased() else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        let host = normalizedHost(url.host)
        let expected = normalizedHost(attributionURL.host)
        return url.scheme?.lowercased() == "https" && host == expected
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    public static func validatedURLs(_ urls: [String: URL]) -> [String: URL] {
        urls.filter { key, url in
            HeroDiscoverySource(rawValue: key)?.acceptsAttributionURL(url) == true
        }
    }
}

/// Featured's release window is independent of library, Watchlist and resume rows.
/// Providers may additionally admit older series with verified current airings.
public struct HeroDiscoveryRecency: Hashable, Sendable {
    public static let `default` = HeroDiscoveryRecency()
    /// Retires cached pools containing removed feeds or older eligibility policies.
    public static let contentVersion = 3
    public let years: Int

    public init(years: Int = 2) {
        self.years = min(10, max(1, years))
    }

    public func cutoff(at now: Date) -> Date {
        let today = Self.calendar.startOfDay(for: now)
        return Self.calendar.date(byAdding: .year, value: -years, to: today)!
    }

    public func includesRelease(of item: MediaItem, at now: Date) -> Bool {
        let calendar = Self.calendar
        let today = calendar.startOfDay(for: now)
        let earliest = cutoff(at: now)
        if let release = item.releaseDate {
            let releasedOn = calendar.startOfDay(for: release)
            return releasedOn >= earliest && releasedOn <= today
        }
        guard let year = item.productionYear else { return false }
        // Year-only records keep the boundary year without inventing a release day.
        return (calendar.component(.year, from: earliest)...calendar.component(.year, from: today))
            .contains(year)
    }

    public func includesUpcomingEpisode(at airing: Date, now: Date) -> Bool {
        let today = Self.calendar.startOfDay(for: now)
        let nextWeek = Self.calendar.date(byAdding: .day, value: 7, to: today)!
        return airing >= today && airing < nextWeek
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

/// Public metadata inputs only. Providers never receive profile credentials or
/// a complete watch history; a few locally selected titles can seed related picks.
public struct HeroDiscoveryRequest: Sendable {
    public struct SeedIdentity: Hashable, Sendable {
        public let kind: MediaItemKind
        public let title: String
        public let year: Int?
        public let providerIDs: [String]
    }

    public static let maximumLimit = 48
    public static let maximumSeeds = 3

    public let limit: Int
    public let language: String
    public let region: String
    public let seeds: [MediaItem]
    public let now: Date
    public let recency: HeroDiscoveryRecency
    public var seedIdentities: [SeedIdentity] {
        seeds.map { item in
            SeedIdentity(
                kind: item.kind, title: item.title, year: item.productionYear,
                providerIDs: item.providerIDs.sorted { $0.key < $1.key }
                    .map { "\($0.key):\($0.value)" }
            )
        }
    }

    public init(
        limit: Int = maximumLimit,
        language: String = "en",
        region: String = "US",
        seeds: [MediaItem] = [],
        now: Date = Date(),
        recency: HeroDiscoveryRecency = .default
    ) {
        self.limit = min(Self.maximumLimit, max(0, limit))
        self.language = language
        self.region = region
        let eligibleSeeds = seeds.lazy.filter {
            $0.allowsTitleBasedMetadataMatching
                && [.movie, .series, .episode, .season].contains($0.kind)
        }.prefix(Self.maximumSeeds)
        self.seeds = eligibleSeeds.enumerated().map { index, item in
            var ids: [String: String] = [:]
            for namespace in ProviderIDNamespace.allCases {
                if let value = item.providerIDs.providerID(namespace) {
                    ids[namespace.canonicalKey] = value
                }
            }
            return MediaItem(
                id: "discovery-seed:\(index)", title: item.title,
                kind: item.kind, parentTitle: item.parentTitle,
                productionYear: item.productionYear, providerIDs: ids,
                locallyValidatedPlayableSource: false
            )
        }
        self.now = now
        self.recency = recency
    }
}

public protocol HeroDiscoveryProviding: Sendable {
    var source: HeroDiscoverySource { get }
    var isEnabled: Bool { get }
    /// Opaque identity for provider configuration/credentials, never a raw key.
    var cacheIdentifier: String { get }
    var usesTitleSeeds: Bool { get }
    func discover(_ request: HeroDiscoveryRequest) async throws -> [MediaItem]
}

public extension HeroDiscoveryProviding {
    var cacheIdentifier: String { source.rawValue }
    var usesTitleSeeds: Bool { source.usesTitleSeeds }
}

public typealias HeroDiscoveryContentProviding =
    @Sendable (HeroDiscoveryRequest, [HeroDiscoverySource]) async -> [MediaItem]

/// The same live identity proof applies when discovery resolves ownership and
/// when an already-verified copy supplies a later watch-state update.
public enum HeroDiscoveryIdentityVerification {
    public static func matches(_ expected: MediaItem, _ record: MediaItem) -> Bool {
        guard expected.kind == record.kind else { return false }
        let expectedIDs = strongIDs(expected)
        let actualIDs = strongIDs(record)
        let shared = Set(expectedIDs.keys).intersection(actualIDs.keys)
        // Index membership alone cannot bless a sparse or title-only record.
        return !shared.isEmpty && shared.allSatisfy { expectedIDs[$0] == actualIDs[$0] }
    }

    public static func hasConflictingStrongIdentity(_ first: MediaItem, _ second: MediaItem) -> Bool {
        let firstIDs = strongIDs(first)
        let secondIDs = strongIDs(second)
        return firstIDs.contains { key, value in
            secondIDs[key].map { $0 != value } ?? false
        }
    }

    private static func strongIDs(_ item: MediaItem) -> [String: String] {
        Dictionary(MediaItemIdentity.identities(for: item).compactMap { identity in
            guard case let .external(source, value) = identity else { return nil }
            return (source, value)
        }, uniquingKeysWith: { first, _ in first })
    }
}

public extension MediaItem {
    /// Retains the visible title while revoking library actions and watch state.
    func removingDiscoveryOwnership() -> MediaItem {
        var item = self
        item.locallyValidatedPlayableSource = false
        item.sourceAccountID = nil
        item.selectedSourceAccountID = nil
        item.explicitSourceSelection = false
        item.additionalSourceAccountIDs = []
        item.sources = []
        item.libraryID = nil
        item.versions = []
        item.selectedVersionID = nil
        item.mediaInfo = nil
        item.resumePosition = nil
        item.playedPercentage = nil
        item.isPlayed = false
        item.hasBeenPlayed = false
        item.lastPlayedAt = nil
        item.isFavorite = false
        item.availability = item.availability ?? .unknown
        item.downloadProgress = nil
        return item
    }
}
