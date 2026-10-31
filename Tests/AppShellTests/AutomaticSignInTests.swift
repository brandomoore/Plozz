import XCTest
import CoreModels
import FeatureAuth
import FeatureMusic
import FeatureProfiles
import FeatureSettings
@testable import AppRuntime
@testable import AppShell

@MainActor
final class AutomaticSignInTests: XCTestCase {
    private struct Household {
        let profiles: ProfileStore
        let accounts: AccountStore
        let startup: AutomaticSignInStore
        let defaults: UserDefaults
        let secrets: InMemorySecureStore
    }

    private struct Launch {
        let profiles: ProfilesModel
        let hub: AccountsProvidersModel
        let plex: PlexHomeUsersModel
        let flow: ProfileFlowModel
        let switchCache: PlexHomeUserTokenCache
    }

    private func household(provider: ProviderKind = .plex) throws -> Household {
        let name = "AutomaticSignInTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        try accounts.add(Account(
            id: "account",
            server: MediaServer(
                id: "server", name: "Server",
                baseURL: URL(string: "https://server.example")!, provider: provider
            ),
            userID: "owner", userName: "Owner", deviceID: "device"
        ), token: "owner-token")
        let secrets = InMemorySecureStore()
        return Household(
            profiles: ProfileStore(defaults: defaults),
            accounts: accounts,
            startup: AutomaticSignInStore(defaults: defaults, secureStore: secrets),
            defaults: defaults, secrets: secrets
        )
    }

    private func launch(_ household: Household, startup: AutomaticSignInStore? = nil) -> Launch {
        let profiles = ProfilesModel(store: household.profiles)
        let hub = AccountsProvidersModel(
            accountStore: household.accounts,
            registry: ProviderRegistry(), profilesModel: profiles
        )
        hub.reloadAccounts()
        let cache = PlexHomeUserTokenCache(store: InMemorySecureStore())
        let plex = PlexHomeUsersModel(
            accountsProviders: hub, profilesModel: profiles,
            plexHomeUserTokenCache: cache,
            automaticSignInStore: startup ?? household.startup,
            switchProfile: { _ in }
        )
        plex.plexHomeUsersFetch = { _, _ in throw URLError(.notConnectedToInternet) }
        plex.plexHomeUserSwitch = { user, pin, _, _ in
            guard pin == "2468" else { throw AppError.unauthorized }
            return "discover-\(user)"
        }
        plex.plexServerTokenResolve = { _, token, _ in "server-\(token)" }
        let flow = ProfileFlowModel(
            profilesModel: profiles, accountsProviders: hub, plexHomeUsers: plex,
            profileSettings: ProfileSettingsModel(namespace: profiles.activeNamespace),
            audioController: AudioPlaybackController(),
            updateTrackersForActiveProfile: {}, discardWatchReconciler: { _ in }
        )
        return Launch(profiles: profiles, hub: hub, plex: plex, flow: flow, switchCache: cache)
    }

    private func drain() async {
        for _ in 0..<200 { await Task.yield() }
    }

    private func authenticatePlex(_ env: Launch, user: String = "parent") async {
        env.plex.setPlexHomeUserForActiveProfile(
            accountID: "account",
            user: PlexHomeUser(id: user, name: user, requiresPIN: true)
        )
        XCTAssertNotNil(env.plex.pendingPlexPINRequest)
        env.plex.submitPlexPIN("2468")
        await drain()
        XCTAssertNil(env.plex.pendingPlexPINRequest)
        XCTAssertEqual(env.plex.resolvedToken(for: "account"), "server-discover-\(user)")
    }

    func testEnabledPreferenceAndLegacyTokensRequirePINProofBeforeTrustedStartup() async throws {
        for legacyRequiresPIN in [false, true] {
            let house = try household()
            let initial = launch(house)
            initial.profiles.update(initial.profiles.activeProfile.settingHomeUserBinding(
                .init(
                    homeUserID: "parent", name: "Parent", requiresPIN: legacyRequiresPIN,
                    pinRequirementVerified: nil
                ),
                forPlexAccount: "account"
            ))
            let profile = initial.profiles.activeProfile
            try house.startup.enable(with: .init(
                profile: .init(profile),
                accounts: initial.hub.accounts.map { .init($0, profile: profile) },
                plexCredentials: [
                    "account": .init(serverToken: "UNVERIFIED-SERVER", discoverToken: "UNVERIFIED-CLOUD")
                ]
            ))
            let env = launch(house)
            env.plex.plexHomeUsersFetch = { _, _ in
                [PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true)]
            }
            env.plex.plexHomeUserSwitch = { _, pin, _, _ in
                guard let pin else {
                    XCTFail("Owner-authorized PIN-less switching is not PIN proof.")
                    return "UNVERIFIED-CLOUD"
                }
                guard pin == "2468" else { throw AppError.unauthorized }
                return "VERIFIED-CLOUD"
            }
            XCTAssertFalse(env.plex.restoreAutomaticSignInAtLaunch())
            XCTAssertTrue(env.plex.automaticallySignIn, "Reauthentication need not erase the opt-in preference.")
            env.plex.ensurePlexIdentityForActiveProfile()
            await env.plex.waitForPlexPINRequirementCheck()
            XCTAssertNotNil(env.plex.pendingPlexPINRequest)
            XCTAssertNil(env.plex.discoverToken(for: "account"))
            XCTAssertNil(try house.startup.load())
            env.plex.setAutomaticallySignIn(true, profileIsUnlocked: true)
            XCTAssertNotNil(env.plex.automaticSignInError)
            env.plex.submitPlexPIN("")
            env.plex.submitPlexPIN("0000")
            await env.plex.waitForPlexPINRequirementCheck()
            XCTAssertNotNil(env.plex.pendingPlexPINRequest)
            XCTAssertNil(try house.startup.load())
            env.plex.submitPlexPIN("2468")
            await env.plex.waitForPlexPINRequirementCheck()
            XCTAssertNil(env.plex.pendingPlexPINRequest)
            XCTAssertEqual(try house.startup.load()?.plexCredentials["account"]?.pinVerified, true)
            let next = launch(house)
            XCTAssertTrue(next.plex.restoreAutomaticSignInAtLaunch())
            next.plex.ensurePlexIdentityForActiveProfile()
            XCTAssertNil(next.plex.pendingPlexPINRequest)
            XCTAssertEqual(next.plex.discoverToken(for: "account"), "VERIFIED-CLOUD")
        }
    }

    func testPlexPINProofDoesNotTravelWithSharedProfilesOrAccounts() async throws {
        let house = try household()
        let first = launch(house)
        await authenticatePlex(first)
        first.flow.setAutomaticallySignIn(true)
        let otherDevice = try household()
        otherDevice.defaults.set(true, forKey: "plozz.device.automaticallySignIn")
        let second = launch(.init(
            profiles: house.profiles, accounts: house.accounts,
            startup: otherDevice.startup, defaults: otherDevice.defaults, secrets: otherDevice.secrets
        ))
        XCTAssertFalse(second.plex.restoreAutomaticSignInAtLaunch())
        second.plex.ensurePlexIdentityForActiveProfile()
        await second.plex.waitForPlexPINRequirementCheck()
        XCTAssertNotNil(second.plex.pendingPlexPINRequest)
        XCTAssertNil(second.plex.discoverToken(for: "account"))
        XCTAssertNil(try otherDevice.startup.load())
    }

    func testDisabledByDefaultAndExistingLaunchPickerIsUnchanged() throws {
        let house = try household()
        let env = launch(house)
        _ = env.profiles.add(name: "Second", avatarSymbol: "person", colorIndex: 1)
        env.flow.prepareLaunchPicker()
        XCTAssertFalse(env.plex.automaticallySignIn)
        XCTAssertTrue(env.flow.isChoosingProfile)
        XCTAssertNil(try house.startup.load())
    }

    func testProtectedPlexStartupRestoresBothTokensWithoutChangingPIN() async throws {
        let house = try household()
        let first = launch(house)
        await authenticatePlex(first)
        first.flow.setAutomaticallySignIn(true)
        XCTAssertTrue(first.plex.automaticallySignIn)
        XCTAssertNil(first.switchCache.token(account: "account", homeUser: "parent"))
        XCTAssertNil(first.switchCache.discoverToken(account: "account", homeUser: "parent"))

        let next = launch(house)
        next.flow.prepareLaunchPicker()
        next.plex.ensurePlexIdentityForActiveProfile()
        XCTAssertFalse(next.flow.isChoosingProfile)
        XCTAssertNil(next.plex.pendingPlexPINRequest)
        XCTAssertEqual(next.plex.resolvedToken(for: "account"), "server-discover-parent")
        XCTAssertEqual(next.plex.discoverToken(for: "account"), "discover-parent")
        XCTAssertEqual(next.profiles.activeProfile.homeUserBinding(forPlexAccount: "account")?.requiresPIN, true)
        XCTAssertFalse(next.plex.restoreAutomaticSignInAtLaunch(), "The launch exemption is one-shot")
    }

    func testRestoredHomeSessionAuthorizesReenabledSiblingButNotManualActivation() async throws {
        let house = try household()
        try house.accounts.add(Account(
            id: "sibling", server: MediaServer(
                id: "sibling-server", name: "Sibling", baseURL: URL(string: "https://sibling.example")!, provider: .plex
            ), userID: "owner", userName: "Owner", deviceID: "device"
        ), token: "sibling-owner")
        let initial = launch(house)
        for id in ["account", "sibling"] {
            initial.profiles.update(initial.profiles.activeProfile.settingHomeUserBinding(
                .init(homeUserID: "parent", name: "Parent", requiresPIN: true), forPlexAccount: id
            ))
        }
        let profile = initial.profiles.activeProfile
        try house.startup.enable(with: .init(
            profile: .init(profile),
            accounts: initial.hub.accounts.map { .init($0, profile: profile) }.sorted { $0.id < $1.id },
            plexCredentials: Dictionary(uniqueKeysWithValues: ["account", "sibling"].map {
                ($0, .init(serverToken: "saved-\($0)", discoverToken: "parent-cloud", pinVerified: true))
            })
        ))
        let next = launch(house)
        next.plex.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true)]
        }
        next.plex.plexHomeUserSwitch = { _, _, _, _ in
            XCTFail("A restored authorized sibling should not request or replay a PIN.")
            return "unexpected"
        }
        XCTAssertTrue(next.plex.restoreAutomaticSignInAtLaunch())
        next.plex.ensurePlexIdentityForActiveProfile()
        next.profiles.setActiveAccountIDs(["account"], for: profile.id)
        next.hub.reloadAccounts()
        next.plex.activeAccountsDidChange()
        XCTAssertNil(next.plex.resolvedToken(for: "sibling"))
        next.profiles.setActiveAccountIDs(["account", "sibling"], for: profile.id)
        next.hub.reloadAccounts()
        next.plex.activeAccountsDidChange()
        await next.plex.waitForPlexPINRequirementCheck()
        XCTAssertNil(next.plex.pendingPlexPINRequest)
        XCTAssertEqual(next.plex.discoverToken(for: "sibling"), "parent-cloud")
        XCTAssertEqual(next.plex.resolvedToken(for: "sibling"), "server-parent-cloud")

        next.plex.beginExplicitProfileActivation()
        next.plex.ensurePlexIdentityForActiveProfile()
        await next.plex.waitForPlexPINRequirementCheck()
        XCTAssertEqual(next.plex.plexPINEntryAvailability, .available)
        XCTAssertNotNil(next.plex.pendingPlexPINRequest)
        XCTAssertNil(next.plex.discoverToken(for: "account"))
        XCTAssertNil(next.plex.discoverToken(for: "sibling"))
    }

    func testManualSwitchBackToSamePlexUserStillPrompts() async throws {
        let house = try household()
        let first = launch(house)
        let parent = first.profiles.activeProfileID
        await authenticatePlex(first)
        first.flow.setAutomaticallySignIn(true)
        let next = launch(house)
        next.flow.prepareLaunchPicker()
        let other = next.profiles.add(
            name: "Other", avatarSymbol: "person", colorIndex: 1,
            plexHomeUserID: "parent", plexHomeUserName: "Parent",
            plexHomeUserAccountID: "account", plexHomeUserRequiresPIN: true
        )
        next.flow.switchProfile(to: other.id)
        XCTAssertNotNil(next.plex.pendingPlexPINRequest)
        XCTAssertNil(next.plex.discoverToken(for: "account"))
        XCTAssertNil(try house.startup.load(), "A pending switch must revoke the old startup session")
        next.flow.switchProfile(to: parent)
        XCTAssertNotNil(next.plex.pendingPlexPINRequest)
        XCTAssertFalse(next.plex.restoreAutomaticSignInAtLaunch())
        next.plex.submitPlexPIN("0000")
        await drain()
        XCTAssertNotNil(next.plex.plexPINError)
        XCTAssertNotNil(next.plex.pendingPlexPINRequest)
        XCTAssertNil(try house.startup.load())
        next.plex.submitPlexPIN("2468")
        await drain()
        XCTAssertNil(next.plex.pendingPlexPINRequest)
    }

    func testReaddedPlexPINRequiresFreshProofOnManualSwitchWithOrWithoutAutomaticSignIn() async throws {
        for automaticallySignIn in [false, true] {
            let house = try household()
            let env = launch(house)
            let parent = env.profiles.activeProfileID
            let other = env.profiles.add(name: "Other", avatarSymbol: "person", colorIndex: 1)
            await authenticatePlex(env)
            if automaticallySignIn { env.flow.setAutomaticallySignIn(true) }

            env.plex.plexHomeUsersFetch = { _, _ in
                [PlexHomeUser(id: "parent", name: "Parent", requiresPIN: false)]
            }
            env.plex.plexHomeUserSwitch = { _, pin, _, _ in
                XCTAssertNil(pin)
                return "UNPROTECTED-CLOUD"
            }
            env.flow.switchProfile(to: other.id)
            env.flow.switchProfile(to: parent)
            await drain()
            XCTAssertNil(env.plex.pendingPlexPINRequest)
            XCTAssertEqual(env.profiles.activeProfile.homeUserBinding(forPlexAccount: "account")?.requiresPIN, false)
            XCTAssertEqual(env.plex.discoverToken(for: "account"), "UNPROTECTED-CLOUD")
            env.switchCache.store(token: "OLD-SERVER", account: "account", homeUser: "parent")
            env.switchCache.storeDiscoverToken("OLD-CLOUD", account: "account", homeUser: "parent")

            env.plex.plexHomeUsersFetch = { _, _ in
                [PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true)]
            }
            env.plex.plexHomeUserSwitch = { _, pin, _, _ in
                XCTAssertNotNil(pin, "The owner's token can switch without a PIN; that must not authorize entry.")
                guard pin == "1357" else { throw AppError.unauthorized }
                return "REPROTECTED-CLOUD"
            }
            env.flow.switchProfile(to: other.id)
            env.flow.switchProfile(to: parent)
            XCTAssertNotNil(env.plex.pendingPlexPINRequest)
            XCTAssertEqual(env.plex.plexPINEntryAvailability, .checking)
            XCTAssertNil(env.plex.resolvedToken(for: "account"))
            XCTAssertNil(env.plex.discoverToken(for: "account"))
            await drain()
            XCTAssertEqual(env.plex.plexPINEntryAvailability, .available)
            XCTAssertEqual(env.profiles.activeProfile.homeUserBinding(forPlexAccount: "account")?.requiresPIN, true)
            XCTAssertNil(try house.startup.load())
            XCTAssertNil(env.switchCache.token(account: "account", homeUser: "parent"))
            do {
                _ = try await env.plex.resolveDiscoverToken(for: "account")
                XCTFail("Cloud recovery must not bypass pending profile authorization.")
            } catch let error as AppError {
                XCTAssertEqual(error, .unauthorized)
            }
            env.plex.submitPlexPIN("2468")
            await drain()
            XCTAssertNotNil(env.plex.pendingPlexPINRequest)
            XCTAssertNil(try house.startup.load())
            env.plex.submitPlexPIN("1357")
            await drain()
            XCTAssertNil(env.plex.pendingPlexPINRequest)
            XCTAssertEqual(env.plex.discoverToken(for: "account"), "REPROTECTED-CLOUD")

            let next = launch(house)
            XCTAssertEqual(next.plex.restoreAutomaticSignInAtLaunch(), automaticallySignIn)
            next.flow.switchProfile(to: parent)
            XCTAssertNotNil(next.plex.pendingPlexPINRequest, "Startup trust never authorizes an explicit selection.")
            XCTAssertNil(next.plex.discoverToken(for: "account"))
        }
    }

    func testJellyfinAndLocalProfileLockUseStartupOnlyUnlockCredit() async throws {
        let house = try household(provider: .jellyfin)
        let first = launch(house)
        var parent = first.profiles.activeProfile
        parent.replaceLock(with: ProfileLock.make(pin: "1357", iterations: 1))
        first.profiles.update(parent)
        first.flow.switchProfile(to: parent.id)
        let accepted = await first.flow.submitProfileLockPIN("1357")
        XCTAssertTrue(accepted)
        first.flow.setAutomaticallySignIn(true)

        let next = launch(house)
        next.flow.prepareLaunchPicker()
        XCTAssertFalse(next.flow.isChoosingProfile)
        XCTAssertFalse(next.flow.activeProfileAwaitsUnlock)
        XCTAssertFalse(next.flow.isUnlockedThisRun(parent.id), "Startup must not grant manual PIN credit")
        XCTAssertFalse(next.flow.enforceLockOnActiveProfile())
        XCTAssertEqual(next.profiles.activeProfile.lock, parent.lock)
        let other = next.profiles.add(name: "Other", avatarSymbol: "person", colorIndex: 1)
        next.flow.switchProfile(to: other.id)
        next.flow.switchProfile(to: parent.id)
        XCTAssertEqual(next.flow.pendingLockedProfile?.id, parent.id)
        next.flow.cancelProfileLockPrompt()
        XCTAssertEqual(next.profiles.activeProfileID, other.id)
    }

    func testAutomaticSignInBypassesReturnPromptUntilDisabled() async throws {
        let house = try household(provider: .jellyfin)
        let first = launch(house)
        var parent = first.profiles.activeProfile
        parent.replaceLock(with: ProfileLock.make(pin: "1357", iterations: 1))
        first.profiles.update(parent)
        first.flow.switchProfile(to: parent.id)
        let accepted = await first.flow.submitProfileLockPIN("1357")
        XCTAssertTrue(accepted)
        first.flow.setAutomaticallySignIn(true)
        let next = launch(house)
        next.flow.prepareLaunchPicker()
        XCTAssertFalse(next.flow.activeProfileAwaitsUnlock)

        XCTAssertNil(next.flow.foregroundReturnDelay)
        next.flow.lockForForegroundIfNeeded()
        XCTAssertFalse(next.flow.isForegroundLocked)
        XCTAssertFalse(next.flow.activeProfileAwaitsUnlock)
        next.flow.setAutomaticallySignIn(false)
        XCTAssertEqual(next.flow.foregroundReturnDelay, 0)
        next.flow.lockForForegroundIfNeeded()
        XCTAssertTrue(next.flow.activeProfileAwaitsUnlock)
        XCTAssertFalse(next.plex.isAutomaticallySignedIn(parent))
        next.flow.switchProfile(to: parent.id)
        XCTAssertNotNil(next.flow.pendingLockedProfile)
        XCTAssertFalse(next.flow.canFinishForegroundUnlock)
    }

    func testForegroundPlexNetworkFailureCannotReuseStartupPINProof() async throws {
        let house = try household()
        let first = launch(house)
        await authenticatePlex(first)
        first.flow.setAutomaticallySignIn(true)
        let next = launch(house)
        next.flow.prepareLaunchPicker()
        XCTAssertFalse(next.flow.isChoosingProfile)
        next.flow.setAutomaticallySignIn(false)
        next.flow.lockForForegroundIfNeeded()
        next.flow.switchProfile(to: next.profiles.activeProfileID)
        await next.plex.waitForPlexPINRequirementCheck()
        XCTAssertNotNil(next.plex.pendingPlexPINRequest)
        XCTAssertEqual(next.plex.plexPINEntryAvailability, .unavailable)
        XCTAssertFalse(next.flow.canFinishForegroundUnlock)
        next.flow.cancelForegroundProfileSelection()
        next.flow.cancelProfileSelection()
        XCTAssertTrue(next.flow.isForegroundLocked)
        XCTAssertTrue(next.flow.isChoosingProfile)
    }

    func testReturnDefaultsFollowProfilesAcrossLaunchWithoutChangingColdStart() throws {
        let house = try household(provider: .jellyfin)
        let first = launch(house)
        XCTAssertNil(first.flow.foregroundReturnDelay)
        let second = first.profiles.add(name: "Second")
        first.flow.switchProfile(to: second.id)
        XCTAssertEqual(first.flow.foregroundReturnDelay, 300)
        let next = launch(house)
        XCTAssertEqual(next.flow.foregroundReturnDelay, 300)
        next.flow.prepareLaunchPicker()
        XCTAssertTrue(next.flow.isChoosingProfile, "The return grace period does not bypass cold-start selection.")
    }

    func testLastSuccessfullySelectedProfileIsRemembered() throws {
        let house = try household(provider: .jellyfin)
        let first = launch(house)
        first.flow.setAutomaticallySignIn(true)
        let other = first.profiles.add(name: "Other", avatarSymbol: "person", colorIndex: 1)
        first.flow.switchProfile(to: other.id)
        let next = launch(house)
        next.flow.prepareLaunchPicker()
        XCTAssertEqual(next.profiles.activeProfileID, other.id)
        XCTAssertFalse(next.flow.isChoosingProfile)
    }

    func testDisableDeletesTrustAndRestoresLaunchPrompt() async throws {
        let house = try household()
        let env = launch(house)
        await authenticatePlex(env)
        env.flow.setAutomaticallySignIn(true)
        env.flow.setAutomaticallySignIn(false)
        XCTAssertNil(house.secrets.string(for: "startupSession"))
        let next = launch(house)
        next.flow.prepareLaunchPicker()
        next.plex.ensurePlexIdentityForActiveProfile()
        XCTAssertFalse(next.plex.automaticallySignIn)
        XCTAssertNotNil(next.plex.pendingPlexPINRequest)
    }

    func testCannotEnableFromUnprovedOrPendingProfile() throws {
        let house = try household()
        let env = launch(house)
        env.plex.setPlexHomeUserForActiveProfile(
            accountID: "account",
            user: PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true)
        )
        env.flow.setAutomaticallySignIn(true)
        XCTAssertFalse(env.plex.automaticallySignIn)
        XCTAssertNotNil(env.plex.automaticSignInError)
        XCTAssertNil(try house.startup.load())
        var profile = env.profiles.activeProfile
        profile.replaceLock(with: ProfileLock.make(pin: "1357", iterations: 1))
        env.profiles.update(profile)
        env.plex.setAutomaticallySignIn(true, profileIsUnlocked: false)
        XCTAssertFalse(env.plex.automaticallySignIn)
    }

    func testChangedPlexBindingRejectsSavedIdentity() async throws {
        let house = try household()
        let env = launch(house)
        await authenticatePlex(env)
        env.flow.setAutomaticallySignIn(true)
        env.profiles.update(env.profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "another", name: "Another", requiresPIN: true),
            forPlexAccount: "account"
        ))
        let next = launch(house)
        XCTAssertFalse(next.plex.restoreAutomaticSignInAtLaunch())
        XCTAssertNil(next.plex.discoverToken(for: "account"))
        next.plex.ensurePlexIdentityForActiveProfile()
        XCTAssertEqual(next.plex.pendingPlexPINRequest?.homeUserID, "another")
    }

    func testChangedAccountCredentialRejectsSavedIdentity() async throws {
        let house = try household()
        let env = launch(house)
        await authenticatePlex(env)
        env.flow.setAutomaticallySignIn(true)
        var account = try XCTUnwrap(env.hub.accounts.first)
        account.credentialRevision = CredentialRevision()
        try house.accounts.add(account, token: "new-owner-token")
        let next = launch(house)
        XCTAssertFalse(next.plex.restoreAutomaticSignInAtLaunch())
        XCTAssertNil(next.plex.discoverToken(for: "account"))
    }

    func testChangedLocalLockRejectsSavedStartupUnlock() throws {
        let house = try household(provider: .emby)
        let env = launch(house)
        env.flow.setAutomaticallySignIn(true)
        var profile = env.profiles.activeProfile
        profile.replaceLock(with: ProfileLock.make(pin: "1357", iterations: 1))
        env.profiles.update(profile)
        let next = launch(house)
        next.flow.prepareLaunchPicker()
        XCTAssertTrue(next.flow.isChoosingProfile)
        XCTAssertTrue(next.flow.activeProfileAwaitsUnlock)
        XCTAssertNil(try house.startup.load())
    }

    func testChangedAccountSourceRejectsSavedIdentityWithoutReusingPINProof() async throws {
        for changesServer in [false, true] {
            let house = try household()
            let env = launch(house)
            await authenticatePlex(env)
            env.flow.setAutomaticallySignIn(true)
            var account = try XCTUnwrap(env.hub.accounts.first)
            if changesServer {
                account.server.id = "replacement-server"
            } else {
                account.userID = "replacement-user"
            }
            try house.accounts.add(account, token: "owner-token")
            let next = launch(house)
            XCTAssertFalse(next.plex.restoreAutomaticSignInAtLaunch())
            XCTAssertNil(next.plex.discoverToken(for: "account"))
        }
    }

    func testSignOutClearsSessionButLatePINCancelPreservesAuthenticatedSession() async throws {
        let house = try household()
        let env = launch(house)
        await authenticatePlex(env)
        env.flow.setAutomaticallySignIn(true)
        env.plex.forgetAccount("account")
        XCTAssertNil(try house.startup.load())
        await authenticatePlex(env)
        XCTAssertNotNil(try house.startup.load())
        env.plex.cancelPlexPIN()
        XCTAssertNotNil(try house.startup.load())
    }

    func testQueuedPINCannotUnlockLaterManualActivation() async throws {
        let house = try household()
        let env = launch(house)
        env.profiles.update(env.profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "parent", name: "Parent", requiresPIN: true), forPlexAccount: "account"
        ))
        env.plex.ensurePlexIdentityForActiveProfile()
        env.plex.submitPlexPIN("2468")
        env.flow.switchProfile(to: env.profiles.activeProfileID)
        await drain()
        XCTAssertNotNil(env.plex.pendingPlexPINRequest)
        XCTAssertNil(env.plex.discoverToken(for: "account"))
    }

    func testPreferenceDoesNotTravelWithProfileSettings() throws {
        let house = try household(provider: .jellyfin)
        let env = launch(house)
        env.flow.setAutomaticallySignIn(true)
        XCTAssertTrue(house.startup.isEnabled)
        XCTAssertNil(ProfileSettingsTransfer.capture(namespace: nil, defaults: house.defaults)["plozz.device.automaticallySignIn"])
        let otherDevice = try household(provider: .jellyfin)
        XCTAssertFalse(launch(otherDevice).plex.automaticallySignIn)
    }

    func testCorruptSessionFailsClosedWithVisibleError() throws {
        let house = try household(provider: .jellyfin)
        launch(house).flow.setAutomaticallySignIn(true)
        try house.secrets.setString("not valid JSON", for: "startupSession")
        let next = launch(house)
        XCTAssertFalse(next.plex.restoreAutomaticSignInAtLaunch())
        XCTAssertFalse(next.plex.automaticallySignIn)
        XCTAssertNotNil(next.plex.automaticSignInError)
    }

    func testAllBoundPlexAccountsRestoreTogether() async throws {
        let house = try household()
        let initial = launch(house)
        let original = try XCTUnwrap(initial.hub.accounts.first)
        var second = original
        second.id = "second-account"
        second.credentialRevision = CredentialRevision()
        try house.accounts.add(second, token: "second-owner")
        let env = launch(house)
        await authenticatePlex(env)
        env.plex.setPlexHomeUserForActiveProfile(
            accountID: second.id,
            user: PlexHomeUser(id: "other-parent", name: "Other Parent", requiresPIN: true)
        )
        env.plex.submitPlexPIN("2468")
        await drain()
        env.flow.setAutomaticallySignIn(true)
        XCTAssertTrue(env.plex.automaticallySignIn)
        let next = launch(house)
        XCTAssertTrue(next.plex.restoreAutomaticSignInAtLaunch())
        next.plex.ensurePlexIdentityForActiveProfile()
        XCTAssertNil(next.plex.pendingPlexPINRequest)
        XCTAssertEqual(next.plex.discoverToken(for: "account"), "discover-parent")
        XCTAssertEqual(next.plex.discoverToken(for: second.id), "discover-other-parent")

        let saved = try XCTUnwrap(house.startup.load())
        try house.startup.save(.init(
            profile: saved.profile, accounts: saved.accounts,
            plexCredentials: ["account": try XCTUnwrap(saved.plexCredentials["account"])]
        ))
        let incomplete = launch(house)
        XCTAssertFalse(incomplete.plex.restoreAutomaticSignInAtLaunch())
        XCTAssertNil(incomplete.plex.discoverToken(for: "account"), "No partial restore")
        XCTAssertNil(incomplete.plex.discoverToken(for: second.id))
    }

    func testAutomaticSignInExcludesDisabledPlexBindingsAndRejectsReenabledSources() throws {
        let house = try household()
        let env = launch(house)
        env.profiles.update(env.profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "parent", name: "Parent", requiresPIN: true), forPlexAccount: "account"
        ))
        env.profiles.setActiveAccountIDs([], for: env.profiles.activeProfileID)
        env.hub.reloadAccounts()
        env.plex.ensurePlexIdentityForActiveProfile()
        env.flow.setAutomaticallySignIn(true)
        XCTAssertTrue(env.plex.automaticallySignIn)
        let saved = try XCTUnwrap(house.startup.load())
        XCTAssertTrue(saved.accounts.isEmpty)
        XCTAssertTrue(saved.plexCredentials.isEmpty)

        let next = launch(house)
        XCTAssertTrue(next.plex.restoreAutomaticSignInAtLaunch())
        next.plex.ensurePlexIdentityForActiveProfile()
        XCTAssertNil(next.plex.pendingPlexPINRequest)
        XCTAssertNil(next.plex.resolvedToken(for: "account"))
        XCTAssertNil(next.plex.discoverToken(for: "account"))

        next.profiles.setActiveAccountIDs(["account"], for: next.profiles.activeProfileID)
        let reenabled = launch(house)
        XCTAssertFalse(reenabled.plex.restoreAutomaticSignInAtLaunch())
        reenabled.plex.ensurePlexIdentityForActiveProfile()
        XCTAssertNotNil(reenabled.plex.pendingPlexPINRequest)
        XCTAssertNil(reenabled.plex.resolvedToken(for: "account"))
    }

    func testDisabledPlexSourceDoesNotBypassSeparateProfileLock() async throws {
        let house = try household()
        let env = launch(house)
        var profile = env.profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "parent", name: "Parent", requiresPIN: true), forPlexAccount: "account"
        )
        profile.replaceLock(with: ProfileLock.make(pin: "1357", iterations: 1))
        env.profiles.update(profile)
        env.profiles.setActiveAccountIDs([], for: profile.id)
        env.hub.reloadAccounts()
        env.flow.switchProfile(to: profile.id)
        XCTAssertTrue(env.flow.activeProfileAwaitsUnlock)
        let incorrect = await env.flow.submitProfileLockPIN("0000")
        XCTAssertFalse(incorrect)
        let accepted = await env.flow.submitProfileLockPIN("1357")
        XCTAssertTrue(accepted)
        XCTAssertFalse(env.flow.activeProfileAwaitsUnlock)
        XCTAssertNil(env.plex.pendingPlexPINRequest)
        XCTAssertNil(env.plex.resolvedToken(for: "account"))
    }

    func testDisablingPlexSourceRemovesTrustedStartupCredentials() async throws {
        let house = try household()
        let env = launch(house)
        await authenticatePlex(env)
        env.flow.setAutomaticallySignIn(true)
        XCTAssertNotNil(try house.startup.load()?.plexCredentials["account"])
        env.profiles.setActiveAccountIDs([], for: env.profiles.activeProfileID)
        env.hub.reloadAccounts()
        env.plex.ensurePlexIdentityForActiveProfile()
        let saved = try XCTUnwrap(house.startup.load())
        XCTAssertTrue(saved.plexCredentials.isEmpty)
        XCTAssertTrue(saved.accounts.isEmpty)
        let next = launch(house)
        XCTAssertTrue(next.plex.restoreAutomaticSignInAtLaunch())
        XCTAssertNil(next.plex.resolvedToken(for: "account"))
        XCTAssertNil(next.plex.discoverToken(for: "account"))
    }

    func testInFlightPINCannotUnlockAReactivatedProfile() async throws {
        let house = try household()
        let env = launch(house)
        let flow = env.flow
        let profileID = env.profiles.activeProfileID
        env.plex.plexServerTokenResolve = { _, _, _ in
            await MainActor.run { flow.switchProfile(to: profileID) }
            return "stale-server-token"
        }
        env.profiles.update(env.profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "parent", name: "Parent", requiresPIN: true), forPlexAccount: "account"
        ))
        env.plex.ensurePlexIdentityForActiveProfile()
        env.plex.submitPlexPIN("2468")
        await drain()
        XCTAssertNotNil(env.plex.pendingPlexPINRequest)
        XCTAssertNil(env.plex.discoverToken(for: "account"))
        XCTAssertNil(try house.startup.load())
    }

    func testDeletedLastUsedProfileCannotUnlockFallbackProfile() throws {
        let house = try household(provider: .jellyfin)
        let env = launch(house)
        var fallback = env.profiles.activeProfile
        fallback.replaceLock(with: ProfileLock.make(pin: "1357", iterations: 1))
        env.profiles.update(fallback)
        let other = env.profiles.add(name: "Other", avatarSymbol: "person", colorIndex: 1)
        env.flow.switchProfile(to: other.id)
        env.flow.setAutomaticallySignIn(true)
        env.profiles.remove(other.id)
        let next = launch(house)
        next.flow.prepareLaunchPicker()
        XCTAssertTrue(next.flow.isChoosingProfile)
        XCTAssertTrue(next.flow.activeProfileAwaitsUnlock)
        XCTAssertNil(try house.startup.load())
    }

    private struct UnwritableStore: SecureStoring {
        enum Failure: Error { case unavailable }
        let backing: InMemorySecureStore
        func string(for key: String) -> String? { backing.string(for: key) }
        func readString(for key: String) throws -> String? { backing.string(for: key) }
        func setString(_ value: String, for key: String) throws { throw Failure.unavailable }
        func removeValue(for key: String) throws { throw Failure.unavailable }
    }

    func testFailedKeychainWriteDoesNotEnableAutomaticSignIn() throws {
        let house = try household(provider: .jellyfin)
        let broken = AutomaticSignInStore(
            defaults: house.defaults, secureStore: UnwritableStore(backing: house.secrets)
        )
        let env = launch(house, startup: broken)
        env.flow.setAutomaticallySignIn(true)
        XCTAssertFalse(env.plex.automaticallySignIn)
        XCTAssertNotNil(env.plex.automaticSignInError)
        XCTAssertNil(try house.startup.load())
    }

    func testFailedKeychainDeletionStillDisablesRestoration() throws {
        let house = try household(provider: .jellyfin)
        launch(house).flow.setAutomaticallySignIn(true)
        let broken = AutomaticSignInStore(
            defaults: house.defaults, secureStore: UnwritableStore(backing: house.secrets)
        )
        let env = launch(house, startup: broken)
        env.flow.setAutomaticallySignIn(false)
        XCTAssertFalse(env.plex.automaticallySignIn)
        XCTAssertNotNil(env.plex.automaticSignInError)
        XCTAssertNotNil(house.secrets.string(for: "startupSession"))
        XCTAssertFalse(launch(house).plex.restoreAutomaticSignInAtLaunch())
    }

    func testFailedInvalidationOnSwitchCannotResurrectOldTrust() throws {
        let house = try household(provider: .jellyfin)
        launch(house).flow.setAutomaticallySignIn(true)
        let broken = AutomaticSignInStore(
            defaults: house.defaults, secureStore: UnwritableStore(backing: house.secrets)
        )
        let env = launch(house, startup: broken)
        env.flow.switchProfile(to: env.profiles.activeProfileID)
        XCTAssertFalse(env.plex.automaticallySignIn)
        XCTAssertNotNil(env.plex.automaticSignInError)
        XCTAssertFalse(launch(house).plex.restoreAutomaticSignInAtLaunch())
    }

    func testLegacyPickerPreferenceCannotSkipSelectionOrGrantPINTrust() throws {
        for legacyValue in ["true", "false"] {
            let house = try household(provider: .jellyfin)
            house.defaults.set(
                Data(legacyValue.utf8), forKey: "com.plozz.profiles.askOnStartup"
            )
            let env = launch(house)
            let other = env.profiles.add(name: "Other", avatarSymbol: "person", colorIndex: 1)
            env.profiles.select(other.id)
            let next = launch(house)
            next.flow.prepareLaunchPicker()
            XCTAssertTrue(next.flow.isChoosingProfile)
            XCTAssertFalse(next.plex.automaticallySignIn)
        }
    }

    func testDisablingTheOnlyStartupSettingRestoresProfileSelection() throws {
        let house = try household(provider: .jellyfin)
        let env = launch(house)
        let other = env.profiles.add(name: "Other", avatarSymbol: "person", colorIndex: 1)
        env.flow.switchProfile(to: other.id)
        env.flow.setAutomaticallySignIn(true)
        let next = launch(house)
        next.flow.prepareLaunchPicker()
        XCTAssertFalse(next.flow.isChoosingProfile)
        next.flow.setAutomaticallySignIn(false)
        let disabled = launch(house)
        disabled.flow.prepareLaunchPicker()
        XCTAssertTrue(disabled.flow.isChoosingProfile)
        XCTAssertFalse(disabled.flow.isProfileSelectionCancelable)
    }

    func testSettingsHaveNoMessageWithoutAnError() {
        let settings = AutomaticSignInSettings(isEnabled: .constant(false))
        XCTAssertNil(settings.error)
    }

    func testSettingsStillSurfaceErrorsWithoutHelpText() {
        let settings = AutomaticSignInSettings(
            isEnabled: .constant(false),
            error: "Couldn’t update automatic sign-in on this device. Try again."
        )
        XCTAssertNotNil(settings.error)
    }

    func testLocalProfileStartupIsProviderIndependent() async throws {
        for provider in [ProviderKind.jellyfin, .emby, .silo] {
            let house = try household(provider: provider)
            let env = launch(house)
            var profile = env.profiles.activeProfile
            profile.replaceLock(with: ProfileLock.make(pin: "1357", iterations: 1))
            env.profiles.update(profile)
            env.flow.switchProfile(to: profile.id)
            let accepted = await env.flow.submitProfileLockPIN("1357")
            XCTAssertTrue(accepted)
            env.flow.setAutomaticallySignIn(true)
            let next = launch(house)
            next.flow.prepareLaunchPicker()
            XCTAssertFalse(next.flow.isChoosingProfile, provider.rawValue)
            XCTAssertFalse(next.flow.activeProfileAwaitsUnlock, provider.rawValue)
            XCTAssertEqual(next.profiles.activeProfileID, profile.id)
        }
    }

    func testStandaloneProfilesRestoreWithoutServerAccounts() throws {
        let house = try household()
        try house.accounts.clearAll()
        let env = launch(house)
        let other = env.profiles.add(name: "Other", avatarSymbol: "person", colorIndex: 1)
        env.flow.switchProfile(to: other.id)
        env.flow.setAutomaticallySignIn(true)
        let next = launch(house)
        next.flow.prepareLaunchPicker()
        XCTAssertTrue(next.hub.accounts.isEmpty)
        XCTAssertFalse(next.flow.isChoosingProfile)
        XCTAssertEqual(next.profiles.activeProfileID, other.id)
    }
}
