import Foundation
import CoreSecureStore
#if canImport(Security)
import Security
#endif

/// Persists Simkl OAuth tokens. Follows the same pattern as TraktTokenStoring.
public protocol SimklTokenStoring: Sendable {
    var authorizationGeneration: UUID { get }
    func load() -> SimklTokens?
    func save(_ tokens: SimklTokens) throws
    func clear() throws
    func setNamespace(_ namespace: String?)
}

#if canImport(Security)
/// Keychain-backed token store for Simkl.

/// Keychain-backed token store for Simkl, on the shared synced box so this
/// sign-in reaches the account's other devices.
public final class KeychainSimklTokenStore: SimklTokenStoring, @unchecked Sendable {
    private let box: SyncedTokenBox<SimklTokens>
    private let lock = NSLock()
    private var generation = UUID()

    public var authorizationGeneration: UUID {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    public init(
        service: String = "com.plozz.app.tokens",
        account: String = "simkl.oauth",
        namespace: String? = nil
    ) {
        box = SyncedTokenBox(
            service: service,
            account: account,
            namespace: namespace
        )
    }

    public func setNamespace(_ namespace: String?) {
        lock.lock(); defer { lock.unlock() }
        box.setNamespace(namespace)
        generation = UUID()
    }
    public func load() -> SimklTokens? { box.load() }
    public func save(_ tokens: SimklTokens) throws {
        invalidateAuthorization()
        try box.save(tokens)
    }
    public func clear() throws {
        invalidateAuthorization()
        try box.clear()
    }

    private func invalidateAuthorization() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID()
    }
}

public enum SimklTokenStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}
#endif

/// In-memory token store for tests/previews.
public final class InMemorySimklTokenStore: SimklTokenStoring, @unchecked Sendable {
    private var storage: [String: SimklTokens] = [:]
    private var namespace: String?
    private let lock = NSLock()
    private var generation = UUID()

    public var authorizationGeneration: UUID {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    public init(tokens: SimklTokens? = nil) {
        if let tokens { storage[""] = tokens }
    }

    public func setNamespace(_ namespace: String?) {
        lock.lock(); defer { lock.unlock() }
        self.namespace = namespace
        generation = UUID()
    }

    public func load() -> SimklTokens? {
        lock.lock(); defer { lock.unlock() }
        return storage[namespace ?? ""]
    }

    public func save(_ tokens: SimklTokens) throws {
        lock.lock(); defer { lock.unlock() }
        storage[namespace ?? ""] = tokens
        generation = UUID()
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        storage[namespace ?? ""] = nil
        generation = UUID()
    }
}
