import Foundation

extension PublicMetaDB {
    public enum ListKind: String, Codable, CaseIterable, Sendable { case watchlist, custom }

    public struct List: Codable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let description: String?
        public let slug: String?
        public let isPublic: Bool
        public let type: ListKind?
        public let contributor: String?
        enum CodingKeys: String, CodingKey {
            case id, name, description, slug, isPublic = "is_public", type, contributor
        }
    }

    public struct ListPage: Decodable, Sendable {
        public let list: List
        public let page: Page<Record<Content>>
        enum CodingKeys: String, CodingKey { case list }
        public init(from decoder: Decoder) throws {
            list = try decoder.container(keyedBy: CodingKeys.self).decode(List.self, forKey: .list)
            page = try Page<Record<Content>>(from: decoder)
        }
    }

    public struct ListAddress: Equatable, Sendable {
        public let username: String
        public let slug: String

        public init(url: URL) throws {
            guard url.scheme == "https", url.host?.lowercased() == "publicmetadb.com",
                  url.port == nil || url.port == 443, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { throw Failure.invalidInput }
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count == 4, parts[0] == "lists", parts[1] == "u" else { throw Failure.invalidInput }
            username = try PublicMetaDBClient.component(String(parts[2]))
            slug = try PublicMetaDBClient.component(String(parts[3]))
        }
    }

    /// Recipe keys are open-ended upstream; retain unknown filters without applying them locally.
    public enum RecipeValue: Decodable, Equatable, Sendable {
        case null, bool(Bool), number(Decimal), string(String)
        case array([RecipeValue]), object([String: RecipeValue])

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { self = .null }
            else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
            else if let number = try? value.decode(Decimal.self) { self = .number(number) }
            else if let string = try? value.decode(String.self) { self = .string(string) }
            else if let array = try? value.decode([RecipeValue].self) { self = .array(array) }
            else { self = .object(try value.decode([String: RecipeValue].self)) }
        }
    }

    public struct Pick: Decodable, Identifiable, Sendable {
        public let id: String
        public let slug: String
        public let name: String
        public let description: String?
        public let seedType: String
        public let seedParameters: [String: RecipeValue]?
        public let filters: [String: RecipeValue]?
        public let weights: [String: RecipeValue]?
        public let excludeWatched: Bool
        public let excludeWatchlist: Bool
        public let created: String?
        public let updated: String?
        enum CodingKeys: String, CodingKey {
            case id, slug, name, description, seedType = "seed_type", excludeWatched = "exclude_watched"
            case excludeWatchlist = "exclude_watchlist", created, updated
            case seedParameters = "seed_params", filters, weights
        }
    }

    public struct PickItem: Decodable, Identifiable, Sendable {
        public var id: Content { content }
        public let content: Content
        public let title: String
        public let posterPath: String?
        public let backdropPath: String?
        public let year: String?
        public let overview: String?
        public let genreIDs: [Int]?
        public let voteAverage: Double?
        public let voteCount: Int?
        public let popularity: Double?
        public let originalLanguage: String?
        public let score: Double?
        public let reasons: [String]
        enum CodingKeys: String, CodingKey {
            case title, posterPath = "poster_path", backdropPath = "backdrop_path", year, overview, score, reasons
            case genreIDs = "genre_ids", voteAverage = "vote_average", voteCount = "vote_count"
            case popularity, originalLanguage = "original_language"
        }
        public init(from decoder: Decoder) throws {
            content = try Content(from: decoder)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = try values.decode(String.self, forKey: .title)
            posterPath = try values.decodeIfPresent(String.self, forKey: .posterPath)
            backdropPath = try values.decodeIfPresent(String.self, forKey: .backdropPath)
            year = try values.decodeIfPresent(String.self, forKey: .year)
            overview = try values.decodeIfPresent(String.self, forKey: .overview)
            genreIDs = try values.decodeIfPresent([Int].self, forKey: .genreIDs)
            voteAverage = try values.decodeIfPresent(Double.self, forKey: .voteAverage)
            voteCount = try values.decodeIfPresent(Int.self, forKey: .voteCount)
            popularity = try values.decodeIfPresent(Double.self, forKey: .popularity)
            originalLanguage = try values.decodeIfPresent(String.self, forKey: .originalLanguage)
            score = try values.decodeIfPresent(Double.self, forKey: .score)
            reasons = try values.decode([String].self, forKey: .reasons)
        }
    }

    public struct PickPage: Decodable, Sendable {
        public let catalog: Pick
        public let page: Page<PickItem>
        public let cached: Bool
        public let tasteVersion: Int?
        enum CodingKeys: String, CodingKey { case catalog, cached, tasteVersion }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            catalog = try values.decode(Pick.self, forKey: .catalog)
            page = try Page<PickItem>(from: decoder)
            cached = try values.decode(Bool.self, forKey: .cached)
            tasteVersion = try values.decodeIfPresent(Int.self, forKey: .tasteVersion)
        }
    }
}

public extension PublicMetaDBClient {
    func lists(page: Int = 1, perPage: Int = 100) async throws -> PublicMetaDB.Page<PublicMetaDB.List> {
        try await self.page(PublicMetaDB.List.self, path: "/lists", page: page, perPage: perPage)
    }

    func createList(
        name: String, description: String? = nil, isPublic: Bool, type: PublicMetaDB.ListKind
    ) async throws -> PublicMetaDB.List {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PublicMetaDB.Failure.invalidInput }
        let result = try await create(
            PublicMetaDB.List.self, path: "/lists",
            body: NewList(name: name, description: description, isPublic: isPublic, type: type)
        )
        guard !result.id.isEmpty, result.name == name, result.description == description,
              result.isPublic == isPublic, result.type == type else { throw PublicMetaDB.Failure.uncertainWrite }
        return result
    }

    func listItems(id: String, page: Int = 1, perPage: Int = 100) async throws -> PublicMetaDB.ListPage {
        let result = try await listPage(path: "/lists/\(Self.component(id))/items", page: page, perPage: perPage)
        guard result.list.id == id else { throw PublicMetaDB.Failure.incompleteResponse }
        return result
    }

    func listItems(
        address: PublicMetaDB.ListAddress, page: Int = 1, perPage: Int = 100
    ) async throws -> PublicMetaDB.ListPage {
        try await listPage(
            path: "/lists/u/\(Self.component(address.username))/\(Self.component(address.slug))/items",
            page: page, perPage: perPage
        )
    }

    func addListItem(_ content: PublicMetaDB.Content, listID: String) async throws -> PublicMetaDB.Record<PublicMetaDB.Content> {
        guard content.season == nil, content.episode == nil else { throw PublicMetaDB.Failure.invalidInput }
        let result = try await create(
            PublicMetaDB.Record<PublicMetaDB.Content>.self,
            path: "/lists/\(Self.component(listID))/items", body: content
        )
        guard result.value == content else { throw PublicMetaDB.Failure.uncertainWrite }
        return result
    }

    func removeListItem(listID: String, itemID: String) async throws {
        try await acknowledge(path: "/lists/\(Self.component(listID))/items/\(Self.component(itemID))")
    }

    func deleteList(id: String) async throws {
        try await acknowledge(path: "/lists/\(Self.component(id))")
    }

    func picks() async throws -> PublicMetaDB.Collection<PublicMetaDB.Pick> {
        try await send(PublicMetaDB.Collection<PublicMetaDB.Pick>.self, path: "/catalogs")
    }

    func pickItems(id: String, page: Int = 1) async throws -> PublicMetaDB.PickPage {
        guard (1...5).contains(page) else { throw PublicMetaDB.Failure.invalidInput }
        let result = try await send(
            PublicMetaDB.PickPage.self, path: "/catalogs/\(Self.component(id))/items",
            query: [.init(name: "page", value: String(page))]
        )
        try result.page.validate(requestedPage: page, maximumPageSize: 20)
        guard result.catalog.id == id, result.page.totalPages <= 5 else { throw PublicMetaDB.Failure.incompleteResponse }
        return result
    }
}

private extension PublicMetaDBClient {
    func listPage(path: String, page: Int, perPage: Int) async throws -> PublicMetaDB.ListPage {
        guard page > 0, (1...500).contains(perPage) else { throw PublicMetaDB.Failure.invalidInput }
        let result = try await send(
            PublicMetaDB.ListPage.self, path: path,
            query: [.init(name: "page", value: String(page)), .init(name: "perPage", value: String(perPage))]
        )
        try result.page.validate(requestedPage: page, maximumPageSize: 500)
        return result
    }
}

private struct NewList: Encodable {
    let name: String
    let description: String?
    let isPublic: Bool
    let type: PublicMetaDB.ListKind
    enum CodingKeys: String, CodingKey { case name, description, isPublic = "is_public", type }
}
