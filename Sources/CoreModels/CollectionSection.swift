import Foundation

public enum LandscapeTitleLogo: String, Codable, CaseIterable, Sendable {
    case on, off

    public static let `default`: Self = .off

    public var title: LocalizedStringResource {
        switch self {
        case .on: "On"
        case .off: "Off"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "automatic" {
            self = .off
        } else if let mode = Self(rawValue: value) {
            self = mode
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown landscape logo mode")
        }
    }
}

/// Content and presentation are independent of the page's order and visibility.
public struct CollectionSection: Codable, Equatable, Sendable, Identifiable {
    public enum CardStyle: String, Codable, CaseIterable, Sendable {
        case poster, landscape, featured

        public var title: LocalizedStringResource {
            switch self {
            case .poster: "Posters"
            case .landscape: "Landscape"
            case .featured: "Featured"
            }
        }
    }

    public let id: String
    public var name: String // l10n:content — user-authored section name
    public var sources: [HomeContentSource]
    public var cardStyle: CardStyle
    public var titleLogo: LandscapeTitleLogo
    public var query: HomeContentQuery

    public init(
        id: String = UUID().uuidString, name: String = "",
        source: HeroCollectionSelection, cardStyle: CardStyle = .poster,
        titleLogo: LandscapeTitleLogo = .default, query: HomeContentQuery = .init()
    ) {
        self.id = id
        self.name = name
        self.sources = [.init(collection: source)]
        self.cardStyle = cardStyle
        self.titleLogo = titleLogo
        self.query = query
    }

    public init(
        id: String = UUID().uuidString, name: String = "",
        sources: [HomeContentSource], cardStyle: CardStyle = .poster,
        titleLogo: LandscapeTitleLogo = .default, query: HomeContentQuery = .init()
    ) {
        self.id = id
        self.name = name
        self.sources = HomeContentSource.normalized(sources)
        self.cardStyle = cardStyle
        self.titleLogo = titleLogo
        self.query = query
    }

    private enum CodingKeys: CodingKey { case id, name, source, sources, cardStyle, titleLogo, query }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        if let decoded = try values.decodeIfPresent([HomeContentSource].self, forKey: .sources) {
            sources = HomeContentSource.normalized(decoded)
        } else {
            sources = [.init(collection: try values.decode(HeroCollectionSelection.self, forKey: .source))]
        }
        cardStyle = try values.decode(CardStyle.self, forKey: .cardStyle)
        titleLogo = try values.decodeIfPresent(LandscapeTitleLogo.self, forKey: .titleLogo) ?? .default
        query = try values.decodeIfPresent(HomeContentQuery.self, forKey: .query) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(sources, forKey: .sources)
        try values.encode(cardStyle, forKey: .cardStyle)
        try values.encode(titleLogo, forKey: .titleLogo)
        try values.encode(query, forKey: .query)
    }

    public var contentTitle: String { sources.map(\.title).joined(separator: ", ") }
    public var localizedContentTitle: LocalizedStringResource? {
        guard sources.contains(where: { $0.localizedTitle != nil }), let first = sources.first else { return nil }
        return sources.dropFirst().reduce(first.localizedTitle ?? LocalizedStringResource("\(first.title)")) { result, source in
            let next = source.localizedTitle ?? LocalizedStringResource("\(source.title)")
            return LocalizedStringResource(
                "\(result), \(next)",
                comment: "Default custom Home row title joining two content-source names. Each name may itself contain a list."
            )
        }
    }

    public var localizedTitle: LocalizedStringResource? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localizedContentTitle : nil
    }
    public var collectionSources: [HeroCollectionSelection] { sources.compactMap(\.collection) }
    public var usesWatchlistDates: Bool { sources.count == 1 && sources.first?.home == .watchlist }

    public func availableSources(
        accounts: [ResolvedAccount], visibility: HomeLibraryVisibility
    ) -> [HomeContentSource] {
        sources.filter { $0.isAvailable(accounts: accounts, visibility: visibility) }
    }

    public var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? contentTitle : trimmed
    }

    public var rowID: HomeRowID { .section(id) }

    public var collectionItem: MediaItem? {
        guard sources.count == 1, let source = sources.first?.collection else { return nil }
        return MediaItem(id: source.collectionID, title: source.title, kind: .collection)
            .taggingSource(source.accountID)
            .taggingLibrary(source.libraryID)
    }
}
