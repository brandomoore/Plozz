import Foundation
import CoreModels
#if canImport(Security)
import Security
#endif

#if canImport(Security)
/// Keychain storage for one tracker's OAuth tokens, shared by every tracker.
///
/// Each tracker used to carry its own byte-identical copy of this — same query
/// shape, same JSON coding, same namespacing — and every copy wrote a
/// `…ThisDeviceOnly` item with no synchronizable attribute. That is the
/// strictest possible setting: it not only skips iCloud Keychain, it forbids it.
/// So signing into a tracker on one device left every other device signed out,
/// while the servers those devices talk to synced fine.
///
/// On new installations, pending or declined iCloud consent selects device-only
/// storage. Existing installations retain their historical sign-in behavior.
/// Tokens are still never written outside the Keychain or logged.
public final class SyncedTokenBox<Token: Codable & Sendable>: @unchecked Sendable {
    private let service: String
    private let baseAccount: String
    private let lock = NSLock()
    private var namespace: String?
    private let synced: any SecureStoring
    private let local: any SecureStoring
    private let allowsSync: @Sendable () -> Bool
    private let synchronizableAttribute: @Sendable (String) -> String

    public convenience init(
        service: String = "com.plozz.app.tokens",
        account: String,
        namespace: String? = nil
    ) {
        self.init(
            service: service, account: account, namespace: namespace,
            synced: KeychainStore(service: service, userIndependent: false,
                                  fallbackToPerUser: false, synchronizable: true),
            local: KeychainStore(service: service, userIndependent: false,
                                 fallbackToPerUser: false),
            allowsSync: { SyncSetupFeatureFlag().allowsAutomaticSignInSync },
            synchronizableAttribute: { Self.storedSynchronizable(service: service, account: $0) }
        )
    }

    init(
        service: String, account: String, namespace: String? = nil,
        synced: any SecureStoring, local: any SecureStoring,
        allowsSync: @escaping @Sendable () -> Bool,
        synchronizableAttribute: @escaping @Sendable (String) -> String = { _ in "injected-store" }
    ) {
        self.service = service
        self.baseAccount = account
        self.namespace = namespace
        self.synced = synced
        self.local = local
        self.allowsSync = allowsSync
        self.synchronizableAttribute = synchronizableAttribute
        registerForSync()
    }

    public func setNamespace(_ namespace: String?) {
        lock.lock()
        self.namespace = namespace
        lock.unlock()
        registerForSync()
    }

    private func registerForSync() {
        SyncedTokenRegistry.shared.register(
            service: service,
            account: currentAccount()
        )
    }

    private func currentAccount() -> String {
        lock.lock(); defer { lock.unlock() }
        if let namespace, !namespace.isEmpty {
            return "\(baseAccount).\(namespace)"
        }
        return baseAccount
    }

    public func load() -> Token? {
        let account = currentAccount()
        guard allowsSync() else {
            return local.string(for: account).flatMap(decode)
        }
        if local.string(for: Self.localAuthenticationKey(account)) != nil,
           let raw = local.string(for: account), let token = decode(raw) {
            do { try save(token, account: account) }
            catch { FanoutDiagnostics.emit("keychain.localAuthenticationMigration result=FAILED") }
            return token
        }
        guard !SyncedTokenRegistry.shared.isSignedOut(.init(service: service, account: account)) else {
            return nil
        }
        if let raw = synced.string(for: account),
           let token = decode(raw) {
            do { try local.removeValue(for: account) }
            catch { FanoutDiagnostics.emit("keychain.localCopyRetirement result=FAILED") }
            FanoutDiagnostics.emit(
                "keychain.read account=\(account) source=synced "
                + "attrSynchronizable=\(synchronizableAttribute(account))"
            )
            return token
        }
        FanoutDiagnostics.emit(
            "keychain.read account=\(account) source=none "
            + "attrSynchronizable=\(synchronizableAttribute(account))"
        )
        // Nothing synced yet. A device that signed in before this existed still
        // holds a device-local item; adopt it so switching storage doesn't read
        // as being signed out, and so it reaches this account's other devices.
        guard let raw = local.string(for: account),
              let token = decode(raw)
        else { return nil }
        do {
            try save(token, account: account)
            if allowsSync() { try local.removeValue(for: account) }
        } catch {
            FanoutDiagnostics.emit("keychain.migration result=FAILED legacy=retained")
        }
        return token
    }

    public func save(_ token: Token) throws {
        try save(token, account: currentAccount())
    }

    private func save(_ token: Token, account: String) throws {
        let data = try JSONEncoder().encode(token)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw SyncedTokenBoxError.encoding
        }
        guard allowsSync() else {
            try local.setString(raw, for: account)
            try local.setString("1", for: Self.localAuthenticationKey(account))
            return
        }
        do {
            try synced.setString(raw, for: account)
            SyncedTokenRegistry.shared.register(service: service, account: account)
            SyncedTokenRegistry.shared.clearSignedOut(
                .init(service: service, account: account)
            )
            SyncedTokenRegistry.shared.noteChanged()
            try local.removeValue(for: Self.localAuthenticationKey(account))
            try local.removeValue(for: account)
            // Never the token itself — only whether the synced write landed and
            // whether the item reads back as synchronizable.
            FanoutDiagnostics.emit(
                "keychain.sync account=\(account) write=ok "
                + "readback=\(synced.string(for: account) == nil ? "miss" : "hit") "
                + "attrSynchronizable=\(synchronizableAttribute(account))"
            )
        } catch {
            FanoutDiagnostics.emit(
                "keychain.sync account=\(account) write=FAILED error=\(error)"
            )
            throw error
        }
    }

    /// What the Keychain actually recorded for the item, which is the only way to
    /// tell a platform that accepted `kSecAttrSynchronizable` from one that
    /// quietly stored a local item instead.
    static func storedSynchronizable(service: String, account: String) -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let attrs = result as? [String: Any] else { return "status:\(status)" }
        let flag = attrs[kSecAttrSynchronizable as String] as? Bool
        return flag.map(String.init) ?? "absent"
    }

    public func clear() throws {
        let account = currentAccount()
        try local.removeValue(for: Self.localAuthenticationKey(account))
        guard allowsSync() else {
            try local.removeValue(for: account)
            return
        }
        try synced.removeValue(for: account)
        // A failed legacy deletion must not report a successful sign-out.
        try local.removeValue(for: account)
        // Deliberate: this must sign the account's other devices out too.
        SyncedTokenRegistry.shared.markSignedOut(
            .init(service: service, account: account)
        )
        SyncedTokenRegistry.shared.noteChanged()
    }

    private func decode(_ raw: String) -> Token? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Token.self, from: data)
    }

    public static func localAuthenticationKey(_ account: String) -> String {
        account + ".local-authentication.v1"
    }

}

public enum SyncedTokenBoxError: Error {
    case encoding
}
#endif
