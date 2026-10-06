import CoreSecureStore
import CoreNetworking
import FeatureSyncCloud
import Foundation
import TraktService

public enum TraktSharedRefreshBootstrap {
    /// Call before making any Trakt service/outbox. This is independent of the
    /// configuration-sync preference: a shared refresh may not become local just
    /// because that preference or the network is unavailable.
    public static func install(containerIdentifier: String = "iCloud.com.thatcube.Plozz") {
        guard CloudTraktRefreshTransport.requiresCoordination(containerIdentifier: containerIdentifier) else { return }
        TraktSharedRefresh.shared.configure(.init(
            transport: CloudTraktRefreshTransport(containerIdentifier: containerIdentifier),
            journal: SecureTraktSharedRefreshJournal(store: KeychainStore(
                service: "com.plozz.trakt.sharedRefreshJournal",
                userIndependent: false, fallbackToPerUser: false, synchronizable: false
            )),
            isLocallySignedOut: { scope in
                let parts = scope.split(separator: "\0", omittingEmptySubsequences: false)
                guard parts.count == 2 else { return false }
                return SyncedTokenRegistry.shared.isSignedOut(.init(
                    service: String(parts[0]), account: String(parts[1])
                ))
            }
        ))
    }

    static func manages(_ account: SyncedTokenRegistry.Account) -> Bool {
        TraktSharedRefresh.shared.isConfigured
            && (account.account == "trakt.oauth" || account.account.hasPrefix("trakt.oauth."))
    }

    static func account(forRecordName name: String) -> SyncedTokenRegistry.Account? {
        if let scope = CloudTraktRefreshTransport.scope(recordName: name) {
            let parts = scope.split(separator: "\0", omittingEmptySubsequences: false)
            return .init(service: String(parts[0]), account: String(parts[1]))
        }
        return TrackerTokenSyncBridge.account(fromRecordName: name)
    }

    public static func synchronizeKnownAccounts() async {
        await synchronize(SyncedTokenRegistry.shared.knownAccounts())
    }

    static func synchronize(_ accounts: [SyncedTokenRegistry.Account]) async {
        var changed = false
        for account in Set(accounts) where manages(account) {
            let store = KeychainTraktTokenStore(service: account.service, account: account.account)
            let previous = store.load()
            do {
                try await TraktSharedRefresh.shared.synchronize(store: store)
            } catch {
                // The durable owner keeps pending work. An interactive Trakt
                // refresh surfaces the retry error; push delivery never signs out.
                PlozzLog.sync.error("Shared Trakt authorization sync deferred; retaining recoverable state")
            }
            changed = changed || previous != store.load()
        }
        if changed {
            NotificationCenter.default.post(name: .plozzTrackerTokensDidChangeRemotely, object: nil)
        }
    }
}
