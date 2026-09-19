import CoreModels
import CoreNetworking

@MainActor
public final class FamilyGuidanceService: FamilyGuidanceLoading {
    private let accounts: AccountsProvidersModel
    private let profiles: ProfilesModel
    private let plexHome: PlexHomeUsersModel

    public init(accounts: AccountsProvidersModel, profiles: ProfilesModel, plexHome: PlexHomeUsersModel) {
        self.accounts = accounts
        self.profiles = profiles
        self.plexHome = plexHome
    }

    public var contextID: String {
        let revisions = accounts.accounts.filter { accounts.activeAccountIDs.contains($0.id) }
            .map { "\($0.id):\(accounts.credentialRevision($0).rawValue)" }.sorted().joined(separator: "|")
        return "\(profiles.activeProfileID)|\(plexHome.plexIdentityGeneration)|\(revisions)"
    }

    public func loadFamilyGuidance(for item: MediaItem) async throws -> FamilyGuidanceAvailability {
        guard let accountID = item.sourceAccountID,
              accounts.activeAccountIDs.contains(accountID),
              let provider = accounts.provider(forAccountID: accountID) else {
            PlozzLog.app.error("Family guidance requested without an active source account")
            throw AppError.unauthorized
        }
        guard let guidanceProvider = provider as? any FamilyGuidanceProviding else { return .unavailable }
        let identity = contextID
        let homeUser = profiles.activeProfile.homeUserBinding(forPlexAccount: accountID)
        let cloudToken = plexHome.discoverToken(for: accountID)
        if provider.kind == .plex, homeUser != nil, cloudToken == nil {
            PlozzLog.app.info("Family guidance is waiting for the Plex Home account credential")
            throw AppError.unauthorized
        }
        let result = try await guidanceProvider.familyGuidance(for: item, accountToken: cloudToken)
        try Task.checkCancellation()
        guard identity == contextID,
              accounts.activeAccountIDs.contains(accountID),
              accounts.tokenResolver(accountID) == provider.session.accessToken,
              plexHome.discoverToken(for: accountID) == cloudToken else {
            throw CancellationError()
        }
        return result
    }
}
