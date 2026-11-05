import Foundation

public enum LandscapeTitleLogo: String, Codable, CaseIterable, Sendable {
    case automatic, on, off

    public static let `default`: Self = .automatic

    public var title: LocalizedStringResource {
        switch self {
        case .automatic: "Auto"
        case .on: "On"
        case .off: "Off"
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
    public var source: HeroCollectionSelection
    public var cardStyle: CardStyle
    public var titleLogo: LandscapeTitleLogo

    public init(
        id: String = UUID().uuidString, name: String = "",
        source: HeroCollectionSelection, cardStyle: CardStyle = .poster,
        titleLogo: LandscapeTitleLogo = .default
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.cardStyle = cardStyle
        self.titleLogo = titleLogo
    }

    private enum CodingKeys: CodingKey { case id, name, source, cardStyle, titleLogo }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        source = try values.decode(HeroCollectionSelection.self, forKey: .source)
        cardStyle = try values.decode(CardStyle.self, forKey: .cardStyle)
        titleLogo = try values.decodeIfPresent(LandscapeTitleLogo.self, forKey: .titleLogo) ?? .default
    }

    public var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? source.title : trimmed
    }

    public var rowID: HomeRowID { .section(id) }

    public var collectionItem: MediaItem {
        MediaItem(id: source.collectionID, title: source.title, kind: .collection)
            .taggingSource(source.accountID)
            .taggingLibrary(source.libraryID)
    }
}
