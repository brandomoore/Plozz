import CoreModels
import CoreNetworking
import FeatureAuthCore
import Foundation
import ProviderJellyfin
import SeerService

@MainActor
public enum SeerProfileAuthentication {
    public static func configure(
        service: SeerService, profiles: ProfilesModel,
        accounts: AccountsProvidersModel, plex: PlexHomeUsersModel
    ) {
        service.localDiscoveryHosts = { [weak accounts, weak profiles] in
            guard let accounts, let profiles else { return [] }
            let allowed = Set(accounts.activeAccountIDs(forProfile: profiles.activeProfileID))
            return accounts.accounts.filter { allowed.contains($0.id) }.compactMap(\.server.baseURL.host)
        }
        service.plexSignIn = { [weak profiles, weak accounts] url, showURL in
            guard let profiles, let accounts else { throw CancellationError() }
            let profileID = profiles.activeProfileID
            let plex = PlexAuthService(deviceID: accounts.deviceID)
            let challenge = try await plex.begin(strong: true)
            guard profiles.activeProfileID == profileID else { throw CancellationError() }
            showURL(plex.authorizationURL(for: challenge))
            let token = try await plex.awaitLink(for: challenge)
            guard profiles.activeProfileID == profileID else { throw CancellationError() }
            try Task.checkCancellation()
            let result = try await SeerAuthentication(baseURL: url).plex(token: token)
            guard profiles.activeProfileID == profileID else { throw CancellationError() }
            return result
        }
        service.embyUsernames = { [weak profiles, weak accounts] in
            guard let profiles, let accounts else { return [] }
            let allowed = Set(accounts.activeAccountIDs(forProfile: profiles.activeProfileID))
            return accounts.accounts.filter {
                allowed.contains($0.id) && $0.server.provider == .emby
            }.map(\.userName)
        }
        service.loginOptions = { [weak profiles, weak accounts, weak plex] in
            guard let profiles, let accounts, let plex else { return [] }
            // Credentials are deliberately unobserved; refresh choices when their identity becomes ready.
            _ = plex.plexIdentityGeneration
            let profile = profiles.activeProfile
            let allowed = Set(accounts.activeAccountIDs(forProfile: profile.id))
            return accounts.accounts.compactMap { account in
                guard allowed.contains(account.id),
                      account.server.provider == .jellyfin || account.server.provider == .plex else { return nil }
                if account.server.provider == .plex,
                   !plex.hasResolvedWatchMutationIdentity(forAccountID: account.id) { return nil }
                let revision = accounts.credentialRevision(account)
                let name = profile.homeUserBinding(forPlexAccount: account.id)?.name ?? account.userName
                return SeerLoginOption(id: account.id, name: name, mediaServerType: account.server.provider == .plex ? 1 : 2) { url in
                    @MainActor @Sendable func requireCurrent() throws {
                        guard profiles.activeProfileID == profile.id,
                              Set(accounts.activeAccountIDs(forProfile: profile.id)).contains(account.id),
                              let current = accounts.accounts.first(where: { $0.id == account.id }),
                              current.connectionScopeKey == account.connectionScopeKey,
                              accounts.credentialRevision(current) == revision else { throw CancellationError() }
                        try Task.checkCancellation()
                    }
                    try requireCurrent()
                    let auth = SeerAuthentication(baseURL: url)
                    let result: SeerAuthenticatedAccount
                    let expectedID: String
                    if account.server.provider == .plex {
                        let token = try await plex.resolveCloudToken(for: account, expectedRevision: revision)
                        try requireCurrent()
                        if profile.homeUserBinding(forPlexAccount: account.id) != nil, token == nil { throw AppError.unauthorized }
                        guard let token = token ?? accounts.accountStore.token(for: account.id) else { throw AppError.unauthorized }
                        expectedID = profile.homeUserBinding(forPlexAccount: account.id)?.homeUserID ?? account.userID
                        result = try await auth.plex(token: token)
                    } else {
                        guard let token = accounts.accountStore.token(for: account.id) else { throw AppError.unauthorized }
                        expectedID = account.userID
                        let authorization = JellyfinDeviceProfile(deviceID: accounts.deviceID)
                            .authorizationHeaderValue(token: token)
                        result = try await auth.jellyfin { code in
                            try await MainActor.run { try requireCurrent() }
                            let endpoint = Endpoint(
                                method: .post, path: "/QuickConnect/Authorize",
                                queryItems: [URLQueryItem(name: "code", value: code)],
                                headers: ["Authorization": authorization], redirectPolicy: .sameOrigin,
                                allowsAutomaticAddressRetry: false
                            )
                            let approved = try await SeerAuthentication.makeHTTPClient().decode(
                                Bool.self, from: endpoint, baseURL: account.server.baseURL
                            )
                            guard approved else { throw AppError.unauthorized }
                            try await MainActor.run { try requireCurrent() }
                        }
                    }
                    try requireCurrent()
                    guard result.mediaUserID?.replacingOccurrences(of: "-", with: "").lowercased()
                            == expectedID.replacingOccurrences(of: "-", with: "").lowercased() else { throw AppError.unauthorized }
                    return result
                }
            }
        }
        service.suggestedAddresses = { [weak profiles, weak accounts] in
            guard let profiles, let accounts else { throw CancellationError() }
            let profileID = profiles.activeProfileID
            let allowed = Set(accounts.activeAccountIDs(forProfile: profileID))
            var urls: [URL] = []
            for account in accounts.accounts where allowed.contains(account.id) && account.server.provider == .jellyfin {
                guard let token = accounts.accountStore.token(for: account.id) else { continue }
                let authorization = JellyfinDeviceProfile(deviceID: accounts.deviceID)
                    .authorizationHeaderValue(token: token)
                let endpoint = Endpoint(
                    path: "/Streamyfin/config", headers: ["Authorization": authorization],
                    redirectPolicy: .sameOrigin, allowsAutomaticAddressRetry: false
                )
                let (data, response) = try await SeerAuthentication.makeHTTPClient().sendRaw(endpoint, baseURL: account.server.baseURL)
                guard profiles.activeProfileID == profileID else { throw CancellationError() }
                if response.statusCode == 404 { continue }
                guard response.statusCode == 200 else { throw AppError.invalidResponse }
                struct Plugin: Decodable {
                    struct Settings: Decodable {
                        struct Value: Decodable { var value: String? }
                        var seerrServerUrl: Value?
                    }
                    var settings: Settings?
                }
                let plugin = try JSONDecoder().decode(Plugin.self, from: data)
                if let raw = plugin.settings?.seerrServerUrl?.value,
                   let url = SeerConfig.normalizedBaseURL(from: raw),
                   SeerServerIdentity(baseURL: url) != nil, !urls.contains(url) { urls.append(url) }
            }
            return urls
        }
    }
}
