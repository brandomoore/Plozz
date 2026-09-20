import CoreModels
import Foundation

/// Public catalog discovery using the bundled project's existing v4 login.
/// Filters describe country of origin and original language, not availability.
/// One release year per pass keeps unpaginated filter responses bounded.
/// API: https://github.com/thetvdb/v4-api/blob/main/docs/swagger.yml.
public struct TVDBDiscoveryProvider: HeroDiscoveryProviding {
    public let source: HeroDiscoverySource = .tvdb
    private let config: TVDBConfig
    private let client: TVDBClient
    private let localeCatalog: LocaleCatalog

    public init(
        config: TVDBConfig = .resolved(),
        http: MetadataDiscoveryHTTPClient = .init()
    ) {
        self.config = config
        let client = TVDBClient(config: config, http: http)
        self.client = client
        self.localeCatalog = LocaleCatalog(client: client)
    }

    public var isEnabled: Bool { config.isConfigured }

    public var cacheIdentifier: String {
        let configuration = "\(config.apiBaseURL.absoluteString)\n\(config.apiKey ?? "")"
        return "tvdb:" + MetadataDiscoveryHTTPClient.configurationFingerprint(configuration)
    }

    public func discover(_ request: HeroDiscoveryRequest) async throws -> [MediaItem] {
        try Task.checkCancellation()
        guard isEnabled, request.limit > 0 else { return [] }
        let locale = try await localeCatalog.resolve(region: request.region, language: request.language)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.year, from: request.now)
        var feeds: [[MediaItem]] = []
        for kind in [MediaItemKind.movie, .series] {
            try Task.checkCancellation()
            var query = [
                URLQueryItem(name: "country", value: locale.country),
                URLQueryItem(name: "lang", value: locale.language),
                URLQueryItem(name: "sort", value: "score"),
                URLQueryItem(name: "year", value: String(year))
            ]
            // v4 documents sortType only for series; neither filter has paging.
            if kind == .series { query.append(URLQueryItem(name: "sortType", value: "desc")) }
            let data = try await client.discoveryData(
                path: kind == .movie ? "movies/filter" : "series/filter",
                query: query
            )
            let response: Response<Record> = try Self.decode(data)
            feeds.append(response.data.prefix(100).compactMap { $0.mediaItem(kind: kind) }
                .filter { request.recency.includesRelease(of: $0, at: request.now) })
        }
        try Task.checkCancellation()
        var result: [MediaItem] = []
        var seen = Set<String>()
        for index in 0..<(feeds.map(\.count).max() ?? 0) {
            for feed in feeds where index < feed.count {
                let item = feed[index]
                guard seen.insert(item.id).inserted else { continue }
                result.append(item)
                if result.count == request.limit { return result }
            }
        }
        return result
    }

    private static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw MetadataDiscoveryHTTPError.invalidResponse
        }
    }

    private struct Response<Record: Decodable>: Decodable {
        let data: [Record]

        private enum CodingKeys: String, CodingKey { case data, status }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decodeIfPresent(String.self, forKey: .status)
            guard status == nil || status?.lowercased() == "success" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .status, in: container, debugDescription: "TheTVDB reported an unsuccessful response"
                )
            }
            data = try container.decode([Record].self, forKey: .data)
        }
    }

    /// The required ISO-3166/639 alpha-3 IDs come from v4's own catalogs, rather
    /// than assuming two-letter app locales are valid filter values. These
    /// static catalogs cost two requests once per provider instance.
    private actor LocaleCatalog {
        private let client: TVDBClient
        private var countries: [LocaleRecord]?
        private var languages: [LocaleRecord]?

        init(client: TVDBClient) { self.client = client }

        func resolve(region: String, language: String) async throws -> (country: String, language: String) {
            if countries == nil {
                let data = try await client.discoveryData(path: "countries")
                let response: Response<LocaleRecord> = try TVDBDiscoveryProvider.decode(data)
                _ = try Self.identifier(region, in: response.data, fallback: "usa")
                countries = response.data
            }
            if languages == nil {
                let data = try await client.discoveryData(path: "languages")
                let response: Response<LocaleRecord> = try TVDBDiscoveryProvider.decode(data)
                _ = try Self.identifier(Self.baseLanguage(language), in: response.data, fallback: "eng")
                languages = response.data
            }
            return (
                try Self.identifier(region, in: countries ?? [], fallback: "usa"),
                try Self.identifier(Self.baseLanguage(language), in: languages ?? [], fallback: "eng")
            )
        }

        private static func baseLanguage(_ value: String) -> String {
            value.replacingOccurrences(of: "_", with: "-").split(separator: "-").first
                .map(String.init) ?? ""
        }

        private static func identifier(_ raw: String, in records: [LocaleRecord], fallback: String) throws -> String {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valid = records.filter {
                guard let id = $0.id, id.utf8.count == 3 else { return false }
                return id.lowercased().utf8.allSatisfy { (97...122).contains($0) }
            }
            let match = valid.first {
                $0.id?.lowercased() == value || $0.shortCode?.lowercased() == value
            } ?? valid.first { $0.id?.lowercased() == fallback }
            guard let id = match?.id else { throw MetadataDiscoveryHTTPError.invalidResponse }
            return id.lowercased()
        }
    }

    private struct LocaleRecord: Decodable, Sendable {
        let id: String?
        let shortCode: String?
    }

    private struct Record: Decodable {
        let id: Int?
        let name: String?
        let image: String?
        let year: String?
        let firstAired: String?
        let overview: String?
        let adult: Bool?
        let isAdult: Bool?

        func mediaItem(kind: MediaItemKind) -> MediaItem? {
            guard let id, id > 0, adult != true, isAdult != true,
                  let title = Self.text(name) else { return nil }
            return MediaItem(
                id: "tvdb:\(kind.rawValue):\(id)",
                title: title,
                kind: kind,
                overview: Self.text(overview),
                productionYear: year.flatMap(Int.init),
                releaseDate: Self.releaseDate(firstAired),
                posterURL: Self.imageURL(image),
                providerIDs: ["Tvdb": String(id)],
                discoverySources: [.tvdb],
                metadataProvenance: MetadataProvenance([
                    .title: MetadataAttribution(
                        source: .tvdb,
                        sourceURL: URL(string: "https://thetvdb.com/dereferrer/\(kind == .movie ? "movie" : "series")/\(id)")
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

        private static func imageURL(_ value: String?) -> URL? {
            guard let value = text(value) else { return nil }
            if let url = URL(string: value), let scheme = url.scheme {
                guard scheme == "https" || scheme == "http", url.host != nil else { return nil }
                return url
            }
            guard !value.hasPrefix("//"), !value.contains("..") else { return nil }
            return URL(string: "https://artworks.thetvdb.com" + (value.hasPrefix("/") ? value : "/" + value))
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
