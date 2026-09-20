import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Filtered movie/TV discovery plus public, title-related recommendations.
/// Application authentication only: no TMDb account or watch-history upload.
/// API: https://developer.themoviedb.org/reference/discover-movie
/// and https://developer.themoviedb.org/reference/discover-tv.
public struct TMDbDiscoveryProvider: HeroDiscoveryProviding {
    public let source: HeroDiscoverySource = .tmdb
    public let usesTitleSeeds = true
    private let access: TMDbAccess
    private let http: MetadataDiscoveryHTTPClient

    public init(
        access: TMDbAccess = MetadataProviderConfig.resolved().tmdb,
        http: MetadataDiscoveryHTTPClient = .init()
    ) {
        self.access = access
        self.http = http
    }

    public var isEnabled: Bool { access.isEnabled }

    public var cacheIdentifier: String {
        let configuration: String
        switch access {
        case .disabled: configuration = "disabled"
        case .proxy(let baseURL): configuration = "proxy:\(baseURL.absoluteString)"
        case .directToken(let token): configuration = "application:\(token)"
        case .userToken(let token): configuration = "user:\(token)"
        }
        return "tmdb:" + MetadataDiscoveryHTTPClient.configurationFingerprint(configuration)
    }

    public func discover(_ request: HeroDiscoveryRequest) async throws -> [MediaItem] {
        try Task.checkCancellation()
        guard isEnabled, request.limit > 0 else { return [] }
        var feeds: [[MediaItem]] = []
        for feed in Self.feeds(for: request) {
            try Task.checkCancellation()
            let response = try await http.decode(
                Response.self,
                from: makeRequest(path: feed.path, query: feed.query)
            )
            feeds.append(response.results.prefix(100).compactMap { $0.mediaItem(kind: feed.kind) })
        }
        try Task.checkCancellation()
        return Self.interleaved(feeds, limit: request.limit)
    }

    private func makeRequest(path: String, query: [URLQueryItem]) throws -> URLRequest {
        let url = access.metadataAPIBaseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw MetadataDiscoveryHTTPError.invalidResponse
        }
        components.queryItems = (components.queryItems ?? []) + query
        guard let finalURL = components.url else { throw MetadataDiscoveryHTTPError.invalidResponse }
        var request = URLRequest(url: finalURL)
        for (name, value) in access.metadataAuthorizationHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private struct Feed {
        var path: String
        var kind: MediaItemKind
        var query: [URLQueryItem]
    }

    /// Two recent feeds, two established-title feeds, at most two seed feeds.
    /// Genre OR groups broaden the catalog picks without cloning daily trending.
    private struct Filter {
        let kind: MediaItemKind
        let recent: Bool
        let minimumVotes: Int
        let minimumRating: Double
        let genres: String?

        static let defaults = [
            Filter(kind: .movie, recent: true, minimumVotes: 100, minimumRating: 6, genres: nil),
            Filter(kind: .series, recent: true, minimumVotes: 50, minimumRating: 6, genres: nil),
            Filter(kind: .movie, recent: false, minimumVotes: 1_000, minimumRating: 7,
                   genres: "12|16|35|80|99|18|10751|14|36|27|10402|9648|10749|878|53|10752|37|28"),
            Filter(kind: .series, recent: false, minimumVotes: 250, minimumRating: 7,
                   genres: "10759|16|35|80|99|18|10751|10762|9648|10765|10768|37")
        ]
    }

    private static func feeds(for request: HeroDiscoveryRequest) -> [Feed] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: request.now)
        let cutoff = calendar.date(byAdding: .year, value: -3, to: today) ?? today
        let beforeCutoff = calendar.date(byAdding: .day, value: -1, to: cutoff) ?? cutoff
        let language = request.language.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        let common = [
            URLQueryItem(name: "language", value: language.isEmpty ? "en" : language),
            URLQueryItem(name: "page", value: "1")
        ]
        var feeds = Filter.defaults.map { filter in
            let movie = filter.kind == .movie
            let dateKey = movie ? "primary_release_date" : "first_air_date"
            var query = common + [
                URLQueryItem(name: "include_adult", value: "false"),
                URLQueryItem(name: "sort_by", value: filter.recent ? "popularity.desc" : "vote_average.desc"),
                URLQueryItem(name: "vote_count.gte", value: String(filter.minimumVotes)),
                URLQueryItem(name: "vote_average.gte", value: String(filter.minimumRating)),
                URLQueryItem(name: "\(dateKey).lte", value: day(filter.recent ? today : beforeCutoff))
            ]
            if filter.recent {
                query.append(URLQueryItem(name: "\(dateKey).gte", value: day(cutoff)))
            }
            if let genres = filter.genres {
                query.append(URLQueryItem(name: "with_genres", value: genres))
            }
            if movie {
                let region = request.region.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                query.append(URLQueryItem(name: "region", value: region.isEmpty ? "US" : region))
                query.append(URLQueryItem(name: "include_video", value: "false"))
            } else {
                query.append(URLQueryItem(name: "include_null_first_air_dates", value: "false"))
            }
            return Feed(path: "3/discover/\(movie ? "movie" : "tv")", kind: filter.kind, query: query)
        }
        var seen = Set<String>()
        var recommendations: [Feed] = []
        for seed in request.seeds {
            let kind: MediaItemKind
            let rawID: String?
            switch seed.kind {
            case .movie:
                kind = .movie
                rawID = seed.providerIDs.providerID(.tmdb)
            case .series:
                kind = .series
                rawID = seed.providerIDs.providerID(.tmdb) ?? seed.providerIDs.providerID(.seriesTmdb)
            case .season, .episode:
                kind = .series
                rawID = seed.providerIDs.providerID(.seriesTmdb)
            default:
                continue
            }
            guard let rawID, let id = positiveID(rawID) else { continue }
            let path = "3/\(kind == .movie ? "movie" : "tv")/\(id)/recommendations"
            guard seen.insert(path).inserted else { continue }
            recommendations.append(Feed(path: path, kind: kind, query: common))
            if recommendations.count == 2 { break }
        }
        feeds.insert(contentsOf: recommendations, at: 2)
        return feeds
    }

    private static func positiveID(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let id = Int(value), id > 0 else { return nil }
        return id
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func interleaved(_ feeds: [[MediaItem]], limit: Int) -> [MediaItem] {
        var result: [MediaItem] = []
        var seen = Set<String>()
        let depth = feeds.map(\.count).max() ?? 0
        for index in 0..<depth {
            for feed in feeds where index < feed.count {
                let item = feed[index]
                guard seen.insert(item.id).inserted else { continue }
                result.append(item)
                if result.count == limit { return result }
            }
        }
        return result
    }

    private struct Response: Decodable, Sendable {
        let results: [Record]

        private enum CodingKeys: String, CodingKey { case results, success }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decodeIfPresent(Bool.self, forKey: .success) != false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .success, in: container, debugDescription: "TMDb reported an unsuccessful response"
                )
            }
            results = try container.decode([Record].self, forKey: .results)
        }
    }

    private struct Record: Decodable, Sendable {
        let id: Int?
        let adult: Bool?
        let media_type: String?
        let title: String?
        let name: String?
        let original_title: String?
        let original_name: String?
        let overview: String?
        let poster_path: String?
        let backdrop_path: String?
        let release_date: String?
        let first_air_date: String?

        func mediaItem(kind: MediaItemKind) -> MediaItem? {
            guard let id, id > 0, adult != true,
                  media_type == nil || media_type == (kind == .movie ? "movie" : "tv"),
                  let title = Self.text(kind == .movie ? title : name) else { return nil }
            let date = kind == .movie ? release_date : first_air_date
            return MediaItem(
                id: "tmdb:\(kind.rawValue):\(id)",
                title: title,
                originalTitle: Self.text(kind == .movie ? original_title : original_name),
                kind: kind,
                overview: Self.text(overview),
                productionYear: date.flatMap { Int($0.prefix(4)) },
                releaseDate: Self.releaseDate(date),
                posterURL: Self.image(poster_path, size: "w500"),
                backdropURL: Self.image(backdrop_path, size: "w1280"),
                heroBackdropURL: Self.image(backdrop_path, size: "original"),
                providerIDs: ["Tmdb": String(id)],
                discoverySources: [.tmdb],
                metadataProvenance: MetadataProvenance([
                    .title: MetadataAttribution(
                        source: .tmdb,
                        sourceURL: URL(string: "https://www.themoviedb.org/\(kind == .movie ? "movie" : "tv")/\(id)")
                    )
                ]),
                availability: .unknown,
                locallyValidatedPlayableSource: false
            )
        }

        private static func text(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        private static func image(_ path: String?, size: String) -> URL? {
            guard let path = text(path), path.hasPrefix("/"), !path.hasPrefix("//"),
                  !path.contains(".."), !path.contains("?"), !path.contains("#") else { return nil }
            return URL(string: "https://image.tmdb.org/t/p/\(size)\(path)")
        }

        private static func releaseDate(_ raw: String?) -> Date? {
            guard let raw else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { return nil }
            return date
        }
    }
}
