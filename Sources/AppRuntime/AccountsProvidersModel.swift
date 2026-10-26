import Foundation
import Observation
import CoreModels
import CoreNetworking
import FeatureAuthCore
import CryptoKit
import FeatureLiveTVCore
import CoreSecureStore

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
    /// All signed-in accounts, in stable order.
    public private(set) var accounts: [Account] = []
    /// The subset of `accounts` currently included in the active set. Sourced
    /// from the active profile (falling back to the household-global active set
    /// for the default profile).
    public private(set) var activeAccountIDs: Set<String> = []
    /// Snapshot on reload so rendering picker badges never reads the Keychain.
    private var householdActiveAccountIDs: [String] = []

    /// Whether the active profile has EXPLICITLY chosen to watch nothing.
    ///
    /// Distinguishes "this profile turned every server off" from "the active set
    /// came out empty for some other reason" (nothing signed in yet, every
    /// stored id gone stale). Both look like an empty set, but only the first is
    /// an instruction — and the fallbacks below exist for the second.
    public private(set) var watchesNothingByChoice = false

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
    @ObservationIgnored private var historySyncControllers: [String: TrackerHistorySyncController] = [:]
    public private(set) var trackerHistorySyncIsForeground = false

    /// The auth token to use for an account id, preferring an in-memory Plex
    /// Home-user override over the account's stored (admin) token. Injected so the
    /// hub doesn't own Plex-home-user state.
    @ObservationIgnored
    public var tokenResolver: @MainActor (String) -> String? = { _ in nil }
    /// The effective credential revision for an account (Plex override aware).
    @ObservationIgnored
    public var credentialRevision: @MainActor (Account) -> CredentialRevision = { $0.credentialRevision }
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

    public init(
        accountStore: AccountPersisting,
        registry: ProviderRegistry,
        profilesModel: ProfilesModel
    ) {
        self.accountStore = accountStore
        self.registry = registry
        self.profilesModel = profilesModel
        let token = NotificationCenter.default.addObserver(
            forName: LiveTVSourceDiagnostics.snapshotRequested, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureLiveTVSourceDiagnostics() }
        }
        sourceDiagnosticObserver = ObservationLease(center: .default, token: token)
    }

    /// This device's stable client identifier.
    public var deviceID: String { accountStore.deviceID() }

    public func makeAccountReauthentication(
        account: Account, isAuthorized: @escaping () -> Bool, onComplete: @escaping () -> Void
    ) -> AccountReauthenticationModel {
        let profile = AutomaticSignInStore.Session.ProfileAccess(profilesModel.activeProfile)
        return AccountReauthenticationModel(
            account: account, deviceID: deviceID, store: accountStore,
            isAuthorized: { [weak self] in
                guard let self else { return false }
                return profile == .init(self.profilesModel.activeProfile) && isAuthorized()
            },
            onComplete: { [weak self] in
                guard let self else { return }
                self.registry.invalidate(accountID: account.id)
                self.reloadAccounts()
                onComplete()
            }
        )
    }

    private var accountSelectionIsUnavailable: Bool {
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
        return profilesModel.activeProfileID + "|" + identities.joined(separator: "|")
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
        let session = makeTrackerHistoryImportSession(
            reconciler: reconciler,
            readSnapshot: {
                guard let connection else { throw TrackerHistoryError.scopeChanged }
                return try await tracker.historySnapshot(expectedConnectionID: connection)
            },
            index: index, isPlexIdentityResolved: isPlexIdentityResolved,
            isAuthorized: {
                isAuthorized() && connection != nil && tracker.historyConnectionID == connection
            }
        )
        if let syncStore, let tracker = tracker as? any TrackerHistorySyncReading,
           let identity = tracker.historySyncIdentity, identity.trackerID == tracker.historySyncTrackerID,
           (tracker.historySyncNamespace ?? ProfileStore.defaultProfileID) == watchMutationServerScope.profileID {
            bindTrackerHistorySync(tracker, store: syncStore)
            let scope = watchMutationServerScope
            let controller: TrackerHistorySyncController
            if let cached = historySyncControllers[identity.trackerID],
               cached.identity == identity, cached.contextScope == scope,
               cached.supportedCategories == tracker.historySyncCategories {
                controller = cached
            } else {
                historySyncControllers[identity.trackerID]?.stop()
                controller = TrackerHistorySyncController(
                    identity: identity, scope: scope, store: syncStore,
                    supportedCategories: tracker.historySyncCategories,
                    isAuthorized: { [weak self, weak tracker] in
                        guard let self else { return false }
                        return self.trackerHistorySyncIsForeground && isAuthorized()
                            && !self.pendingHistorySyncRevocations.contains(.init(
                                profileID: scope.profileID, trackerID: identity.trackerID
                            ))
                            && tracker?.historySyncIdentity == identity
                            && self.watchMutationServerScope == scope
                            && self.isCurrentWatchMutationServerScope(scope, isPlexIdentityResolved: isPlexIdentityResolved)
                    },
                    makeSession: { [weak self, weak tracker] selectedScope, permitsDelivery in
                        guard let self else { throw TrackerHistoryError.scopeChanged }
                        return self.makeTrackerHistoryImportSession(
                            reconciler: reconciler, scope: selectedScope,
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
                historySyncControllers[identity.trackerID] = controller
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
                if let controller = self.historySyncControllers[scope.trackerID],
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
        for controller in historySyncControllers.values { controller.stop() }
    }

    public func setTrackerHistorySyncForeground(_ foreground: Bool) {
        trackerHistorySyncIsForeground = foreground
        if !foreground { stopTrackerHistorySync() }
    }

    public func makeTrackerHistoryImportSession(
        reconciler: WatchStateReconciler,
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
            return .init(id: account.id, serverName: account.server.name, userName: homeName ?? account.userName)
        }
        let current: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self, isAuthorized(), self.watchMutationServerScope == contextScope else { return false }
            return self.isCurrentWatchMutationServerScope(scope, isPlexIdentityResolved: isPlexIdentityResolved)
        }
        return TrackerHistoryImportSession(
            scope: scope, destinations: destinations, reconciler: reconciler, readSnapshot: readSnapshot,
            index: index,
            resolveProvider: { [weak self] accountID in
                guard let self, current(), scope.accounts.contains(where: { $0.accountID == accountID }),
                      let provider = self.provider(forAccountID: accountID) else { throw TrackerHistoryError.scopeChanged }
                return provider
            },
            isAuthorized: current
        )
    }

    public func makeTrackerServerHistorySource(
        reconciler: WatchStateReconciler,
        isPlexIdentityResolved: @escaping @MainActor @Sendable (String) -> Bool,
        isAuthorized: @escaping @MainActor @Sendable () -> Bool
    ) -> TrackerServerHistorySource {
        let scope = watchMutationServerScope
        let authorizationID = liveTVAuthorizationID
        let identities = scope.accounts.compactMap { identity -> TrackerHistoryImportSession.Destination? in
            guard let account = accounts.first(where: { $0.id == identity.accountID }) else { return nil }
            let homeName = profilesModel.activeProfile.homeUserBinding(forPlexAccount: account.id)?.name
            return .init(id: account.id, serverName: account.server.name, userName: homeName ?? account.userName)
        }
        let current: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self, isAuthorized(), self.watchMutationServerScope == scope,
                  self.liveTVAuthorizationID == authorizationID else { return false }
            return self.isCurrentWatchMutationServerScope(scope, isPlexIdentityResolved: isPlexIdentityResolved)
        }
        return TrackerServerHistorySource(
            scope: scope, accounts: identities,
            resolveProvider: { [weak self] accountID in
                guard let self, current(), scope.accounts.contains(where: { $0.accountID == accountID }),
                      let provider = self.provider(forAccountID: accountID) else { throw TrackerHistoryError.scopeChanged }
                return provider
            },
            isAuthorized: current,
            isPlaying: { accountID, itemID in
                await reconciler.isLiveSession(accountID: accountID, itemID: itemID, serverScope: scope)
            }
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
                kind: kind, provider: provider
            )
        }
    }

    private func liveTVAuthorizationID(for account: Account) -> String {
        let fields = [
            profilesModel.activeProfileID, account.id, account.server.id,
            account.server.provider.rawValue, account.server.baseURL.absoluteString,
            account.userID, account.deviceID, credentialRevision(account).rawValue.uuidString
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
        case .mediaShare, .silo: nil
        }
    }

    /// The provider for the primary active account — the single-provider Home in
    /// this branch. `nil` when not signed in.
    public var primaryProvider: (any MediaProvider)? {
        guard let account = primaryActiveAccount,
              let token = tokenResolver(account.id) else { return nil }
        return resolveProvider(for: providerResolutionContext(for: account, token: token))
    }

    /// The active account that drives the current single-provider UI.
    public var primaryActiveAccount: Account? {
        // A profile that chose to watch nothing has no primary account. Without
        // this the `?? accounts.first` below answered with the household's first
        // server, so Settings showed every server off while Home played from one.
        if watchesNothingByChoice || accountSelectionIsUnavailable { return nil }
        return accounts.first { activeAccountIDs.contains($0.id) } ?? accounts.first
    }

    /// The active accounts paired with their resolved providers. Multi-account
    /// Home/Search fan out over this list (one provider call per account,
    /// merged by the view model). Tokens are resolved on demand and never
    /// stored on the value.
    public var resolvedActiveAccounts: [ResolvedAccount] {
        guard !accountSelectionIsUnavailable else { return [] }
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
        ids.compactMap { id in
            guard let account = accounts.first(where: { $0.id == id }),
                  let token = tokenResolver(account.id),
                  let provider = resolveProvider(
                      for: providerResolutionContext(for: account, token: token)
                  )
            else { return nil }
            return resolvedAccount(account, provider: provider)
        }
    }

    /// The accounts the unified Home/Search fan out over. Normally the active
    /// set; falls back to the primary account so the signed-in UI is never empty
    /// when the active-id set is empty for a reason the user didn't ask for.
    ///
    /// The fallback is deliberately NOT applied when the profile chose to watch
    /// nothing — that's an instruction, not a gap to paper over, and honouring it
    /// is what stops a Kids Profile with every server switched off still being
    /// fed the household's first server.
    public var homeAccounts: [ResolvedAccount] {
        let active = resolvedActiveAccounts
        if !active.isEmpty { return active }
        if watchesNothingByChoice { return [] }
        guard let account = primaryActiveAccount,
              let token = tokenResolver(account.id),
              let provider = resolveProvider(
                  for: providerResolutionContext(for: account, token: token)
              )
        else { return [] }
        return [resolvedAccount(account, provider: provider)]
    }

    /// Configured sources for navigation, not authorization to access their data.
    /// Pending credentials must not turn a media profile into a Live-TV-only one.
    public var navigationAccounts: [Account] {
        guard !watchesNothingByChoice, !accountSelectionIsUnavailable else { return [] }
        let active = accounts.filter { activeAccountIDs.contains($0.id) }
        if !active.isEmpty { return active }
        return primaryActiveAccount.map { [$0] } ?? []
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
        let localMediaContext = account.server.provider == .mediaShare || account.server.provider == .iptv
            ? LocalMediaContext(
                accountID: account.id,
                profileID: profilesModel.activeProfileID,
                profileNamespace: profilesModel.activeNamespace
            )
            : nil
        return ProviderResolutionContext(
            session: account.session(token: token),
            accountID: account.id,
            credentialRevision: credentialRevision(account),
            localMediaContext: localMediaContext
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
    /// are still signed in. An unset or entirely stale nonempty selection falls
    /// back to the household-global set; an explicit empty selection stays empty.
    public func activeAccountIDs(forProfile id: String) -> [String] {
        let known = Set(accounts.map(\.id))
        if let stored = profilesModel.storedActiveAccountIDs(for: id) {
            let valid = stored.filter { known.contains($0) }
            if !valid.isEmpty || stored.isEmpty { return valid }
        }
        return householdActiveAccountIDs.filter { known.contains($0) }
    }

    public func profileShowsPINLock(_ profile: Profile) -> Bool {
        let plexIDs = Set(accounts.filter { $0.server.provider == .plex }.map(\.id))
        return profile.showsPINLock(
            activePlexAccountIDs: Set(activeAccountIDs(forProfile: profile.id)).intersection(plexIDs)
        )
    }

    /// Explicitly adding IPTV includes it in this viewer's selection, not just the household fallback.
    public func includeIPTVAccountInActiveProfile(_ account: Account) throws {
        guard account.server.provider == .iptv else { return }
        let profileID = profilesModel.activeProfileID
        guard !accountSelectionIsUnavailable else {
            PlozzLog.auth.error("IPTV setup could not read the current profile's server selection")
            throw ProfilesModel.AccountSelectionError.unavailable
        }
        guard var selected = profilesModel.storedActiveAccountIDs(for: profileID),
              !selected.contains(account.id) else { return }
        selected.append(account.id)
        profilesModel.setActiveAccountIDs(selected, for: profileID)
        guard !accountSelectionIsUnavailable,
              Set(profilesModel.storedActiveAccountIDs(for: profileID) ?? []) == Set(selected) else {
            PlozzLog.auth.error("IPTV setup could not save the current profile's server selection")
            throw ProfilesModel.AccountSelectionError.unavailable
        }
    }

    /// Reloads accounts from the store and recomputes the active set for the
    /// active profile. Invalidates the provider cache first, then fires
    /// `onActiveAccountsChanged` so the media-share runtime can update its
    /// preferred-account keys.
    public func reloadAccounts(updatingServerAddressesFor addressAccountID: String? = nil) {
        profilesModel.retryUnconfirmedAccountSelections()
        liveTVAuthorizationCache = [:]
        let updated = accountStore.loadAccounts()
        if let addressAccountID,
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
            registry.invalidateCache()
        }
        onAccountsInvalidated()
        accounts = updated
        householdActiveAccountIDs = accountStore.activeAccountIDs()
        let resolved = Set(activeAccountIDs(forProfile: profilesModel.activeProfileID))
        activeAccountIDs = resolved
        // Only an explicit, still-honoured empty selection counts as a choice:
        // the stale-fallback branch above has already re-expanded the other case.
        watchesNothingByChoice = resolved.isEmpty
            && !accountSelectionIsUnavailable
            && (profilesModel.storedActiveAccountIDs(for: profilesModel.activeProfileID)?.isEmpty ?? false)
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
        let store = accountStore
        Task { @MainActor [weak self] in
            let updated = await ServerNameRefresher(accountStore: store).refresh()
            if updated > 0 { self?.reloadAccounts() }
        }
    }
}
