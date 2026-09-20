import Foundation

public enum HeroDiscoverySource: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case tmdb, simkl, anilist, tvdb, tvmaze

    public var id: String { rawValue }
    public var usesTitleSeeds: Bool { self == .tmdb }

    /// Anime remains an explicit choice rather than assuming every profile wants it.
    public static let defaultSelection: [HeroDiscoverySource] = [.tmdb, .simkl, .tvdb, .tvmaze]

    public var displayName: String {
        switch self {
        case .tmdb: return "TMDB"
        case .simkl: return "Simkl"
        case .anilist: return "AniList"
        case .tvdb: return "TheTVDB"
        case .tvmaze: return "TVmaze"
        }
    }

    public var detail: LocalizedStringResource {
        switch self {
        case .tmdb: return "Movies and shows, including picks related to your watchlist."
        case .simkl: return "Movies and shows people are watching this week."
        case .anilist: return "Trending and seasonal anime."
        case .tvdb: return "Movies and shows from TheTVDB's catalog."
        case .tvmaze: return "TV premieres and returning shows."
        }
    }

    public var attributionURL: URL {
        switch self {
        case .tmdb: return URL(string: "https://www.themoviedb.org")!
        case .simkl: return URL(string: "https://simkl.com")!
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
        now: Date = Date()
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
