import Foundation
import CoreModels

/// Community-sourced skip markers, layered under the server's own
/// (Plex markers / Jellyfin media segments) as a backup.
///
/// Two keyless public databases:
///  * **IntroDB** (introdb.app) — `GET https://api.introdb.app/segments`, keyed
///    by IMDb id (+ season/episode). Returns intro, recap and outro (credits).
///  * **TheIntroDB** (theintrodb.org) — `GET https://api.theintrodb.org/v3/media`,
///    keyed by TMDB id (IMDb accepted as a fallback) (+ season/episode). Returns
///    intro, recap, credits and preview.
///
/// For an episode both expect the **series** id plus season/episode numbers.
/// Every lookup is best-effort: any failure (offline, 404, rate limit, decode)
/// just yields no markers.
public struct CommunitySkipMarkerQuery: Sendable, Equatable {
    public var isMovie: Bool
    /// The movie's IMDb id, or the episode's **series** IMDb id.
    public var imdbID: String?
    /// The movie's TMDB id, or the episode's **series** TMDB id.
    public var tmdbID: String?
    public var season: Int?
    public var episode: Int?
    /// The item's runtime in seconds, used to resolve open-ended ("runs to the
    /// end") segments. Segments that need it are dropped when it's unknown.
    public var duration: TimeInterval?

    public init(
        isMovie: Bool,
        imdbID: String?,
        tmdbID: String?,
        season: Int? = nil,
        episode: Int? = nil,
        duration: TimeInterval? = nil
    ) {
        self.isMovie = isMovie
        self.imdbID = imdbID
        self.tmdbID = tmdbID
        self.season = season
        self.episode = episode
        self.duration = duration
    }

    /// Builds a query for `item`, or `nil` when it isn't a movie/episode or lacks
    /// the ids and episode numbers the databases need. For an episode the series
    /// ids are read from `item`, then from `series` (the owning series item, which
    /// callers fetch when the episode doesn't carry them).
    public init?(item: MediaItem, series: MediaItem? = nil, duration: TimeInterval? = nil) {
        switch item.kind {
        case .movie:
            let imdb = item.providerID(.imdb)
            let tmdb = item.providerID(.tmdb)
            guard imdb != nil || tmdb != nil else { return nil }
            self.init(isMovie: true, imdbID: imdb, tmdbID: tmdb, duration: duration ?? item.runtime)
        case .episode:
            guard let season = item.seasonNumber, let episode = item.episodeNumber else { return nil }
            let imdb = item.providerID(.seriesImdb) ?? series?.providerID(.imdb)
            let tmdb = item.providerID(.seriesTmdb) ?? series?.providerID(.tmdb)
            guard imdb != nil || tmdb != nil else { return nil }
            self.init(
                isMovie: false, imdbID: imdb, tmdbID: tmdb,
                season: season, episode: episode, duration: duration ?? item.runtime
            )
        default:
            return nil
        }
    }

    /// Whether an episode query still lacks series ids that fetching the series
    /// item could supply.
    public static func needsSeriesIDs(_ item: MediaItem) -> Bool {
        item.kind == .episode
            && item.providerID(.seriesImdb) == nil
            && item.providerID(.seriesTmdb) == nil
    }

    /// A normalised `tt…` IMDb id, or `nil` when absent/malformed.
    var normalizedIMDbID: String? {
        guard let raw = imdbID?.trimmingCharacters(in: .whitespaces).lowercased(),
              raw.hasPrefix("tt"), raw.count > 2 else { return nil }
        return raw
    }

    /// A numeric TMDB id, or `nil` when absent/malformed.
    var normalizedTMDbID: String? {
        guard let raw = tmdbID?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty, raw.allSatisfy(\.isNumber) else { return nil }
        return raw
    }
}

/// Which community databases to consult.
public struct CommunitySkipMarkerSources: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let introDB = CommunitySkipMarkerSources(rawValue: 1 << 0)
    public static let theIntroDB = CommunitySkipMarkerSources(rawValue: 1 << 1)
}

/// Seam over the community databases so the player can be tested without network.
public protocol CommunitySkipMarkerFetching: Sendable {
    func segments(for query: CommunitySkipMarkerQuery, sources: CommunitySkipMarkerSources) async -> [MediaSegment]
}

/// Queries the enabled community databases concurrently and merges them: IntroDB
/// first, TheIntroDB filling any kind IntroDB lacks.
public struct CommunitySkipMarkerService: CommunitySkipMarkerFetching {
    public init() {}

    public func segments(
        for query: CommunitySkipMarkerQuery,
        sources: CommunitySkipMarkerSources
    ) async -> [MediaSegment] {
        async let introDB: [MediaSegment] = sources.contains(.introDB)
            ? IntroDBClient.segments(for: query) : []
        async let theIntroDB: [MediaSegment] = sources.contains(.theIntroDB)
            ? TheIntroDBClient.segments(for: query) : []
        return await introDB.filling(from: theIntroDB)
    }
}

// MARK: - IntroDB (introdb.app)

enum IntroDBClient {
    static let baseURL = URL(string: "https://api.introdb.app")!

    struct Response: Decodable {
        struct Segment: Decodable {
            let start_ms: Double
            let end_ms: Double
        }
        let intro: Segment?
        let recap: Segment?
        let outro: Segment?
    }

    static func url(for query: CommunitySkipMarkerQuery) -> URL? {
        guard let imdb = query.normalizedIMDbID else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("segments"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "imdb_id", value: imdb)]
        if query.isMovie {
            items.append(URLQueryItem(name: "is_movie", value: "true"))
        } else {
            guard let season = query.season, let episode = query.episode else { return nil }
            items.append(URLQueryItem(name: "season", value: String(season)))
            items.append(URLQueryItem(name: "episode", value: String(episode)))
        }
        components?.queryItems = items
        return components?.url
    }

    static func segments(for query: CommunitySkipMarkerQuery) async -> [MediaSegment] {
        guard let url = url(for: query),
              let response = await MetadataHTTP.get(Response.self, url: url) else { return [] }
        return segments(from: response)
    }

    static func segments(from response: Response) -> [MediaSegment] {
        let pairs: [(MediaSegment.Kind, Response.Segment?)] = [
            (.intro, response.intro), (.recap, response.recap), (.credits, response.outro)
        ]
        return pairs.compactMap { kind, segment in
            guard let segment else { return nil }
            let start = segment.start_ms / 1000
            let end = segment.end_ms / 1000
            guard end > start else { return nil }
            return MediaSegment(id: "introdb-\(kind.rawValue)", kind: kind, start: start, end: end)
        }
    }
}

// MARK: - TheIntroDB (theintrodb.org)

enum TheIntroDBClient {
    static let baseURL = URL(string: "https://api.theintrodb.org/v3")!

    struct Response: Decodable {
        struct Segment: Decodable {
            /// `nil` = from the very start of the item.
            let start_ms: Double?
            /// `nil` = to the very end of the item.
            let end_ms: Double?
        }
        let intro: [Segment]?
        let recap: [Segment]?
        let credits: [Segment]?
        let preview: [Segment]?
    }

    static func url(for query: CommunitySkipMarkerQuery) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("media"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem]
        if let tmdb = query.normalizedTMDbID {
            items = [URLQueryItem(name: "tmdb_id", value: tmdb)]
        } else if let imdb = query.normalizedIMDbID {
            items = [URLQueryItem(name: "imdb_id", value: imdb)]
        } else {
            return nil
        }
        if !query.isMovie {
            guard let season = query.season, let episode = query.episode else { return nil }
            items.append(URLQueryItem(name: "season", value: String(season)))
            items.append(URLQueryItem(name: "episode", value: String(episode)))
        }
        components?.queryItems = items
        return components?.url
    }

    static func segments(for query: CommunitySkipMarkerQuery) async -> [MediaSegment] {
        guard let url = url(for: query),
              let response = await MetadataHTTP.get(Response.self, url: url) else { return [] }
        return segments(from: response, duration: query.duration)
    }

    static func segments(from response: Response, duration: TimeInterval?) -> [MediaSegment] {
        let groups: [(MediaSegment.Kind, [Response.Segment]?)] = [
            (.intro, response.intro), (.recap, response.recap),
            (.credits, response.credits), (.preview, response.preview)
        ]
        return groups.flatMap { kind, segments -> [MediaSegment] in
            (segments ?? []).enumerated().compactMap { index, segment in
                let start = (segment.start_ms ?? 0) / 1000
                // An open end runs to the end of the item — unusable without a
                // known duration (the skip target would be undefined).
                guard let end = segment.end_ms.map({ $0 / 1000 }) ?? duration,
                      end > start else { return nil }
                return MediaSegment(id: "theintrodb-\(kind.rawValue)-\(index)", kind: kind, start: start, end: end)
            }
        }
    }
}
