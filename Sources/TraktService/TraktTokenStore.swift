import Foundation
import CoreSecureStore
#if canImport(Security)
import Security
#endif

/// Persists the Trakt OAuth tokens. Abstracted behind a protocol so the service
/// can be unit-tested with an in-memory double — real Keychain access isn't
/// available in unit tests.
public protocol TraktTokenStoring: Sendable {
    func load() -> TraktTokens?
    func save(_ tokens: TraktTokens) throws
    func clear() throws
    /// Switches which profile's tokens this store reads and writes. Pass `nil`
    /// for the default/primary profile, which keeps the legacy un-namespaced
    /// storage location (backward compatible with already-connected devices);
    /// any other namespace scopes tokens to that household profile.
    func setNamespace(_ namespace: String?)
    /// A fixed namespace view sharing the same backing storage.
    func snapshot() -> any TraktTokenStoring
    /// Equal for independent stores addressing the same credential.
    var coordinationID: String { get }
}

#if canImport(Security)
/// Keychain-backed token store for Trakt, on the shared synced box so this
/// sign-in reaches the profile's other devices through iCloud Keychain and the
/// app's encrypted CloudKit transport. The default namespace retains `trakt.oauth`;
/// other profiles use `trakt.oauth.<namespace>`.
public final class KeychainTraktTokenStore: TraktTokenStoring, @unchecked Sendable {
    private let box: SyncedTokenBox<TraktTokens>
    private let service: String
    private let account: String
    private var namespace: String?
    private let lock = NSLock()

    public init(
        service: String = "com.plozz.app.tokens",
        account: String = "trakt.oauth",
        namespace: String? = nil
    ) {
        self.service = service
        self.account = account
        self.namespace = namespace
        box = SyncedTokenBox(
            service: service,
            account: account,
            namespace: namespace
        )
    }

    public func setNamespace(_ namespace: String?) {
        lock.lock()
        defer { lock.unlock() }
        self.namespace = namespace
        box.setNamespace(namespace)
    }
    public func snapshot() -> any TraktTokenStoring {
        lock.lock()
        defer { lock.unlock() }
        return KeychainTraktTokenStore(service: service, account: account, namespace: namespace)
    }
    public var coordinationID: String {
        lock.lock()
        defer { lock.unlock() }
        let suffix = namespace.flatMap { $0.isEmpty ? nil : ".\($0)" } ?? ""
        return "\(service)\u{0}\(account)\(suffix)"
    }
    public func load() -> TraktTokens? { box.load() }
    public func save(_ tokens: TraktTokens) throws { try box.save(tokens) }
    public func clear() throws { try box.clear() }
}

public enum TraktTokenStoreError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}
#endif

/// In-memory token store for tests, previews, and non-Apple hosts. **Not** secure.
/// Namespace-keyed so each profile's tokens stay isolated (the default profile
/// uses the empty-string key).
public final class InMemoryTraktTokenStore: TraktTokenStoring, @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        let id = UUID().uuidString
        let lock = NSLock()
        var tokens: [String: TraktTokens] = [:]
    }
    private let storage: Storage
    private var namespace: String?
    private let lock = NSLock()

    public init(tokens: TraktTokens? = nil) {
        storage = Storage()
        if let tokens { storage.tokens[""] = tokens }
    }

    private init(storage: Storage, namespace: String?) {
        self.storage = storage
        self.namespace = namespace
    }

    public func snapshot() -> any TraktTokenStoring {
        lock.lock()
        defer { lock.unlock() }
        return InMemoryTraktTokenStore(storage: storage, namespace: namespace)
    }

    public var coordinationID: String {
        lock.lock()
        defer { lock.unlock() }
        return "\(storage.id)\u{0}\(namespace ?? "")"
    }

    public func setNamespace(_ namespace: String?) {
        lock.lock(); defer { lock.unlock() }
        self.namespace = namespace
    }

    public func load() -> TraktTokens? {
        lock.lock(); defer { lock.unlock() }
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.tokens[namespace ?? ""]
    }

    public func save(_ tokens: TraktTokens) throws {
        lock.lock(); defer { lock.unlock() }
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.tokens[namespace ?? ""] = tokens
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.tokens[namespace ?? ""] = nil
    }
}
