import Foundation

/// A server's ordered Home sections, independent of Plozz's presentation.
public struct ServerHomeLayout: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case server
        case webPreferences
        case promotedHubs
    }

    public var sections: [ServerHomeSection]
    public var source: Source
    public var omitsReading: Bool
    public var omitsMusic: Bool

    public init(
        sections: [ServerHomeSection], source: Source,
        omitsReading: Bool = false, omitsMusic: Bool = false
    ) {
        self.sections = sections
        self.source = source
        self.omitsReading = omitsReading
        self.omitsMusic = omitsMusic
    }
}

public struct ServerHomeSection: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case libraries
        case continueWatching
        case nextUp
        case recentlyAdded
        case liveTV
        case recordings
        case recommendations

        public var title: LocalizedStringResource {
            switch self {
            case .libraries: "Libraries"
            case .continueWatching: "Continue Watching"
            case .nextUp: "Next Up"
            case .recentlyAdded: "Recently Added"
            case .liveTV: "Live TV"
            case .recordings: "Recordings"
            case .recommendations: "Recommended"
            }
        }
    }

    /// Provider-local section identity; never qualified before a provider request.
    public var id: String
    public var kind: Kind
    public var title: String? // l10n:content — server-authored Home section heading
    public var libraryID: String?
    public var includesNextUp: Bool
    /// Optional provider-issued shelf locator, validated and stripped of credentials by the provider.
    public var contentKey: String?

    public var isAccountWideHistory: Bool {
        libraryID == nil && (kind == .continueWatching || kind == .nextUp)
    }

    public init(
        id: String, kind: Kind, title: String? = nil, libraryID: String? = nil,
        includesNextUp: Bool = false, contentKey: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.libraryID = libraryID
        self.includesNextUp = includesNextUp
        self.contentKey = contentKey
    }
}

/// Items and their continuation come from the same provider response, not layout discovery.
public struct ServerHomeRowContent: Sendable {
    public var items: [MediaItem]
    public var browseID: String?

    public init(items: [MediaItem], browseID: String? = nil) {
        self.items = items
        self.browseID = browseID
    }
}

/// A saved custom row retains its source and request, even when the server's
/// automatic layout changes or that source is temporarily unavailable.
public struct HomeServerRowDefinition: Codable, Hashable, Identifiable, Sendable {
    public var accountID: String
    public var serverName: String
    public var providerKind: ProviderKind
    public var section: ServerHomeSection

    public var id: HomeRowID {
        switch section.kind {
        case .libraries: .libraries
        case .continueWatching: .global(.continueWatching)
        case .liveTV: .liveTV
        default: .server(accountID: accountID, section: section.id)
        }
    }

    public init(
        accountID: String, serverName: String, providerKind: ProviderKind,
        section: ServerHomeSection
    ) {
        self.accountID = accountID
        self.serverName = serverName
        self.providerKind = providerKind
        self.section = section
    }

}

public struct HomeResolvedRowDefaults: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case server
        case combined
        case providerFallback
    }

    public var mode: Mode
    public var order: [HomeRowID]
    public var serverRows: [HomeServerRowDefinition]
    public var omitsMusic: Bool
    public var omitsReading: Bool
    public var source: ServerHomeLayout.Source?
    /// Sources without a readable native arrangement retain their provider rows.
    public var fallbackAccountIDs: Set<String>

    public init(
        mode: Mode, order: [HomeRowID] = [], serverRows: [HomeServerRowDefinition] = [],
        omitsMusic: Bool = false, omitsReading: Bool = false,
        source: ServerHomeLayout.Source? = nil, fallbackAccountIDs: Set<String> = []
    ) {
        self.mode = mode
        self.order = order
        self.serverRows = serverRows
        self.omitsMusic = omitsMusic
        self.omitsReading = omitsReading
        self.source = source
        self.fallbackAccountIDs = fallbackAccountIDs
    }
}

public struct CachedHomeRowDefaults: Codable, Equatable, Sendable {
    public var scope: [String]
    public var defaults: HomeResolvedRowDefaults

    public init(scope: [String], defaults: HomeResolvedRowDefaults) {
        self.scope = scope
        self.defaults = defaults
    }
}
