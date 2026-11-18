import CoreModels
import CryptoKit
import FeatureAuthCore
import Foundation

/// Device-local proof of a successful online Home-user sign-in. Never synced.
public struct OfflinePlexSignInStore {
    struct Entry: Codable {
        let profile: AutomaticSignInStore.Session.ProfileAccess
        let account: AutomaticSignInStore.Session.AccountAccess
        let deviceID: String
        let pinVerifier: ProfileLock?
        let serverToken: String
    }

    private let secureStore: any SecureStoring
    private let defaults: UserDefaults?

    public init(secureStore: any SecureStoring, defaults: UserDefaults? = nil) {
        self.secureStore = secureStore
        self.defaults = defaults
    }

    public static func makeDefault() -> Self {
        #if canImport(Security)
        Self(secureStore: KeychainStore(
            service: "com.plozz.app.offlineSignIn",
            userIndependent: false, synchronizable: false
        ), defaults: .standard)
        #else
        Self(secureStore: InMemorySecureStore())
        #endif
    }

    func load(profile: Profile, account: Account) throws -> Entry? {
        guard defaults?.bool(forKey: revocationKey(profile: profile, account: account)) != true,
              let binding = profile.homeUserBinding(forPlexAccount: account.id),
              binding.pinRequirementVerified == true,
              let raw = try secureStore.readString(for: key(profile: profile, account: account)),
              let data = raw.data(using: .utf8) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        guard entry.profile == .init(profile), entry.account == .init(account, profile: profile),
              entry.deviceID == account.deviceID, !entry.serverToken.isEmpty,
              (binding.requiresPIN == true) == (entry.pinVerifier != nil) else { return nil }
        return entry
    }

    func save(
        profile: Profile, account: Account, pinVerifier: ProfileLock?,
        serverToken: String
    ) throws {
        guard let binding = profile.homeUserBinding(forPlexAccount: account.id),
              binding.pinRequirementVerified == true,
              (binding.requiresPIN == true) == (pinVerifier != nil),
              !serverToken.isEmpty else { throw AppError.unauthorized }
        let entry = Entry(
            profile: .init(profile), account: .init(account, profile: profile),
            deviceID: account.deviceID, pinVerifier: pinVerifier,
            serverToken: serverToken
        )
        try secureStore.setString(
            String(decoding: JSONEncoder().encode(entry), as: UTF8.self),
            for: key(profile: profile, account: account)
        )
        defaults?.removeObject(forKey: revocationKey(profile: profile, account: account))
    }

    func remove(profile: Profile, account: Account) throws {
        defaults?.set(true, forKey: revocationKey(profile: profile, account: account))
        try secureStore.removeValue(for: key(profile: profile, account: account))
    }

    private func revocationKey(profile: Profile, account: Account) -> String {
        "plozz.offlineSignIn.revoked." + key(profile: profile, account: account)
    }

    private func key(profile: Profile, account: Account) -> String {
        let identity = [profile.id, account.id].map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func permitsFallback(after error: Error) -> Bool {
        if error as? AppError == .serverUnreachable { return true }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
             .timedOut, .networkConnectionLost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}
