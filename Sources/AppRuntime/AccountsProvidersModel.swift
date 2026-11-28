import Foundation
import Observation
import CoreModels
import CoreNetworking
import MediaTransportCore
import FeatureAuthCore
import CryptoKit
import FeatureLiveTVCore
import CoreSecureStore
import CoreUI

/// The accounts + providers hub, extracted from `AppState`.
///
/// Owns the multi-account core: the persisted `AccountPersisting` store, the
/// `ProviderRegistry`, the signed-in `accounts` and the active-account subset,
/// and every provider-resolution accessor (`provider(forAccountID:)`,
/// `homeAccounts`, `resolvedActiveAccounts`, …). This is the dependency HUB the
/// Plex-home-user, media-share, profile-flow, and household facets sit downstream
/// of, so it's extracted first and exposes a stable typed interface rather than
/// throwaway closures.
///
/// It depends OUTWARD only through narrow injected seams so the hub never reaches
/// back into the domains that will later be split out of `AppState`:
///  - `tokenResolver` — the effective auth token for an account (Plex Home-user
///    override aware). Wired by `AppState` today; becomes the Plex-home-user
///    facet's responsibility in a later batch.
///  - `credentialRevision` — the effective credential revision (override aware).
///  - `onActiveAccountsChanged` — fired after `reloadAccounts` recomputes the
///    active set, so the media-share runtime can update its preferred-account
///    keys. Keeps the media-share concern out of the hub.
///
/// Kept `@MainActor @Observable` so `accounts` / `activeAccountIDs` observation is
/// identical to when they lived on `AppState`.
@MainActor
@Observable
public final class AccountsProvidersModel {
    @ObservationIgnored public var onLocalAccountAuthentication: (String) -> Void = { _ in }
    /// All signed-in accounts, in stable order.
    public private(set) var accounts: [Account] = []
    /// Whether `accounts` reflects what is on disk yet. `false` until the first
    /// `reloadAccounts()` completes: consumers that would prune durable state on an
    /// empty list (Home's cached snapshot is the first) must wait for this, or they
    /// throw away a perfectly good snapshot during launch, before the account store
    /// has been read, and the page has to re-fetch everything.
    public private(set) var hasResolvedAccounts = false
    private var publishedAccountIDs: Set<String> = []
    private var publishedProfileID: String?
    private var publishedSelection: [String]?
    /// Do not reuse the previous profile's grants between a switch or failed
    /// write and the account hub's next publication.
    public var activeAccountIDs: Set<String> {
        guard !accountSelectionIsUnavailable, publishedProfileID == profilesModel.activeProfileID,
              publishedSelection == profilesModel.storedActiveAccountIDs(for: profilesModel.activeProfileID)
        else { return [] }
        return publishedAccountIDs
    }
    /// Snapshot on reload so rendering picker badges never reads the Keychain.
    @ObservationIgnored private var lastReloadedViewer: AutomaticSignInStore.Session.ProfileAccess?

    /// An explicit selection has no locally available accounts, including when
    /// its selected accounts were removed. Never substitute an excluded account.
    public private(set) var watchesNothingByChoice = false
    /// Non-nil replaces, never supplements, online providers while browsing downloads.
    public var localProviders: [String: any MediaProvider]?

    /// The persisted multi-account store (token per account in the Keychain).
    @ObservationIgnored
    public let accountStore: AccountPersisting
    /// Resolves the right `MediaProvider` per account, with a per-account cache.
    @ObservationIgnored
    public let registry: ProviderRegistry

    /// The household's profiles + active selection. Shared reference (the same
    /// instance `AppState` holds); read for the active-set resolution and the
    /// media-share local-media context.
    @ObservationIgnored
    private let profilesModel: ProfilesModel
    @ObservationIgnored
    private var liveTVAuthorizationCache: [String: (fingerprint: String, digest: String)] = [:]
    @ObservationIgnored private var sourceDiagnosticObserver: ObservationLease?
    @ObservationIgnored private var historySyncControllers: [String: (activation: String, controller: TrackerHistorySyncController)] = [:]
    public private(set) var trackerHistorySyncIsForeground = false

    /// The auth token to use for an account id, preferring an in-memory Plex
    /// Home-user override over the account's stored (admin) token. Injected so the
    /// hub doesn't own Plex-home-user state.
    @ObservationIgnored
    public var tokenResolver: @MainActor (String) -> String? = { _ in nil }
    /// The effective credential revision for an account (Plex override aware).
    @ObservationIgnored
    public var credentialRevision: @MainActor (Account) -> CredentialRevision = { $0.credentialRevision }
    @ObservationIgnored
    public var cloudTokenResolver: @MainActor (Account, CredentialRevision) async throws -> String? = { _, _ in nil }
    /// Fired after `reloadAccounts` recomputes the active set, with the resolved
    /// active ids and the full account list, so the media-share runtime can update
    /// its preferred-account keys without the hub knowing about media shares.
    @ObservationIgnored
    public var onActiveAccountsChanged: @MainActor (Set<String>, [Account]) -> Void = { _, _ in }
    /// Fired at the START of every `reloadAccounts`, before anything is
    /// recomputed, so caches keyed on the account set are dropped rather than
    /// serving a stale answer. Separate from `onActiveAccountsChanged` (which
    /// fires at the end, after the new set is known) because an invalidation must
    /// happen even if the recompute below returns early.
    public var onAccountsInvalidated: @MainActor () -> Void = {}
    @ObservationIgnored private let removedAccountIDs: () -> Set<String>

    public init(
        accountStore: AccountPersisting,
        registry: ProviderRegistry,
        profilesModel: ProfilesModel,
        removedAccountIDs: @escaping () -> Set<String> = { RemovedAccountsStore().removedIDs }
    ) {
        self.accountStore = accountStore
        self.registry = registry
        self.profilesModel = profilesModel
        self.removedAccountIDs = removedAccountIDs
        try? prepareSourceRegistration()
        let token = NotificationCenter.default.addObserver(
            forName: LiveTVSourceDiagnostics.snapshotRequested, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureLiveTVSourceDiagnostics() }
        }
        sourceDiagnosticObserver = ObservationLease(center: .default, token: token)
    }

    /// This device's stable client identifier.
    public var deviceID: String { accountStore.deviceID() }

    public func configureAuthenticatedArtwork() {
        ArtworkSession.authenticatedLoader = { [weak self] reference in
            guard let self else { throw AppError.cancelled }
            let profileID = self.profilesModel.activeProfileID
            @MainActor func authorizedProvider() throws -> any AuthenticatedArtworkProviding {
                guard self.localProviders == nil, !self.accountSelectionIsUnavailable,
                      self.profilesModel.activeProfileID == profileID,
                      self.homeAccounts.contains(where: {
                          $0.account.id == reference.accountID
                            && self.credentialRevision($0.account) == reference.credentialRevision
                      }),
                      let provider = self.provider(forAccountID: reference.accountID)
                        as? any AuthenticatedArtworkProviding else { throw AppError.unauthorized }
                return provider
            }
            let bytes = try await authorizedProvider().artworkData(for: reference)
            try Task.checkCancellation()
            _ = try authorizedProvider()
            return bytes
        }
    }

    public func downloadUserID(for accountID: String, profileID: String) -> String? {
        guard profilesModel.activeProfileID == profileID, activeAccountIDs.contains(accountID),
              let account = accounts.first(where: { $0.id == accountID }) else { return nil }
        return WatchMutationServerScope.AccountIdentity(
            account: account, profile: profilesModel.activeProfile
        ).downloadUserID
    }

    public func makeAccountReauthentication(
        account: Account, isAuthorized: @escaping () -> Bool, onComplete: @escaping () -> Void
    ) -> AccountReauthenticationModel {
        let profile = AutomaticSignInStore.Session.ProfileAccess(profilesModel.activeProfile)
        let generation = profilesModel.selectionGeneration
        return AccountReauthenticationModel(
            account: account, deviceID: deviceID, store: accountStore,
            isAuthorized: { [weak self] in
                guard let self else { return false }
                return generation == self.profilesModel.selectionGeneration
                    && profile == .init(self.profilesModel.activeProfile) && isAuthorized()
                    && (try? self.profilesModel.confirmedSourceMembership(for: profile.id).contains(account.id)) == true
            },
            onComplete: { [weak self] in
                guard let self else { return }
                self.onLocalAccountAuthentication(account.id)
                self.registry.invalidate(accountID: account.id)
                self.reloadAccounts()
                onComplete()
            }
        )
    }

    private var accountSelectionIsUnavailable: Bool {
        !profilesModel.sourceMembershipsPrepared ||
            profilesModel.unconfirmedAccountSelectionProfileIDs.contains(profilesModel.activeProfileID)
    }

    /// Sync may record a question before the account's provider is known.
    /// Only locally present, active Plex accounts can require an identity choice.
    public var activeProfileAwaitsIdentity: Bool {
        profilesModel.activeProfile.awaitsIdentity(
            amongAccounts: accounts.lazy.filter {
                self.activeAccountIDs.contains($0.id) && $0.server.provider == .plex
            }.map(\.id)
        )
    }

    public var liveTVServerChoices: [LiveTVServerChoice] {
        // Listing connected servers must not resolve credentials during a render.
        // The resolver verifies access when the user checks or imports a server.
        guard !accountSelectionIsUnavailable else { return [] }
        return accounts.compactMap { account in
            guard activeAccountIDs.contains(account.id),
                  let kind = Self.liveTVKind(account.server.provider) else { return nil }
            let name = account.server.name.isEmpty
                ? (account.server.baseURL.host ?? kind.rawValue)
                : account.server.name
            return LiveTVServerChoice(
                id: account.id, name: name, userName: account.userName, kind: kind
            )
        }
    }

    public var liveTVAuthorizationID: String {
        let identities = accounts.filter { activeAccountIDs.contains($0.id) }
            .map(liveTVAuthorizationID(for:)).sorted()
        return profilesModel.activeProfileID + (localProviders == nil ? "|online|" : "|offline|")
            + identities.joined(separator: "|")
    }

    /// Stable watch-state ownership. Unlike the live authorization fingerprint,
    /// this survives token rotation and process restarts.
    public var watchMutationServerScope: WatchMutationServerScope {
        let primaryID = primaryActiveAccount?.id
        return WatchMutationServerScope(
            profile: profilesModel.activeProfile,
            accounts: accounts.filter { activeAccountIDs.contains($0.id) || $0.id == primaryID }
        )
    }

    public func requireWatchMutationServerScope(
        _ scope: WatchMutationServerScope,
        isPlexIdentityResolved: (String) -> Bool
    ) throws {
        guard profilesModel.activeProfileID == scope.profileID else {
            throw WatchMutationServerScopeError.unavailable
        }
        let current = watchMutationServerScope
        guard scope.accounts.allSatisfy({ expected in
            current.accounts.contains(expected)
                && (expected.providerKind != .plex || isPlexIdentityResolved(expected.accountID))
        }) else {
            throw WatchMutationServerScopeError.unavailable
        }
    }

    public func makeTrackerHistoryImportSession(
        tracker: any TrackerHistoryReading, reconciler: WatchStateReconciler,
        syncStore: DurableLocalStateStore? = nil,
        index: @escaping @MainActor @Sendable () -> IdentityIndexSnapshot,
        isPlexIdentityResolved: @escaping @MainActor @Sendable (String) -> Bool,
        isAuthorized: @escaping @MainActor @Sendable () -> Bool
    ) -> TrackerHistoryImportSession {
        let connection = tracker.historyConnectionID
        let syncTracker = tracker as? any TrackerHistorySyncReading
        let activation = syncTracker?.historyActivationID
        let session = makeTrackerHistoryImportSession(
            purpose: .enrollment, reconciler: reconciler,
            readSnapshot: {
                guard let connection else { throw TrackerHistoryError.scopeChanged }
                return try await tracker.historySnapshot(expectedConnectionID: connection)
            },
            index: index, isPlexIdentityResolved: isPlexIdentityResolved,
            isAuthorized: {
                isAuthorized() && connection != nil && tracker.historyConnectionID == connection
                    && (syncTracker == nil || (activation != nil && syncTracker?.historyActivationID == activation))
            }
        )
        if let syncStore, let tracker = syncTracker, let activation,
           let identity = tracker.historySyncIdentity, identity.trackerID == tracker.historySyncTrackerID,
           (tracker.historySyncNamespace ?? ProfileStore.defaultProfileID) == watchMutationServerScope.profileID {
            bindTrackerHistorySync(tracker, store: syncStore)
            let scope = watchMutationServerScope
            let controller: TrackerHistorySyncController
            if let entry = historySyncControllers[identity.trackerID], entry.activation == activation,
               entry.controller.identity == identity, entry.controller.contextScope == scope,
               entry.controller.supportedCategories == tracker.historySyncCategories {
                controller = entry.controller
            } else {
                historySyncControllers[identity.trackerID]?.controller.stop()
                controller = TrackerHistorySyncController(
                    identity: identity, scope: scope, store: syncStore,
                    supportedCategories: tracker.historySyncCategories,
                    isAuthorized: { [weak self, weak tracker] in
                        guard let self else { return false }
                        return self.trackerHistorySyncIsForeground && isAuthorized()
                            && !self.pendingHistorySyncRevocations.contains(.init(
                                profileID: scope.profileID, trackerID: identity.trackerID
                            ))
                            && tracker?.historyActivationID == activation && tracker?.historySyncIdentity == identity
                            && self.watchMutationServerScope == scope
                            && self.isCurrentWatchMutationServerScope(scope, isPlexIdentityResolved: isPlexIdentityResolved)
                    },
                    makeSession: { [weak self, weak tracker] selectedScope, permitsDelivery in
                        guard let self else { throw TrackerHistoryError.scopeChanged }
                        // Enrollment rechecks the full profile; a delivery session
                        // may only compare and apply to selected media shares.
                        let sharesOnly = !selectedScope.accounts.isEmpty
                            && selectedScope.accounts.allSatisfy { $0.providerKind == .mediaShare }
                        return self.makeTrackerHistoryImportSession(
                            purpose: sharesOnly ? .transfer : .enrollment, reconciler: reconciler, scope: selectedScope,
                            readSnapshot: {
                                guard let tracker, let connection = tracker.historyConnectionID else {
                                    throw TrackerHistoryError.scopeChanged
                                }
                                return try await tracker.historySnapshot(expectedConnectionID: connection)
                            },
                            index: index, isPlexIdentityResolved: isPlexIdentityResolved,
                            isAuthorized: permitsDelivery
                        )
                    }
                )
                historySyncControllers[identity.trackerID] = (activation, controller)
            }
            session.ongoingSync = controller
        }
        return session
    }

    private struct HistorySyncRevocationScope: Hashable {
        let profileID: String
        let trackerID: String
    }

    private var pendingHistorySyncRevocations: Set<HistorySyncRevocationScope> = []

    public func bindTrackerHistorySync(_ tracker: any TrackerHistorySyncReading, store: DurableLocalStateStore?) {
        tracker.onHistorySyncDisconnect = { [weak self, weak tracker] in
            guard let self, let tracker else { throw TrackerHistoryError.scopeChanged }
            let scope = HistorySyncRevocationScope(
                profileID: tracker.historySyncNamespace ?? ProfileStore.defaultProfileID,
                trackerID: tracker.historySyncTrackerID
            )
            self.pendingHistorySyncRevocations.insert(scope)
            do {
                guard let store else { throw TrackerHistorySyncError.revocationFailed }
                if let controller = self.historySyncControllers[scope.trackerID]?.controller,
                   controller.contextScope.profileID == scope.profileID {
                    controller.disable()
                    if let error = controller.error { throw error }
                } else {
                    try TrackerHistorySyncController.revokePermission(
                        store: store, profileID: scope.profileID, trackerID: scope.trackerID
                    )
                }
                self.pendingHistorySyncRevocations.remove(scope)
            } catch {
                throw TrackerHistorySyncError.revocationFailed
            }
        }
    }

    public func stopTrackerHistorySync() {
        for entry in historySyncControllers.values { entry.controller.stop() }
    }

    public func setTrackerHistorySyncForeground(_ foreground: Bool) {
        trackerHistorySyncIsForeground = foreground
        if !foreground { stopTrackerHistorySync() }
    }

    private func makeTrackerHistoryImportSession(
        purpose: TrackerHistoryImportSession.Purpose, reconciler: WatchStateReconciler,
        scope selectedScope: WatchMutationServerScope? = nil,
        readSnapshot: @escaping @MainActor @Sendable () async throws -> TrackerHistorySnapshot,
        index: @escaping @MainActor @Sendable () -> IdentityIndexSnapshot,
        isPlexIdentityResolved: @escaping @MainActor @Sendable (String) -> Bool,
        isAuthorized: @escaping @MainActor @Sendable () -> Bool
    ) -> TrackerHistoryImportSession {
        let scope = selectedScope ?? watchMutationServerScope
        let contextScope = watchMutationServerScope
        let destinations = scope.accounts.compactMap { identity -> TrackerHistoryImportSession.Destination? in
            guard let account = accounts.first(where: { $0.id == identity.accountID }) else { return nil }
            let homeName = profilesModel.activeProfile.homeUserBinding(forPlexAccount: account.id)?.name
            return .init(account: account, userName: homeName)
        }
        let current: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self, isAuthorized(), self.watchMutationServerScope == contextScope else { return false }
            return self.isCurrentWatchMutationServerScope(scope, isPlexIdentityResolved: isPlexIdentityResolved)
        }
        return TrackerHistoryImportSession(
            purpose: purpose, scope: scope, destinations: destinations, reconciler: reconciler, readSnapshot: readSnapshot,
            index: index,
            resolveProvider: { [weak self] accountID in
                guard let self, current(), scope.accounts.contains(where: { $0.accountID == accountID }),
                      let provider = self.provider(forAccountID: accountID) else { throw TrackerHistoryError.scopeChanged }
                return provider
            },
            isAuthorized: current
        )
    }

    public func isCurrentWatchMutationServerScope(
        _ scope: WatchMutationServerScope?,
        isPlexIdentityResolved: (String) -> Bool
    ) -> Bool {
        guard let scope else { return true }
        do {
            try requireWatchMutationServerScope(scope, isPlexIdentityResolved: isPlexIdentityResolved)
            return true
        } catch {
            return false
        }
    }

    /// Validate and resolve without a suspension between them. The returned
    /// provider therefore cannot belong to a replacement viewer, even if a
    /// switch happens while the caller awaits this main-actor operation.
    public func provider(
        forWatchMutationAccountID accountID: String,
        isPlexIdentityResolved: (String) -> Bool
    ) -> (any MediaProvider)? {
        if let scope = WatchMutationDeliveryAuthorization.current?.serverScope {
            guard scope.accounts.contains(where: { $0.accountID == accountID }) else { return nil }
            do {
                try requireWatchMutationServerScope(scope, isPlexIdentityResolved: isPlexIdentityResolved)
            } catch {
                return nil
            }
        }
        return provider(forAccountID: accountID)
    }

    public func liveTVProviderResolver() -> LiveTVServerProviderResolver {
        let expectedProfile = profilesModel.activeProfileID
        return { [weak self] accountID in
            guard let self, self.profilesModel.activeProfileID == expectedProfile,
                  !self.accountSelectionIsUnavailable,
                  self.activeAccountIDs.contains(accountID),
                  let account = self.accounts.first(where: { $0.id == accountID }),
                  let kind = Self.liveTVKind(account.server.provider),
                  let provider = self.provider(forAccountID: accountID) as? any ServerLiveTVProviding
            else { return nil }
            return LiveTVAuthorizedServerProvider(
                accountID: accountID, authorizationID: self.liveTVAuthorizationID(for: account),
                kind: kind, provider: provider, viewerScopeID: self.liveTVViewerScopeID(for: account)
            )
        }
    }

    private func liveTVViewerScopeID(for account: Account) -> String? {
        let identity = WatchMutationServerScope.AccountIdentity(account: account, profile: profilesModel.activeProfile)
        guard !identity.accountID.isEmpty, !identity.serverID.isEmpty, !identity.userID.isEmpty,
              identity.plexHomeUserID?.isEmpty != true else { return nil }
        let fields = [profilesModel.activeProfileID, identity.accountID, identity.downloadUserID]
        let fingerprint = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func liveTVAuthorizationID(for account: Account) -> String {
        let fields = [
            profilesModel.activeProfileID, account.id, account.server.id,
            account.server.provider.rawValue, account.server.baseURL.absoluteString,
            account.userID, account.deviceID, credentialRevision(account).rawValue.uuidString,
            liveTVViewerScopeID(for: account) ?? "unscoped"
        ] + (account.server.connectionURLs ?? []).map(\.absoluteString)
        let fingerprint = fields.map { "\($0.utf8.count):\($0)" }.joined()
        if let cached = liveTVAuthorizationCache[account.id],
           cached.fingerprint.utf8.elementsEqual(fingerprint.utf8) {
            return cached.digest
        }
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        liveTVAuthorizationCache[account.id] = (fingerprint, digest)
        return digest
    }

    private static func liveTVKind(_ kind: ProviderKind) -> LiveTVPrototypeSource? {
        switch kind {
        case .plex: .plex
        case .jellyfin: .jellyfin
        case .emby: .emby
        case .iptv: .iptv
        case .mediaShare, .silo, .subsonic: nil
        }
    }

    /// The provider for the primary active account — the single-provider Home in
    /// this branch. `nil` when not signed in.
    public var primaryProvider: (any MediaProvider)? {
        if let localProviders {
            return primaryActiveAccount.flatMap { localProviders[$0.id] }
        }
        guard let account = primaryActiveAccount,
              let token = tokenResolver(account.id) else { return nil }
        return resolveProvider(for: providerResolutionContext(for: account, token: token))
    }

    /// The active account that drives the current single-provider UI.
    public var primaryActiveAccount: Account? {
        guard !accountSelectionIsUnavailable else { return nil }
        return accounts.first { activeAccountIDs.contains($0.id) }
    }

    /// The active accounts paired with their resolved providers. Multi-account
    /// Home/Search fan out over this list (one provider call per account,
    /// merged by the view model). Tokens are resolved on demand and never
    /// stored on the value.
    public var resolvedActiveAccounts: [ResolvedAccount] {
        guard !accountSelectionIsUnavailable else { return [] }
        if let localProviders {
            return accounts.compactMap { account in
                guard activeAccountIDs.contains(account.id), let provider = localProviders[account.id] else { return nil }
                return resolvedAccount(account, provider: provider)
            }
        }
        return accounts.compactMap { account in
            guard activeAccountIDs.contains(account.id),
                  let token = tokenResolver(account.id),
                  let provider = resolveProvider(
                      for: providerResolutionContext(for: account, token: token)
                  )
            else { return nil }
            return resolvedAccount(account, provider: provider)
        }
    }

    /// Resolves specific account ids into `ResolvedAccount`s for the onboarding
    /// "choose your libraries" step (which fans a library-listing call out over
    /// the just-added accounts). Tokens are resolved on demand.
    public func resolvedAccounts(withIDs ids: [String]) -> [ResolvedAccount] {
        guard !accountSelectionIsUnavailable else { return [] }
        if let localProviders {
            return accounts.compactMap { account in
                guard ids.contains(account.id), activeAccountIDs.contains(account.id),
                      let provider = localProviders[account.id] else { return nil }
                return resolvedAccount(account, provider: provider)
            }
        }
        return ids.compactMap { id in
            guard activeAccountIDs.contains(id), let account = accounts.first(where: { $0.id == id }),
                  let token = tokenResolver(account.id),
                  let provider = resolveProvider(
                      for: providerResolutionContext(for: account, token: token)
                  )
            else { return nil }
            return resolvedAccount(account, provider: provider)
        }
    }

    /// Home and Search resolve exactly the active profile's available sources.
    public var homeAccounts: [ResolvedAccount] { resolvedActiveAccounts }

    /// Configured sources for navigation, not authorization to access their data.
    /// Pending credentials must not turn a media profile into a Live-TV-only one.
    public var navigationAccounts: [Account] {
        let ids = activeAccountIDs
        return accounts.filter { ids.contains($0.id) }
    }

    private func resolvedAccount(_ account: Account, provider: any MediaProvider) -> ResolvedAccount {
        ResolvedAccount(
            account: account, provider: provider,
            plexHomeUserID: account.server.provider == .plex
                ? profilesModel.activeProfile.homeUserBinding(forPlexAccount: account.id)?.homeUserID : nil,
            credentialRevision: credentialRevision(account)
        )
    }

    /// Resolves the provider for a specific account id — used to route a tapped
    /// library/item from the merged Home back to its owning provider. Tokens are
    /// resolved on demand and never stored on the value.
    public func provider(forAccountID id: String) -> (any MediaProvider)? {
        guard activeAccountIDs.contains(id), !accountSelectionIsUnavailable else { return nil }
        if let localProviders {
            return localProviders[id]
        }
        guard let account = accounts.first(where: { $0.id == id }),
              let token = tokenResolver(account.id)
        else { return nil }
        return resolveProvider(for: providerResolutionContext(for: account, token: token))
    }

    /// Builds the provider-resolution context for an account + resolved token.
    public func providerResolutionContext(
        for account: Account,
        token: String
    ) -> ProviderResolutionContext {
        let localMediaContext = [.mediaShare, .iptv, .plex].contains(account.server.provider)
            ? LocalMediaContext(
                accountID: account.id,
                profileID: profilesModel.activeProfileID,
                profileNamespace: profilesModel.activeNamespace,
                serverUserID: account.server.provider == .plex
                    ? (profilesModel.activeProfile.homeUserBinding(forPlexAccount: account.id)?.homeUserID ?? account.userID)
                    : nil
            )
            : nil
        let revision = credentialRevision(account)
        let cloudTokenResolver: (@Sendable () async throws -> String?)?
        if account.server.provider == .plex {
            cloudTokenResolver = { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.cloudTokenResolver(account, revision)
            }
        } else {
            cloudTokenResolver = nil
        }
        return ProviderResolutionContext(
            session: account.session(token: token),
            accountID: account.id,
            credentialRevision: revision,
            localMediaContext: localMediaContext,
            cloudTokenResolver: cloudTokenResolver
        )
    }

    /// Resolves a provider through the registry, logging any resolution error
    /// (unregistered provider, missing/stale credential revision, local-media
    /// context mismatch) instead of silently swallowing it. Returns `nil` on
    /// failure exactly as the previous `try?` did, so the observable resolution
    /// behavior is unchanged — the only new effect is a diagnostic log line so
    /// config/state bugs aren't invisible.
    private func resolveProvider(for context: ProviderResolutionContext) -> (any MediaProvider)? {
        do {
            return try registry.provider(for: context)
        } catch {
            PlozzLog.app.error("Provider resolution failed for account \(context.accountID): \(error)")
            return nil
        }
    }

    /// The active account ids for a specific profile, filtered to accounts that
    /// are still signed in. Absent IDs are retained but never authorize another account.
    public func activeAccountIDs(forProfile id: String) -> [String] {
        guard profilesModel.sourceMembershipsPrepared else { return [] }
        let known = Set(accounts.map(\.id))
        return (profilesModel.storedActiveAccountIDs(for: id) ?? []).filter(known.contains)
    }

    /// A signed-out connection may be recoverable on another device, but its
    /// descriptor is not a discovery result and cannot be advertised to peers.
    public func scopedSetupDescriptors(_ candidates: [SyncedAccountDescriptor]) -> [SyncedAccountDescriptor] {
        guard !accountSelectionIsUnavailable else { return [] }
        let members = Set(profilesModel.storedActiveAccountIDs(for: profilesModel.activeProfileID) ?? [])
        return candidates.compactMap { candidate in
            guard members.contains(candidate.id) else { return nil }
            guard candidate.provider == .iptv else { return candidate }
            var display = candidate
            display.serverName = candidate.provider.displayName
            display.candidateBaseURLs = []
            display.userName = ""
            display.avatarURL = nil
            return display
        }
    }

    public func profileShowsPINLock(_ profile: Profile) -> Bool {
        let plexIDs = Set(accounts.filter { $0.server.provider == .plex }.map(\.id))
        return profile.showsPINLock(
            activePlexAccountIDs: Set(activeAccountIDs(forProfile: profile.id)).intersection(plexIDs)
        )
    }

    public func prepareSourceRegistration() throws {
        try profilesModel.prepareSourceMemberships {
            let legacy = try accountStore.legacySourceSelection()
            let removed = removedAccountIDs()
            return (legacy.active.filter { !removed.contains($0) }, legacy.playlists)
        }

    }

    public func connectedIPTVMode(accountID: String) throws -> IPTVCredential.Mode {
        guard activeAccountIDs.contains(accountID),
              accounts.contains(where: { $0.id == accountID && $0.server.provider == .iptv }),
              try profilesModel.confirmedSourceMembership(for: profilesModel.activeProfileID).contains(accountID),
              let token = accountStore.token(for: accountID) else { throw AppError.unauthorized }
        return try IPTVCredential.decode(token).mode
    }

    public func configureAuthenticatedHTTP(_ resolver: ManagedAuthenticatedHTTPResolver) {
        resolver.configure { [weak self] locator in
            guard let self, activeAccountIDs.contains(locator.accountID),
                  let published = accounts.first(where: { $0.id == locator.accountID }),
                  let account = accountStore.loadAccounts().first(where: { $0.id == locator.accountID }),
                  account.server.provider == locator.provider, published.server.provider == locator.provider,
                  account.userID == published.userID, account.server.id == published.server.id,
                  account.credentialRevision == published.credentialRevision,
                  credentialRevision(account) == locator.credentialRevision,
                  let token = tokenResolver(account.id), !token.isEmpty else {
                throw MediaTransportError.authentication(reason: "inactive authenticated HTTP identity")
            }
            // After an address edit, an old provider must not override the freshly saved origin.
            let provider = published.connectionScopeKey == account.connectionScopeKey
                ? self.provider(forAccountID: account.id) : nil
            let origin = provider as? any AuthenticatedHTTPOriginProviding
            guard account.server.provider != .plex || origin != nil else {
                throw MediaTransportError.unsupportedCapability("dynamic authenticated HTTP origin")
            }
            return ManagedAuthenticatedHTTPResolver.Context(
                provider: locator.provider, accountID: account.id, credentialRevision: locator.credentialRevision,
                baseURL: origin?.authenticatedHTTPOrigin ?? account.server.baseURL, token: token,
                resourceResolver: provider as? any ProviderHTTPResourceResolving, originProvider: origin,
                connectionScopeKey: "\(profilesModel.selectionGeneration)|\(profilesModel.activeProfileID)|\(account.connectionScopeKey)"
            )
        }
    }

    public func beginSourceAuthentication() throws {
        try prepareSourceRegistration()
        try profilesModel.confirmPersistedProfile(profilesModel.activeProfile)
        _ = try profilesModel.confirmedSourceMembership(for: profilesModel.activeProfileID)
    }

    /// Plex credentials stay staged until the Home identity flow commits its
    /// explicit targets. Every other provider joins only the initiating profile.
    public func connectAuthenticatedSource(_ account: Account) throws {
        guard account.server.provider != .plex else { return }
        try profilesModel.addSourceMemberships([account.id], for: profilesModel.activeProfileID)
    }

    public func registerMediaShare(
        _ prepared: PreparedMediaShareAccount, using service: MediaShareAccountConfigurationService
    ) throws {
        try beginSourceAuthentication()
        try service.persist(prepared)
        try connectAuthenticatedSource(prepared.account)
    }

    public func needsPlexConnectionDecision(for accountID: String) throws -> Bool {
        let roster = try profilesModel.confirmedSourceRoster()
        return try !roster.contains {
            if $0.homeUserBinding(forPlexAccount: accountID) != nil { return true }
            return try profilesModel.confirmedSourceMembership(for: $0.id).contains(accountID)
        }
    }

    public func beginsFirstRun(adding provider: ProviderKind) throws -> Bool {
        guard !profilesModel.firstRunProfileSetupComplete else { return false }
        if accounts.isEmpty { return true }
        // A failed or cancelled Plex Home decision leaves staged credentials,
        // not a configured viewer. Retrying must still complete first run.
        guard provider == .plex, accounts.allSatisfy({ $0.server.provider == .plex }),
              try profilesModel.confirmedSourceRoster().count == 1 else { return false }
        return try profilesModel.confirmedSourceMembership(for: profilesModel.activeProfileID).isEmpty
    }

    /// A URL manufactured as a fallback ID is not a verified server identity.
    /// Only offer a credential back to its original endpoint, never a lookalike
    /// host, a LAN advertisement, a playlist or an unverified redirect.
    public func savedSignIns(for verified: MediaServer) -> [Account] {
        guard verified.provider.usesMediaBrowserAPI, !verified.id.isEmpty,
              URL(string: verified.id)?.scheme == nil else { return [] }
        let authorized = Set(activeAccountIDs(forProfile: profilesModel.activeProfileID))
        return accounts.filter {
            authorized.contains($0.id) && $0.server.provider == verified.provider &&
            $0.server.id == verified.id && $0.server.baseURL == verified.baseURL &&
            !$0.userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            accountStore.token(for: $0.id)?.isEmpty == false
        }
    }

    public func confirmSavedSignIn(_ account: Account, for verified: MediaServer) throws {
        try profilesModel.confirmPersistedProfile(profilesModel.activeProfile)
        guard try profilesModel.confirmedSourceMembership(for: profilesModel.activeProfileID).contains(account.id),
              !removedAccountIDs().contains(account.id),
              savedSignIns(for: verified).contains(account),
              accountStore.loadAccounts().contains(account) else { throw AppError.unauthorized }
    }

    public func recoverablePlaylistAccountIDs(referencedBy configuration: LiveTVSourcesConfiguration) -> Set<String> {
        profilesModel.legacyPlaylistRecoveryIDs.intersection(configuration.servers.map(\.accountID))
            .intersection(accounts.filter { $0.server.provider == .iptv }.map(\.id))
    }

    public func recoverPlaylistAccount(
        _ id: String, referencedBy configuration: LiveTVSourcesConfiguration, for profileID: String
    ) throws {
        guard recoverablePlaylistAccountIDs(referencedBy: configuration).contains(id),
              accountStore.loadAccounts().contains(where: { $0.id == id && $0.server.provider == .iptv }),
              !removedAccountIDs().contains(id) else { throw AppError.unauthorized }
        try profilesModel.restoreLegacyPlaylistMembership(id, for: profileID)
        refreshActiveAccountSelection()
    }

    /// Reloads accounts from the store and recomputes the active set for the
    /// active profile. Reconciles the provider cache first, then fires
    /// `onActiveAccountsChanged` so the media-share runtime can update its
    /// preferred-account keys.
    public func reloadAccounts(updatingServerAddressesFor addressAccountID: String? = nil) {
        try? prepareSourceRegistration()
        profilesModel.retryUnconfirmedAccountSelections()
        liveTVAuthorizationCache = [:]
        let removed = removedAccountIDs()
        for account in accountStore.loadAccounts() where removed.contains(account.id) {
            do { try accountStore.remove(id: account.id) }
            catch { PlozzLog.auth.error("Household account removal is pending local credential storage recovery") }
        }
        // Receipt of a household revocation denies use even if Keychain deletion
        // must be retried on a later reload.
        let updated = accountStore.loadAccounts().filter { !removed.contains($0.id) }
        let viewer = AutomaticSignInStore.Session.ProfileAccess(profilesModel.activeProfile)
        let selectedIDs = Set(profilesModel.storedActiveAccountIDs(for: viewer.id) ?? [])
        if let addressAccountID,
           viewer == lastReloadedViewer, !accountSelectionIsUnavailable,
           activeAccountIDs == selectedIDs.intersection(updated.map(\.id)),
           let account = updated.first(where: { $0.id == addressAccountID }),
           accounts.map({ old in
               var expected = old
               if old.id == addressAccountID {
                   expected.server.alternateConnectionURLs = account.server.alternateConnectionURLs
               }
               return expected
           }) == updated {
            registry.updateServerAddresses(accountID: addressAccountID,
                                           alternatives: account.server.alternateConnectionURLs ?? [])
        } else {
            // Silo locators refer to grants owned by the instance that negotiated
            // them. An unchanged login must survive refreshes on either side of start.
            let retained = updated.compactMap { account -> ProviderResolutionContext? in
                guard account.server.provider == .silo, viewer == lastReloadedViewer,
                      localProviders == nil, !accountSelectionIsUnavailable,
                      activeAccountIDs.contains(account.id), selectedIDs.contains(account.id),
                      let token = tokenResolver(account.id), !token.isEmpty else { return nil }
                return providerResolutionContext(for: account, token: token)
            }
            registry.invalidateCache(preserving: retained)
        }
        lastReloadedViewer = viewer
        onAccountsInvalidated()
        accounts = updated
        hasResolvedAccounts = true
        publishActiveAccountSelection()
    }

    /// Membership edits do not change household credentials or unrelated
    /// providers. Retire only disabled sources, retaining other connections.
    public func refreshActiveAccountSelection() {
        profilesModel.retryUnconfirmedAccountSelections()
        let resolved = Set(activeAccountIDs(forProfile: profilesModel.activeProfileID))
        for id in publishedAccountIDs.subtracting(resolved) {
            registry.invalidate(accountID: id)
        }
        onAccountsInvalidated()
        publishActiveAccountSelection()
    }

    private func publishActiveAccountSelection() {
        let resolved = Set(activeAccountIDs(forProfile: profilesModel.activeProfileID))
        publishedProfileID = profilesModel.activeProfileID
        publishedSelection = profilesModel.storedActiveAccountIDs(for: profilesModel.activeProfileID)
        publishedAccountIDs = resolved
        watchesNothingByChoice = resolved.isEmpty
            && !accountSelectionIsUnavailable
            && profilesModel.storedActiveAccountIDs(for: profilesModel.activeProfileID) != nil
        recordLiveTVAccountState(.accountsReloaded)
        onActiveAccountsChanged(resolved, accounts)
    }

    private func recordLiveTVAccountState(_ event: LiveTVSourceDiagnostics.Event) {
        let profileID = profilesModel.activeProfileID
        let namespace = profilesModel.activeNamespace
        let selected = profilesModel.storedActiveAccountIDs(for: profileID)
        var identities: [LiveTVSourceDiagnostics.Identity: String] = [
            .profile: profileID, .namespace: namespace ?? "default"
        ]
        identities[.rootNamespaceOwner] = profilesModel.rootNamespaceOwnerID
        LiveTVSourceDiagnostics.shared.record(
            event, identities: identities,
            counts: [
                .accounts: accounts.count, .activeAccounts: activeAccountIDs.count,
                .selectedAccounts: selected?.count ?? 0,
                .iptvAccounts: accounts.filter { $0.server.provider == .iptv }.count
            ],
            flags: [
                .selectionUnavailable: accountSelectionIsUnavailable,
                .explicitSelection: selected != nil,
                .identityPending: profilesModel.activeProfile.awaitsIdentity(amongAccounts: activeAccountIDs),
                .actionableIdentityPending: activeProfileAwaitsIdentity,
                .defaultNamespace: namespace == nil,
                .storageNamespaceMatches: namespace == LiveTVLibraryStorage.preferencesNamespace(
                    profileID: profileID, profiles: profilesModel
                )
            ]
        )
        for account in accounts {
            LiveTVSourceDiagnostics.shared.record(
                .accountSnapshot, identities: [.profile: profileID, .account: account.id],
                flags: [
                    .active: activeAccountIDs.contains(account.id), .iptv: account.server.provider == .iptv,
                    .plex: account.server.provider == .plex, .jellyfin: account.server.provider == .jellyfin,
                    .emby: account.server.provider == .emby
                ]
            )
        }
    }

    private func captureLiveTVSourceDiagnostics() {
        recordLiveTVAccountState(.reportSnapshot)
        let profileID = profilesModel.activeProfileID
        let namespace = profilesModel.activeNamespace
        let expected = LiveTVLibraryStorage.preferencesNamespace(profileID: profileID, profiles: profilesModel)
        var namespaces = [namespace]
        if expected != namespace { namespaces.append(expected) }
        for namespace in namespaces {
            do {
                let configuration = try LiveTVSourceStorage.store(namespace: namespace).load()
                LiveTVSourceDiagnostics.shared.configuration(configuration, namespace: namespace, event: .reportSnapshot)
                let suppression = try LiveTVServerEnrollmentSuppressionStore(
                    profileID: profileID, namespace: namespace
                ).records()
                LiveTVSourceDiagnostics.shared.record(
                    .reportSnapshot, identities: [.profile: profileID, .namespace: namespace ?? "default"],
                    counts: [.suppressedAccounts: suppression.values.filter { $0 }.count]
                )
                for (account, suppressed) in suppression.sorted(by: { $0.key < $1.key }).prefix(64) {
                    LiveTVSourceDiagnostics.shared.record(
                        .suppressionChanged,
                        identities: [.profile: profileID, .namespace: namespace ?? "default", .account: account],
                        flags: [.suppressed: suppressed]
                    )
                }
            } catch {
                LiveTVSourceDiagnostics.shared.record(
                    .reportSnapshot, identities: [.profile: profileID, .namespace: namespace ?? "default"],
                    flags: [.failed: true], reason: .storage, error: error
                )
            }
        }
    }

    public func applySyncedMediaShareLibraries(_ descriptors: [SyncedAccountDescriptor]) {
        let localShareIDs = Set(accounts.filter { $0.server.provider == .mediaShare }.map(\.id))
        var updated = false
        for descriptor in descriptors
        where descriptor.provider == .mediaShare && localShareIDs.contains(descriptor.id) {
            do {
                if try accountStore.updateMediaShareLibrary(from: descriptor) {
                    updated = true
                }
            } catch {
                PlozzLog.sync.error("Could not apply synced share library \(descriptor.id): \(error)")
            }
        }
        if updated { reloadAccounts() }
    }

    /// Retries credentials whose launch-time Keychain read failed, without
    /// rebuilding accounts or providers during an interactive navigation path.
    @discardableResult
    public func retryUnconfirmedCredentials() -> Bool {
        let membershipsRecovered = profilesModel.retryUnconfirmedAccountSelections()
        let credentialsRecovered = accountStore.retryUnconfirmedCredentials()
        guard membershipsRecovered || credentialsRecovered else { return false }
        reloadAccounts()
        return true
    }

    /// Refresh public names and canonical addresses on both platforms. Reloading
    /// propagates address changes to retained providers and library/Home tasks.
    /// Offline servers are skipped; account and credential identities are retained.
    public func refreshServerNames() {
        guard !OfflineMode.shared.isEnabled else { return }
        let store = accountStore
        Task { @MainActor [weak self] in
            let updated = await ServerNameRefresher(accountStore: store).refresh()
            if updated > 0 { self?.reloadAccounts() }
        }
    }
}
