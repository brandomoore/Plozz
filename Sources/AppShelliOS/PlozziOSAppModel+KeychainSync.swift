#if os(iOS)
import Foundation
import CoreModels
import CoreNetworking
import FeatureAuthCore
import FeatureSyncSetup
import SeerService
import CoreSecureStore

// MARK: - PlozziOSAppModel + iCloud Keychain credential auto-connect
//
// The "it just works" credential path for iPhone/iPad. Server descriptors already
// sync (non-secret) over CloudKit; the LOGINS ride iCloud Keychain instead — the
// end-to-end-encrypted store Apple designed for exactly this. Each device publishes
// its account bearer tokens as SYNCHRONIZABLE Keychain items; the user's other
// iOS/iPadOS devices read them and sign in automatically, with NO typing and NO
// pairing. (tvOS can't participate in iCloud Keychain, so it keeps using the LAN
// pairing bridge.)
//
// Only bearer-token accounts (Jellyfin/Plex/Emby) are published here. Media-share
// SSH keys stay device-local (they never leave a device), matching the pairing
// policy.
extension PlozziOSAppModel {

    nonisolated private static let portableCredService = "com.plozz.portablecred.v1"

    /// A synchronizable (iCloud-Keychain-backed) store for portable credentials.
    private var portableCredStore: KeychainStore {
        KeychainStore(service: Self.portableCredService, userIndependent: false, synchronizable: true)
    }

    static func makePortableCredentialPublisher() -> SerializedCredentialPublisher {
        let store = KeychainStore(service: portableCredService, userIndependent: false, synchronizable: true)
        return SerializedCredentialPublisher(
            store: store, clearStore: { try store.removeAll() },
            isEnabled: { SyncSetupFeatureFlag().isEnabled },
            onFailure: { operation, error in
                if case KeychainError.unexpectedStatus(let status) = error {
                    PlozzLog.auth.error("KeychainSync: \(operation.rawValue) failed, status=\(status)")
                } else {
                    PlozzLog.auth.error("KeychainSync: \(operation.rawValue) failed")
                }
            }
        )
    }

    /// This device's transferable credentials (bearer tokens + share envelopes). Also
    /// used by the pairing `secretsProvider`, so both paths agree on what's shareable.
    func currentSecretsBundle() -> SyncSecretsBundle {
        Self.buildSecretsBundle(accounts: accountsProviders.accounts, accountStore: accountStore)
    }

    /// Pure builder shared by the instance method above AND the pairing service's
    /// `secretsProvider` (which runs during init, before `self` is usable, so it can
    /// only capture already-initialized properties — not call an instance method).
    nonisolated static func buildSecretsBundle(accounts: [Account], accountStore: AccountPersisting) -> SyncSecretsBundle {
        var accts: [AccountSecret] = []
        var shares: [ShareSecret] = []
        for account in accounts {
            guard account.server.provider.permitsCredentialTransfer else { continue }
            if account.server.provider == .mediaShare {
                if let envelope = try? accountStore.mediaShareCredential(for: account.id) {
                    if case .generatedKey = envelope.authentication {
                        // The SSH key lives in THIS device's Keychain and never
                        // travels; the paired device re-adds this share (own key).
                        PlozzLog.auth.info("KeychainSync: skipping generated-key share \(account.id)")
                    } else if let encoded = try? MediaShareCredentialCodec.encode(envelope) {
                        shares.append(ShareSecret(accountID: account.id, credentialEnvelope: encoded))
                    }
                }
                continue
            }
            guard let token = accountStore.token(for: account.id) else { continue }
            accts.append(AccountSecret(
                accountID: account.id, provider: account.server.provider, token: token,
                deviceID: account.deviceID,
                trustedOrigin: LocalAuthorization.origin(of: account.server.baseURL)))
        }
        return SyncSecretsBundle(accounts: accts, shares: shares, seerr: currentSeerrSecret())
    }

    // MARK: - Shared household Seerr connection

    /// Fixed key for the household Seerr connection in the portable-credential
    /// store. Not an account id (Seerr is one household-wide connection, not a
    /// per-account login), so it's namespaced to avoid ever colliding with one.
    nonisolated private static let portableSeerrKey = "household.seerr.connection.v1"

    /// The household Keychain store backing the Seerr connection. One definition so
    /// the app's read path and these transfer paths can't drift on service or key.
    nonisolated static func seerrConnectionStore() -> HouseholdSeerConnectionStore {
        HouseholdSeerConnectionStore(secureStore: KeychainStore(service: "com.plozz.app.household"))
    }

    /// This device's Seerr connection as a transferable secret, or nil if unset.
    nonisolated static func currentSeerrSecret() -> SeerrSecret? {
        guard let connection = seerrConnectionStore().load() else { return nil }
        return SeerrSecret(baseURL: connection.baseURL.absoluteString, apiKey: connection.apiKey)
    }

    /// Install a received Seerr connection, unless this device already has one.
    /// Never clobbers: the local connection may hold the URL reachable on THIS
    /// network, and arriving credentials shouldn't silently repoint it.
    @discardableResult
    static func installSeerrSecretIfAbsent(_ secret: SeerrSecret) -> Bool {
        let store = seerrConnectionStore()
        guard store.load() == nil, let url = URL(string: secret.baseURL) else { return false }
        do {
            try store.save(SeerConnection(baseURL: url, apiKey: secret.apiKey))
            return true
        } catch {
            PlozzLog.auth.error("KeychainSync: Seerr install failed: \(error.localizedDescription)")
            return false
        }
    }

    /// WRITE: publish this device's transferable credentials to the iCloud-Keychain-
    /// synced store so the user's OTHER iPhone/iPad auto-connect with zero taps —
    /// bearer tokens (Plex/Jellyfin/Emby) AND media-share credential envelopes
    /// (NFS/SMB/WebDAV). Gated on sync being enabled (the household consent decision).
    ///
    /// SFTP shares with a device-local generated SSH key are intentionally NOT
    /// published (the private key must never leave the device) — `buildSecretsBundle`
    /// already omits those, so they still require a manual re-add on each device.
    func publishPortableCredentials() {
        guard SyncSetupFeatureFlag().isEnabled else { return }
        let accounts = accountsProviders.accounts
        let accountStore = accountStore
        portableCredentialPublisher.publish {
            let bundle = Self.buildSecretsBundle(accounts: accounts, accountStore: accountStore)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var records: [String: String] = [:]
            for secret in bundle.accounts {
                records[secret.accountID] = String(decoding: try encoder.encode(secret), as: UTF8.self)
            }
            for share in bundle.shares {
                records[share.accountID] = String(decoding: try encoder.encode(share), as: UTF8.self)
            }
            if let seerr = bundle.seerr {
                records[Self.portableSeerrKey] = String(decoding: try encoder.encode(seerr), as: UTF8.self)
            }
            return records
        }
    }

    /// Adopt a Seerr connection published by another of the user's devices. Runs
    /// independently of the pending-server loop below: Seerr is household-wide and
    /// has no descriptor, so it isn't gated on any server being pending.
    private func adoptSyncedSeerrConnection(from store: KeychainStore) {
        guard portableCredentialPublisher.mayRead(Self.portableSeerrKey) else { return }
        guard let json = store.string(for: Self.portableSeerrKey) else {
            PlozzLog.auth.info("KeychainSync: no Seerr connection in iCloud Keychain yet")
            return
        }
        guard let data = json.data(using: .utf8),
              let secret = try? JSONDecoder().decode(SeerrSecret.self, from: data) else {
            PlozzLog.auth.error("KeychainSync: Seerr connection in iCloud Keychain is undecodable")
            return
        }
        guard Self.installSeerrSecretIfAbsent(secret) else {
            PlozzLog.auth.info("KeychainSync: Seerr already configured locally — keeping this device's connection")
            return
        }
        PlozzLog.auth.info("KeychainSync: adopted shared Seerr connection from iCloud Keychain")
        // The service cached its config at init, BEFORE this ran, so without an
        // explicit reload the freshly-installed connection stays invisible until
        // the next launch.
        Task { await seerService.reloadConnection() }
    }

    /// Remove a portable credential (an account was signed out on this device), so it
    /// stops auto-connecting the user's other devices.
    func removePortableCredential(_ accountID: String) {
        portableCredentialPublisher.removeValue(for: accountID)
    }

    /// Debug: purge EVERY synced iCloud-Keychain login for the whole household —
    /// including credentials synced in from other devices whose account IDs this
    /// device never held locally. Because the store is synchronizable, the deletion
    /// propagates through iCloud Keychain to the household's other devices, so no
    /// device silently auto-reconnects afterward. Used by "Erase Everything From
    /// iCloud" to reach a true clean slate for cold-start testing.
    func removeAllPortableCredentials() async throws {
        try await withCheckedThrowingContinuation { continuation in
            portableCredentialPublisher.removeAll { continuation.resume(with: $0) }
        }
    }

    /// Whether this device already has a synced iCloud-Keychain login for `accountID`,
    /// i.e. `autoConnectFromSyncedCredentials()` can sign it in with no user action. Used
    /// to suppress the manual "add this server?" prompt when a silent auto-connect will
    /// handle it (e.g. iPhone → iPad, where the login rides iCloud Keychain).
    func hasPortableCredential(_ accountID: String) -> Bool {
        portableCredentialPublisher.mayRead(accountID) && portableCredStore.string(for: accountID) != nil
    }

    /// AUTO-CONNECT (READ): for each server synced from another device but not signed in
    /// here (and not ignored), look for a matching credential in the iCloud-Keychain
    /// synced store and sign in automatically — no typing, no pairing. Safe + idempotent:
    /// only acts on pending (not-yet-local) servers, and `accountStore.add` replaces any
    /// existing entry rather than duplicating.
    func autoConnectFromSyncedCredentials() {
        guard SyncSetupFeatureFlag().isEnabled else { return }
        let store = portableCredStore
        adoptSyncedSeerrConnection(from: store)
        let localIDs = Set(accountsProviders.accounts.map(\.id))
        let removedIDs = RemovedAccountsStore().removedIDs
        // Don't auto-resurrect a server the user removed household-wide. (Deterministic
        // account ids mean an already-signed-in server shares the descriptor's id, so
        // it's already excluded by `pending(excludingLocal:)`.)
        let pending = PendingSyncedServersStore().pending(excludingLocal: localIDs)
            .filter { !removedIDs.contains($0.id) }
        guard !pending.isEmpty else { return }
        var connected = 0
        for desc in pending {
            guard portableCredentialPublisher.mayRead(desc.id),
                  let json = store.string(for: desc.id),
                  let data = json.data(using: .utf8) else { continue }
            if desc.provider == .mediaShare {
                // Media share: restore from a published ShareSecret envelope (NFS/SMB/
                // WebDAV). SFTP-with-generated-key was never published, so those simply
                // aren't found here and fall through to manual/pairing setup.
                guard let share = try? JSONDecoder().decode(ShareSecret.self, from: data),
                      let envelope = try? MediaShareCredentialCodec.decodeVersioned(share.credentialEnvelope),
                      let baseURL = desc.candidateBaseURLs.first else { continue }
                if case .generatedKey = envelope.authentication { continue } // never travels
                let server = MediaServer(
                    id: desc.serverID, name: desc.serverName, baseURL: baseURL,
                    provider: .mediaShare,
                    connectionURLs: desc.candidateBaseURLs.isEmpty ? nil : desc.candidateBaseURLs,
                    mediaShareLibraryConfiguration: desc.mediaShareLibraryConfiguration)
                let account = Account(
                    id: desc.id, server: server, userID: desc.userID, userName: desc.userName,
                    avatarURL: desc.avatarURL, deviceID: accountStore.deviceID())
                do { try accountStore.addMediaShare(account, credential: envelope, generatedPrivateKey: nil); connected += 1 }
                catch { PlozzLog.auth.error("KeychainSync: auto-connect share failed for \(desc.id): \(error.localizedDescription)") }
                continue
            }
            // Token provider (Plex/Jellyfin/Emby): restore from an AccountSecret.
            guard desc.provider.permitsCredentialTransfer,
                  let secret = try? JSONDecoder().decode(AccountSecret.self, from: data),
                  secret.provider.permitsCredentialTransfer else { continue }
            let baseURL = desc.candidateBaseURLs.first
                ?? URL(string: secret.trustedOrigin)
                ?? URL(string: "https://localhost")!
            let server = MediaServer(
                id: desc.serverID, name: desc.serverName, baseURL: baseURL,
                provider: desc.provider,
                connectionURLs: desc.candidateBaseURLs.isEmpty ? nil : desc.candidateBaseURLs)
            let account = Account(
                id: desc.id, server: server, userID: desc.userID, userName: desc.userName,
                avatarURL: desc.avatarURL, deviceID: secret.deviceID)
            do { try accountStore.add(account, token: secret.token); connected += 1 }
            catch { PlozzLog.auth.error("KeychainSync: auto-connect failed for \(desc.id): \(error.localizedDescription)") }
        }
        if connected > 0 {
            PlozzLog.auth.info("KeychainSync: auto-connected \(connected) server(s) from iCloud Keychain")
            accountsProviders.reloadAccounts()
            refreshPendingSyncedServers()
        }
    }
}
#endif
