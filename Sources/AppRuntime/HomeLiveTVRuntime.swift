import CoreModels
import CoreSecureStore
import CryptoKit
import Foundation

@MainActor
public enum HomeLiveTVRuntime {
    private static var models: [String: HomeLiveTVModel] = [:]
    private static var authorizations: [ObjectIdentifier: Authorization] = [:]

    private final class Authorization {
        weak var owner: AccountsProvidersModel?
        let epoch: String
        let profileID: String
        let digest: String
        init(owner: AccountsProvidersModel, epoch: String, profileID: String, digest: String) {
            self.owner = owner
            self.epoch = epoch
            self.profileID = profileID
            self.digest = digest
        }
    }

    /// Hydrates only the small local metadata file. Never creates
    /// LiveTVCatalogStorage, initializes portable sync, or touches a provider.
    public static func model(profileID: String) -> HomeLiveTVModel {
        if let model = models[profileID] { return model }
        let model = HomeLiveTVModel(profileID: profileID, store: HomeLiveTVSnapshotStore(
            profileID: profileID, secureStore: LiveTVSourceStorage.catalogSecrets()
        ))
        models[profileID] = model
        return model
    }

    static func applyPortableStateChange(_ notification: Notification, to model: HomeLiveTVModel) -> Bool {
        guard notification.object as? String == model.profileID else { return false }
        // Channel-ID migrations must be republished by this profile's catalog owner.
        model.publish(.empty)
        model.cancelRequest()
        return true
    }

    /// Runtime Plex override revisions are deliberately ephemeral. A durable
    /// card scope uses persisted account credential revisions instead. The
    /// source-approval identity separately fences the selected Plex Home user.
    /// No token (or token-derived hash) enters the persisted scope.
    public static func authorizationID(
        profileID: String, accounts: AccountsProvidersModel?
    ) -> String? {
        guard let accounts else { return nil }
        let active = accounts.accounts.filter { accounts.activeAccountIDs.contains($0.id) }
        let durableRevisions = active.sorted { $0.id < $1.id }
            .map(\.connectionScopeKey).joined(separator: "|")
        let epoch = accounts.liveTVAuthorizationID + "|" + durableRevisions
        let key = ObjectIdentifier(accounts)
        var credentialIDs = Set<String>()
        for account in active where account.server.provider != .mediaShare && account.server.provider != .silo {
            // Credential resolvers already cache local reads. Never memoize a
            // positive credential presence after it has been removed or locked.
            guard accounts.tokenResolver(account.id)?.isEmpty == false else {
                authorizations[key] = nil
                return nil
            }
            credentialIDs.insert(account.id)
        }
        if let cached = authorizations[key], cached.owner === accounts,
           cached.epoch == epoch, cached.profileID == profileID {
            return cached.digest
        }
        authorizations = authorizations.filter { $0.value.owner != nil }
        guard let digest = durableAuthorizationID(
            profileID: profileID,
            accounts: active,
            hasCredential: { credentialIDs.contains($0) }
        ) else {
            authorizations[key] = nil
            return nil
        }
        authorizations[key] = Authorization(owner: accounts, epoch: epoch, profileID: profileID, digest: digest)
        return digest
    }

    static func durableAuthorizationID(
        profileID: String, accounts: [Account], hasCredential: (String) -> Bool
    ) -> String? {
        var digest = SHA256()
        func append(_ value: String) {
            digest.update(data: Data("\(value.utf8.count):".utf8))
            digest.update(data: Data(value.utf8))
        }
        append("home-live-tv-authority-v1")
        append(profileID)
        for account in accounts.sorted(by: { $0.id < $1.id }) {
            switch account.server.provider {
            case .mediaShare, .silo, .subsonic: continue
            case .plex, .jellyfin, .emby, .iptv: break
            }
            guard hasCredential(account.id) else { return nil }
            for value in [
                account.id, account.server.id, account.server.provider.rawValue,
                account.server.baseURL.absoluteString, account.userID, account.deviceID,
                account.credentialRevision.rawValue.uuidString
            ] { append(value) }
            for address in account.server.connectionURLs ?? [] { append(address.absoluteString) }
            for address in account.server.alternateConnectionURLs ?? [] { append(address.absoluteString) }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func visibleSnapshot(
        cached: HomeLiveTVSnapshot, profileID: String, serverAuthorizationID: String,
        configuration: LiveTVSourcesConfiguration, authorization: LiveTVSourceAuthorization,
        preferences: LiveTVPreferences
    ) -> HomeLiveTVSnapshot {
        guard authorization.profileID == profileID else { return .empty }
        let hidden = preferences.hiddenChannelIDs
        let filtered = cached.filtering { card in
            let route = card.route
            guard route.profileID == profileID,
                  route.sourceAuthorizationID == authorization.identity,
                  route.serverAuthorizationID == serverAuthorizationID,
                  !hidden.contains(route.channelID) else { return false }
            if let metadata = card.organizationMetadata,
               preferences.organization.hiddenReason(channelID: route.channelID, metadata: metadata) != nil {
                return false
            }
            // Older cached IPTV cards have no classification to evaluate.
            if card.organizationMetadata == nil, route.accountID == nil,
               preferences.organization.hasVisibilityRules {
                return false
            }
            if let accountID = route.accountID {
                return configuration.servers.contains {
                    $0.id == route.sourceID && $0.accountID == accountID && $0.isEnabled
                }
            }
            return authorization.allowsPlaylist(route.sourceID)
                && configuration.playlists.contains { $0.id == route.sourceID && $0.isEnabled }
        }
        let cards = filtered.recentChannels + filtered.channels
        let byID = Dictionary(cards.map { ($0.route.channelID, $0) }, uniquingKeysWith: { first, _ in first })
        return .build(
            recentIDs: preferences.recentChannelIDs,
            favoriteIDs: preferences.favoriteOrder + filtered.channels.filter {
                guard let metadata = $0.organizationMetadata else { return false }
                return preferences.organization.isCategoryFavorite(channelID: $0.route.channelID, metadata: metadata)
            }.map { $0.route.channelID },
            fallbackIDs: filtered.channels.map { $0.route.channelID },
            channel: { byID[$0] }
        )
    }
}

#if canImport(SwiftUI)
import CoreUI
import SwiftUI

private struct HomeLiveTVScope: ViewModifier {
    let profileID: String
    let namespace: String?
    let accounts: AccountsProvidersModel
    let isAuthorized: @MainActor () -> Bool
    let navigate: @MainActor () -> Bool
    @Environment(ProfilesModel.self) private var profiles
    @State private var visible: HomeLiveTVSnapshot = .empty
    @State private var presentedIdentity: Identity?

    private struct Identity: Equatable {
        let profileID: String
        let serverAuthorizationID: String?
        let approvalIdentity: String
        let isAuthorized: Bool
    }

    private var model: HomeLiveTVModel { HomeLiveTVRuntime.model(profileID: profileID) }
    private var identity: Identity {
        Identity(
            profileID: profiles.activeProfileID,
            serverAuthorizationID: HomeLiveTVRuntime.authorizationID(profileID: profileID, accounts: accounts),
            approvalIdentity: LiveTVSourceApprovalContext(profiles: profiles).identity,
            isAuthorized: isAuthorized() && profiles.activeProfileID == profileID
        )
    }
    private var snapshot: HomeLiveTVSnapshot {
        presentedIdentity == identity && identity.isAuthorized ? visible : .empty
    }

    func body(content: Content) -> some View {
        content
            .environment(\.homeLiveTVSnapshot, snapshot)
            .environment(\.openHomeLiveTV, { route in
                // Recheck local authority at the press, not only at last paint.
                refresh()
                guard isAuthorized(), model.request(route, in: snapshot) else { return }
                if !navigate() { model.cancelRequest() }
            })
            .onChange(of: identity, initial: true) { old, new in
                if old != new {
                    HomeLiveTVRuntime.model(profileID: old.profileID).cancelRequest()
                    model.cancelRequest()
                }
                refresh()
            }
            .onDisappear { model.cancelRequest() }
            .onChange(of: model.snapshot, initial: true) { _, _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVPreferencesDidChange)
                .receive(on: DispatchQueue.main)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVSourceApprovalsDidChange)
                .receive(on: DispatchQueue.main)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVPortableStateDidChange)
                .receive(on: DispatchQueue.main)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVPortableStateDidApply)
                .receive(on: DispatchQueue.main)) { notification in
                    guard HomeLiveTVRuntime.applyPortableStateChange(notification, to: model) else { return }
                    refresh()
                }
    }

    private func refresh() {
        let current = identity
        defer { presentedIdentity = current }
        guard current.isAuthorized, let serverAuthorizationID = current.serverAuthorizationID,
              !model.snapshot.isEmpty else {
            visible = .empty
            return
        }
        do {
            let configuration = try LiveTVSourceStorage.approvalAwareStore(
                profileID: profileID, namespace: namespace
            ).load()
            let authorization = try LiveTVSourceApprovalStore(
                profileID: profileID, namespace: namespace
            ).authorization(context: LiveTVSourceApprovalContext(profiles: profiles), configuration: configuration)
            visible = HomeLiveTVRuntime.visibleSnapshot(
                cached: model.snapshot, profileID: profileID,
                serverAuthorizationID: serverAuthorizationID,
                configuration: configuration, authorization: authorization,
                preferences: try LiveTVPreferencesStore(namespace: namespace).load()
            )
        } catch {
            visible = .empty
            model.cancelRequest()
        }
    }
}

public extension View {
    func homeLiveTVScope(
        profileID: String, namespace: String?, accounts: AccountsProvidersModel,
        isAuthorized: @escaping @MainActor () -> Bool,
        navigate: @escaping @MainActor () -> Bool
    ) -> some View {
        modifier(HomeLiveTVScope(
            profileID: profileID, namespace: namespace, accounts: accounts,
            isAuthorized: isAuthorized, navigate: navigate
        ))
    }
}
#endif
