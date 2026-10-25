import CoreModels
import Foundation

public struct PublicMetaDBWatchlistSelection: Codable, Equatable, Sendable {
    public let id: UUID
    public let connectionID: UUID
    public let listID: String
    public let listName: String
    public let isPublic: Bool

    init(list: PublicMetaDB.List, connectionID: UUID) {
        id = UUID()
        self.connectionID = connectionID
        listID = list.id
        listName = list.name
        isPublic = list.isPublic
    }
}

/// Consent is local to this device and profile; synchronized credentials alone grant no writes.
struct PublicMetaDBWatchlistStore {
    let defaults: UserDefaults
    let namespace: String?
    private var key: String { SettingsKey.scoped("com.plozz.publicmetadb.watchlist", namespace: namespace) }

    func load() throws -> PublicMetaDBWatchlistSelection? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(PublicMetaDBWatchlistSelection.self, from: data)
    }

    func save(_ value: PublicMetaDBWatchlistSelection) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}
