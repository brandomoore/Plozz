import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A bounded two-day premiere/returning-series feed, not the full TVmaze catalog.
/// Broadcast/local-web and global-web schedules have different show envelopes.
public struct TVmazeDiscoveryProvider: HeroDiscoveryProviding {
    public let source: HeroDiscoverySource = .tvmaze
    public let isEnabled: Bool
    private let http: MetadataDiscoveryHTTPClient

    public init(http: MetadataDiscoveryHTTPClient = .init(), isEnabled: Bool = true) {
        self.http = http
        self.isEnabled = isEnabled
    }

    public func discover(_ request: HeroDiscoveryRequest) async throws -> [MediaItem] {
        guard isEnabled, request.limit > 0 else { return [] }
        try Task.checkCancellation()
        let calendar = Self.calendar
        let today = calendar.startOfDay(for: request.now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            throw MetadataDiscoveryHTTPError.invalidResponse
        }
        let formatter = Self.dateFormatter
        let country = Self.countryCode(request.region)
        var seen = Set<Int>()
        var items: [MediaItem] = []
        for date in [today, tomorrow] {
            let day = formatter.string(from: date)
            for globalWeb in [false, true] {
                try Task.checkCancellation()
                var components = URLComponents()
                components.scheme = "https"
                components.host = "api.tvmaze.com"
                components.path = globalWeb ? "/schedule/web" : "/schedule"
                components.queryItems = [
                    URLQueryItem(name: "country", value: globalWeb ? "" : country),
                    URLQueryItem(name: "date", value: day),
                ]
                guard let url = components.url else { throw MetadataDiscoveryHTTPError.invalidResponse }
                var urlRequest = URLRequest(url: url)
                urlRequest.httpShouldHandleCookies = false
                let episodes = try await http.decode([Episode].self, from: urlRequest)
                for episode in episodes {
                    guard episode.number == 1, (episode.season ?? 0) > 0,
                          episode.type == nil || episode.type == "regular",
                          episode.airdate == day,
                          episode.isAdult != true, episode.is_adult != true, episode.adult != true,
                          let show = episode.show ?? episode._embedded?.show,
                          let item = Self.item(show, formatter: formatter),
                          seen.insert(show.id).inserted else { continue }
                    items.append(item)
                    if items.count == request.limit { return items }
                }
            }
        }
        return items
    }

    private static func item(_ show: Show, formatter: DateFormatter) -> MediaItem? {
        guard show.id > 0, let title = nonempty(show.name),
              show.isAdult != true, show.is_adult != true, show.adult != true,
              !(show.genres ?? []).contains(where: {
                  ["adult", "hentai", "pornography"].contains($0.lowercased())
              }) else { return nil }
        var ids = [ProviderIDNamespace.tvmaze.canonicalKey: String(show.id)]
        if let tvdb = show.externals?.thetvdb, tvdb > 0 {
            ids[ProviderIDNamespace.tvdb.canonicalKey] = String(tvdb)
        }
        if let imdb = nonempty(show.externals?.imdb),
           imdb.range(of: "^tt[0-9]+$", options: .regularExpression) != nil {
            ids[ProviderIDNamespace.imdb.canonicalKey] = imdb
        }
        // A returning season's air date must never replace the show's first premiere.
        let premiere = show.premiered.flatMap { value -> Date? in
            guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
                return nil
            }
            return date
        }
        let poster = imageURL(show.image?.original) ?? imageURL(show.image?.medium)
        let overview = OverviewRouter.strippedHTML(show.summary)
        let attribution = MetadataAttribution(
            source: .tvmaze,
            sourceURL: URL(string: "https://www.tvmaze.com/shows/\(show.id)")
        )
        var provenance = MetadataProvenance([.title: attribution])
        if overview != nil { provenance[.overview] = attribution }
        if poster != nil { provenance[.posterURL] = attribution }
        return MediaItem(
            id: "tvmaze:series:\(show.id)",
            title: title,
            kind: .series,
            overview: overview,
            productionYear: premiere.map { calendar.component(.year, from: $0) },
            releaseDate: premiere,
            genres: show.genres ?? [],
            posterURL: poster,
            providerIDs: ids,
            discoverySources: [.tvmaze],
            metadataProvenance: provenance,
            availability: .unknown,
            locallyValidatedPlayableSource: false
        )
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private static func countryCode(_ value: String) -> String {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code == "UK" { return "GB" }
        return code.count == 2 && Locale.isoRegionCodes.contains(code) ? code : "US"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func imageURL(_ value: String?) -> URL? {
        guard let value = nonempty(value), let url = URL(string: value),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else {
            return nil
        }
        return url
    }

    private struct Episode: Decodable, Sendable {
        let number: Int?
        let season: Int?
        let type: String?
        let airdate: String?
        let isAdult: Bool?
        let is_adult: Bool?
        let adult: Bool?
        let show: Show?
        let _embedded: Embedded?
        struct Embedded: Decodable, Sendable {
            let show: Show?
        }
    }

    private struct Show: Decodable, Sendable {
        let id: Int
        let name: String?
        let premiered: String?
        let summary: String?
        let genres: [String]?
        let isAdult: Bool?
        let is_adult: Bool?
        let adult: Bool?
        let externals: Externals?
        let image: Image?
        struct Externals: Decodable, Sendable {
            let thetvdb: Int?
            let imdb: String?
        }
        struct Image: Decodable, Sendable {
            let original: String?
            let medium: String?
        }
    }
}
