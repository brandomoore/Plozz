#if os(iOS)
import CoreModels
import FeatureAuth
import XCTest
@testable import AppRuntime
@testable import AppShelliOS

@MainActor
final class PlexSyncAuthorizationTests: XCTestCase {
    func testSyncedImportIdentityReusesProfileButStillRequiresPlexAuthorization() async throws {
        try await withApp { app in
            await authenticate(app)
            let activeID = app.profiles.activeProfileID
            let child = try XCTUnwrap(app.profiles.profiles.first { $0.id != activeID })
            var incoming = ProfileSyncDTO(profile: child)
            incoming.plexHomeImportIdentity = .init(ownerUserID: "owner", homeUserID: "child")
            app.applySyncRecords(["profile:\(child.id)": try XCTUnwrap(CanonicalJSON.encode(incoming))])
            XCTAssertNil(app.profiles.profiles.first { $0.id == child.id }?.homeUserBinding(forPlexAccount: "plex"))
            XCTAssertEqual(app.accountsProviders.tokenResolver("plex"), "FIXTURE-SERVER")
            let users = [
                PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true),
                PlexHomeUser(id: "child", name: "Child", requiresPIN: true)
            ]
            app.plexHomeUsers.plexHomeUsersFetch = { _, _ in users }
            app.plexHomeUsers.presentUserSelection(.init(
                accountID: "plex", serverName: "Fixture", users: users,
                isFirstRun: false, applyToAccountIDs: ["plex"]
            ))
            XCTAssertEqual(app.plexHomeUsers.importOnboardingProfiles(), .existing)
            XCTAssertEqual(app.profiles.profiles.count, 2)
            XCTAssertEqual(app.plexHomeUsers.importedOnboardingProfileID(for: users[1]), child.id)
            XCTAssertEqual(app.profiles.activeProfileID, activeID)

            app.selectProfile(child.id)
            await app.plexHomeUsers.waitForPlexPINRequirementCheck()
            XCTAssertEqual(app.plexHomeUsers.pendingPlexPINRequest?.homeUserID, "child")
            XCTAssertNil(app.accountsProviders.tokenResolver("plex"))
        }
    }

    func testRepeatedPlexSignInReusesLegacyAccountWithoutReplacingTheHomeUser() async throws {
        try await withApp { app in
            await authenticate(app)
            let original = try XCTUnwrap(app.accountsProviders.accounts.first { $0.id == "plex" })
            let binding = app.profiles.activeProfile.homeUserBinding(forPlexAccount: original.id)
            let membership = app.activeAccountIDs(for: app.profiles.activeProfileID)

            XCTAssertTrue(app.persist([original.session(token: "FIXTURE-OWNER")]))
            await app.plexHomeUsers.waitForPlexPINRequirementCheck()

            XCTAssertEqual(app.accountsProviders.accounts, [original])
            XCTAssertEqual(app.profiles.activeProfile.homeUserBinding(forPlexAccount: original.id), binding)
            XCTAssertEqual(app.activeAccountIDs(for: app.profiles.activeProfileID), membership)
            XCTAssertNil(app.plexHomeUsers.pendingPlexPINRequest)
            XCTAssertEqual(app.accountsProviders.tokenResolver(original.id), "FIXTURE-SERVER")
        }
    }

    func testCosmeticSyncDoesNotAskForTheSamePlexPINAgain() async throws {
        try await withApp { app in
            await authenticate(app)
            let generation = app.plexHomeUsers.plexIdentityGeneration
            let activeID = app.profiles.activeProfileID
            for profile in app.profiles.profiles {
                var update = ProfileSyncDTO(profile: profile)
                update.name = "Renamed \(profile.name)"
                app.applySyncRecords(["profile:\(profile.id)": try XCTUnwrap(CanonicalJSON.encode(update))])
                await app.plexHomeUsers.waitForPlexPINRequirementCheck()
                XCTAssertEqual(app.profiles.activeProfileID, activeID)
                XCTAssertNil(app.plexHomeUsers.pendingPlexPINRequest)
                XCTAssertEqual(app.accountsProviders.tokenResolver("plex"), "FIXTURE-SERVER")
                XCTAssertEqual(app.plexHomeUsers.plexIdentityGeneration, generation)
                XCTAssertEqual(app.profiles.profiles.first { $0.id == profile.id }?.name, update.name)
            }
        }
    }

    func testCosmeticSyncPreservesInFlightPlexPINSubmission() async throws {
        try await withApp { app in
            let started = expectation(description: "Plex accepts the PIN request")
            let (release, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            app.plexHomeUsers.plexHomeUserSwitch = { _, pin, _, _ in
                XCTAssertEqual(pin, "2468")
                started.fulfill()
                for await _ in release { break }
                return "FIXTURE-CLOUD"
            }
            app.plexHomeUsers.submitPlexPIN("2468")
            await fulfillment(of: [started], timeout: 3)
            let request = app.plexHomeUsers.pendingPlexPINRequest
            var update = ProfileSyncDTO(profile: app.profiles.activeProfile)
            update.colorIndex += 1
            app.applySyncRecords(["profile:\(update.id)": try XCTUnwrap(CanonicalJSON.encode(update))])
            XCTAssertEqual(app.plexHomeUsers.pendingPlexPINRequest, request)
            XCTAssertTrue(app.plexHomeUsers.isSubmittingPlexPIN)
            continuation.yield(())
            continuation.finish()
            await app.plexHomeUsers.waitForPlexPINRequirementCheck()
            XCTAssertNil(app.plexHomeUsers.pendingPlexPINRequest)
            XCTAssertEqual(app.accountsProviders.tokenResolver("plex"), "FIXTURE-SERVER")
        }
    }

    func testSyncedMembershipStillRevokesAndRechecksPlexAuthorization() async throws {
        try await withApp { app in
            await authenticate(app)
            let key = "membership:\(app.profiles.activeProfileID)"
            app.applySyncRecords([key: try XCTUnwrap(CanonicalJSON.encode([String]()))])
            XCTAssertNil(app.accountsProviders.tokenResolver("plex"))
            XCTAssertNil(app.plexHomeUsers.pendingPlexPINRequest)
            app.applySyncRecords([key: try XCTUnwrap(CanonicalJSON.encode(["plex"]))])
            await app.plexHomeUsers.waitForPlexPINRequirementCheck()
            XCTAssertEqual(app.plexHomeUsers.pendingPlexPINRequest?.homeUserID, "parent")
            XCTAssertNil(app.accountsProviders.tokenResolver("plex"))
        }
    }

    func testManualSelectionAfterSyncStillRechecksThePlexPIN() async throws {
        try await withApp { app in
            await authenticate(app)
            app.applySyncRecords([:])
            app.selectProfile(app.profiles.activeProfileID)
            await app.plexHomeUsers.waitForPlexPINRequirementCheck()
            XCTAssertEqual(app.plexHomeUsers.pendingPlexPINRequest?.homeUserID, "parent")
            XCTAssertNil(app.accountsProviders.tokenResolver("plex"))
        }
    }

    func testSyncedProfileLockStillRequiresUnlocking() async throws {
        try await withApp { app in
            await authenticate(app)
            var update = ProfileSyncDTO(profile: app.profiles.activeProfile)
            update.lock = try XCTUnwrap(ProfileLock.make(pin: "1234", iterations: 10))
            update.lockRevision = ProfileLockRevision(counter: 100, nonce: "sync-lock")
            app.applySyncRecords(["profile:\(update.id)": try XCTUnwrap(CanonicalJSON.encode(update))])
            XCTAssertTrue(app.mustChooseProfile)
            XCTAssertEqual(app.gate.lockedSwitch?.target.id, update.id)
        }
    }

    func testSyncedActiveProfileDeletionStillRequiresNewPlexAuthorization() async throws {
        try await withApp { app in
            let fallbackID = app.profiles.activeProfileID
            let other = try XCTUnwrap(app.profiles.profiles.first { $0.id != fallbackID })
            app.profiles.update(other.settingHomeUserBinding(
                .init(homeUserID: "parent", name: "Parent", requiresPIN: true, pinRequirementVerified: true),
                forPlexAccount: "plex"
            ))
            app.profiles.setActiveAccountIDs(["plex"], for: other.id)
            app.selectProfile(other.id)
            await app.plexHomeUsers.waitForPlexPINRequirementCheck()
            await authenticate(app)
            app.applySyncRecords(["profile:\(other.id)": nil])
            await app.plexHomeUsers.waitForPlexPINRequirementCheck()
            XCTAssertEqual(app.profiles.activeProfileID, fallbackID)
            XCTAssertEqual(app.plexHomeUsers.pendingPlexPINRequest?.homeUserID, "parent")
            XCTAssertNil(app.accountsProviders.tokenResolver("plex"))
        }
    }

    private func authenticate(_ app: PlozziOSAppModel) async {
        app.plexHomeUsers.submitPlexPIN("2468")
        await app.plexHomeUsers.waitForPlexPINRequirementCheck()
        XCTAssertNil(app.plexHomeUsers.pendingPlexPINRequest)
        XCTAssertEqual(app.accountsProviders.tokenResolver("plex"), "FIXTURE-SERVER")
    }

    private func withApp(_ exercise: (PlozziOSAppModel) async throws -> Void) async throws {
        let suite = "PlexSyncAuthorization.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        try accounts.add(Account(
            id: "plex", server: MediaServer(
                id: "fixture", name: "Fixture", baseURL: URL(string: "https://plex.example")!, provider: .plex
            ), userID: "owner", userName: "Owner", deviceID: "fixture"
        ), token: "FIXTURE-OWNER")
        let store = ProfileStore(defaults: defaults)
        let profiles = ProfilesModel(store: store)
        let activeID = profiles.activeProfileID
        _ = profiles.add(name: "Other profile", avatarSymbol: "person", colorIndex: 1)
        profiles.select(activeID)
        profiles.update(profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "parent", name: "Parent", requiresPIN: true, pinRequirementVerified: true),
            forPlexAccount: "plex"
        ))
        profiles.setActiveAccountIDs(["plex"], for: activeID)
        let app = PlozziOSAppModel(accountStore: accounts, profileStore: store)
        app.plexHomeUsers.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true)]
        }
        app.plexHomeUsers.plexHomeUserSwitch = { _, pin, _, _ in
            XCTAssertEqual(pin, "2468")
            return "FIXTURE-CLOUD"
        }
        app.plexHomeUsers.plexServerTokenResolve = { _, _, _ in "FIXTURE-SERVER" }
        app.selectProfile(activeID)
        await app.plexHomeUsers.waitForPlexPINRequirementCheck()
        XCTAssertEqual(app.plexHomeUsers.pendingPlexPINRequest?.homeUserID, "parent")
        try await exercise(app)
        app.plexHomeUsers.forgetAccount("plex")
    }
}
#endif
