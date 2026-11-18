import Foundation
import CoreModels
import CoreNetworking
import CoreSecureStore
import TraktService

/// Mirrors tracker sign-ins between devices through the app's existing
/// encrypted CloudKit channel.
///
/// Why this exists at all: tokens belong in the Keychain, and they still live
/// there on every device. But Apple documents that tvOS accepts
/// `kSecAttrSynchronizable` without ever synchronising an app's keychain items
/// through iCloud — measured on device, the Apple TV stored all three connected
/// trackers with `synchronizable=true` while the iPhone's lookup of the very
/// same account returned `errSecItemNotFound`. So iCloud Keychain can carry a
/// sign-in between iPhone and iPad but can neither reach nor leave the Apple TV,
/// which is the device most likely to be signed in first.
///
/// The payload rides in `encryptedValues`. Exclusive access to CloudKit encryption
/// keys depends on the user's Advanced Data Protection setting.
/// The Keychain remains the store of record on each device; this is transport.
public enum TrackerTokenSyncBridge {
    static let signedOutValue = Data("Plozz.TrackerSignedOut.v1".utf8)
    public static func preserveLocalSignInsBeforeDisablingSync() throws {
        guard SyncSetupFeatureFlag().usesOnboardingConsent else { return }
        try SyncedTokenRegistry.preserveDeviceSignIns(
            SyncedTokenRegistry.shared.knownAccounts().filter { !TraktSharedRefreshBootstrap.manages($0) }
        )
    }

    public static func erasureStores(profileNamespaces: [String?]) -> [any TraktTokenStoring] {
        // Register inactive profiles as well as the currently constructed services.
        var stores: [any TraktTokenStoring] = Set(profileNamespaces + [nil]).flatMap { namespace in
            ["trakt.oauth", "wetrakr.oauth"].map {
                KeychainTraktTokenStore(account: $0, namespace: namespace)
            }
        }
        let existing = Set(stores.map(\.coordinationID))
        stores += SyncedTokenRegistry.shared.knownAccounts().filter {
            TraktSharedRefreshBootstrap.manages($0)
                && !existing.contains($0.service + "\0" + $0.account)
        }.map { KeychainTraktTokenStore(service: $0.service, account: $0.account) }
        return stores
    }

    public static func eraseLocalTokens() throws {
        for account in SyncedTokenRegistry.shared.knownAccounts() {
            // clear() never decodes the generic payload and also removes legacy copies.
            try SyncedTokenBox<String>(service: account.service, account: account.account).clear()
        }
        for synchronizable in [true, false] {
            try KeychainStore(
                service: "com.plozz.app.tokens", userIndependent: false,
                fallbackToPerUser: false, synchronizable: synchronizable
            ).removeAll()
        }
        NotificationCenter.default.post(name: .plozzTrackerTokensDidChangeRemotely, object: nil)
    }

    /// `<service>|<account>`, both of which are already stable, non-secret
    /// identifiers. The record name must not be derived from the token.
    static func recordName(for account: SyncedTokenRegistry.Account) -> SyncRecordID {
        "trackerToken:\(account.service)|\(account.account)"
    }

    static func account(
        fromRecordName name: SyncRecordID
    ) -> SyncedTokenRegistry.Account? {
        let prefix = "trackerToken:"
        guard name.hasPrefix(prefix) else { return nil }
        let body = name.dropFirst(prefix.count)
        guard let separator = body.firstIndex(of: "|") else { return nil }
        let service = String(body[..<separator])
        let account = String(body[body.index(after: separator)...])
        guard !service.isEmpty, !account.isEmpty else { return nil }
        return SyncedTokenRegistry.Account(service: service, account: account)
    }

    /// Every tracker account this device holds a token for.
    ///
    /// Accounts with no local token are simply absent rather than published as
    /// empty, so a device that has never signed in cannot delete a sign-in that
    /// another device made.
    public static func capture(
        fallback: [SyncRecordID: Data]
    ) -> [SyncRecordID: Data] {
        var records: [SyncRecordID: Data] = [:]
        var signedOut: Set<SyncRecordID> = []
        for account in SyncedTokenRegistry.shared.knownAccounts() {
            guard !TraktSharedRefreshBootstrap.manages(account) else { continue }
            let name = recordName(for: account)
            let local = KeychainStore(
                service: account.service, userIndependent: false,
                fallbackToPerUser: false, synchronizable: false)
            if local.string(for: SyncedTokenBox<String>.localAuthenticationKey(account.account)) != nil,
               let raw = local.string(for: account.account) {
                records[name] = Data(raw.utf8)
                continue
            }
            if SyncedTokenRegistry.shared.isSignedOut(account) {
                // Explicit intent survives even when this is the last credential.
                records[name] = signedOutValue
                signedOut.insert(name)
                continue
            }
            let store = SyncedTokenRegistry.store(for: account)
            guard let raw = store.string(for: account.account),
                  let data = raw.data(using: .utf8) else { continue }
            records[name] = data
        }
        for (name, value) in fallback where records[name] == nil {
            guard let account = account(fromRecordName: name) else { continue }
            guard !TraktSharedRefreshBootstrap.manages(account) else { continue }
            // A real sign-out must not be resurrected by its own ledger entry.
            guard !signedOut.contains(name) else { continue }
            // Otherwise this device simply doesn't have the token: either it has
            // never signed in, or something local discarded it. Keep publishing
            // what the account already agreed on rather than deleting it, and
            // restore the local copy so the device heals itself instead of
            // waiting for a remote edit it may never get.
            records[name] = value
            let store = SyncedTokenRegistry.store(for: account)
            if value != signedOutValue, store.string(for: account.account) == nil,
               let raw = String(data: value, encoding: .utf8) {
                do {
                    try store.setString(raw, for: account.account)
                    FanoutDiagnostics.emit("keychain.cloudHeal account=\(account.account)")
                } catch {
                    PlozzLog.sync.error("Tracker credential recovery could not save to Keychain")
                }
            }
        }
        return records
    }

    /// Write incoming sign-ins into the local Keychain.
    ///
    /// A `nil` value is a genuine remote sign-out and clears the local token.
    /// Returns the accounts that actually changed so the caller can refresh the
    /// services holding them.
    @discardableResult
    public static func apply(_ changes: SyncLocalChanges) -> [SyncedTokenRegistry.Account] {
        var touched: [SyncedTokenRegistry.Account] = []
        var sharedTrakt: Set<SyncedTokenRegistry.Account> = []
        for (name, value) in changes {
            if let account = TraktSharedRefreshBootstrap.account(forRecordName: name),
               TraktSharedRefreshBootstrap.manages(account) {
                SyncedTokenRegistry.shared.register(service: account.service, account: account.account)
                sharedTrakt.insert(account)
                continue
            }
            guard let account = account(fromRecordName: name) else { continue }
            let store = SyncedTokenRegistry.store(for: account)
            guard let value, value != signedOutValue else {
                // Another device signed out. Match it, and remember that this is
                // a sign-out rather than a gap, so the next capture doesn't
                // publish the token straight back.
                SyncedTokenRegistry.shared.markSignedOut(account)
                do {
                    try store.removeValue(for: account.account)
                    let local = KeychainStore(
                        service: account.service, userIndependent: false,
                        fallbackToPerUser: false, synchronizable: false
                    )
                    try local.removeValue(for: SyncedTokenBox<String>.localAuthenticationKey(account.account))
                    try local.removeValue(for: account.account)
                    touched.append(account)
                } catch {
                    PlozzLog.sync.error("Remote tracker sign-out could not remove a local credential")
                }
                continue
            }
            guard let raw = String(data: value, encoding: .utf8) else { continue }
            // Don't rewrite an identical token; that would churn the Keychain and
            // re-trigger the change handler on every fetch.
            guard store.string(for: account.account) != raw else { continue }
            do { try store.setString(raw, for: account.account) }
            catch {
                PlozzLog.sync.error("Remote tracker sign-in could not be saved to Keychain")
                continue
            }
            SyncedTokenRegistry.shared.clearSignedOut(account)
            SyncedTokenRegistry.shared.register(
                service: account.service,
                account: account.account
            )
            touched.append(account)
        }
        if !sharedTrakt.isEmpty {
            let accounts = Array(sharedTrakt)
            Task { await TraktSharedRefreshBootstrap.synchronize(accounts) }
        }
        if !touched.isEmpty {
            // The services hold their connection phase in memory, so a token
            // arriving from another device is invisible until they re-read it.
            NotificationCenter.default.post(
                name: .plozzTrackerTokensDidChangeRemotely,
                object: nil
            )
            FanoutDiagnostics.emit(
                "keychain.cloudApply accounts=\(touched.map(\.account).sorted().joined(separator: ","))"
            )
        }
        return touched
    }
}


extension Notification.Name {
    /// A tracker sign-in arrived from another device.
    public static let plozzTrackerTokensDidChangeRemotely = Notification.Name(
        "com.plozz.app.trackerTokensDidChangeRemotely"
    )
}
