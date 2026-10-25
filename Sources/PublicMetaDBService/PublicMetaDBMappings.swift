import Foundation

extension PublicMetaDB {
    public enum ExternalIDType: String, Codable, CaseIterable, Sendable {
        case imdb, tvdb, mal, anilist, anidb, trakt
    }

    public struct Mapping: Codable, Equatable, Sendable {
        public let content: Content
        public let idType: ExternalIDType
        public let idValue: String

        public init(content: Content, idType: ExternalIDType, idValue: String) throws {
            guard content.season == nil, content.episode == nil,
                  !idValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidInput }
            self.content = content
            self.idType = idType
            self.idValue = idValue
        }
        enum CodingKeys: String, CodingKey { case idType = "id_type", idValue = "id_value" }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(content: Content(from: decoder),
                          idType: values.decode(ExternalIDType.self, forKey: .idType),
                          idValue: values.decode(String.self, forKey: .idValue))
        }

        public func encode(to encoder: Encoder) throws {
            try content.encode(to: encoder)
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(idType, forKey: .idType)
            try values.encode(idValue, forKey: .idValue)
        }
    }

    public struct Mappings: Decodable, Sendable {
        public struct Value: Decodable, Sendable { public let value: String }
        public let tmdbID: Int
        public let mediaType: MediaType
        public let mappings: [String: [Record<Value>]]
        public let total: Int
        enum CodingKeys: String, CodingKey { case tmdbID = "tmdb_id", mediaType = "media_type", mappings, total }
    }

    public struct Lookup: Decodable, Sendable {
        public let results: [Content]
        public let total: Int
        public var isUnambiguous: Bool { total == 1 && results.count == 1 }
    }

    public struct AnimeChunk: Codable, Hashable, Sendable {
        public let tmdbSeason: Int
        public let tmdbEpisodeStart: Int?
        public let tmdbEpisodeEnd: Int?
        public let chunkTmdbID: Int?

        public init(
            tmdbSeason: Int, tmdbEpisodeStart: Int? = nil,
            tmdbEpisodeEnd: Int? = nil, chunkTmdbID: Int? = nil
        ) throws {
            guard tmdbSeason >= 0,
                  tmdbEpisodeStart.map({ $0 > 0 }) ?? true, tmdbEpisodeEnd.map({ $0 > 0 }) ?? true,
                  chunkTmdbID.map({ $0 > 0 }) ?? true else { throw Failure.invalidInput }
            if let tmdbEpisodeStart, let tmdbEpisodeEnd, tmdbEpisodeEnd < tmdbEpisodeStart {
                throw Failure.invalidInput
            }
            self.tmdbSeason = tmdbSeason
            self.tmdbEpisodeStart = tmdbEpisodeStart
            self.tmdbEpisodeEnd = tmdbEpisodeEnd
            self.chunkTmdbID = chunkTmdbID
        }

        enum CodingKeys: String, CodingKey {
            case tmdbSeason = "tmdb_season", tmdbEpisodeStart = "tmdb_episode_start"
            case tmdbEpisodeEnd = "tmdb_episode_end", chunkTmdbID = "chunk_tmdb_id"
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                tmdbSeason: values.decode(Int.self, forKey: .tmdbSeason),
                tmdbEpisodeStart: values.decodeIfPresent(Int.self, forKey: .tmdbEpisodeStart),
                tmdbEpisodeEnd: values.decodeIfPresent(Int.self, forKey: .tmdbEpisodeEnd),
                chunkTmdbID: values.decodeIfPresent(Int.self, forKey: .chunkTmdbID)
            )
        }
    }

    public struct AnimeMapping: Encodable, Sendable {
        public let tmdbID: Int
        public let seasonNumber: Int
        public let seasonName: String?
        public let chunks: [AnimeChunk]

        public init(tmdbID: Int, seasonNumber: Int, seasonName: String? = nil, chunks: [AnimeChunk]) throws {
            guard tmdbID > 0, seasonNumber > 0, seasonName.map({ $0.count <= 100 }) ?? true,
                  !chunks.isEmpty else { throw Failure.invalidInput }
            self.tmdbID = tmdbID
            self.seasonNumber = seasonNumber
            self.seasonName = seasonName
            self.chunks = chunks
        }
        enum CodingKeys: String, CodingKey {
            case tmdbID = "tmdb_id", seasonNumber = "season_number", seasonName = "season_name", chunks
        }
    }

    public struct AnimeSeasons: Decodable, Equatable, Sendable {
        public struct Group: Decodable, Equatable, Identifiable, Sendable {
            public let id: String
            public let seasonNumber: Int
            public let seasonName: String?
            public let source: String
            public let contributor: String
            public let votes: Int
            public let recommended: Bool
            public let chunks: [Record<AnimeChunk>]
            enum CodingKeys: String, CodingKey {
                case id = "pmdb_id", seasonNumber = "season_number", seasonName = "season_name"
                case source, contributor, votes, recommended, chunks
            }
        }
        public let tmdbID: Int
        public let seasons: [Group]
        public let total: Int
        enum CodingKeys: String, CodingKey { case tmdbID = "tmdb_id", seasons, total }
    }

    public struct AnimeReplacement: Decodable, Sendable {
        public let success: Bool
        public let tmdbID: Int
        public let seasonNumber: Int
        public let seasonName: String?
        public let chunks: [Record<AnimeChunk>]
        enum CodingKeys: String, CodingKey {
            case success, tmdbID = "tmdb_id", seasonNumber = "season_number", seasonName = "season_name", chunks
        }
    }
}

public extension PublicMetaDBClient {
    func mappings(for content: PublicMetaDB.Content, idType: PublicMetaDB.ExternalIDType? = nil) async throws -> PublicMetaDB.Mappings {
        try await send(
            PublicMetaDB.Mappings.self, path: "/mappings",
            query: content.query + (idType.map { [.init(name: "id_type", value: $0.rawValue)] } ?? [])
        )
    }

    func lookup(
        idType: PublicMetaDB.ExternalIDType, idValue: String, mediaType: PublicMetaDB.MediaType? = nil
    ) async throws -> PublicMetaDB.Lookup {
        guard !idValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PublicMetaDB.Failure.invalidInput }
        return try await send(
            PublicMetaDB.Lookup.self, path: "/mappings/lookup",
            query: [.init(name: "id_type", value: idType.rawValue), .init(name: "id_value", value: idValue)]
                + (mediaType.map { [.init(name: "media_type", value: $0.rawValue)] } ?? [])
        )
    }

    func submitMapping(_ mapping: PublicMetaDB.Mapping) async throws -> PublicMetaDB.Record<PublicMetaDB.Mapping> {
        let result = try await create(PublicMetaDB.Record<PublicMetaDB.Mapping>.self, path: "/mappings", body: mapping)
        guard result.value == mapping else { throw PublicMetaDB.Failure.uncertainWrite }
        return result
    }

    func animeSeasons(tmdbID: Int) async throws -> PublicMetaDB.AnimeSeasons {
        guard tmdbID > 0 else { throw PublicMetaDB.Failure.invalidInput }
        return try await send(
            PublicMetaDB.AnimeSeasons.self, path: "/anime-seasons",
            query: [.init(name: "tmdb_id", value: String(tmdbID))]
        )
    }

    /// Replaces all of this contributor's chunks in the selected logical season.
    func replaceAnimeMapping(_ mapping: PublicMetaDB.AnimeMapping) async throws -> PublicMetaDB.AnimeReplacement {
        let result = try await send(
            PublicMetaDB.AnimeReplacement.self, method: .post, path: "/anime-seasons", body: Self.encode(mapping)
        )
        guard result.success, result.tmdbID == mapping.tmdbID, result.seasonNumber == mapping.seasonNumber,
              result.seasonName == mapping.seasonName,
              result.chunks.count == mapping.chunks.count,
              Set(result.chunks.map(\.id)).count == result.chunks.count,
              result.chunks.map(\.value) == mapping.chunks else { throw PublicMetaDB.Failure.uncertainWrite }
        return result
    }

    @discardableResult
    func deleteAnimeMapping(tmdbID: Int, seasonNumber: Int) async throws -> Int {
        guard tmdbID > 0, seasonNumber > 0 else { throw PublicMetaDB.Failure.invalidInput }
        let result = try await send(
            PublicMetaDB.Acknowledgement.self, method: .delete, path: "/anime-seasons",
            query: [.init(name: "tmdb_id", value: String(tmdbID)), .init(name: "season_number", value: String(seasonNumber))]
        )
        guard result.success else { throw PublicMetaDB.Failure.rejected }
        guard let deleted = result.deleted, deleted >= 0 else { throw PublicMetaDB.Failure.uncertainWrite }
        return deleted
    }
}
