import XCTest
import CoreModels
import CoreNetworking
import FeatureAuth
import FeatureProfiles
import ProviderPlex
@testable import AppRuntime

@MainActor
final class OfflinePlexSignInTests: XCTestCase {
    private struct Fixture {
        let profiles: ProfilesModel
        let accounts: AccountsProvidersModel
        let model: PlexHomeUsersModel
        let proofs: OfflinePlexSignInStore
    }

    private func fixture(
        protected: Bool = true, savedProof: Bool = true,
        featureFlags: RuntimeFeatureFlags = .buildDefault
    ) throws -> Fixture {
        let suite = "OfflinePlexSignInTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let store = AccountStore(secureStore: InMemorySecureStore())
        try store.add(Account(
            id: "server-account",
            server: MediaServer(
                id: "server", name: "LAN Server",
                baseURL: URL(string: "http://192.0.2.1:32400")!, provider: .plex
            ),
            userID: "owner", userName: "Owner", deviceID: "device"
        ), token: "OWNER-NOT-A-VIEWER")
        let accounts = AccountsProvidersModel(
            accountStore: store, registry: ProviderRegistry(), profilesModel: profiles
        )
        accounts.reloadAccounts()
        profiles.update(profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "viewer", name: "Viewer", requiresPIN: protected, pinRequirementVerified: true),
            forPlexAccount: "server-account"
        ))
        let proofs = OfflinePlexSignInStore(secureStore: InMemorySecureStore(), defaults: defaults)
        if savedProof {
            try proofs.save(
                profile: profiles.activeProfile, account: XCTUnwrap(accounts.accounts.first),
                pinVerifier: protected ? ProfileLock.make(pin: "2468", iterations: 100) : nil,
                serverToken: "VIEWER-SERVER"
            )
        }
        let model = PlexHomeUsersModel(
            accountsProviders: accounts, profilesModel: profiles,
            plexHomeUserTokenCache: .init(store: InMemorySecureStore()),
            automaticSignInStore: .init(defaults: defaults, secureStore: InMemorySecureStore()),
            offlineSignInStore: proofs, runtimeFeatureFlags: featureFlags, switchProfile: { _ in }
        )
        model.plexHomeUsersFetch = { _, _ in throw URLError(.notConnectedToInternet) }
        model.plexHomeUserSwitch = { _, _, _, _ in throw URLError(.notConnectedToInternet) }
        return Fixture(profiles: profiles, accounts: accounts, model: model, proofs: proofs)
    }

    func testInternetOutageKeepsPINAndRestoresOnlyViewerServerToken() async throws {
        let fixture = try fixture()
        fixture.model.ensurePlexIdentityForActiveProfile()
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertEqual(fixture.model.plexPINEntryAvailability, .available)
        XCTAssertNil(fixture.model.resolvedToken(for: "server-account"))
        fixture.model.submitPlexPIN("0000")
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertNotNil(fixture.model.pendingPlexPINRequest)
        XCTAssertNil(fixture.model.resolvedToken(for: "server-account"))
        fixture.model.submitPlexPIN("2468")
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertNil(fixture.model.pendingPlexPINRequest)
        XCTAssertEqual(fixture.model.resolvedToken(for: "server-account"), "VIEWER-SERVER")
        XCTAssertNil(fixture.model.discoverToken(for: "server-account"))
    }

    func testUnprotectedPreviouslyAuthenticatedViewerCanEnterDuringOutage() async throws {
        let fixture = try fixture(protected: false)
        fixture.model.ensurePlexIdentityForActiveProfile()
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertNil(fixture.model.pendingPlexPINRequest)
        XCTAssertEqual(fixture.model.resolvedToken(for: "server-account"), "VIEWER-SERVER")
        XCTAssertNil(fixture.model.discoverToken(for: "server-account"))
    }

    func testDisabledFlagRetainsProofButCannotUseItDuringAnOutage() async throws {
        for protected in [false, true] {
            let fixture = try fixture(protected: protected, featureFlags: .init())
            fixture.model.ensurePlexIdentityForActiveProfile()
            await fixture.model.waitForPlexPINRequirementCheck()
            XCTAssertNotNil(fixture.model.pendingPlexPINRequest)
            XCTAssertNil(fixture.model.resolvedToken(for: "server-account"))
            XCTAssertEqual(fixture.model.plexPINEntryAvailability, .unavailable)
            XCTAssertNotNil(try fixture.proofs.load(
                profile: fixture.profiles.activeProfile, account: XCTUnwrap(fixture.accounts.accounts.first)
            ))
        }
    }

    func testDisabledFlagAllowsOnlinePINWithoutCreatingOfflineProof() async throws {
        let fixture = try fixture(savedProof: false, featureFlags: .init())
        fixture.model.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "viewer", name: "Viewer", requiresPIN: true)]
        }
        fixture.model.plexHomeUserSwitch = { _, pin, _, _ in
            XCTAssertEqual(pin, "2468")
            return "VIEWER-CLOUD"
        }
        fixture.model.plexServerTokenResolve = { _, _, _ in "VIEWER-SERVER" }
        fixture.model.ensurePlexIdentityForActiveProfile()
        await fixture.model.waitForPlexPINRequirementCheck()
        fixture.model.submitPlexPIN("2468")
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertNil(fixture.model.pendingPlexPINRequest)
        XCTAssertEqual(fixture.model.resolvedToken(for: "server-account"), "VIEWER-SERVER")
        XCTAssertNil(try fixture.proofs.load(
            profile: fixture.profiles.activeProfile, account: XCTUnwrap(fixture.accounts.accounts.first)
        ))
    }

    func testCachedViewerCanResolveTheSavedLANRouteWithoutCloudDiscovery() async throws {
        let fixture = try fixture(protected: false)
        fixture.model.ensurePlexIdentityForActiveProfile()
        await fixture.model.waitForPlexPINRequirementCheck()
        let token = try XCTUnwrap(fixture.model.resolvedToken(for: "server-account"))
        let local = try XCTUnwrap(URL(string: "http://192.168.1.25:32400"))
        let resolver = PlexConnectionResolver(
            candidates: [local, URL(string: "https://remote.example:32400")!],
            deviceProfile: .init(clientIdentifier: "offline-test"), token: token,
            probe: LANProbe(expected: local),
            refresh: {
                XCTFail("A reachable saved LAN address must not depend on plex.tv.")
                return []
            }, reachableSeed: local
        )
        let resolved = await resolver.resolved()
        XCTAssertEqual(resolved, local)
        XCTAssertTrue(resolver.hasConfirmedReachableConnection)
        XCTAssertFalse(OfflineMode.shared.isEnabled)
    }

    private struct LANProbe: HTTPClient {
        let expected: URL
        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            guard baseURL == expected else { throw URLError(.notConnectedToInternet) }
            XCTAssertEqual(endpoint.headers["X-Plex-Token"], "VIEWER-SERVER")
            return (Data(), try XCTUnwrap(HTTPURLResponse(
                url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil
            )))
        }
    }

    func testExplicitOfflineModeDoesNotAttemptCloudAuthentication() async throws {
        OfflineMode.shared.setEnabled(true)
        defer { OfflineMode.shared.setEnabled(false) }
        let fixture = try fixture()
        fixture.model.plexHomeUsersFetch = { _, _ in
            XCTFail("Explicit offline entry must not query plex.tv.")
            throw AppError.unauthorized
        }
        fixture.model.plexHomeUserSwitch = { _, _, _, _ in
            XCTFail("The established PIN must be verified locally.")
            throw AppError.unauthorized
        }
        fixture.model.ensurePlexIdentityForActiveProfile()
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertEqual(fixture.model.plexPINEntryAvailability, .available)
        fixture.model.submitPlexPIN("2468")
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertNil(fixture.model.pendingPlexPINRequest)
        XCTAssertEqual(fixture.model.resolvedToken(for: "server-account"), "VIEWER-SERVER")
    }

    func testForegroundEntryStillRequiresTheCachedPIN() async throws {
        let fixture = try fixture()
        fixture.model.ensurePlexIdentityForActiveProfile()
        await fixture.model.waitForPlexPINRequirementCheck()
        fixture.model.submitPlexPIN("2468")
        await fixture.model.waitForPlexPINRequirementCheck()
        fixture.model.suspendProfileAccessForForeground()
        fixture.model.resumeProfileAccessAfterForegroundSelection()
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertNotNil(fixture.model.pendingPlexPINRequest)
        XCTAssertEqual(fixture.model.plexPINEntryAvailability, .available)
        fixture.model.submitPlexPIN("0000")
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertNotNil(fixture.model.pendingPlexPINRequest)
        fixture.model.submitPlexPIN("2468")
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertNil(fixture.model.pendingPlexPINRequest)
    }

    func testUnprotectedSwitchConnectionFailureUsesEstablishedProof() async throws {
        let fixture = try fixture(protected: false)
        fixture.model.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "viewer", name: "Viewer", requiresPIN: false)]
        }
        fixture.model.ensurePlexIdentityForActiveProfile()
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertNil(fixture.model.pendingPlexPINRequest)
        XCTAssertEqual(fixture.model.resolvedToken(for: "server-account"), "VIEWER-SERVER")
    }

    func testCloudOnlyRepairPreservesTheOfflineServerCredential() async throws {
        let fixture = try fixture(protected: false, savedProof: false)
        fixture.model.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "viewer", name: "Viewer", requiresPIN: false)]
        }
        fixture.model.plexHomeUserSwitch = { _, _, _, _ in "VIEWER-CLOUD" }
        fixture.model.plexServerTokenResolve = { _, _, _ in "VIEWER-SERVER" }
        fixture.model.ensurePlexIdentityForActiveProfile()
        await fixture.model.waitForPlexPINRequirementCheck()
        fixture.model.plexDiscoverTokens.setToken(nil, for: "server-account")
        fixture.model.plexHomeUserSwitch = { _, _, _, _ in "REFRESHED-CLOUD" }
        let repaired = try await fixture.model.resolveDiscoverToken(for: "server-account")
        XCTAssertEqual(repaired, "REFRESHED-CLOUD")
        let proof = try fixture.proofs.load(
            profile: fixture.profiles.activeProfile, account: XCTUnwrap(fixture.accounts.accounts.first)
        )
        XCTAssertEqual(proof?.serverToken, "VIEWER-SERVER")
    }

    func testSuccessfulOnlinePINCreatesTheDeviceLocalVerifier() async throws {
        let fixture = try fixture(savedProof: false)
        fixture.model.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "viewer", name: "Viewer", requiresPIN: true)]
        }
        fixture.model.plexHomeUserSwitch = { _, pin, _, _ in
            XCTAssertEqual(pin, "2468")
            return "VIEWER-CLOUD"
        }
        fixture.model.plexServerTokenResolve = { _, _, _ in "VIEWER-SERVER" }
        fixture.model.ensurePlexIdentityForActiveProfile()
        await fixture.model.waitForPlexPINRequirementCheck()
        fixture.model.submitPlexPIN("2468")
        await fixture.model.waitForPlexPINRequirementCheck()
        let proof = try XCTUnwrap(fixture.proofs.load(
            profile: fixture.profiles.activeProfile, account: XCTUnwrap(fixture.accounts.accounts.first)
        ))
        XCTAssertEqual(proof.serverToken, "VIEWER-SERVER")
        let verifier = try XCTUnwrap(proof.pinVerifier)
        XCTAssertTrue(verifier.matches(pin: "2468"))
        XCTAssertFalse(verifier.matches(pin: "0000"))
        fixture.model.beginExplicitProfileActivation()
        fixture.model.plexHomeUsersFetch = { _, _ in throw URLError(.notConnectedToInternet) }
        fixture.model.plexHomeUserSwitch = { _, _, _, _ in throw URLError(.notConnectedToInternet) }
        fixture.model.ensurePlexIdentityForActiveProfile()
        await fixture.model.waitForPlexPINRequirementCheck()
        fixture.model.submitPlexPIN("2468")
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertEqual(fixture.model.resolvedToken(for: "server-account"), "VIEWER-SERVER")
        XCTAssertNil(fixture.model.discoverToken(for: "server-account"))
    }

    func testMissingProofDoesNotUseOwnerCredential() async throws {
        let fixture = try fixture(protected: false, savedProof: false)
        fixture.model.ensurePlexIdentityForActiveProfile()
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertNotNil(fixture.model.pendingPlexPINRequest)
        XCTAssertEqual(fixture.model.plexPINEntryAvailability, .unavailable)
        XCTAssertNil(fixture.model.resolvedToken(for: "server-account"))
    }

    func testOnlineCredentialRejectionRevokesOfflineProof() async throws {
        let fixture = try fixture()
        fixture.model.plexHomeUsersFetch = { _, _ in throw AppError.unauthorized }
        fixture.model.ensurePlexIdentityForActiveProfile()
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertNil(try fixture.proofs.load(
            profile: fixture.profiles.activeProfile, account: XCTUnwrap(fixture.accounts.accounts.first)
        ))
        fixture.model.plexHomeUsersFetch = { _, _ in throw URLError(.notConnectedToInternet) }
        fixture.model.retryPlexPINRequirement()
        await fixture.model.waitForPlexPINRequirementCheck()
        XCTAssertEqual(fixture.model.plexPINEntryAvailability, .unavailable)
        XCTAssertNil(fixture.model.resolvedToken(for: "server-account"))
    }

    func testProofIsBoundToProfileAccountDeviceAndHomeUser() throws {
        let fixture = try fixture()
        let account = try XCTUnwrap(fixture.accounts.accounts.first)
        let profile = fixture.profiles.activeProfile
        XCTAssertNotNil(try fixture.proofs.load(profile: profile, account: account))
        var changed = account
        changed.deviceID = "another-device"
        XCTAssertNil(try fixture.proofs.load(profile: profile, account: changed))
        changed = account
        changed.credentialRevision = CredentialRevision()
        XCTAssertNil(try fixture.proofs.load(profile: profile, account: changed))
        let anotherViewer = profile.settingHomeUserBinding(
            .init(homeUserID: "another-viewer", name: "Viewer", requiresPIN: true, pinRequirementVerified: true),
            forPlexAccount: account.id
        )
        XCTAssertNil(try fixture.proofs.load(profile: anotherViewer, account: account))
        var locked = profile
        locked.lock = ProfileLock.make(pin: "1234", iterations: 100)
        XCTAssertNil(try fixture.proofs.load(profile: locked, account: account))
    }

    func testOnlyConnectivityFailuresPermitCachedSignIn() {
        for error in [
            URLError(.secureConnectionFailed), URLError(.serverCertificateUntrusted),
            URLError(.cancelled), URLError(.badServerResponse)
        ] {
            XCTAssertFalse(OfflinePlexSignInStore.permitsFallback(after: error))
        }
        XCTAssertFalse(OfflinePlexSignInStore.permitsFallback(after: AppError.unauthorized))
        XCTAssertFalse(OfflinePlexSignInStore.permitsFallback(after: AppError.invalidResponse))
        XCTAssertFalse(OfflinePlexSignInStore.permitsFallback(after: CancellationError()))
        XCTAssertTrue(OfflinePlexSignInStore.permitsFallback(after: URLError(.notConnectedToInternet)))
        XCTAssertTrue(OfflinePlexSignInStore.permitsFallback(after: URLError(.cannotConnectToHost)))
    }
}
