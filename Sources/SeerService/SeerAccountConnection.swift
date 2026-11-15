import CoreModels
import Foundation

public struct SeerSessionCredential: Codable, Hashable, Sendable {
    public var cookie: String
    public var csrfToken: String?
    public var userID: Int
    public var name: String
    public var permissions: Int
    public var expiresAt: Date
}

public struct SeerAccountConnection: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var baseURL: URL
    public var name: String
    public var credential: Credential
    public var requiresRelink = false

    public enum Credential: Codable, Hashable, Sendable {
        case session(SeerSessionCredential)
        case apiKey(key: String, userID: Int?, userName: String?)
    }

    public var accountName: String {
        switch credential {
        case let .session(session): session.name
        case let .apiKey(_, _, name): name ?? "Admin"
        }
    }

    public var label: String { "\(name.isEmpty ? baseURL.absoluteString : name) · \(accountName)" }

    var config: SeerConfig {
        switch credential {
        case let .session(session): SeerConfig(baseURL: baseURL, session: session)
        case let .apiKey(key, userID, _): SeerConfig(baseURL: baseURL, apiKey: key, userId: userID)
        }
    }
}

public struct SeerProfileConnections: Codable, Hashable, Sendable {
    public var connections: [SeerAccountConnection] = []
    public var defaultID: UUID?
    public var lastSuccessfulID: UUID?
    public var rememberLastUsed = false
    public var askEachTime = false
    // A deliberate empty list must not re-adopt a legacy household key.
    public var configured = false

    public init() {}

    public var selected: SeerAccountConnection? {
        let id = rememberLastUsed ? lastSuccessfulID ?? defaultID : defaultID
        return connections.first { $0.id == id }
    }

    public var offersChoice: Bool { askEachTime || connections.count > 1 }

    mutating func repairSelection() {
        let ids = Set(connections.map(\.id))
        if defaultID.map(ids.contains) != true { defaultID = connections.first?.id }
        if lastSuccessfulID.map(ids.contains) != true { lastSuccessfulID = nil }
    }
}

public protocol SeerAccountConnectionStoring: Sendable {
    func load(profileID: String) throws -> SeerProfileConnections
    func save(_ connections: SeerProfileConnections, profileID: String) throws
    func migrateLegacy(_ connection: SeerConnection?, profiles: [Profile]) throws
}

public final class SeerAccountConnectionStore: SeerAccountConnectionStoring, @unchecked Sendable {
    private let secureStore: SecureStoring
    private let lock = NSRecursiveLock()
    private let key = "seer.profile.connections.v1"
    private struct Ledger: Codable {
        var profiles: [String: SeerProfileConnections] = [:]
        var migrated = false
    }

    public init(secureStore: SecureStoring) { self.secureStore = secureStore }

    public func load(profileID: String) throws -> SeerProfileConnections {
        lock.lock(); defer { lock.unlock() }
        return try read().profiles[profileID] ?? .init()
    }

    public func save(_ connections: SeerProfileConnections, profileID: String) throws {
        lock.lock(); defer { lock.unlock() }
        var ledger = try read()
        ledger.profiles[profileID] = connections
        try write(ledger)
    }

    public func migrateLegacy(_ connection: SeerConnection?, profiles: [Profile]) throws {
        lock.lock(); defer { lock.unlock() }
        var ledger = try read()
        guard !ledger.migrated else { return }
        if let connection {
            for profile in profiles where ledger.profiles[profile.id] == nil {
                ledger.profiles[profile.id] = legacyConnections(connection, profile: profile)
            }
        }
        ledger.migrated = true
        try write(ledger)
    }

    public func exportAPIKeys() throws -> [String: SeerProfileConnections] {
        lock.lock(); defer { lock.unlock() }
        return try read().profiles.compactMapValues { state in
            var result = state
            result.connections = state.connections.filter {
                if case .apiKey = $0.credential { return true }
                return false
            }
            guard !result.connections.isEmpty else { return nil }
            result.repairSelection()
            return result
        }
    }

    @discardableResult
    public func importAPIKeysIfAbsent(_ values: [String: SeerProfileConnections], allowedProfiles: Set<String>) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var ledger = try read()
        var changed: Set<String> = []
        for (profileID, state) in values where allowedProfiles.contains(profileID) {
            guard ledger.profiles[profileID]?.configured != true else { continue }
            guard !state.connections.isEmpty,
                  Set(state.connections.map(\.id)).count == state.connections.count,
                  state.connections.allSatisfy({ connection in
                      guard SeerServerIdentity(baseURL: connection.baseURL) != nil,
                            case let .apiKey(key, userID, _) = connection.credential else { return false }
                      return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && userID.map { $0 > 0 } != false
                  }) else { throw AppError.invalidResponse }
            var imported = state
            imported.repairSelection()
            imported.configured = true
            ledger.profiles[profileID] = imported
            changed.insert(profileID)
        }
        if !changed.isEmpty { try write(ledger) }
        return changed
    }

    public func importLegacyIfAbsent(_ connection: SeerConnection, profiles: [Profile]) throws {
        try importAPIKeysIfAbsent(
            Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, legacyConnections(connection, profile: $0)) }),
            allowedProfiles: Set(profiles.map(\.id))
        )
    }

    private func read() throws -> Ledger {
        guard let value = try secureStore.readString(for: key) else { return .init() }
        return try JSONDecoder().decode(Ledger.self, from: Data(value.utf8))
    }
    private func write(_ ledger: Ledger) throws {
        let data = try JSONEncoder().encode(ledger)
        guard let value = String(data: data, encoding: .utf8) else { throw SeerConnectionStoreError.encodingFailed }
        try secureStore.setString(value, for: key)
    }
}

public final class InMemorySeerAccountConnectionStore: SeerAccountConnectionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SeerProfileConnections] = [:]
    private var migrated = false
    public init() {}
    public func load(profileID: String) throws -> SeerProfileConnections {
        lock.lock(); defer { lock.unlock() }
        return values[profileID] ?? .init()
    }
    public func save(_ connections: SeerProfileConnections, profileID: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[profileID] = connections
    }
    public func migrateLegacy(_ connection: SeerConnection?, profiles: [Profile]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !migrated else { return }
        if let connection {
            for profile in profiles where values[profile.id] == nil {
                values[profile.id] = legacyConnections(connection, profile: profile)
            }
        }
        migrated = true
    }
}

private func legacyConnections(_ connection: SeerConnection, profile: Profile) -> SeerProfileConnections {
    var state = SeerProfileConnections()
    // Unverified mappings stay unusable rather than becoming administrator requests.
    let identity = profile.seerrRequestIdentity
    let endpoint = SeerServerIdentity(baseURL: connection.baseURL)
    var saved = SeerAccountConnection(
        id: UUID(), baseURL: connection.baseURL, name: "",
        credential: .apiKey(key: connection.apiKey, userID: identity.userID, userName: profile.seerrUserName)
    )
    saved.requiresRelink = identity.requiresRelink(to: endpoint)
    state.connections = [saved]
    state.defaultID = saved.id
    state.configured = true
    return state
}
