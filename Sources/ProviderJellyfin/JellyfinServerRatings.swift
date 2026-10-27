import Foundation
import CoreModels
import CoreNetworking

/// Reads only the installed plugin's cache, never its upstream providers or refresh endpoints.
actor JellyfinServerRatings {
    private struct Cached {
        let ratings: [ExternalRating]?
        let expires: ContinuousClock.Instant
    }

    private var unavailableUntil: ContinuousClock.Instant?
    private var cached: [String: Cached] = [:]
    private var cacheOrder: [String] = []
    private let timeout: Duration

    init(timeout: Duration = .seconds(2)) {
        self.timeout = timeout
    }

    func cachedRatings(for item: MediaItem) -> [ExternalRating]? {
        guard let entry = cached[item.id], ContinuousClock.now < entry.expires else { return nil }
        return entry.ratings
    }

    func ratings(for item: MediaItem, client: JellyfinClient) async throws -> [ExternalRating]? {
        guard client.providerKind == .jellyfin,
              [.movie, .series, .season, .episode].contains(item.kind) else { return nil }
        // The plugin accepts a Guid, unlike compatible servers' synthetic item IDs.
        let id = item.id.replacingOccurrences(of: "-", with: "")
        guard id.utf8.count == 32,
              id.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        try Task.checkCancellation()
        if let entry = cached[item.id], ContinuousClock.now < entry.expires { return entry.ratings }
        if let unavailableUntil, ContinuousClock.now < unavailableUntil { return nil }
        do {
            let response = try await withThrowingTaskGroup(of: MdbListCachedRatings.self) { group in
                group.addTask { try await client.cachedServerRatings(itemID: item.id) }
                group.addTask { [timeout] in
                    try await Task.sleep(for: timeout)
                    throw AppError.serverUnreachable
                }
                defer { group.cancelAll() }
                guard let response = try await group.next() else { throw AppError.invalidResponse }
                return response
            }
            try Task.checkCancellation()
            let supplied = response.hasCache ? response.displayRatings() : []
            let ratings = supplied.isEmpty ? nil : supplied
            cached[item.id] = Cached(
                ratings: ratings,
                expires: ContinuousClock.now.advanced(by: ratings == nil ? .seconds(30) : .seconds(300))
            )
            cacheOrder.removeAll { $0 == item.id }
            cacheOrder.append(item.id)
            if cacheOrder.count > 64 { cached.removeValue(forKey: cacheOrder.removeFirst()) }
            return ratings
        } catch {
            if Task.isCancelled || error is CancellationError || error as? AppError == .cancelled {
                throw CancellationError()
            }
            if error as? AppError == .notFound {
                unavailableUntil = ContinuousClock.now.advanced(by: .seconds(300))
                return nil
            }
            let failure = (error as? AppError) ?? .invalidResponse
            PlozzLog.networking.error(
                "Server-provided ratings unavailable error=\(HandoffDiagnostics.errorCode(failure))"
            )
            return nil
        }
    }
}

struct MdbListCachedRatings: Decodable, Sendable {
    struct Rating: Decodable, Sendable {
        let source: String
        let value: Double?
        let score: Double?
        let votes: Int?
    }

    let hasCache: Bool
    let ratings: [Rating]

    private enum CodingKeys: String, CodingKey { case hasCache, ratings }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hasCache = try values.decode(Bool.self, forKey: .hasCache)
        guard hasCache else {
            ratings = []
            return
        }
        var entries = try values.nestedUnkeyedContainer(forKey: .ratings)
        var decoded: [Rating] = []
        while !entries.isAtEnd {
            let entry = try entries.superDecoder()
            do {
                decoded.append(try Rating(from: entry))
            } catch {
                PlozzLog.networking.error("Server returned a malformed cached rating.")
            }
        }
        ratings = decoded
    }

    func displayRatings() -> [ExternalRating] {
        var result: [ExternalRating] = []
        var indices: [String: Int] = [:]
        for entry in ratings {
            let key = entry.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, key.count <= 64 else {
                PlozzLog.networking.error("Server returned an invalid rating source.")
                continue
            }
            let family = Self.family(for: key)
            let source = Self.source(for: family)
            let score: Double?
            if let normalized = entry.score {
                score = normalized
            } else if let value = entry.value, let maximum = Self.nativeMaximum(for: key) {
                score = value / maximum * 100
            } else {
                score = nil
            }
            guard let score, score.isFinite, (0...100).contains(score) else {
                PlozzLog.networking.error("Server returned a rating without a valid score or known scale.")
                continue
            }
            let scale: RatingScale
            switch source {
            case .imdb, .tmdb: scale = .outOfTen
            case .rottenTomatoes, .rottenTomatoesAudience, .anilist: scale = .percent
            case .letterboxd: scale = .outOfFive
            default: scale = .outOfHundred
            }
            var rating = ExternalRating(
                source: source, value: score / 100 * scale.maximum, scale: scale,
                ratingCount: entry.votes.flatMap { $0 > 0 ? $0 : nil }
            )
            let order = indices[family] ?? result.count
            rating.providerDisplay = .init(
                sourceID: family, name: Self.name(for: key, family: family, source: source),
                value: rating.displayValue, order: order
            )
            if let index = indices[family] {
                if (rating.ratingCount ?? 0) > (result[index].ratingCount ?? 0) {
                    result[index] = rating
                }
            } else {
                indices[family] = result.count
                result.append(rating)
            }
        }
        return result
    }

    private static func family(for key: String) -> String {
        switch key {
        case "whatson_imdb", "simkl_imdb": return "imdb"
        case "whatson_tmdb": return "tmdb"
        case "whatson_trakt": return "trakt"
        case "whatson_tomatoes": return "tomatoes"
        case "whatson_popcorn": return "popcorn"
        case "whatson_metacritic": return "metacritic"
        case "metacriticus", "whatson_metacriticuser": return "metacriticuser"
        case "whatson_letterboxd": return "letterboxd"
        case "simkl_mal": return "myanimelist"
        default: return key
        }
    }

    private static func source(for family: String) -> RatingSource {
        switch family {
        case "tomatoes": return .rottenTomatoes
        case "popcorn": return .rottenTomatoesAudience
        default: return RatingSource(rawValue: family) ?? .provider
        }
    }

    private static func nativeMaximum(for key: String) -> Double? {
        switch key {
        case "imdb", "whatson_imdb", "simkl_imdb", "whatson_tmdb",
             "trakt", "whatson_trakt", "metacriticus", "metacriticuser",
             "whatson_metacriticuser", "senscritique", "betaseries", "myanimelist",
             "simkl_mal", "tvmaze": return 10
        case "tmdb", "tomatoes", "whatson_tomatoes", "popcorn", "whatson_popcorn",
             "metacritic", "whatson_metacritic", "anilist", "mdblist", "simkl": return 100
        case "letterboxd", "whatson_letterboxd", "allocine_critics", "allocine_users": return 5
        case "rogerebert": return 4
        default: return nil
        }
    }

    private static func name(for key: String, family: String, source: RatingSource) -> String { // l10n:content — server rating-service names
        let name: String
        switch family {
        case "trakt": name = "Trakt"
        case "metacriticuser": name = "Metacritic User"
        case "senscritique": name = "SensCritique"
        case "betaseries": name = "BetaSeries"
        case "myanimelist": name = "MyAnimeList"
        case "tvmaze": name = "TVmaze"
        case "mdblist": name = "MDBList"
        case "simkl": name = "Simkl"
        case "whatson": name = "WhatsOn"
        case "allocine_critics": name = "AlloCine Critics"
        case "allocine_users": name = "AlloCine Users"
        case "rogerebert": name = "RogerEbert.com"
        default: name = source == .provider ? key : source.displayName
        }
        if key.hasPrefix("whatson_") { return "\(name) (WhatsOn)" }
        if key.hasPrefix("simkl_") { return "\(name) (Simkl)" }
        return name
    }
}
