import XCTest
import Synchronization
import CoreModels
import CoreUI
import FeatureAuth
import AppRuntime
@testable import AppShell
@testable import FeatureLiveTVCore

@MainActor
private final class AccountsHistoryReader: TrackerHistorySyncReading {
    let historySyncTrackerID = "fixture"
    var historySyncNamespace: String?
    var historySyncCategories: Set<TrackerHistorySyncCategory> = [.watched, .resume]
    var onHistorySyncDisconnect: (@MainActor () throws -> Void)?
    var connection: String? = "original"
    var reads = 0
    var historyConnectionID: String? { connection }
    var historySyncIdentity: TrackerHistorySyncIdentity? {
        connection.map { .init(trackerID: "fixture", connectionID: $0) }
    }
    func snapshot() throws -> TrackerHistorySnapshot {
        guard let connection else { throw TrackerHistoryError.scopeChanged }
        return try .init(trackerID: "fixture", connectionID: connection, observations: [], expectedCount: 0)
    }
    func historySnapshot(expectedConnectionID: String) async throws -> TrackerHistorySnapshot {
        guard connection == expectedConnectionID else { throw TrackerHistoryError.scopeChanged }
        reads += 1
        return try snapshot()
    }
}

/// Unit tests for ``AccountsProvidersModel`` — the accounts + providers hub split
/// out of ``AppState``. Cover the hub's own behavior over in-memory stores:
/// `reloadAccounts` loads accounts and recomputes the active set, the
/// `onActiveAccountsChanged` hook fires with the resolved set, provider resolution
/// gates on the injected token seam, and the profile/device delegations hold.
/// The full active-set resolution matrix (explicit choice vs. fallback) stays
/// covered end-to-end by ServerToggleTests through AppState.
@MainActor
final class AccountsProvidersModelTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "AccountsProvidersModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func account(id: String, host: String, provider: ProviderKind = .jellyfin) -> Account {
        Account(
            id: id,
            server: MediaServer(
                id: "srv-\(id)",
                name: host,
                baseURL: URL(string: provider == .mediaShare ? "smb://\(host)/media" : "https://\(host)")!,
                provider: provider
            ),
            userID: "user-\(id)",
            userName: "User \(id)",
            deviceID: "device"
        )
    }

    private func makeModel(accountIDs: [(String, String)]) throws -> (AccountsProvidersModel, AccountStore, ProfilesModel) {
        let secrets = InMemorySecureStore()
        let store = AccountStore(
            secureStore: secrets, mediaCredentialVault: MediaCredentialVault(secureStore: secrets),
            credentialJournal: try CredentialMutationJournal(
                store: DurableLocalStateStore(secureStore: InMemorySecureStore())
            )
        )
        for (id, host) in accountIDs {
            try store.add(account(id: id, host: host), token: "token-\(id)")
        }
        let profiles = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        let model = AccountsProvidersModel(
            accountStore: store,
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
        return (model, store, profiles)
    }

    func testReloadAccountsLoadsAccountsAndFiresHook() throws {
        let (model, _, _) = try makeModel(accountIDs: [("a", "a.example.com"), ("b", "b.example.com")])

        var hookResolved: Set<String>?
        var hookAccountsCount: Int?
        model.onActiveAccountsChanged = { resolved, accounts in
            hookResolved = resolved
            hookAccountsCount = accounts.count
        }

        XCTAssertTrue(model.accounts.isEmpty)
        model.reloadAccounts()

        XCTAssertEqual(Set(model.accounts.map(\.id)), ["a", "b"])
        // The hook fires exactly with the recomputed active set + full account list.
        XCTAssertEqual(hookResolved, model.activeAccountIDs)
        XCTAssertEqual(hookAccountsCount, 2)
        // The resolved active set is a subset of the known accounts.
        XCTAssertTrue(model.activeAccountIDs.isSubset(of: ["a", "b"]))
    }

    private func makeHistoryModel() throws -> (AccountsProvidersModel, ProfilesModel) {
        let (model, store, profiles) = try makeModel(accountIDs: [("server", "server.test")])
        try store.add(account(id: "a", host: "share.test", provider: .mediaShare), token: "fixture")
        profiles.setActiveAccountIDs(["a", "server"], for: profiles.activeProfileID)
        model.reloadAccounts()
        return (model, profiles)
    }

    func testOngoingHistoryFactoryFencesForegroundConnectionAndProfile() async throws {
        let (model, profiles) = try makeHistoryModel()
        let tracker = AccountsHistoryReader()
        let store = try DurableLocalStateStore(secureStore: InMemorySecureStore())
        let reconciler = WatchStateReconciler(
            store: InMemoryWatchMutationStore(),
            applier: AppShellWatchMutationApplier(
                resolveProvider: { _ in XCTFail("Empty history must not resolve a writer"); return nil },
                applyTrakt: { _ in XCTFail("Unexpected tracker write") },
                applySimkl: { _ in XCTFail("Unexpected tracker write") },
                applyAniList: { _ in XCTFail("Unexpected tracker write") },
                applyMAL: { _ in XCTFail("Unexpected tracker write") }
            )
        )
        let index = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "550"): [.init(accountID: "a", itemID: "movie", providerKind: .mediaShare, kind: .movie)]
        ])
        func makeSession() -> TrackerHistoryImportSession {
            model.makeTrackerHistoryImportSession(
                tracker: tracker, reconciler: reconciler, syncStore: store,
                index: { index }, isPlexIdentityResolved: { _ in true }, isAuthorized: { true }
            )
        }
        let first = makeSession()
        let sync = try XCTUnwrap(first.ongoingSync)
        XCTAssertEqual(Set(first.destinations.map(\.id)), ["a", "server"])
        XCTAssertEqual(sync.eligibleAccountIDs, ["a"])
        XCTAssertTrue(sync === makeSession().ongoingSync)
        await sync.enable(from: first, accountIDs: ["a"], categories: [.watched])
        XCTAssertFalse(sync.isEnabled)
        XCTAssertEqual(tracker.reads, 0, "An inactive app cannot start tracker reads")
        model.setTrackerHistorySyncForeground(true)
        await first.compare()
        XCTAssertNil(first.plan)
        XCTAssertEqual(first.error as? TrackerHistoryError, .invalidSelection)
        await first.apply(rowIDs: [], overridingConflicts: [], confirmsDestructiveChanges: true)
        XCTAssertEqual(first.error as? TrackerHistoryError, .invalidSelection)
        XCTAssertEqual(tracker.reads, 0, "Even a foreground enrollment session cannot perform a one-time import")
        await sync.enable(from: first, accountIDs: ["a"], categories: [.watched])
        XCTAssertTrue(sync.isEnabled)
        first.cancel()
        await sync.synchronize(manual: false)
        XCTAssertNil(sync.error, "Durable consent does not depend on the original comparison remaining open")
        let reads = tracker.reads
        await sync.synchronize(manual: false)
        XCTAssertEqual(tracker.reads, reads, "Repeated foreground/index callbacks obey the interval")
        let (coldModel, _) = try makeHistoryModel()
        defer { withExtendedLifetime(coldModel) {} }
        coldModel.bindTrackerHistorySync(tracker, store: store)
        tracker.historySyncNamespace = "another-profile"
        try XCTUnwrap(tracker.onHistorySyncDisconnect)()
        sync.reload()
        XCTAssertTrue(sync.isEnabled, "Disconnect must use the credential's namespace, not the visible profile")
        tracker.historySyncNamespace = nil
        try XCTUnwrap(tracker.onHistorySyncDisconnect)()
        sync.reload()
        XCTAssertFalse(sync.isEnabled, "Disconnect before opening comparison must revoke the persisted grant")
        tracker.connection = nil
        tracker.connection = "original"
        XCTAssertFalse(try XCTUnwrap(makeSession().ongoingSync).isEnabled,
                       "Restoring the old credential cannot restore revoked permission")
        model.setTrackerHistorySyncForeground(false)
        await sync.synchronize()
        XCTAssertEqual(tracker.reads, reads)
        model.setTrackerHistorySyncForeground(true)
        tracker.connection = nil
        XCTAssertNil(makeSession().ongoingSync)
        await sync.synchronize()
        XCTAssertEqual(tracker.reads, reads)
        tracker.connection = "replacement"
        let replacement = try XCTUnwrap(makeSession().ongoingSync)
        XCTAssertFalse(replacement === sync)
        XCTAssertFalse(replacement.isEnabled)
        let another = profiles.add(name: "Another", activeAccountIDs: ["a"])
        profiles.select(another.id)
        model.reloadAccounts()
        XCTAssertNil(makeSession().ongoingSync, "A tracker still scoped to the previous profile cannot enroll")
        tracker.historySyncNamespace = another.id
        let otherProfile = try XCTUnwrap(makeSession().ongoingSync)
        XCTAssertFalse(otherProfile.isEnabled)
        await sync.synchronize()
        XCTAssertEqual(tracker.reads, reads)
    }

    func testUnavailableRevocationStoreBlocksNewControllersUntilRevocationSucceeds() async throws {
        let (model, _) = try makeHistoryModel()
        model.setTrackerHistorySyncForeground(true)
        let tracker = AccountsHistoryReader()
        model.bindTrackerHistorySync(tracker, store: nil)
        XCTAssertThrowsError(try XCTUnwrap(tracker.onHistorySyncDisconnect)()) {
            XCTAssertEqual($0 as? TrackerHistorySyncError, .revocationFailed)
        }
        let store = try DurableLocalStateStore(secureStore: InMemorySecureStore())
        let session = model.makeTrackerHistoryImportSession(
            tracker: tracker,
            reconciler: WatchStateReconciler(
                store: InMemoryWatchMutationStore(),
                applier: AppShellWatchMutationApplier(
                    resolveProvider: { _ in XCTFail("Unexpected provider access"); return nil },
                    applyTrakt: { _ in XCTFail("Unexpected tracker write") },
                    applySimkl: { _ in XCTFail("Unexpected tracker write") },
                    applyAniList: { _ in XCTFail("Unexpected tracker write") },
                    applyMAL: { _ in XCTFail("Unexpected tracker write") }
                )
            ),
            syncStore: store, index: { IdentityIndexSnapshot(byIdentity: [:]) },
            isPlexIdentityResolved: { _ in true }, isAuthorized: { true }
        )
        let sync = try XCTUnwrap(session.ongoingSync)
        let reviewed = TrackerHistoryImportPlan(
            snapshot: try tracker.snapshot(), serverScope: session.scope, candidates: []
        )
        await sync.enable(afterReview: reviewed, accountIDs: ["a"], categories: [.watched])
        XCTAssertFalse(sync.isEnabled)
        XCTAssertEqual(tracker.reads, 0)
        try XCTUnwrap(tracker.onHistorySyncDisconnect)()
        await sync.enable(afterReview: reviewed, accountIDs: ["a"], categories: [.watched])
        XCTAssertTrue(sync.isEnabled)
    }

        func testAuthenticatedArtworkRejectsHiddenAccountsAndChangedCredentials() async throws {
            let (model, store, profiles) = try makeModel(accountIDs: [("a", "a.test")])
            model.registry.register(.jellyfin) { LiveTVAccountsTestProvider(session: $0.session) }
            model.tokenResolver = { _ in "fixture" }
            store.setActiveAccountIDs(["a"])
            profiles.setActiveAccountIDs(["a"], for: profiles.activeProfileID)
            model.reloadAccounts()
            let previousLoader = ArtworkSession.authenticatedLoader
            defer { ArtworkSession.authenticatedLoader = previousLoader }
            model.configureAuthenticatedArtwork()
            let loader = try XCTUnwrap(ArtworkSession.authenticatedLoader)
            let account = try XCTUnwrap(model.accounts.first)
            let reference = AuthenticatedArtworkReference(
                accountID: account.id, credentialRevision: model.credentialRevision(account),
                resourceID: "cover", size: nil
            )
            let bytes = try await loader(reference)
            XCTAssertEqual(bytes, Data([1]))
            let stale = AuthenticatedArtworkReference(
                accountID: account.id, credentialRevision: .init(), resourceID: "cover", size: nil
            )
            do {
                _ = try await loader(stale)
                XCTFail("Stale credentials must be rejected")
            } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
            profiles.setActiveAccountIDs([], for: profiles.activeProfileID)
            model.refreshActiveAccountSelection()
            do {
                _ = try await loader(reference)
                XCTFail("Hidden accounts must be rejected")
            } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
        }

        func testAuthenticatedArtworkCannotPublishAfterAProfileSwitch() async throws {
            let (model, store, profiles) = try makeModel(accountIDs: [("a", "a.test")])
            let other = profiles.add(name: "Other", activeAccountIDs: ["a"])
            model.registry.register(.jellyfin) { context in
                LiveTVAccountsTestProvider(session: context.session, artwork: {
                    await MainActor.run {
                        profiles.select(other.id)
                        model.reloadAccounts()
                    }
                    return Data([1])
                })
            }
            model.tokenResolver = { _ in "fixture" }
            store.setActiveAccountIDs(["a"])
            profiles.setActiveAccountIDs(["a"], for: profiles.activeProfileID)
            model.reloadAccounts()
            let previousLoader = ArtworkSession.authenticatedLoader
            defer { ArtworkSession.authenticatedLoader = previousLoader }
            model.configureAuthenticatedArtwork()
            let loader = try XCTUnwrap(ArtworkSession.authenticatedLoader)
            let account = try XCTUnwrap(model.accounts.first)
            do {
                _ = try await loader(.init(
                    accountID: account.id, credentialRevision: model.credentialRevision(account),
                    resourceID: "cover", size: nil
                ))
                XCTFail("A late download must not cross profile activation")
            } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
        }

    func testMembershipChangesRetainUnrelatedProvidersAcrossTwentyServers() throws {
        let (model, store, profiles) = try makeModel(accountIDs: [])
        let kinds: [ProviderKind] = [.mediaShare, .plex, .jellyfin, .emby]
        for index in 0..<20 {
            try store.add(
                account(id: "source-\(index)", host: "source-\(index).test", provider: kinds[index % kinds.count]),
                token: "fixture"
            )
        }
        for kind in kinds {
            model.registry.register(kind) { LiveTVAccountsTestProvider(session: $0.session) }
        }
        model.tokenResolver = { _ in "fixture" }
        let selected = Set((0..<20).map { "source-\($0)" })
        profiles.setActiveAccountIDs(Array(selected), for: profiles.activeProfileID)
        model.reloadAccounts()
        let original = try Dictionary(uniqueKeysWithValues: model.resolvedActiveAccounts.map {
            ($0.account.id, try XCTUnwrap($0.provider as? LiveTVAccountsTestProvider))
        })
        var notifications = 0
        model.onActiveAccountsChanged = { ids, accounts in
            notifications += 1
            XCTAssertEqual(ids, model.activeAccountIDs)
            XCTAssertEqual(accounts.count, 20)
        }
        for id in ["source-0", "source-1", "source-2", "source-3"] {
            profiles.setActiveAccountIDs(Array(selected.subtracting([id])), for: profiles.activeProfileID)
            model.refreshActiveAccountSelection()
            XCTAssertEqual(model.activeAccountIDs, selected.subtracting([id]))
            for resolved in model.resolvedActiveAccounts where resolved.account.id != id {
                // Earlier disabled sources have already been replaced.
                if !["source-0", "source-1", "source-2", "source-3"].contains(resolved.account.id) {
                    XCTAssertTrue((resolved.provider as? LiveTVAccountsTestProvider) === original[resolved.account.id])
                }
            }
            profiles.setActiveAccountIDs(Array(selected), for: profiles.activeProfileID)
            model.refreshActiveAccountSelection()
            let reenabled = try XCTUnwrap(model.provider(forAccountID: id) as? LiveTVAccountsTestProvider)
            XCTAssertFalse(reenabled === original[id], "Disabled sources must release their old provider.")
        }
        XCTAssertEqual(notifications, 8)
        profiles.setActiveAccountIDs([], for: profiles.activeProfileID)
        model.refreshActiveAccountSelection()
        XCTAssertTrue(model.watchesNothingByChoice)
        XCTAssertTrue(model.homeAccounts.isEmpty)
        XCTAssertNil(model.primaryProvider)
        XCTAssertEqual(model.accounts.count, 20, "Profile edits must not remove household accounts.")

        model.reloadAccounts()
        XCTAssertTrue(model.homeAccounts.isEmpty, "Explicitly choosing nothing must survive a full reload.")
    }

    func testAddressOnlyReloadUpdatesRetainedProviderWithoutEvictingOtherSignIns() throws {
        let (model, store, _) = try makeModel(accountIDs: [("a", "a.test"), ("b", "b.test")])
        model.registry.register(.jellyfin) { LiveTVAccountsTestProvider(session: $0.session) }
        model.tokenResolver = { _ in "fixture-token" }
        model.reloadAccounts()
        let first = try XCTUnwrap(model.provider(forAccountID: "a") as? LiveTVAccountsTestProvider)
        let unrelated = try XCTUnwrap(model.provider(forAccountID: "b") as? LiveTVAccountsTestProvider)
        let account = try XCTUnwrap(model.accounts.first { $0.id == "a" })
        let alias = URL(string: "http://192.168.1.50:8096")!
        try store.updateServerAddresses(expected: account, alternatives: [alias])
        model.reloadAccounts(updatingServerAddressesFor: account.id)
        XCTAssertTrue(try XCTUnwrap(model.provider(forAccountID: "a") as? LiveTVAccountsTestProvider) === first)
        XCTAssertTrue(try XCTUnwrap(model.provider(forAccountID: "b") as? LiveTVAccountsTestProvider) === unrelated)
        XCTAssertEqual(first.alternatives, [alias])
        XCTAssertTrue(unrelated.alternatives.isEmpty)
        XCTAssertEqual(model.accounts.first { $0.id == "a" }?.credentialRevision, account.credentialRevision)
        let updated = try XCTUnwrap(model.accounts.first { $0.id == "a" })
        try store.updateServerAddresses(expected: updated, alternatives: [])
        model.reloadAccounts(updatingServerAddressesFor: account.id)
        XCTAssertTrue(first.alternatives.isEmpty)
        XCTAssertTrue(try XCTUnwrap(model.provider(forAccountID: "a") as? LiveTVAccountsTestProvider) === first)
    }

    func testAccountRecoveryRechecksProfileAndReloadsOnlyAfterSaving() throws {
        let (model, store, profiles) = try makeModel(accountIDs: [("a", "a.test")])
        model.reloadAccounts()
        let account = try XCTUnwrap(model.accounts.first)
        var completed = false
        var authenticatedIDs: [String] = []
        model.onLocalAccountAuthentication = { authenticatedIDs.append($0) }
        let recovery = model.makeAccountReauthentication(
            account: account, isAuthorized: { true }, onComplete: { completed = true }
        )
        let other = profiles.add(name: "Other", activeAccountIDs: ["a"])
        profiles.select(other.id)
        XCTAssertThrowsError(try recovery.complete(account.session(token: "NEW")))
        XCTAssertFalse(completed)
        XCTAssertTrue(authenticatedIDs.isEmpty)
        XCTAssertEqual(store.token(for: account.id), "token-a")

        let currentRecovery = model.makeAccountReauthentication(
            account: account, isAuthorized: { true }, onComplete: { completed = true }
        )
        try currentRecovery.complete(account.session(token: "NEW"))
        XCTAssertTrue(completed)
        XCTAssertEqual(authenticatedIDs, [account.id])
        XCTAssertEqual(store.token(for: account.id), "NEW")
        XCTAssertEqual(model.accounts, store.loadAccounts())
        XCTAssertNotEqual(model.accounts.first?.credentialRevision, account.credentialRevision)
    }

    func testUnknownSyncedIdentityOnlyGatesWhenAnActivePlexAccountArrives() throws {
        for provider in [ProviderKind.plex, .iptv, .jellyfin, .emby, .silo, .mediaShare] {
            let (model, store, profiles) = try makeModel(accountIDs: [])
            let profileID = profiles.activeProfileID
            profiles.applySyncedMembership(
                ["arriving"], forProfile: profileID, knownNonPlexAccountIDs: []
            )
            model.tokenResolver = { _ in
                XCTFail("Admission must not resolve credentials or construct providers.")
                return nil
            }
            model.reloadAccounts()
            XCTAssertFalse(model.activeProfileAwaitsIdentity)

            try store.add(
                account(id: "arriving", host: "server.example", provider: provider),
                token: "fixture"
            )
            model.reloadAccounts()
            XCTAssertEqual(model.activeAccountIDs, ["arriving"])
            XCTAssertEqual(model.activeProfileAwaitsIdentity, provider == .plex)
            XCTAssertEqual(profiles.activeProfile.pendingIdentityAccountIDs, ["arriving"])

            profiles.setActiveAccountIDs([], for: profileID)
            model.reloadAccounts()
            XCTAssertFalse(model.activeProfileAwaitsIdentity)
            profiles.setActiveAccountIDs(["arriving"], for: profileID)
            model.reloadAccounts()
            XCTAssertEqual(model.activeProfileAwaitsIdentity, provider == .plex)

            let other = profiles.add(name: "Other", activeAccountIDs: ["arriving"])
            profiles.select(other.id)
            model.reloadAccounts()
            XCTAssertFalse(model.activeProfileAwaitsIdentity)
            profiles.select(profileID)
            model.reloadAccounts()
            XCTAssertEqual(model.activeProfileAwaitsIdentity, provider == .plex)

            var answered = profiles.activeProfile
            answered.resolveAccountAwaitingIdentity("arriving")
            profiles.update(answered)
            XCTAssertFalse(model.activeProfileAwaitsIdentity)
        }
    }

    func testProviderResolutionGatesOnTokenSeam() throws {
        let (model, _, _) = try makeModel(accountIDs: [("a", "a.example.com")])
        model.reloadAccounts()

        // No token → nil, before the registry is even consulted.
        model.tokenResolver = { _ in nil }
        XCTAssertNil(model.provider(forAccountID: "a"))
        // Unknown account id → nil regardless of the token seam.
        model.tokenResolver = { _ in "tok" }
        XCTAssertNil(model.provider(forAccountID: "does-not-exist"))
    }

    func testPendingMediaCredentialsDoNotRedirectStartupToLiveTV() throws {
        for provider in [ProviderKind.plex, .jellyfin, .emby, .silo, .mediaShare] {
            for includesIPTV in [false, true] {
                let (model, store, profiles) = try makeModel(accountIDs: [])
                try store.add(account(id: "media", host: "media.example", provider: provider), token: "fixture")
                model.registry.register(provider) { LiveTVAccountsTestProvider(session: $0.session) }
                if includesIPTV {
                    try store.add(account(id: "iptv", host: "iptv.example", provider: .iptv), token: "fixture")
                    model.registry.register(.iptv) { LiveTVAccountsTestProvider(session: $0.session) }
                }
                let expectedIDs: Set<String> = includesIPTV ? ["media", "iptv"] : ["media"]
                profiles.setActiveAccountIDs(Array(expectedIDs), for: profiles.activeProfileID)
                var mediaIsReady = false
                model.tokenResolver = { id in mediaIsReady || id == "iptv" ? "fixture" : nil }
                model.reloadAccounts()

                func initialSelection(current: NavigationRailDestination) -> NavigationRailDestination {
                    let availability = NavigationContentAvailability(
                        accounts: model.navigationAccounts, libraries: [], discoveredAccountIDs: [],
                        disabledLibraryKeys: [], hasDiscoverySearch: false, hasWatchlistItems: false
                    )
                    return AppAdmissionNavigation.initialSelection(
                        current: current, visible: [.home, .liveTV, .settings],
                        liveTV: .liveTV, fallback: .settings,
                        admission: AppAdmissionContext(hasMediaAccounts: !model.accounts.isEmpty),
                        hasPendingLiveTVEntry: false, prefersLiveTV: availability.prefersLiveTV
                    )
                }

                XCTAssertEqual(Set(model.homeAccounts.map(\.account.id)), includesIPTV ? ["iptv"] : [])
                XCTAssertEqual(Set(model.navigationAccounts.map(\.id)), expectedIDs)
                let startup = initialSelection(current: .home)
                XCTAssertEqual(startup, .home, "\(provider), IPTV: \(includesIPTV)")

                mediaIsReady = true
                XCTAssertEqual(Set(model.homeAccounts.map(\.account.id)), expectedIDs)
                XCTAssertEqual(initialSelection(current: startup), .home)
                XCTAssertEqual(initialSelection(current: .settings), .settings)
            }
        }
    }

    func testNavigationAccountsNeverResolveCredentialsOrIncludeOtherProfiles() throws {
        let (model, store, profiles) = try makeModel(accountIDs: [("a", "a.example"), ("b", "b.example")])
        store.setActiveAccountIDs(["a", "b"])
        model.tokenResolver = { _ in
            XCTFail("Navigation availability must not resolve credentials.")
            return nil
        }
        profiles.setActiveAccountIDs(["a"], for: profiles.activeProfileID)
        model.reloadAccounts()
        XCTAssertEqual(model.navigationAccounts.map(\.id), ["a"])

        let other = profiles.add(name: "Other", activeAccountIDs: ["b"])
        profiles.select(other.id)
        model.reloadAccounts()
        XCTAssertEqual(model.navigationAccounts.map(\.id), ["b"])

        profiles.setActiveAccountIDs([], for: other.id)
        model.reloadAccounts()
        XCTAssertTrue(model.navigationAccounts.isEmpty)
    }

    func testDeviceIDDelegatesToStore() throws {
        let (model, store, _) = try makeModel(accountIDs: [])
        XCTAssertEqual(model.deviceID, store.deviceID())
    }

    func testPrimaryActiveAccountFallsBackToFirst() throws {
        let (model, store, _) = try makeModel(accountIDs: [("a", "a.example.com"), ("b", "b.example.com")])
        store.setActiveAccountIDs([])
        model.reloadAccounts()
        // Even if the active set were empty, primaryActiveAccount falls back to the
        // first account so the signed-in UI is never empty.
        XCTAssertNotNil(model.primaryActiveAccount)
        XCTAssertTrue(["a", "b"].contains(model.primaryActiveAccount!.id))
        XCTAssertTrue(model.activeAccountIDs.isEmpty)
        XCTAssertEqual(model.navigationAccounts, [try XCTUnwrap(model.primaryActiveAccount)])
    }

    // MARK: Active-set resolution matrix (reloadAccounts)
    // The hub is the sole authority for account-set resolution. These unit-test
    // the three explicit-choice branches directly on the hub (previously only
    // covered end-to-end via ServerToggleTests through AppState), driving them
    // through the same injected profilesModel/accountStore seams.

    func testPickerLockUsesEachProfilesResolvedPlexSources() throws {
        let (model, store, profiles) = try makeModel(accountIDs: [])
        try store.add(account(id: "plex", host: "plex.example", provider: .plex), token: "fixture")
        try store.add(account(id: "silo", host: "silo.example", provider: .silo), token: "fixture")
        store.setActiveAccountIDs(["plex", "silo"])
        var target = profiles.add(name: "Silo")
        target = target.settingHomeUserBinding(
            .init(homeUserID: "protected", name: "Viewer", requiresPIN: true), forPlexAccount: "plex"
        )
        profiles.update(target)
        model.reloadAccounts()
        XCTAssertNotEqual(profiles.activeProfileID, target.id)
        XCTAssertTrue(model.profileShowsPINLock(target), "An unset subset inherits household sources.")

        profiles.setActiveAccountIDs(["silo"], for: target.id)
        XCTAssertFalse(model.profileShowsPINLock(target), "Inactive picker tiles use their own source choice.")
        profiles.setActiveAccountIDs([], for: target.id)
        XCTAssertFalse(model.profileShowsPINLock(target))
        profiles.setActiveAccountIDs(["plex", "silo"], for: target.id)
        XCTAssertTrue(model.profileShowsPINLock(target), "Re-enabling Plex restores its lock hint.")
        profiles.setActiveAccountIDs(["gone"], for: target.id)
        XCTAssertFalse(model.profileShowsPINLock(target), "Absent selected sources cannot enable an excluded Plex account.")
        profiles.select(target.id)
        model.reloadAccounts()
        XCTAssertEqual(model.activeAccountIDs, Set(model.activeAccountIDs(forProfile: target.id)))

        profiles.setActiveAccountIDs(["gone", "silo"], for: target.id)
        XCTAssertFalse(model.profileShowsPINLock(target), "Only the surviving selected source is active.")
        profiles.setActiveAccountIDs(["plex"], for: target.id)
        try store.remove(id: "plex")
        model.reloadAccounts()
        XCTAssertFalse(model.profileShowsPINLock(target), "A removed source cannot ask for a PIN.")
        target.lock = ProfileLock.make(pin: "1234", matchesPlexPIN: true, iterations: 1)
        profiles.update(target)
        XCTAssertTrue(model.profileShowsPINLock(target), "Local locks remain independent of Plex enablement.")
    }

    /// (a) An explicit EMPTY choice is honored — "watch nothing" / master toggle
    /// off — and must NOT be silently re-expanded to the household-global set.
    func testReloadHonorsExplicitEmptyChoice() throws {
        let (model, _, profiles) = try makeModel(accountIDs: [("a", "a.example.com"), ("b", "b.example.com")])
        // The profile explicitly chose to watch nothing.
        profiles.setActiveAccountIDs([], for: profiles.activeProfileID)

        model.reloadAccounts()

        XCTAssertTrue(model.activeAccountIDs.isEmpty)
        XCTAssertTrue(model.navigationAccounts.isEmpty)
    }

    func testReloadPreservesExplicitSelectionWhenAllChosenAccountsAreAbsent() throws {
        let (model, store, profiles) = try makeModel(accountIDs: [("a", "a.example.com"), ("b", "b.example.com")])
        // Household-global active set is just "b".
        store.setActiveAccountIDs(["b"])
        // The profile's explicit choice references only accounts that no longer exist.
        profiles.setActiveAccountIDs(["gone-1", "gone-2"], for: profiles.activeProfileID)

        model.reloadAccounts()

        XCTAssertTrue(model.activeAccountIDs.isEmpty)
        XCTAssertTrue(model.navigationAccounts.isEmpty)
        XCTAssertTrue(model.watchesNothingByChoice)
        XCTAssertNil(model.primaryActiveAccount)
        XCTAssertEqual(profiles.storedActiveAccountIDs(for: profiles.activeProfileID), ["gone-1", "gone-2"])
    }

    func testDeletingLastSelectedAccountCannotStartExcludedShareWorkAndReaddRestoresOnlyIt() throws {
        let (model, store, profiles) = try makeModel(accountIDs: [("selected", "selected.example")])
        try store.add(account(id: "share", host: "share.invalid", provider: .mediaShare), token: "fixture")
        store.setActiveAccountIDs(["selected", "share"])
        profiles.setActiveAccountIDs(["selected"], for: profiles.activeProfileID)
        model.reloadAccounts()
        XCTAssertEqual(model.activeAccountIDs, ["selected"])
        var notified: Set<String>?
        model.onActiveAccountsChanged = { selected, _ in notified = selected }

        try store.remove(id: "selected")
        model.reloadAccounts()

        XCTAssertEqual(notified, [])
        XCTAssertTrue(model.activeAccountIDs.isEmpty)
        XCTAssertTrue(model.navigationAccounts.isEmpty)
        XCTAssertNil(model.primaryActiveAccount)
        XCTAssertTrue(model.homeAccounts.isEmpty)
        XCTAssertTrue(model.watchMutationServerScope.accounts.isEmpty)
        let work = MediaShareWorkScope.resolve(
            profileID: profiles.activeProfileID, isProfileAuthorized: true,
            activeAccountIDs: model.activeAccountIDs, accounts: model.accounts, visibility: .default
        )
        XCTAssertTrue(work.accountKeys.isEmpty)
        XCTAssertEqual(profiles.storedActiveAccountIDs(for: profiles.activeProfileID), ["selected"])
        model.reloadAccounts()
        XCTAssertTrue(model.activeAccountIDs.isEmpty)

        try store.add(account(id: "selected", host: "selected.example"), token: "fixture")
        model.reloadAccounts()
        XCTAssertEqual(model.activeAccountIDs, ["selected"])
        XCTAssertEqual(model.navigationAccounts.map(\.id), ["selected"])
    }

    /// (c) An explicit choice where only SOME chosen accounts survive honors
    /// exactly the survivors — it does not fall back to the global set.
    func testReloadHonorsSurvivingSubsetOfExplicitChoice() throws {
        let (model, store, profiles) = try makeModel(accountIDs: [("a", "a.example.com"), ("b", "b.example.com")])
        // Global set is everything, to prove we do NOT fall back to it here.
        store.setActiveAccountIDs(["a", "b"])
        // The profile chose "a" plus an account that no longer exists.
        profiles.setActiveAccountIDs(["a", "gone"], for: profiles.activeProfileID)

        model.reloadAccounts()

        // Exactly the surviving chosen account — not the global {a, b}.
        XCTAssertEqual(model.activeAccountIDs, ["a"])
        XCTAssertEqual(model.navigationAccounts.map(\.id), ["a"])
    }

    func testLiveTVNeverFallsBackToAnExcludedAccount() throws {
        let (model, store, profiles) = try makeModel(accountIDs: [("a", "a.example.com"), ("b", "b.example.com")])
        model.registry.register(.jellyfin) { LiveTVAccountsTestProvider(session: $0.session) }
        model.tokenResolver = { _ in "fixture-effective-user-token" }
        store.setActiveAccountIDs(["a", "b"])
        profiles.setActiveAccountIDs(["a"], for: profiles.activeProfileID)
        model.reloadAccounts()
        let resolver = model.liveTVProviderResolver()
        XCTAssertEqual(model.liveTVServerChoices.map(\.id), ["a"])
        XCTAssertNotNil(resolver("a"))
        XCTAssertNil(resolver("b"))

        profiles.setActiveAccountIDs([], for: profiles.activeProfileID)
        model.reloadAccounts()
        XCTAssertNotNil(model.provider(forAccountID: "a"))
        XCTAssertTrue(model.liveTVServerChoices.isEmpty)
        XCTAssertNil(resolver("a"))
    }

    func testLiveTVUsesEffectiveCredentialsAndInvalidatesTheirIdentity() throws {
        for kind: ProviderKind in [.plex, .jellyfin, .emby] {
            let (model, store, profiles) = try makeModel(accountIDs: [])
            let originalAccount = account(id: "a", host: "a.example.com", provider: kind)
            try store.add(originalAccount, token: "fixture-effective-user-token")
            model.registry.register(kind) { LiveTVAccountsTestProvider(session: $0.session) }
            model.tokenResolver = { store.token(for: $0) }
            profiles.setActiveAccountIDs(["a"], for: profiles.activeProfileID)
            model.reloadAccounts()
            let resolver = model.liveTVProviderResolver()
            let original = try XCTUnwrap(resolver("a"))
            let scope = try XCTUnwrap(original.viewerScopeID)
            XCTAssertFalse(scope.isEmpty)
            let provider = try XCTUnwrap(original.provider as? LiveTVAccountsTestProvider)
            XCTAssertEqual(provider.session.accessToken, "fixture-effective-user-token")
            let revision = try XCTUnwrap(model.accounts.first).credentialRevision

            try store.add(originalAccount, token: "fixture-rotated-token")
            model.reloadAccounts()
            let replacement = try XCTUnwrap(resolver("a"))
            XCTAssertNotEqual(revision, model.accounts.first?.credentialRevision)
            XCTAssertEqual(replacement.viewerScopeID, scope, "A new session is still the same viewer: \(kind)")
            XCTAssertNotEqual(original.authorizationID, replacement.authorizationID)
            XCTAssertEqual((replacement.provider as? LiveTVAccountsTestProvider)?.session.accessToken, "fixture-rotated-token")
            XCTAssertFalse(replacement.authorizationID.contains("fixture-rotated-token"))
            XCTAssertFalse(scope.contains("fixture-effective-user-token"))

            // Durable rows may reopen, but must acquire the new runtime authorization.
            let source = LiveTVServerSource(id: "server", name: "Server", accountID: "a")
            let catalog = try LiveTVServerCatalog(
                source: source, context: original, channels: [.init(id: "native", name: "Saved")]
            )
            let rows = LiveTVLastSeenSnapshot.Source(
                sourceID: source.id, accountID: "a", kind: original.kind,
                entries: [.init(nativeID: "native", channel: catalog.channels[0])], viewerScopeID: scope
            )
            let reopened = try XCTUnwrap(LiveTVServerCatalog(lastSeen: rows, source: source, context: replacement))
            XCTAssertEqual(reopened.channels, catalog.channels)
            XCTAssertEqual(Set(reopened.references.values.map(\.authorizationID)), [replacement.authorizationID])
        }
    }

    func testLiveTVViewerScopeChangesWithServerAndServerUserForPlexJellyfinAndEmby() throws {
        for kind: ProviderKind in [.plex, .jellyfin, .emby] {
            let (model, store, profiles) = try makeModel(accountIDs: [])
            var current = account(id: "a", host: "a.example.com", provider: kind)
            model.registry.register(kind) { LiveTVAccountsTestProvider(session: $0.session) }
            model.tokenResolver = { store.token(for: $0) }
            profiles.setActiveAccountIDs(["a"], for: profiles.activeProfileID)
            var scopes: Set<String> = []
            for boundary in ["original", "server", "server-user"] {
                if boundary == "server" { current.server.id = "replacement-server" }
                if boundary == "server-user" { current.userID = "replacement-user" }
                try store.add(current, token: "same-token")
                model.reloadAccounts()
                let context = try XCTUnwrap(model.liveTVProviderResolver()("a"))
                let scope = try XCTUnwrap(context.viewerScopeID)
                XCTAssertFalse(scope.isEmpty)
                XCTAssertTrue(scopes.insert(scope).inserted, "Different \(boundary) must not reuse rows: \(kind)")
                XCTAssertEqual(model.liveTVProviderResolver()("a")?.viewerScopeID, scope)
            }
            XCTAssertEqual(scopes.count, 3)
        }
    }

    func testLiveTVMissingCredentialsAndEmptyRequiredViewerIdentityFailClosed() throws {
        for kind: ProviderKind in [.plex, .jellyfin, .emby] {
            for missing in ["account", "server", "server-user"] {
                let (model, store, profiles) = try makeModel(accountIDs: [])
                var invalid = account(id: missing == "account" ? "" : "a", host: "a.test", provider: kind)
                if missing == "server" { invalid.server.id = "" }
                if missing == "server-user" { invalid.userID = "" }
                try store.add(invalid, token: "fixture")
                model.registry.register(kind) { LiveTVAccountsTestProvider(session: $0.session) }
                profiles.setActiveAccountIDs([invalid.id], for: profiles.activeProfileID)
                model.reloadAccounts()
                XCTAssertNil(model.liveTVProviderResolver()(invalid.id), "An absent credential cannot resolve a provider")
                model.tokenResolver = { store.token(for: $0) }
                let context = try XCTUnwrap(model.liveTVProviderResolver()(invalid.id))
                XCTAssertNil(context.viewerScopeID, "Empty \(missing) cannot authorize durable rows: \(kind)")
            }
        }
    }

    func testLiveTVLateSnapshotCannotPublishUnderAReplacementProductionViewerScope() async throws {
        try await assertLateLiveTVResponseIsFenced(suspendSnapshot: true)
    }

    func testLiveTVLateProviderCannotPublishUnderAReplacementProductionViewerScope() async throws {
        try await assertLateLiveTVResponseIsFenced(suspendSnapshot: false)
    }

    private func assertLateLiveTVResponseIsFenced(suspendSnapshot: Bool) async throws {
        for kind: ProviderKind in [.plex, .jellyfin, .emby] {
            let (hub, store, profiles) = try makeModel(accountIDs: [])
            var current = account(id: "a", host: "a.test", provider: kind)
            try store.add(current, token: "fixture")
            profiles.setActiveAccountIDs(["a"], for: profiles.activeProfileID)
            let snapshotStarted = suspendSnapshot ? expectation(description: "Snapshot suspended: \(kind)") : nil
            let lineupStarted = expectation(description: "Lineup suspended: \(kind)")
            let snapshotGate = snapshotStarted.map { LiveTVAccountResponseGate(started: $0) }
            let lineupGate = LiveTVAccountResponseGate(started: lineupStarted)
            defer {
                Task {
                    await snapshotGate?.release()
                    await lineupGate.release()
                }
            }
            hub.registry.register(kind) { context in
                let name = context.session.userID == "replacement-user" ? "Replacement viewer" : "Previous viewer"
                return LiveTVAccountsTestProvider(session: context.session, channels: {
                    await lineupGate.wait()
                    return [.init(id: "native", name: name, groups: [name])]
                })
            }
            hub.tokenResolver = { store.token(for: $0) }
            hub.reloadAccounts()
            let resolver = hub.liveTVProviderResolver()
            let original = try XCTUnwrap(resolver("a"))
            let scope = try XCTUnwrap(original.viewerScopeID)
            XCTAssertFalse(scope.isEmpty)
            let source = LiveTVServerSource(id: "server", name: "Server", accountID: "a")
            let catalog = try LiveTVServerCatalog(
                source: source, context: original,
                channels: [.init(id: "native", name: "Previous viewer", groups: ["Previous viewer"])]
            )
            let rows = LiveTVLastSeenSnapshot(sources: [.init(
                sourceID: source.id, accountID: "a", kind: original.kind,
                entries: [.init(nativeID: "native", channel: catalog.channels[0])], viewerScopeID: scope
            )], browse: .init(categories: ["Previous viewer"], categoryCounts: ["Previous viewer": 1], totalCount: 1))
            let lastSeen = LiveTVAccountSnapshotStore(rows, gate: snapshotGate)
            let imports = LiveTVPrototypeImportModel(
                configuration: .init(servers: [source]), serverProviderResolver: resolver, lastSeen: lastSeen
            )
            let model = LiveTVPrototypeModel(channels: [])
            let reload = Task { await imports.reload(into: model, forceServerRefresh: false) }
            if let snapshotStarted {
                await fulfillment(of: [snapshotStarted], timeout: 2)
                XCTAssertTrue(model.channels.isEmpty)
            } else {
                await fulfillment(of: [lineupStarted], timeout: 2)
                XCTAssertEqual(model.channels.map(\.name), ["Previous viewer"], "Positive saved-row admission control")
            }

            current.userID = "replacement-user"
            try store.add(current, token: "replacement-token")
            hub.reloadAccounts()
            let replacement = try XCTUnwrap(resolver("a"))
            let replacementScope = try XCTUnwrap(replacement.viewerScopeID)
            XCTAssertFalse(replacementScope.isEmpty)
            XCTAssertNotEqual(scope, replacementScope)
            XCTAssertNotEqual(original.authorizationID, replacement.authorizationID)
            if suspendSnapshot {
                await snapshotGate?.release()
                await fulfillment(of: [lineupStarted], timeout: 2)
                XCTAssertTrue(model.channels.isEmpty, "A late snapshot must not install the previous viewer's rows")
                XCTAssertTrue(imports.serverChannelReferences.isEmpty)
                XCTAssertEqual(model.categoryChannelCount(nil), 0)
            }
            await lineupGate.release()
            await reload.value
            if !suspendSnapshot {
                XCTAssertTrue(model.channels.isEmpty, "The retired provider's late response must not publish")
                XCTAssertTrue(imports.serverChannelReferences.isEmpty)
                XCTAssertFalse(model.browsingCategories.contains { $0.name == "Previous viewer" })
                await imports.reload(into: model, forceServerRefresh: false)
            }
            XCTAssertEqual(model.channels.map(\.name), ["Replacement viewer"])
            XCTAssertEqual(Set(imports.serverChannelReferences.values.map(\.authorizationID)), [replacement.authorizationID])
            XCTAssertFalse(model.browsingCategories.contains { $0.name == "Previous viewer" })
            XCTAssertEqual(model.categoryChannelCount(nil), 1)
        }
    }

    func testLiveTVResolverIsBoundToTheProfileThatCreatedIt() throws {
        let (model, store, profiles) = try makeModel(accountIDs: [("a", "a.example.com")])
        model.registry.register(.jellyfin) { LiveTVAccountsTestProvider(session: $0.session) }
        model.tokenResolver = { _ in "fixture-effective-user-token" }
        store.setActiveAccountIDs(["a"])
        profiles.setActiveAccountIDs(["a"], for: profiles.activeProfileID)
        model.reloadAccounts()
        let resolver = model.liveTVProviderResolver()
        let original = try XCTUnwrap(resolver("a"))
        let other = profiles.add(name: "Other profile", activeAccountIDs: ["a"])
        profiles.select(other.id)
        model.reloadAccounts()
        XCTAssertNil(resolver("a"))
        let replacement = try XCTUnwrap(model.liveTVProviderResolver()("a"))
        XCTAssertNotEqual(original.authorizationID, replacement.authorizationID)
        let originalScope = try XCTUnwrap(original.viewerScopeID)
        let replacementScope = try XCTUnwrap(replacement.viewerScopeID)
        XCTAssertFalse(originalScope.isEmpty)
        XCTAssertFalse(replacementScope.isEmpty)
        XCTAssertNotEqual(originalScope, replacementScope)
    }
}

final class LiveTVAccountsTestProvider: MediaProvider, ServerLiveTVProviding, ServerAddressUpdating,
    AuthenticatedArtworkProviding, Sendable {
    var kind: ProviderKind { session.server.provider }
    let session: UserSession
    private let routes = Mutex<[URL]>([])
    var alternatives: [URL] { routes.withLock { $0 } }
    func updateServerAddresses(_ alternatives: [URL]) { routes.withLock { $0 = alternatives } }

    private let artwork: @Sendable () async throws -> Data
    private let channels: (@Sendable () async throws -> [ServerLiveTVChannel])?
    init(
        session: UserSession,
        artwork: @escaping @Sendable () async throws -> Data = { Data([1]) },
        channels: (@Sendable () async throws -> [ServerLiveTVChannel])? = nil
    ) {
        self.session = session
        self.artwork = artwork
        self.channels = channels
    }
    func artworkData(for reference: AuthenticatedArtworkReference) async throws -> Data { try await artwork() }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        if channels != nil { return .init(status: .available, supportsGuide: false) }
        XCTFail("Listing authorized accounts must not contact a Live TV server")
        throw ServerLiveTVError.unsupportedAPI
    }
    func liveTVChannels() async throws -> [ServerLiveTVChannel] {
        if let channels { return try await channels() }
        XCTFail("Listing authorized accounts must not load channels")
        return []
    }
    func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
        XCTFail("Listing authorized accounts must not load a guide")
        return []
    }
    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        XCTFail("Listing authorized accounts must not open a tuner")
        throw ServerLiveTVError.unsupportedPlaybackMode
    }
}

private actor LiveTVAccountResponseGate {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor LiveTVAccountSnapshotStore: LiveTVLastSeenStoring {
    private let snapshot: LiveTVLastSeenSnapshot
    private let gate: LiveTVAccountResponseGate?

    init(_ snapshot: LiveTVLastSeenSnapshot, gate: LiveTVAccountResponseGate?) {
        self.snapshot = snapshot
        self.gate = gate
    }

    func load() async -> LiveTVLastSeenSnapshot? {
        await gate?.wait()
        return snapshot
    }

    func save(_ snapshot: LiveTVLastSeenSnapshot?) async {}
}
