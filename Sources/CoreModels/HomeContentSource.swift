import Foundation

/// A feed reference, not a copy of its contents. Server feeds retain the viewer
/// that selected them; shared feeds follow the currently active profile.
public struct HomeContentSource: Codable, Hashable, Sendable, Identifiable {
    public enum Feed: Codable, Hashable, Sendable {
        case collection(String)
        case playlist(String)
        case library(MediaItemKind)
        case recommendation(sectionID: String, kind: MediaItemKind)
        case server(ServerHomeSection)
        case home(HomeGlobalRow)
    }

    public struct ID: Hashable, Sendable {
        let accountID: String?
        let serverUserID: String?
        let libraryID: String?
        let key: String
    }

    public let feed: Feed
    public let accountID: String?
    public let serverUserID: String?
    public let libraryID: String?
    public let title: String // l10n:content — source title supplied by the server

    /// Full inventories can amortize round trips; Home feeds retain their endpoint limits.
    var inventoryPageLimit: Int {
        switch feed {
        case .library, .collection, .playlist: return 200
        case .recommendation, .server, .home: return PageRequest.defaultLimit
        }
    }

    public init(
        feed: Feed, accountID: String? = nil, serverUserID: String? = nil,
        libraryID: String? = nil, title: String
    ) {
        self.feed = feed
        self.accountID = accountID
        self.serverUserID = serverUserID
        self.libraryID = libraryID
        self.title = title
    }

    public init(collection: HeroCollectionSelection) {
        self.init(
            feed: .collection(collection.collectionID), accountID: collection.accountID,
            serverUserID: collection.serverUserID, libraryID: collection.libraryID, title: collection.title
        )
    }

    public init(home: HomeGlobalRow) {
        self.init(feed: .home(home), title: home.rawValue)
    }

    public var id: ID {
        let key: String
        switch feed {
        case let .collection(value): key = "collection:\(value)"
        case let .playlist(value): key = "playlist:\(value)"
        case let .library(kind): key = "library:\(kind.rawValue)"
        case let .recommendation(sectionID, _): key = "recommendation:\(sectionID)"
        case let .server(section): key = "server:\(section.id)"
        case let .home(kind): key = "home:\(kind.rawValue)"
        }
        return ID(accountID: accountID, serverUserID: serverUserID, libraryID: libraryID, key: key)
    }

    public var localizedTitle: LocalizedStringResource? {
        if case let .home(kind) = feed { return kind.title }
        if case let .recommendation(id, _) = feed,
           id == LibraryHomeRowKind.recentlyAdded.rawValue || id == LibraryHomeRowKind.nextUp.rawValue {
            return LibraryHomeRowKind(rawValue: id)?.displayName
        }
        if case let .server(section) = feed, section.title == nil { return section.kind.title }
        return nil
    }

    public var libraryKey: String? {
        guard let accountID, let libraryID else { return nil }
        return "\(accountID):\(libraryID)"
    }

    public var collection: HeroCollectionSelection? {
        guard case let .collection(id) = feed, let accountID else { return nil }
        return .init(
            accountID: accountID, libraryID: libraryID, collectionID: id,
            title: title, serverUserID: serverUserID
        )
    }

    public var home: HomeGlobalRow? {
        if case let .home(kind) = feed { return kind }
        return nil
    }

    public var isAccountWideHistory: Bool {
        if home == .continueWatching { return true }
        if case let .server(section) = feed { return section.isAccountWideHistory }
        return false
    }

    public var isValid: Bool {
        if case .home = feed { return accountID == nil && serverUserID == nil && libraryID == nil }
        guard accountID?.isEmpty == false, serverUserID?.isEmpty == false,
              libraryID?.isEmpty != true, !title.isEmpty else { return false }
        switch feed {
        case let .collection(id), let .playlist(id): return !id.isEmpty
        case .library: return libraryID != nil
        case let .recommendation(id, _): return libraryID != nil && !id.isEmpty
        case let .server(section): return !section.id.isEmpty && section.libraryID == libraryID
        case .home: return false
        }
    }

    public func matches(_ account: ResolvedAccount) -> Bool {
        accountID == account.account.id
            && serverUserID == (account.plexHomeUserID ?? account.provider.session.userID)
    }

    public func isAvailable(accounts: [ResolvedAccount], visibility: HomeLibraryVisibility) -> Bool {
        isValid && libraryKey.map(visibility.isEnabled) != false
            && (home != nil ? !accounts.isEmpty : accounts.contains(where: matches))
    }

    public static func normalized(_ sources: [Self]) -> [Self] {
        var seen = Set<ID>()
        return sources.filter { seen.insert($0.id).inserted }
    }
}
