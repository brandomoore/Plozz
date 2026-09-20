import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One public weekly watcher feed; no account token or paid endpoint.
/// Current Simkl rules require app registration parameters even on CDN files.
public struct SimklDiscoveryProvider: HeroDiscoveryProviding {
    public let source: HeroDiscoverySource = .simkl
    public let isEnabled: Bool
    public let includesAnime: Bool
    private let http: MetadataDiscoveryHTTPClient
    private let clientID: String?

    public var cacheIdentifier: String {
        "simkl:" + MetadataDiscoveryHTTPClient.configurationFingerprint(
            "\(clientID ?? "")|anime:\(includesAnime)"
        )
    }

    /// A nil client ID resolves the app's existing bundled Simkl registration.
    /// An empty/unresolved ID disables discovery rather than bypassing API rules.
    public init(
        http: MetadataDiscoveryHTTPClient = .init(),
        clientID: String? = nil,
        isEnabled: Bool = true,
        includesAnime: Bool = false
    ) {
        self.http = http
        let resolved = clientID ?? Self.bundledClientID
        self.clientID = Self.sanitizedClientID(resolved)
        self.isEnabled = isEnabled && self.clientID != nil
        self.includesAnime = includesAnime
    }

    public func discover(_ request: HeroDiscoveryRequest) async throws -> [MediaItem] {
        guard isEnabled, request.limit > 0, let clientID else { return [] }
        try Task.checkCancellation()
        var components = URLComponents(string: "https://data.simkl.in/discover/trending/week_100.json")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "app-name", value: "Plozz"),
            URLQueryItem(
                name: "app-version",
                value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? "development"
            ),
        ]
        guard let url = components.url else { throw MetadataDiscoveryHTTPError.invalidResponse }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpShouldHandleCookies = false
        let feed = try await http.decode(Feed.self, from: urlRequest)
        let groups: [(Category, [Title])] = [
            (.movie, feed.movies), (.tv, feed.tv),
        ] + (includesAnime ? [(.anime, feed.anime)] : [])
        let formatter = Self.releaseDateFormatter
        var seen = Set<String>()
        var items: [MediaItem] = []
        // Keep each category's watcher ranking without starving movies behind TV.
        for index in 0..<100 {
            for (category, titles) in groups where index < titles.count {
                guard let item = Self.item(titles[index], category: category, formatter: formatter),
                      seen.insert(item.id).inserted else { continue }
                items.append(item)
                if items.count == request.limit { return items }
            }
        }
        return items
    }

    private static func item(_ title: Title, category: Category, formatter: DateFormatter) -> MediaItem? {
        guard let id = title.ids?.simkl_id?.positiveNumber,
              let name = nonempty(title.title),
              title.adult != true, title.is_adult != true, title.isAdult != true,
              !(title.genres ?? []).contains(where: {
                  ["adult", "hentai", "pornography"].contains($0.lowercased())
              }) else { return nil }
        let kind: MediaItemKind
        switch category {
        case .movie: kind = .movie
        case .tv: kind = .series
        case .anime:
            switch title.anime_type?.lowercased() {
            case "movie": kind = .movie
            case "tv", "ova", "ona": kind = .series
            default: return nil
            }
        }
        var ids: [String: String] = [:]
        let externalIDs: [(ProviderIDNamespace, Identifier?)] = [
            (.tmdb, title.ids?.tmdb), (.tvdb, title.ids?.tvdb),
            (.aniList, title.ids?.anilist), (.myAnimeList, title.ids?.mal),
            (.aniDB, title.ids?.anidb),
        ]
        for (namespace, value) in externalIDs {
            if let value = value?.positiveNumber { ids[namespace.canonicalKey] = value }
        }
        if let imdb = nonempty(title.ids?.imdb),
           imdb.range(of: "^tt[0-9]+$", options: .regularExpression) != nil {
            ids[ProviderIDNamespace.imdb.canonicalKey] = imdb
        }
        let releaseDate = title.release_date.flatMap { value -> Date? in
            guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
                return nil
            }
            return date
        }
        let year = title.year.flatMap { (1...9999).contains($0) ? $0 : nil }
            ?? releaseDate.map { formatter.calendar.component(.year, from: $0) }
        let poster = imageURL(title.poster, category: "posters", size: "_m")
        let backdrop = imageURL(title.fanart, category: "fanart", size: "_medium")
        let overview = nonempty(title.overview)
        let attribution = MetadataAttribution(
            source: MetadataSource(rawValue: "simkl"),
            sourceURL: itemURL(title, category: category, id: id)
        )
        var provenance = MetadataProvenance([.title: attribution])
        if overview != nil { provenance[.overview] = attribution }
        if poster != nil { provenance[.posterURL] = attribution }
        if backdrop != nil { provenance[.backdropURL] = attribution }
        return MediaItem(
            id: "simkl:\(kind.rawValue):\(id)",
            title: name,
            originalTitle: nonempty(title.title_romaji),
            kind: kind,
            overview: overview,
            productionYear: year,
            releaseDate: releaseDate,
            genres: title.genres ?? [],
            posterURL: poster,
            backdropURL: backdrop,
            heroBackdropURL: backdrop,
            providerIDs: ids,
            discoverySources: [.simkl],
            metadataProvenance: provenance,
            availability: .unknown,
            locallyValidatedPlayableSource: false
        )
    }

    private static func itemURL(_ title: Title, category: Category, id: String) -> URL {
        let base = URL(string: "https://simkl.com/\(category.rawValue)/\(id)")!
        guard let slug = nonempty(title.ids?.slug),
              slug.range(of: "^[a-zA-Z0-9-]+$", options: .regularExpression) != nil else {
            return base
        }
        return base.appendingPathComponent(slug)
    }

    private static func imageURL(_ path: String?, category: String, size: String) -> URL? {
        guard let path = nonempty(path),
              path.range(of: "^[0-9]+/[a-zA-Z0-9]+$", options: .regularExpression) != nil else {
            return nil
        }
        // Documented original CDN, not the optional third-party image proxy.
        return URL(string: "https://simkl.in/\(category)/\(path)\(size).webp")
    }

    private static var releaseDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.calendar.timeZone = formatter.timeZone
        formatter.dateFormat = "MM/dd/yyyy"
        formatter.isLenient = false
        return formatter
    }

    private static var bundledClientID: String? {
        sanitizedClientID(Bundle.main.object(forInfoDictionaryKey: "SimklClientID") as? String)
            ?? sanitizedClientID(ProcessInfo.processInfo.environment["SIMKL_CLIENT_ID"])
    }

    private static func sanitizedClientID(_ value: String?) -> String? {
        guard let value = nonempty(value), !value.contains("$(") else { return nil }
        return value
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private enum Category: String {
        case movie = "movies"
        case tv
        case anime
    }

    private struct Feed: Decodable, Sendable {
        let movies: [Title]
        let tv: [Title]
        let anime: [Title]
    }

    private struct Title: Decodable, Sendable {
        let title: String?
        let title_romaji: String?
        let anime_type: String?
        let year: Int?
        let release_date: String?
        let overview: String?
        let genres: [String]?
        let poster: String?
        let fanart: String?
        let ids: IDs?
        let adult: Bool?
        let is_adult: Bool?
        let isAdult: Bool?

        struct IDs: Decodable, Sendable {
            let simkl_id: Identifier?
            let slug: String?
            let imdb: String?
            let tmdb: Identifier?
            let tvdb: Identifier?
            let mal: Identifier?
            let anilist: Identifier?
            let anidb: Identifier?
        }
    }

    /// CDN external IDs are strings; Simkl's own ID is an integer.
    private struct Identifier: Decodable, Sendable {
        let value: String
        var positiveNumber: String? {
            guard let number = Int(value), number > 0 else { return nil }
            return String(number)
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            do {
                value = try container.decode(String.self)
            } catch DecodingError.typeMismatch {
                value = String(try container.decode(Int.self))
            }
        }
    }
}
