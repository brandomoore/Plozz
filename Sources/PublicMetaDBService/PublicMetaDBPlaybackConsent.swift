import CoreModels
import Foundation

public struct PublicMetaDBPlaybackConsent: Codable, Equatable, Sendable {
    public let id: UUID
    public let connectionID: UUID
    public var lastFailure: TrackerPlaybackDeliveryError?
    public var deliveryScope: String { "publicmetadb#playback#\(connectionID.uuidString)#\(id.uuidString)" }

    init(connectionID: UUID) {
        id = UUID()
        self.connectionID = connectionID
    }
}

struct PublicMetaDBPlaybackConsentStore {
    let defaults: UserDefaults
    let namespace: String?
    private var key: String { SettingsKey.scoped("com.plozz.publicmetadb.playback", namespace: namespace) }

    func load() throws -> PublicMetaDBPlaybackConsent? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try JSONDecoder().decode(PublicMetaDBPlaybackConsent.self, from: data)
    }

    func save(_ consent: PublicMetaDBPlaybackConsent) throws {
        defaults.set(try JSONEncoder().encode(consent), forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}
