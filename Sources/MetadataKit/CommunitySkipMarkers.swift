import Foundation
import CoreModels
import CoreNetworking

/// Community-sourced skip markers, layered under the server's own
/// (Plex markers / Jellyfin media segments) as a backup.
///
/// Two keyless public databases:
///  * **IntroDB** (introdb.app) — `GET https://api.introdb.app/segments`, keyed
///    by IMDb id (+ season/episode). Returns intro, recap and outro (credits).
///  * **TheIntroDB** (theintrodb.org) — `GET https://api.theintrodb.org/v4/media`,
///    keyed by TVDB id (TMDB and IMDb accepted as fallbacks). Returns
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
    /// The movie's TVDB id, or the episode's **series** TVDB id.
    public var tvdbID: String?
    public var tvdbEpisodeID: String?
    public var episodeName: String?
    public var episodeOrdering: EpisodeOrdering?
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
        duration: TimeInterval? = nil,
        tvdbID: String? = nil,
        tvdbEpisodeID: String? = nil,
        episodeName: String? = nil,
        episodeOrdering: EpisodeOrdering? = nil
    ) {
        self.isMovie = isMovie
        self.imdbID = imdbID
        self.tmdbID = tmdbID
        self.season = season
        self.episode = episode
        self.duration = duration
        self.tvdbID = tvdbID
        self.tvdbEpisodeID = tvdbEpisodeID
        self.episodeName = episodeName
        self.episodeOrdering = episodeOrdering
    }

    /// Builds a query for `item`, or `nil` when it isn't a movie/episode or lacks
    /// the ids and episode numbers the databases need. For an episode the series
    /// ids are read from `item`, then from `series` (the owning series item, which
    /// callers fetch when the episode doesn't carry them).
    public init?(item: MediaItem, series: MediaItem? = nil, duration: TimeInterval? = nil) {
        let series = series.flatMap {
            $0.kind == .series && $0.id == item.seriesID ? $0 : nil
        }
        switch item.kind {
        case .movie:
            let imdb = item.providerID(.imdb)
            let tmdb = item.providerID(.tmdb)
            let tvdb = item.providerID(.tvdb)
            guard imdb != nil || tmdb != nil || tvdb != nil else { return nil }
            self.init(isMovie: true, imdbID: imdb, tmdbID: tmdb, duration: duration ?? item.runtime, tvdbID: tvdb)
        case .episode:
            guard let season = item.seasonNumber, let episode = item.episodeNumber else { return nil }
            guard item.episodeNumberEnd == nil || item.episodeNumberEnd == episode else { return nil }
            let imdb = item.providerID(.seriesImdb) ?? series?.providerID(.imdb)
            let tmdb = item.providerID(.seriesTmdb) ?? series?.providerID(.tmdb)
            let tvdb = item.providerID(.seriesTvdb) ?? series?.providerID(.tvdb)
            guard imdb != nil || tmdb != nil || tvdb != nil else { return nil }
            self.init(
                isMovie: false, imdbID: imdb, tmdbID: tmdb,
                season: season, episode: episode, duration: duration ?? item.runtime,
                tvdbID: tvdb, tvdbEpisodeID: item.providerID(.tvdb),
                episodeName: item.title, episodeOrdering: item.episodeOrdering ?? series?.episodeOrdering
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
            && item.providerID(.seriesTvdb) == nil
    }

    /// A normalised `tt…` IMDb id, or `nil` when absent/malformed.
    var normalizedIMDbID: String? {
        guard let raw = imdbID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw.hasPrefix("tt"), (9...10).contains(raw.utf8.count),
              raw.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return raw
    }

    /// A numeric TMDB id, or `nil` when absent/malformed.
    var normalizedTMDbID: String? {
        Self.numericID(tmdbID, maximum: 10_000_000)
    }

    var normalizedTVDBID: String? { Self.numericID(tvdbID, maximum: 100_000_000) }
    var normalizedTVDBEpisodeID: String? { Self.numericID(tvdbEpisodeID, maximum: Int64.max) }

    private static func numericID(_ value: String?, maximum: Int64) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int64(raw), (1...maximum).contains(number) else { return nil }
        return String(number)
    }

    var mapping: String? {
        switch episodeOrdering {
        case .tvdbDefault: "default"
        case .aired: "official"
        case .dvd: "dvd"
        case .absolute: "absolute"
        case .alternate: "alternate"
        case .regional: "regional"
        case .tmdb, .unknown, nil: nil
        }
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

/// Asks the enabled community databases in turn: IntroDB first, then TheIntroDB
/// only when IntroDB lacks an intro or credits marker, filling the kinds it lacks.
/// One at a time rather than both at once, so a title IntroDB already covers is
/// never sent to TheIntroDB too.
public struct CommunitySkipMarkerService: CommunitySkipMarkerFetching {
    public init() {}

    public func segments(
        for query: CommunitySkipMarkerQuery,
        sources: CommunitySkipMarkerSources
    ) async -> [MediaSegment] {
        var segments = sources.contains(.introDB) ? await IntroDBClient.segments(for: query) : []
        if sources.contains(.theIntroDB), !segments.coversIntroAndCredits, !Task.isCancelled {
            segments = segments.filling(from: await TheIntroDBClient.segments(for: query))
        }
        return segments
    }
}

// MARK: - IntroDB (introdb.app)

enum IntroDBClient {
    static let baseURL = URL(string: "https://api.introdb.app")!

    struct Response: Decodable {
        struct Segment: Decodable {
            let start_ms: Double?
            let end_ms: Double?
        }
        let intro: Segment?
        let recap: Segment?
        let outro: Segment?
        let post_credits: Segment?
    }

    static func url(for query: CommunitySkipMarkerQuery) -> URL? {
        guard let imdb = query.normalizedIMDbID else { return nil }
        if !query.isMovie, let order = query.episodeOrdering, order != .aired {
            // IntroDB has no order-conversion API. Let TheIntroDB resolve these.
            return nil
        }
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
        return segments(from: response).normalizedSkipMarkers(duration: query.duration)
    }

    static func segments(from response: Response) -> [MediaSegment] {
        let pairs: [(MediaSegment.Kind, Response.Segment?)] = [
            (.intro, response.intro), (.recap, response.recap), (.credits, response.outro)
        ]
        let segments = pairs.compactMap { kind, segment -> MediaSegment? in
            guard let segment, let startMS = segment.start_ms, let endMS = segment.end_ms else { return nil }
            let start = startMS / 1000
            let end = endMS / 1000
            guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            return MediaSegment(id: "introdb-\(kind.rawValue)", kind: kind, start: start, end: end)
        }
        let postCredits = response.post_credits.flatMap { segment -> MediaSegment? in
            guard let start = segment.start_ms, let end = segment.end_ms else { return nil }
            return MediaSegment(id: "introdb-post-credits", kind: .unknown, start: start / 1000, end: end / 1000)
        }
        return segments.normalizedSkipMarkers(protecting: postCredits)
    }
}

// MARK: - TheIntroDB (theintrodb.org)

enum TheIntroDBClient {
    static let baseURL = URL(string: "https://api.theintrodb.org/v4")!

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
        guard query.isMovie || query.episodeOrdering != .unknown else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("media"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem]
        let exactEpisode = query.normalizedTVDBEpisodeID
        let needsTMDBCoordinates = !query.isMovie && query.episodeOrdering == .tmdb
        let needsTVDBMapping = !query.isMovie && query.mapping != nil
        // The deployed API ignores mapping with TMDB addressing and does not
        // reliably prioritize episode IDs. Keep the caller's coordinate namespace.
        if let tvdb = query.normalizedTVDBID, !needsTMDBCoordinates {
            items = [URLQueryItem(name: "tvdb_id", value: tvdb)]
        } else if let tmdb = query.normalizedTMDbID, !needsTVDBMapping {
            items = [URLQueryItem(name: "tmdb_id", value: tmdb)]
        } else if let imdb = query.normalizedIMDbID, !needsTMDBCoordinates {
            items = [URLQueryItem(name: "imdb_id", value: imdb)]
        } else {
            return nil
        }
        if !query.isMovie {
            guard let season = query.season, (0...1000).contains(season),
                  let episode = query.episode, (0...10000).contains(episode) else { return nil }
            items.append(URLQueryItem(name: "season", value: String(season)))
            items.append(URLQueryItem(name: "episode", value: String(episode)))
            if let exactEpisode {
                items.append(URLQueryItem(name: "tvdb_episode_id", value: exactEpisode))
            }
            if let mapping = query.mapping {
                items.append(URLQueryItem(name: "mapping", value: mapping))
            }
            if items.first?.name != "tmdb_id",
               let name = query.episodeName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                items.append(URLQueryItem(name: "episode_name", value: name))
            }
        }
        if let duration = query.duration, duration.isFinite, duration > 0,
           let milliseconds = Int64(exactly: (duration * 1000).rounded()), milliseconds > 0 {
            items.append(URLQueryItem(name: "duration_ms", value: String(milliseconds)))
        }
        components?.queryItems = items
        return components?.url
    }

    static func segments(
        for query: CommunitySkipMarkerQuery,
        session: URLSession = MetadataHTTP.session
    ) async -> [MediaSegment] {
        guard !Task.isCancelled else { return [] }
        guard let url = url(for: query) else {
            PlozzLog.playback.debug("TheIntroDB lookup omitted: unsupported identity, episode order or coordinates")
            return []
        }
        let result = await MetadataHTTP.getWithStatus(Response.self, url: url, session: session)
        guard !Task.isCancelled else { return [] }
        guard let response = result.value else {
            if !result.reachable {
                PlozzLog.playback.debug("TheIntroDB lookup failed; retaining server markers")
            }
            return []
        }
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
                      start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
                if let duration, duration.isFinite, duration > 0, end > duration { return nil }
                return MediaSegment(id: "theintrodb-\(kind.rawValue)-\(index)", kind: kind, start: start, end: end)
            }.normalizedSkipMarkers(duration: duration)
        }
    }
}
