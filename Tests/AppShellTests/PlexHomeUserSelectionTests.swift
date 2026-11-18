import CoreModels
import CoreUI
import FeatureAuth
import XCTest
@testable import AppRuntime

@MainActor
final class PlexHomeUserSelectionTests: XCTestCase {
    private struct Fixture {
        let model: PlexHomeUsersModel
        let profiles: ProfilesModel
        let profileStore: ProfileStore
        let hub: AccountsProvidersModel
        let startup: AutomaticSignInStore
    }

    private func fixture() throws -> Fixture {
        let suite = "PlexHomeUserSelectionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let profileStore = ProfileStore(defaults: defaults)
        let profiles = ProfilesModel(store: profileStore)
        profiles.markFirstRunProfileSetupComplete()
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        for id in ["a", "b"] {
            try accounts.add(Account(
                id: id, server: MediaServer(
                    id: id, name: id, baseURL: URL(string: "https://\(id).example")!, provider: .plex
                ), userID: "owner", userName: "Owner", deviceID: "fixture"
            ), token: "ADMIN-\(id)")
        }
        let hub = AccountsProvidersModel(
            accountStore: accounts, registry: ProviderRegistry(), profilesModel: profiles
        )
        hub.reloadAccounts()
        let startup = AutomaticSignInStore(defaults: defaults, secureStore: InMemorySecureStore())
        let model = PlexHomeUsersModel(
            accountsProviders: hub, profilesModel: profiles,
            plexHomeUserTokenCache: PlexHomeUserTokenCache(store: InMemorySecureStore()),
            automaticSignInStore: startup,
            offlineSignInStore: .init(secureStore: InMemorySecureStore()),
            switchProfile: { _ in XCTFail("Cancelling a proposed user must not switch Plozz profiles.") }
        )
        model.plexHomeUsersFetch = { _, _ in
            ["old", "target", "next"].map { PlexHomeUser(id: $0, name: $0, requiresPIN: true) }
        }
        model.plexHomeUserSwitch = { user, pin, _, _ in
            guard pin == "2468" else { throw AppError.unauthorized }
            return "CLOUD-\(user)"
        }
        model.plexServerTokenResolve = { _, token, _ in "SERVER-\(token)" }
        return Fixture(model: model, profiles: profiles, profileStore: profileStore, hub: hub, startup: startup)
    }

    private func establishPreviousUsers(_ env: Fixture) async throws {
        for id in ["a", "b"] {
            env.model.setPlexHomeUserForActiveProfile(
                accountID: id, user: PlexHomeUser(id: "old", name: "old", requiresPIN: true)
            )
            await env.model.waitForPlexPINRequirementCheck()
            env.model.submitPlexPIN("2468")
            await env.model.waitForPlexPINRequirementCheck()
            XCTAssertNil(env.model.pendingPlexPINRequest)
        }
        env.model.setAutomaticallySignIn(true, profileIsUnlocked: true)
        XCTAssertTrue(env.model.automaticallySignIn)
        XCTAssertNotNil(try env.startup.load())
    }

    private func assertPreviousUsers(
        _ env: Fixture, file: StaticString = #filePath, line: UInt = #line
    ) {
        for id in ["a", "b"] {
            XCTAssertEqual(env.profiles.activeProfile.homeUserBinding(forPlexAccount: id)?.homeUserID, "old", file: file, line: line)
            XCTAssertEqual(env.profileStore.loadProfiles().first?.homeUserBinding(forPlexAccount: id)?.homeUserID, "old", file: file, line: line)
            XCTAssertEqual(env.model.resolvedToken(for: id), "SERVER-CLOUD-old", file: file, line: line)
            XCTAssertEqual(env.model.discoverToken(for: id), "CLOUD-old", file: file, line: line)
            XCTAssertTrue(env.model.hasResolvedWatchMutationIdentity(forAccountID: id), file: file, line: line)
        }
    }

    func testWrongPINAndCancelPreserveSavedUsersCredentialsAndStartupTrust() async throws {
        let env = try fixture()
        try await establishPreviousUsers(env)
        let revisions = env.hub.accounts.map { env.model.effectiveCredentialRevision(for: $0) }
        let generation = env.model.plexIdentityGeneration
        env.model.setPlexHomeUserForActiveProfile(
            accountID: "a", user: PlexHomeUser(id: "target", name: "Target", requiresPIN: true)
        )
        assertPreviousUsers(env)
        XCTAssertEqual(env.model.plexPINEntryAvailability, .checking)
        await env.model.waitForPlexPINRequirementCheck()
        XCTAssertEqual(env.model.plexPINEntryAvailability, .available)
        env.model.submitPlexPIN("0000")
        await env.model.waitForPlexPINRequirementCheck()
        XCTAssertEqual(env.model.plexPINError, ProfileLockCopy.incorrectPIN)
        assertPreviousUsers(env)
        env.model.cancelPlexPIN()
        XCTAssertNil(env.model.pendingPlexPINRequest)
        env.model.cancelPlexPIN()
        env.model.dismissPlexPINIfPresented()
        assertPreviousUsers(env)
        XCTAssertEqual(env.model.plexIdentityGeneration, generation)
        XCTAssertEqual(env.hub.accounts.map { env.model.effectiveCredentialRevision(for: $0) }, revisions)
        let saved = try XCTUnwrap(env.startup.load())
        XCTAssertEqual(saved.accounts.compactMap(\.homeUserID), ["old", "old"])
        XCTAssertTrue(saved.plexCredentials.values.allSatisfy { $0.pinVerified == true })
    }

    func testCommitWaitsForAuthenticationAndCredentialResolutionIncludingOwner() async throws {
        for isOwner in [false, true] {
            let env = try fixture()
            try await establishPreviousUsers(env)
            let responses = AsyncStream<String>.makeStream()
            defer { responses.continuation.finish() }
            let resolving = expectation(description: "Resolving target credentials")
            env.model.plexServerTokenResolve = { _, _, _ in
                resolving.fulfill()
                for await token in responses.stream { return token }
                return nil
            }
            env.model.setPlexHomeUserForActiveProfile(
                accountID: "a", user: PlexHomeUser(id: "target", name: "Target", requiresPIN: true, isAdmin: isOwner)
            )
            await env.model.waitForPlexPINRequirementCheck()
            env.model.submitPlexPIN("2468")
            await fulfillment(of: [resolving], timeout: 2)
            assertPreviousUsers(env)
            env.model.ensurePlexIdentityForActiveProfile()
            assertPreviousUsers(env)
            responses.continuation.yield("TARGET-SERVER")
            await env.model.waitForPlexPINRequirementCheck()
            XCTAssertNil(env.model.pendingPlexPINRequest)
            XCTAssertEqual(env.profileStore.loadProfiles().first?.homeUserBinding(forPlexAccount: "a")?.homeUserID, "target")
            XCTAssertEqual(env.model.resolvedToken(for: "a"), "TARGET-SERVER")
            XCTAssertEqual(env.model.discoverToken(for: "a"), "CLOUD-target")
            XCTAssertEqual(env.model.resolvedToken(for: "b"), "SERVER-CLOUD-old")
            XCTAssertEqual(try env.startup.load()?.accounts.first(where: { $0.id == "a" })?.homeUserID, "target")
        }
    }

    func testUnprotectedSelectionFailureAndRetryDoNotExposePINOrSaveEarly() async throws {
        let env = try fixture()
        try await establishPreviousUsers(env)
        env.model.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "target", name: "Target", requiresPIN: false)]
        }
        env.model.plexHomeUserSwitch = { _, pin, _, _ in
            XCTAssertNil(pin)
            throw URLError(.notConnectedToInternet)
        }
        env.model.setPlexHomeUserForActiveProfile(
            accountID: "a", user: PlexHomeUser(id: "target", name: "Target", requiresPIN: false)
        )
        await env.model.waitForPlexPINRequirementCheck()
        XCTAssertEqual(env.model.plexPINEntryAvailability, .unavailable)
        assertPreviousUsers(env)
        env.model.plexHomeUserSwitch = { _, pin, _, _ in
            XCTAssertNil(pin)
            return "UNPROTECTED"
        }
        env.model.retryPlexPINRequirement()
        await env.model.waitForPlexPINRequirementCheck()
        XCTAssertNil(env.model.pendingPlexPINRequest)
        XCTAssertEqual(env.model.plexPINEntryAvailability, .checking)
        XCTAssertEqual(env.profiles.activeProfile.homeUserBinding(forPlexAccount: "a")?.homeUserID, "target")
        XCTAssertEqual(env.profiles.activeProfile.homeUserBinding(forPlexAccount: "a")?.requiresPIN, false)
    }

    func testSupersededSuccessAndFailureCannotSaveOrContaminateNewSelection() async throws {
        enum Mutation: CaseIterable {
            case cancel, newerSelection, activation, profile, binding, lock, credential, accountRemoval
        }
        for mutation in Mutation.allCases {
            for fails in [false, true] {
                let env = try fixture()
                try await establishPreviousUsers(env)
                let originalProfileID = env.profiles.activeProfileID
                env.model.plexHomeUserSwitch = { _, _, _, _ in
                    try await MainActor.run {
                        switch mutation {
                        case .cancel: env.model.cancelPlexPIN()
                        case .newerSelection:
                            env.model.setPlexHomeUserForActiveProfile(
                                accountID: "a", user: PlexHomeUser(id: "next", name: "Next", requiresPIN: true)
                            )
                        case .activation: env.model.beginExplicitProfileActivation()
                        case .profile:
                            let other = env.profiles.add(name: "Other", avatarSymbol: "person", colorIndex: 1)
                            env.profiles.select(other.id)
                        case .binding:
                            env.profiles.update(env.profiles.activeProfile.settingHomeUserBinding(
                                .init(homeUserID: "external", name: "External", requiresPIN: true), forPlexAccount: "a"
                            ))
                        case .lock:
                            var profile = env.profiles.activeProfile
                            profile.replaceLock(with: ProfileLock.make(pin: "1357", iterations: 1))
                            env.profiles.update(profile)
                        case .credential:
                            try env.hub.accountStore.add(env.hub.accounts[0], token: "ROTATED")
                            env.hub.reloadAccounts()
                        case .accountRemoval:
                            env.model.forgetAccount("a")
                            try env.hub.accountStore.remove(id: "a")
                            env.hub.reloadAccounts()
                        }
                    }
                    if fails { throw AppError.unauthorized }
                    return "STALE-TARGET"
                }
                env.model.setPlexHomeUserForActiveProfile(
                    accountID: "a", user: PlexHomeUser(id: "target", name: "Target", requiresPIN: true)
                )
                await env.model.waitForPlexPINRequirementCheck()
                env.model.submitPlexPIN("2468")
                await env.model.waitForPlexPINRequirementCheck()
                await env.model.waitForPlexPINRequirementCheck()
                let saved = try XCTUnwrap(env.profileStore.loadProfiles().first(where: { $0.id == originalProfileID }))
                XCTAssertNotEqual(saved.homeUserBinding(forPlexAccount: "a")?.homeUserID, "target", "\(mutation), failure=\(fails)")
                XCTAssertNotEqual(env.model.discoverToken(for: "a"), "STALE-TARGET")
                XCTAssertNil(env.model.plexPINError, "A superseded response must not poison the live prompt.")
                if mutation == .cancel { assertPreviousUsers(env) }
                if mutation == .newerSelection {
                    XCTAssertEqual(env.model.pendingPlexPINRequest?.homeUserID, "next")
                    env.model.cancelPlexPIN()
                }
            }
        }
    }

    func testReplacementAccountCannotReuseProtectedPINProof() async throws {
        enum Replacement: CaseIterable { case credential, server, user }
        for replacement in Replacement.allCases {
            let env = try fixture()
            try await establishPreviousUsers(env)
            var account = try XCTUnwrap(env.hub.accounts.first(where: { $0.id == "a" }))
            if replacement == .server { account.server.id = "replacement-server" }
            if replacement == .user { account.userID = "replacement-owner" }
            try env.hub.accountStore.add(account, token: replacement == .credential ? "ROTATED" : "ADMIN-a")
            env.hub.reloadAccounts()
            XCTAssertNil(env.model.resolvedToken(for: "a"), "Stale credentials must be unavailable before reconciliation.")
            XCTAssertNil(env.model.discoverToken(for: "a"))
            XCTAssertFalse(env.model.hasResolvedWatchMutationIdentity(forAccountID: "a"))
            env.model.ensurePlexIdentityForActiveProfile()
            await env.model.waitForPlexPINRequirementCheck()
            XCTAssertEqual(env.model.pendingPlexPINRequest?.homeUserID, "old")
            XCTAssertNil(env.model.discoverToken(for: "a"))
            XCTAssertFalse(env.model.hasResolvedWatchMutationIdentity(forAccountID: "a"))
            XCTAssertNil(try env.startup.load())
            XCTAssertEqual(env.model.resolvedToken(for: "b"), "SERVER-CLOUD-old")
        }
    }

    func testDifferentUserWithIdenticalTokenStillChangesCredentialIdentity() async throws {
        let env = try fixture()
        try await establishPreviousUsers(env)
        let previousRevision = env.model.effectiveCredentialRevision(for: env.hub.accounts[0])
        let generation = env.model.plexIdentityGeneration
        env.model.plexServerTokenResolve = { _, _, _ in "SERVER-CLOUD-old" }
        env.model.setPlexHomeUserForActiveProfile(
            accountID: "a", user: PlexHomeUser(id: "target", name: "Target", requiresPIN: true)
        )
        await env.model.waitForPlexPINRequirementCheck()
        env.model.submitPlexPIN("2468")
        await env.model.waitForPlexPINRequirementCheck()
        XCTAssertNotEqual(env.model.effectiveCredentialRevision(for: env.hub.accounts[0]), previousRevision)
        XCTAssertGreaterThan(env.model.plexIdentityGeneration, generation)
    }

    func testCloudOnlyRecoveryCannotRevalidateAStaleServerCredential() async throws {
        let env = try fixture()
        env.model.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "old", name: "old", requiresPIN: false)]
        }
        env.model.plexHomeUserSwitch = { _, _, _, _ in "CLOUD-old" }
        env.model.setPlexHomeUserForActiveProfile(
            accountID: "a", user: PlexHomeUser(id: "old", name: "old", requiresPIN: false)
        )
        await env.model.waitForPlexPINRequirementCheck()
        XCTAssertEqual(env.model.resolvedToken(for: "a"), "SERVER-CLOUD-old")
        let account = try XCTUnwrap(env.hub.accounts.first(where: { $0.id == "a" }))
        try env.hub.accountStore.add(account, token: "ROTATED")
        env.hub.reloadAccounts()
        env.model.plexHomeUserSwitch = { _, _, _, _ in
            XCTFail("Cloud-only recovery must not relabel a stale server credential.")
            return "NEW-CLOUD"
        }
        do {
            _ = try await env.model.resolveDiscoverToken(for: "a")
            XCTFail("A replaced source requires full identity reconciliation.")
        } catch let error as AppError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertNil(env.model.resolvedToken(for: "a"))
        XCTAssertNil(env.model.discoverToken(for: "a"))
        XCTAssertFalse(env.model.hasResolvedWatchMutationIdentity(forAccountID: "a"))
    }
}
