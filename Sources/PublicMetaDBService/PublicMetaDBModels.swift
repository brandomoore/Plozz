import CoreModels
import Foundation

public enum PublicMetaDB {
    public enum MediaType: String, Codable, CaseIterable, Sendable {
        case movie, tv
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidInput
        case invalidKey
        case disconnected
        case connectionChanged
        case blocked
        case incompleteResponse
        case responseTooLarge
        case uncertainWrite
        case rejected

        public var appError: AppError {
            switch self {
            case .invalidKey, .disconnected: .unauthorized
            case .connectionChanged: .cancelled
            case .blocked: .accessRestricted
            case .invalidInput, .incompleteResponse, .responseTooLarge, .rejected: .invalidResponse
            case .uncertainWrite: .conflict
            }
        }
    }

    public struct Content: Codable, Hashable, Sendable {
        public let tmdbID: Int
        public let mediaType: MediaType
        public let season: Int?
        public let episode: Int?

        public init(tmdbID: Int, mediaType: MediaType, season: Int? = nil, episode: Int? = nil) throws {
            guard tmdbID > 0, season.map({ $0 >= 0 }) ?? true,
                  episode.map({ $0 > 0 }) ?? true,
                  episode == nil || season != nil,
                  mediaType == .tv || (season == nil && episode == nil) else {
                throw Failure.invalidInput
            }
            self.tmdbID = tmdbID
            self.mediaType = mediaType
            self.season = season
            self.episode = episode
        }

        public var isPlayable: Bool { mediaType == .movie || (season != nil && episode != nil) }

        public static func matching(_ item: MediaItem) -> Self? {
            let isChild = item.kind == .episode || item.kind == .season
            guard let id = resolvedTMDBID(item.providerIDs, namespace: isChild ? .seriesTmdb : .tmdb) else { return nil }
            switch item.kind {
            case .movie: return try? .init(tmdbID: id, mediaType: .movie)
            case .series: return try? .init(tmdbID: id, mediaType: .tv)
            case .season:
                guard item.episodeOrdering == .tmdb, let season = item.seasonNumber else { return nil }
                return try? .init(tmdbID: id, mediaType: .tv, season: season)
            case .episode:
                guard item.episodeOrdering == .tmdb, let season = item.seasonNumber, let episode = item.episodeNumber,
                      item.episodeNumberEnd == nil || item.episodeNumberEnd == episode else { return nil }
                return try? .init(tmdbID: id, mediaType: .tv, season: season, episode: episode)
            default: return nil
            }
        }

        static func resolvedTMDBID(_ values: [String: String], namespace: ProviderIDNamespace) -> Int? {
            let candidates = values.compactMap { [$0.key: $0.value].providerID(namespace) }
            let ids = candidates.compactMap(Int.init)
            guard !ids.isEmpty, ids.count == candidates.count, ids.allSatisfy({ $0 > 0 }),
                  Set(ids).count == 1 else { return nil }
            return ids.first
        }

        enum CodingKeys: String, CodingKey {
            case tmdbID = "tmdb_id", mediaType = "media_type", season, episode
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                tmdbID: values.decode(Int.self, forKey: .tmdbID),
                mediaType: values.decode(MediaType.self, forKey: .mediaType),
                season: values.decodeIfPresent(Int.self, forKey: .season),
                episode: values.decodeIfPresent(Int.self, forKey: .episode)
            )
        }

        var query: [URLQueryItem] {
            var items = [
                URLQueryItem(name: "tmdb_id", value: String(tmdbID)),
                URLQueryItem(name: "media_type", value: mediaType.rawValue)
            ]
            if let season { items.append(.init(name: "season", value: String(season))) }
            if let episode { items.append(.init(name: "episode", value: String(episode))) }
            return items
        }
    }

    public struct Record<Value: Decodable & Sendable>: Decodable, Identifiable, Sendable {
        public let id: String
        public let value: Value
        public let contributor: String?
        public let created: String?
        public let updated: String?

        private enum CodingKeys: String, CodingKey { case id, contributor, created, updated }

        private init(id: String, value: Value, contributor: String?, created: String?, updated: String?) {
            self.id = id
            self.value = value
            self.contributor = contributor
            self.created = created
            self.updated = updated
        }

        func map<NewValue: Decodable & Sendable>(
            _ transform: (Value) throws -> NewValue
        ) rethrows -> Record<NewValue> {
            try Record<NewValue>(
                id: id, value: transform(value), contributor: contributor, created: created, updated: updated
            )
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            guard !id.isEmpty else { throw Failure.incompleteResponse }
            value = try Value(from: decoder)
            contributor = try values.decodeIfPresent(String.self, forKey: .contributor)
            created = try values.decodeIfPresent(String.self, forKey: .created)
            updated = try values.decodeIfPresent(String.self, forKey: .updated)
        }
    }

    public struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
        public let items: [Item]
        public let total: Int
        public let page: Int
        public let perPage: Int
        public let totalPages: Int

        public func validate(requestedPage: Int, maximumPageSize: Int) throws {
            guard page == requestedPage, page > 0, total >= 0, perPage > 0,
                  perPage <= maximumPageSize, items.count <= perPage, items.count <= total,
                  totalPages >= 0,
                  totalPages == (total == 0 ? 0 : (total - 1) / perPage + 1)
                    || (total == 0 && totalPages == 1),
                  (total == 0 && items.isEmpty && page == 1)
                    || (page <= totalPages && !items.isEmpty),
                  page >= totalPages || items.count == perPage else {
                throw Failure.incompleteResponse
            }
        }
    }

    public struct Collection<Item: Decodable & Sendable>: Decodable, Sendable {
        public let items: [Item]
        public let total: Int
        public var isComplete: Bool { total >= 0 && items.count == total }
    }

    public struct Acknowledgement: Decodable, Sendable {
        public let success: Bool
        public let deleted: Int?
        public let already: Bool?
    }

    public struct Created<Item: Decodable & Sendable>: Decodable, Sendable {
        public let success: Bool
        public let item: Item
        public let action: String?
    }

    public enum WatchDate: Equatable, Sendable {
        case now
        case known(Date)
        case unknown

        func matches(_ observed: Date?) -> Bool {
            switch self {
            case .now: return observed != nil
            case .unknown: return observed == nil
            case .known(let date):
                guard let observed else { return false }
                return abs(observed.timeIntervalSince(date)) < 0.001
            }
        }
    }

    public struct Watch: Codable, Sendable {
        public let content: Content
        public let watchedAt: Date?

        enum CodingKeys: String, CodingKey { case watchedAt = "watched_at" }

        public init(from decoder: Decoder) throws {
            content = try Content(from: decoder)
            guard content.isPlayable else { throw Failure.incompleteResponse }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // An absent date is not evidence of a watch that happened now.
            guard values.contains(.watchedAt) else { throw Failure.incompleteResponse }
            watchedAt = try values.decodeIfPresent(Date.self, forKey: .watchedAt)
        }

        public func encode(to encoder: Encoder) throws {
            try content.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(watchedAt, forKey: .watchedAt)
        }
    }

    public struct Resume: Codable, Sendable {
        public let content: Content
        public let positionMilliseconds: Double
        public let runtimeMilliseconds: Double
        public var progress: Double { positionMilliseconds / runtimeMilliseconds * 100 }

        public enum Disposition: String, Codable, Sendable { case saved, ignored, completed }
        public var expectedDisposition: Disposition {
            if progress < 2 { return .ignored }
            if progress >= 80 { return .completed }
            return .saved
        }

        public init(content: Content, positionMilliseconds: Double, runtimeMilliseconds: Double) throws {
            guard content.isPlayable, positionMilliseconds.isFinite, runtimeMilliseconds.isFinite,
                  positionMilliseconds >= 0, runtimeMilliseconds > 0,
                  positionMilliseconds <= runtimeMilliseconds else { throw Failure.invalidInput }
            self.content = content
            self.positionMilliseconds = positionMilliseconds
            self.runtimeMilliseconds = runtimeMilliseconds
        }

        enum CodingKeys: String, CodingKey {
            case positionMilliseconds = "position_ms", runtimeMilliseconds = "runtime_ms"
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                content: Content(from: decoder),
                positionMilliseconds: values.decode(Double.self, forKey: .positionMilliseconds),
                runtimeMilliseconds: values.decode(Double.self, forKey: .runtimeMilliseconds)
            )
        }

        public func encode(to encoder: Encoder) throws {
            try content.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(positionMilliseconds, forKey: .positionMilliseconds)
            try values.encode(runtimeMilliseconds, forKey: .runtimeMilliseconds)
        }
    }

    public struct ResumeResult: Decodable, Sendable {
        public let action: Resume.Disposition
        public let item: Record<Resume>?
        public let progress: Double?
        public let content: Content?
        private enum CodingKeys: String, CodingKey { case action, item, progress, tmdbID = "tmdb_id" }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            action = try values.decode(Resume.Disposition.self, forKey: .action)
            item = try values.decodeIfPresent(Record<Resume>.self, forKey: .item)
            progress = try values.decodeIfPresent(Double.self, forKey: .progress)
            content = values.contains(.tmdbID) ? try Content(from: decoder) : nil
        }
    }

    public struct ShowTotal: Decodable, Sendable {
        public let tmdbID: Int
        public let watchedEpisodes: Int
        public let lastWatchedAt: Date?
        enum CodingKeys: String, CodingKey {
            case tmdbID = "tmdb_id", watchedEpisodes = "watched_episodes", lastWatchedAt = "last_watched_at"
        }
    }

}

extension PublicMetaDB.Record: Equatable where Value: Equatable {}
