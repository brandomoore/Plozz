import Foundation

extension PublicMetaDB {
    public enum Contribution: String, Codable, CaseIterable, Sendable {
        case skips, ratings, highlights, mappings
        case animeSeasons = "anime-seasons"
        case episodeRatings = "episode-ratings"
    }

    public enum Vote: Int, Codable, CaseIterable, Sendable {
        case down = -1, neutral = 0, up = 1
    }

    public struct Votes: Decodable, Sendable {
        public struct Entry: Decodable, Identifiable, Sendable {
            public let id: String
            public let vote: Vote
            public let contributor: String?
        }
        public struct Summary: Decodable, Sendable {
            public let upvotes: Int
            public let downvotes: Int
            public let score: Int
        }
        public let items: [Entry]
        public let total: Int
        public let summary: Summary
        public let userVote: Vote?

        enum CodingKeys: String, CodingKey { case items, total, summary, userVote }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.userVote) else { throw Failure.incompleteResponse }
            items = try values.decode([Entry].self, forKey: .items)
            total = try values.decode(Int.self, forKey: .total)
            summary = try values.decode(Summary.self, forKey: .summary)
            userVote = try values.decodeIfPresent(Vote.self, forKey: .userVote)
        }
    }

    public struct Rating: Codable, Equatable, Sendable {
        public let content: Content
        public let score: Double
        public let label: String

        public init(content: Content, score: Double, label: String) throws {
            guard score.isFinite, (0...100).contains(score),
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidInput }
            self.content = content
            self.score = score
            self.label = label
        }

        enum CodingKeys: String, CodingKey { case score, label }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(content: Content(from: decoder), score: values.decode(Double.self, forKey: .score),
                          label: values.decode(String.self, forKey: .label))
        }

        public func encode(to encoder: Encoder) throws {
            try content.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(score, forKey: .score)
            try values.encode(label, forKey: .label)
        }
    }

    public struct Ratings: Decodable, Sendable {
        public let items: [Record<Rating>]
        public let total: Int
        public let average: Double?
        public var isComplete: Bool { total >= 0 && items.count == total }
    }

    public struct SeasonRatings: Decodable, Sendable {
        public struct Aggregate: Decodable, Sendable {
            public let label: String
            public let count: Int
            public let average: Double
        }
        public struct Episode: Decodable, Sendable {
            public let episode: Int
            public let total: Int
            public let aggregates: [String: Aggregate]
            public let ratings: [Record<Rating>]
        }
        public let tmdbID: Int
        public let mediaType: MediaType
        public let season: Int
        public let episodes: [Episode]
        public let totalRatings: Int
        public let seasonAverage: Double?
        public let episodeCount: Int
        public var mayBeCapped: Bool { totalRatings >= 5_000 }
        enum CodingKeys: String, CodingKey {
            case tmdbID = "tmdb_id", mediaType = "media_type", season, episodes
            case totalRatings, seasonAverage, episodeCount
        }
    }

    public struct EpisodeRatingInput: Encodable, Sendable {
        public let episode: Int
        public let score: Double
        public let label: String?

        public init(episode: Int, score: Double, label: String? = nil) throws {
            guard episode > 0, score.isFinite, (0...100).contains(score),
                  label.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true else {
                throw Failure.invalidInput
            }
            self.episode = episode
            self.score = score
            self.label = label
        }
    }

    public struct RatingBatchResult: Decodable, Sendable {
        public struct Item: Decodable, Identifiable, Sendable {
            public let id: String
            public let tmdbID: Int
            public let season: Int
            public let episode: Int
            public let score: Double
            public let label: String
            enum CodingKeys: String, CodingKey { case id, tmdbID = "tmdb_id", season, episode, score, label }
        }
        public let success: Bool
        public let created: Int
        public let failed: Int
        public let total: Int
        public let items: [Item]
        public var isCompleteSuccess: Bool { success && failed == 0 && created == total }
    }

    public struct RatingBatchDeletion: Decodable, Sendable {
        public let success: Bool
        public let deleted: Int
        public let failed: Int
        public let total: Int
        public let deletedIds: [String]
        public var isCompleteSuccess: Bool { success && failed == 0 && deleted == total }
    }

    public struct Segment: Codable, Equatable, Sendable {
        public let startMilliseconds: Double
        public let endMilliseconds: Double

        public init(startMilliseconds: Double, endMilliseconds: Double) throws {
            guard startMilliseconds.isFinite, endMilliseconds.isFinite,
                  startMilliseconds >= 0, endMilliseconds > startMilliseconds else { throw Failure.invalidInput }
            self.startMilliseconds = startMilliseconds
            self.endMilliseconds = endMilliseconds
        }
    }

    public enum ReleaseSource: String, Codable, CaseIterable, Sendable { case streaming, physical }

    public struct Skip: Codable, Equatable, Sendable {
        public let content: Content
        public let source: ReleaseSource?
        public let intro: Segment?
        public let credits: Segment?
        public let recap: Segment?
        public let preview: Segment?

        public init(
            content: Content, source: ReleaseSource, intro: Segment? = nil, credits: Segment? = nil,
            recap: Segment? = nil, preview: Segment? = nil
        ) throws {
            guard content.isPlayable, [intro, credits, recap, preview].contains(where: { $0 != nil }),
                  content.mediaType == .tv || (recap == nil && preview == nil) else { throw Failure.invalidInput }
            self.content = content
            self.source = source
            self.intro = intro
            self.credits = credits
            self.recap = recap
            self.preview = preview
        }

        enum CodingKeys: String, CodingKey {
            case source
            case introStart = "intro_start_ms", introEnd = "intro_end_ms"
            case creditsStart = "credits_start_ms", creditsEnd = "credits_end_ms"
            case recapStart = "recap_start_ms", recapEnd = "recap_end_ms"
            case previewStart = "preview_start_ms", previewEnd = "preview_end_ms"
        }

        public init(from decoder: Decoder) throws {
            content = try Content(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            source = try values.decodeIfPresent(ReleaseSource.self, forKey: .source)
            func segment(_ start: CodingKeys, _ end: CodingKeys) throws -> Segment? {
                let start = try values.decodeIfPresent(Double.self, forKey: start)
                let end = try values.decodeIfPresent(Double.self, forKey: end)
                if start == nil && end == nil { return nil }
                guard let start, let end else { throw Failure.incompleteResponse }
                return try Segment(startMilliseconds: start, endMilliseconds: end)
            }
            intro = try segment(.introStart, .introEnd)
            credits = try segment(.creditsStart, .creditsEnd)
            recap = try segment(.recapStart, .recapEnd)
            preview = try segment(.previewStart, .previewEnd)
            guard content.isPlayable, content.mediaType == .tv || (recap == nil && preview == nil) else {
                throw Failure.incompleteResponse
            }
        }

        public func encode(to encoder: Encoder) throws {
            try content.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(source, forKey: .source)
            for (segment, start, end) in [
                (intro, CodingKeys.introStart, CodingKeys.introEnd),
                (credits, .creditsStart, .creditsEnd), (recap, .recapStart, .recapEnd),
                (preview, .previewStart, .previewEnd)
            ] {
                if let segment {
                    try values.encode(segment.startMilliseconds, forKey: start)
                    try values.encode(segment.endMilliseconds, forKey: end)
                }
            }
        }
    }

    public struct Highlight: Codable, Equatable, Sendable {
        public let content: Content
        public let segment: Segment
        public let description: String?

        public init(content: Content, segment: Segment, description: String? = nil) throws {
            guard content.isPlayable else { throw Failure.invalidInput }
            self.content = content
            self.segment = segment
            self.description = description
        }

        enum CodingKeys: String, CodingKey {
            case start = "highlight_start_ms", end = "highlight_end_ms", description
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                content: Content(from: decoder),
                segment: Segment(startMilliseconds: values.decode(Double.self, forKey: .start),
                                 endMilliseconds: values.decode(Double.self, forKey: .end)),
                description: values.decodeIfPresent(String.self, forKey: .description)
            )
        }

        public func encode(to encoder: Encoder) throws {
            try content.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(segment.startMilliseconds, forKey: .start)
            try values.encode(segment.endMilliseconds, forKey: .end)
            try values.encodeIfPresent(description, forKey: .description)
        }
    }
}

public extension PublicMetaDBClient {
    func ratings(for content: PublicMetaDB.Content, label: String? = nil) async throws -> PublicMetaDB.Ratings {
        try await send(
            PublicMetaDB.Ratings.self, path: content.season == nil ? "/ratings" : "/episode-ratings",
            query: content.query + (label.map { [.init(name: "label", value: $0)] } ?? [])
        )
    }

    func episodeRatings(
        tmdbID: Int, season: Int? = nil, episode: Int? = nil, label: String? = nil, perPage: Int = 500
    ) async throws -> PublicMetaDB.Ratings {
        let content = try PublicMetaDB.Content(tmdbID: tmdbID, mediaType: .tv, season: season, episode: episode)
        guard (1...500).contains(perPage) else { throw PublicMetaDB.Failure.invalidInput }
        return try await send(
            PublicMetaDB.Ratings.self, path: "/episode-ratings",
            query: content.query + [.init(name: "perPage", value: String(perPage))]
                + (label.map { [.init(name: "label", value: $0)] } ?? [])
        )
    }

    func submitRating(_ rating: PublicMetaDB.Rating) async throws -> PublicMetaDB.Record<PublicMetaDB.Rating> {
        guard rating.content.season == nil || rating.content.episode != nil else { throw PublicMetaDB.Failure.invalidInput }
        let result = try await create(
            PublicMetaDB.Record<PublicMetaDB.Rating>.self,
            path: rating.content.episode == nil ? "/ratings" : "/episode-ratings", body: rating
        )
        guard result.value == rating else { throw PublicMetaDB.Failure.uncertainWrite }
        return result
    }

    func seasonRatings(tmdbID: Int, season: Int, label: String? = nil) async throws -> PublicMetaDB.SeasonRatings {
        let content = try PublicMetaDB.Content(tmdbID: tmdbID, mediaType: .tv, season: season)
        return try await send(
            PublicMetaDB.SeasonRatings.self, path: "/episode-ratings/batch",
            query: content.query + (label.map { [.init(name: "label", value: $0)] } ?? [])
        )
    }

    func submitEpisodeRatings(
        tmdbID: Int, season: Int, label: String, ratings: [PublicMetaDB.EpisodeRatingInput]
    ) async throws -> PublicMetaDB.RatingBatchResult {
        let content = try PublicMetaDB.Content(tmdbID: tmdbID, mediaType: .tv, season: season)
        guard (1...50).contains(ratings.count), Set(ratings.map(\.episode)).count == ratings.count,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PublicMetaDB.Failure.invalidInput }
        let result = try await send(
            PublicMetaDB.RatingBatchResult.self, method: .post, path: "/episode-ratings/batch",
            body: Self.encode(EpisodeRatingsBody(content: content, label: label, ratings: ratings))
        )
        guard result.total == ratings.count, result.failed >= 0,
              result.created == result.items.count, result.created + result.failed == result.total,
              Set(result.items.map(\.id)).count == result.items.count,
              Set(result.items.map(\.episode)).count == result.items.count,
              result.items.allSatisfy({ item in
                  !item.id.isEmpty && item.tmdbID == tmdbID && item.season == season
                    && ratings.contains(where: {
                        $0.episode == item.episode && $0.score == item.score && ($0.label ?? label) == item.label
                    })
              }) else { throw PublicMetaDB.Failure.uncertainWrite }
        return result
    }

    func deleteEpisodeRatings(ids: [String]) async throws -> PublicMetaDB.RatingBatchDeletion {
        guard (1...50).contains(ids.count), Set(ids).count == ids.count else { throw PublicMetaDB.Failure.invalidInput }
        for id in ids { _ = try Self.component(id) }
        let result = try await send(
            PublicMetaDB.RatingBatchDeletion.self, method: .delete, path: "/episode-ratings/batch",
            body: Self.encode(["ids": ids])
        )
        guard result.total == ids.count, result.failed >= 0, result.deleted == result.deletedIds.count,
              result.deleted + result.failed == result.total,
              Set(result.deletedIds).count == result.deletedIds.count,
              Set(result.deletedIds).isSubset(of: Set(ids)) else { throw PublicMetaDB.Failure.uncertainWrite }
        return result
    }

    func skips(
        for content: PublicMetaDB.Content, source: PublicMetaDB.ReleaseSource? = nil,
        page: Int = 1, perPage: Int = 30
    ) async throws -> PublicMetaDB.Page<PublicMetaDB.Record<PublicMetaDB.Skip>> {
        try await self.page(
            PublicMetaDB.Record<PublicMetaDB.Skip>.self, path: "/skips",
            query: content.query + (source.map { [.init(name: "source", value: $0.rawValue)] } ?? []),
            page: page, perPage: perPage, maximumPageSize: 200
        )
    }

    func submitSkip(_ skip: PublicMetaDB.Skip) async throws -> PublicMetaDB.Record<PublicMetaDB.Skip> {
        guard skip.source != nil else { throw PublicMetaDB.Failure.invalidInput }
        let result = try await create(PublicMetaDB.Record<PublicMetaDB.Skip>.self, path: "/skips", body: skip)
        guard result.value == skip else { throw PublicMetaDB.Failure.uncertainWrite }
        return result
    }

    func highlights(for content: PublicMetaDB.Content) async throws -> PublicMetaDB.Collection<PublicMetaDB.Record<PublicMetaDB.Highlight>> {
        try await send(
            PublicMetaDB.Collection<PublicMetaDB.Record<PublicMetaDB.Highlight>>.self,
            path: "/highlights", query: content.query
        )
    }

    func submitHighlight(_ highlight: PublicMetaDB.Highlight) async throws -> PublicMetaDB.Record<PublicMetaDB.Highlight> {
        let result = try await create(PublicMetaDB.Record<PublicMetaDB.Highlight>.self, path: "/highlights", body: highlight)
        guard result.value == highlight else { throw PublicMetaDB.Failure.uncertainWrite }
        return result
    }

    func deleteContribution(_ category: PublicMetaDB.Contribution, id: String) async throws {
        try await acknowledge(path: "/\(category.rawValue)/\(Self.component(id))")
    }

    func votes(
        for category: PublicMetaDB.Contribution, id: String, all: Bool = false
    ) async throws -> PublicMetaDB.Votes {
        try await send(
            PublicMetaDB.Votes.self, path: "/\(category.rawValue)/\(Self.component(id))/votes",
            query: [.init(name: "all", value: String(all))]
        )
    }

    func setVote(_ vote: PublicMetaDB.Vote, for category: PublicMetaDB.Contribution, id: String) async throws {
        let result = try await send(
            VoteResult.self, method: .post, path: "/\(category.rawValue)/\(Self.component(id))/votes",
            body: Self.encode(["vote": vote.rawValue])
        )
        guard result.success, result.vote.vote == vote else { throw PublicMetaDB.Failure.uncertainWrite }
    }

    func removeVote(for category: PublicMetaDB.Contribution, id: String) async throws {
        try await acknowledge(path: "/\(category.rawValue)/\(Self.component(id))/votes")
    }
}

private struct VoteResult: Decodable, Sendable {
    let success: Bool
    let vote: PublicMetaDB.Votes.Entry
}

private struct EpisodeRatingsBody: Encodable {
    let content: PublicMetaDB.Content
    let label: String
    let ratings: [PublicMetaDB.EpisodeRatingInput]
    enum CodingKeys: String, CodingKey { case label, ratings }
    func encode(to encoder: Encoder) throws {
        try content.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(label, forKey: .label)
        try values.encode(ratings, forKey: .ratings)
    }
}
