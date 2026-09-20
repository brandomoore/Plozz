import CoreModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AniListDiscoveryError: Error, Equatable, Sendable {
    case graphQL
}

/// Public anime discovery. Profile source selection keeps this opt-in.
/// One GraphQL request combines bounded trending and current-season pages.
public struct AniListDiscoveryProvider: HeroDiscoveryProviding {
    public let source: HeroDiscoverySource = .anilist
    public let isEnabled: Bool
    private let http: MetadataDiscoveryHTTPClient

    public init(http: MetadataDiscoveryHTTPClient = .init(), isEnabled: Bool = true) {
        self.http = http
        self.isEnabled = isEnabled
    }

    public func discover(_ request: HeroDiscoveryRequest) async throws -> [MediaItem] {
        guard isEnabled, request.limit > 0 else { return [] }
        try Task.checkCancellation()
        let components = Self.calendar.dateComponents([.year, .month], from: request.now)
        guard let year = components.year, let month = components.month, (1...12).contains(month) else {
            throw MetadataDiscoveryHTTPError.invalidResponse
        }
        let season = ["WINTER", "SPRING", "SUMMER", "FALL"][(month - 1) / 3]
        var urlRequest = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        urlRequest.httpMethod = "POST"
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(Query(
            query: Self.document,
            variables: .init(perPage: request.limit, season: season, year: year)
        ))
        let response = try await http.decode(Response.self, from: urlRequest)
        guard response.errors?.isEmpty != false else { throw AniListDiscoveryError.graphQL }
        guard let trending = response.data?.trending?.media,
              let seasonal = response.data?.seasonal?.media else {
            throw MetadataDiscoveryHTTPError.invalidResponse
        }
        var seen = Set<String>()
        var items: [MediaItem] = []
        for index in 0..<request.limit {
            for page in [trending, seasonal] where index < page.count {
                guard let media = page[index],
                      let item = Self.item(media, language: request.language),
                      seen.insert(item.id).inserted else { continue }
                items.append(item)
                if items.count == request.limit { return items }
            }
        }
        return items
    }

    private static func item(_ media: Media, language: String) -> MediaItem? {
        guard let id = media.id, id > 0, media.type == "ANIME", media.isAdult == false else {
            return nil
        }
        let kind: MediaItemKind
        switch media.format {
        case "MOVIE": kind = .movie
        case "TV", "TV_SHORT", "OVA", "ONA": kind = .series
        default: return nil
        }
        let languageCode = language.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first?.lowercased()
        let titles = languageCode == "ja"
            ? [media.title?.native, media.title?.romaji, media.title?.english]
            : [media.title?.english, media.title?.romaji, media.title?.native]
        guard let title = titles.compactMap(nonempty).first else { return nil }
        var ids = [ProviderIDNamespace.aniList.canonicalKey: String(id)]
        if let mal = media.idMal, mal > 0 {
            ids[ProviderIDNamespace.myAnimeList.canonicalKey] = String(mal)
        }
        let banner = imageURL(media.bannerImage)
        let poster = imageURL(media.coverImage?.extraLarge) ?? imageURL(media.coverImage?.large)
        let overview = OverviewRouter.strippedHTML(media.description)
        let attribution = MetadataAttribution(
            source: .anilist,
            sourceURL: URL(string: "https://anilist.co/anime/\(id)")
        )
        var provenance = MetadataProvenance([.title: attribution])
        if overview != nil { provenance[.overview] = attribution }
        if poster != nil { provenance[.posterURL] = attribution }
        if banner != nil { provenance[.backdropURL] = attribution }
        let year = media.startDate?.year.flatMap { (1...9999).contains($0) ? $0 : nil }
        return MediaItem(
            id: "anilist:\(kind.rawValue):\(id)",
            title: title,
            originalTitle: nonempty(media.title?.native) ?? nonempty(media.title?.romaji),
            kind: kind,
            overview: overview,
            productionYear: year,
            releaseDate: media.startDate?.date,
            genres: media.genres ?? [],
            posterURL: poster,
            backdropURL: banner,
            heroBackdropURL: banner,
            providerIDs: ids,
            discoverySources: [.anilist],
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

    private static let document = """
    query ($perPage: Int!, $season: MediaSeason!, $year: Int!) {
      trending: Page(page: 1, perPage: $perPage) {
        media(type: ANIME, isAdult: false,
              format_in: [MOVIE, TV, TV_SHORT, OVA, ONA], sort: TRENDING_DESC) {
          ...DiscoveryMedia
        }
      }
      seasonal: Page(page: 1, perPage: $perPage) {
        media(type: ANIME, isAdult: false, season: $season, seasonYear: $year,
              format_in: [MOVIE, TV, TV_SHORT, OVA, ONA], sort: POPULARITY_DESC) {
          ...DiscoveryMedia
        }
      }
    }
    fragment DiscoveryMedia on Media {
      id idMal type format isAdult
      title { english romaji native }
      description(asHtml: false)
      startDate { year month day }
      genres bannerImage coverImage { extraLarge large }
    }
    """

    private struct Query: Encodable {
        let query: String
        let variables: Variables
        struct Variables: Encodable {
            let perPage: Int
            let season: String
            let year: Int
        }
    }

    private struct Response: Decodable, Sendable {
        let data: Pages?
        let errors: [GraphQLError]?
        struct Pages: Decodable, Sendable {
            let trending: Page?
            let seasonal: Page?
        }
        struct Page: Decodable, Sendable {
            let media: [Media?]?
        }
        struct GraphQLError: Decodable, Sendable {
            let message: String?
        }
    }

    private struct Media: Decodable, Sendable {
        let id: Int?
        let idMal: Int?
        let type: String?
        let format: String?
        let isAdult: Bool?
        let title: Title?
        let description: String?
        let startDate: StartDate?
        let genres: [String]?
        let bannerImage: String?
        let coverImage: CoverImage?

        struct Title: Decodable, Sendable {
            let english: String?
            let romaji: String?
            let native: String?
        }
        struct CoverImage: Decodable, Sendable {
            let extraLarge: String?
            let large: String?
        }
        struct StartDate: Decodable, Sendable {
            let year: Int?
            let month: Int?
            let day: Int?

            var date: Date? {
                guard let year, (1...9999).contains(year), let month, let day else { return nil }
                let components = DateComponents(year: year, month: month, day: day)
                let calendar = AniListDiscoveryProvider.calendar
                guard components.isValidDate(in: calendar) else { return nil }
                return calendar.date(from: components)
            }
        }
    }
}
