#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
import XCTest
@testable import AppRuntime
@testable import AppShelliOS

@MainActor
final class PlexHomeOnboardingFlowTests: XCTestCase {
    func testImportedSelectionRetargetsTheExistingSetupOwner() throws {
        let suite = "PlexHomeOnboardingOwnership.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileStore(defaults: defaults)
        store.setFirstRunProfileSetupComplete(true)
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()), profileStore: store
        )
        let previous = app.profiles.add(name: "Previous", isAwaitingSetup: true)
        app.selectProfile(previous.id)
        app.resumeProfileOnboardingIfNeeded()
        XCTAssertEqual(app.profileOnboardingID, previous.id)
        let selected = app.profiles.add(name: "Imported", isAwaitingSetup: true)
        app.selectProfileForPlexOnboarding(selected.id) {}
        XCTAssertEqual(app.profileOnboardingID, selected.id)
        XCTAssertEqual(app.profileOnboardingStep, .libraries)
        app.advanceProfileOnboarding()
        XCTAssertEqual(app.profileBeingOnboarded?.id, selected.id)
        XCTAssertEqual(app.profileOnboardingStep, .seerr)
        XCTAssertTrue(app.profiles.profiles.first { $0.id == previous.id }?.needsSetup == true)
        XCTAssertFalse(app.profiles.activeProfile.needsSetup)
    }

    func testImportAllContinuesThroughLibrariesProfileAndAppearance() async throws {
        try await verifyImportAll(selectedIndex: 0)
        try await verifyImportAll(selectedIndex: 1)
    }

    private func verifyImportAll(selectedIndex: Int) async throws {
        let suite = "PlexHomeOnboardingFlow.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        let users = [
            PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true, isAdmin: true),
            PlexHomeUser(id: "child", name: "Child", requiresPIN: false, isRestricted: true)
        ]
        app.plexHomeUsers.plexHomeUsersFetch = { _, _ in users }
        let authentication = AuthenticationGate()
        app.plexHomeUsers.plexHomeUserSwitch = { user, pin, _, _ in
            XCTAssertEqual(user, users[selectedIndex].id)
            XCTAssertEqual(pin, selectedIndex == 0 ? "2468" : nil)
            return await authentication.token()
        }
        app.plexHomeUsers.plexServerTokenResolve = { _, _, _ in "fixture-server" }
        let sessions = ["a", "b"].map {
            UserSession(
                server: MediaServer(
                    id: $0, name: $0, baseURL: URL(string: "https://\($0).example.invalid")!, provider: .plex
                ), userID: "owner", userName: "Owner", deviceID: "fixture", accessToken: "fixture-\($0)"
            )
        }
        XCTAssertTrue(app.persist(sessions))
        for _ in 0..<200 {
            if app.plexHomeUsers.pendingPlexUserSelection != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(app.plexHomeUsers.pendingPlexUserSelection)
        XCTAssertEqual(app.importPlexHomeProfilesDuringOnboarding(), .added)
        XCTAssertEqual(authentication.calls, 0, "Import must not authenticate other Home users.")
        XCTAssertEqual(app.profiles.profiles.count, 2, "Import precedes the viewer's choice.")
        let selectedID = try XCTUnwrap(app.plexHomeUsers.importedOnboardingProfileID(for: users[selectedIndex]))
        authentication.permits = true
        app.selectPlexUserDuringOnboarding(users[selectedIndex], addAllProfiles: true)
        XCTAssertEqual(app.profiles.activeProfileID, selectedID)
        XCTAssertEqual(app.profiles.profiles.first?.name, "Parent")
        for _ in 0..<200 {
            if app.pendingLibrarySelection != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(app.pendingLibrarySelection)
        XCTAssertNil(app.plexPINRequestForAppPresentation, "The library-selection surface owns its PIN prompt.")
        await app.plexHomeUsers.waitForPlexPINRequirementCheck()
        if selectedIndex == 0 {
            XCTAssertEqual(app.plexHomeUsers.plexPINEntryAvailability, .available)
            XCTAssertEqual(authentication.calls, 0)
            XCTAssertTrue(app.accountsProviders.resolvedAccounts(withIDs: sessions.map(Account.stableID(for:))).isEmpty)
            app.completeLibrarySelection()
            XCTAssertNotNil(app.pendingLibrarySelection, "A pending PIN cannot be bypassed by completing the picker.")
            app.plexHomeUsers.submitPlexPIN("2468")
        }
        await app.plexHomeUsers.waitForPlexPINRequirementCheck()
        await app.plexHomeUsers.waitForPlexPINRequirementCheck()
        XCTAssertNil(app.plexHomeUsers.pendingPlexPINRequest)
        XCTAssertEqual(app.accountsProviders.resolvedAccounts(withIDs: sessions.map(Account.stableID(for:))).count, 2)
        XCTAssertGreaterThan(authentication.calls, 0, "Authenticate the selected viewer before choosing libraries.")
        let callsBeforeAppearance = authentication.calls
        XCTAssertEqual(app.profiles.profiles.count, 2)
        XCTAssertFalse(app.profiles.firstRunProfileSetupComplete)
        app.completeLibrarySelection()
        XCTAssertEqual(app.pendingFirstRunStep, .confirmProfile)
        app.confirmFirstRunProfile()
        XCTAssertEqual(app.pendingFirstRunStep, .seerr)
        app.completeFirstRunSeerrSetup()
        XCTAssertEqual(app.pendingFirstRunStep, .theme)
        app.finishFirstRunThemeSelection()
        XCTAssertNil(app.pendingFirstRunStep)
        XCTAssertTrue(app.profiles.firstRunProfileSetupComplete)
        XCTAssertFalse(app.profiles.activeProfile.needsSetup)
        if selectedIndex == 1 {
            XCTAssertEqual(app.profiles.activeNamespace, selectedID)
            XCTAssertTrue(try XCTUnwrap(app.profiles.profiles.first).needsSetup)
            XCTAssertEqual(app.settings.hero.effectiveSettings.sources,
                           [.continueWatching, .recentlyAdded, .randomFromLibrary, .watchlist])
        }
        await app.plexHomeUsers.waitForPlexPINRequirementCheck()
        await app.plexHomeUsers.waitForPlexPINRequirementCheck()
        XCTAssertNil(app.plexHomeUsers.pendingPlexPINRequest)
        XCTAssertEqual(authentication.calls, callsBeforeAppearance)
    }
}

@MainActor
private final class AuthenticationGate {
    var permits = false
    var calls = 0
    func token() -> String {
        XCTAssertTrue(permits, "Only the chosen viewer authenticates before library selection.")
        calls += 1
        return "fixture-cloud"
    }
}
#endif
