#if os(iOS)
import CoreModels
import FeatureAuth
import SwiftUI
import UIKit
import XCTest
@testable import AppRuntime
@testable import AppShelliOS

@MainActor
final class PlexPINPresentationTests: XCTestCase {
    func testUnresolvedDefaultProfilePINDisallowsInteractiveSheetDismissal() async throws {
        try await verifyPINPresentation(isChangingSelection: false)
    }

    func testCancellingProposedPlexUserDismissesSheetWithoutSavingSelection() async throws {
        try await verifyPINPresentation(isChangingSelection: true)
    }

    func testExpiredAccountRecoveryCancelDismissesOnlyProposedSelection() async throws {
        try await verifyPINPresentation(isChangingSelection: true, expiredAccount: true)
        try await verifyPINPresentation(isChangingSelection: false, expiredAccount: true)
    }

    func testShellCannotFallBackToOwnerAfterHomeCredentialSourceChanges() async throws {
        try await verifyShellTokenDenial(afterCredentialReplacement: true)
    }

    func testManualProfileSwitchRechecksPreviouslyUnprotectedPlexUser() async throws {
        try await verifyShellTokenDenial(afterCredentialReplacement: false)
    }

    func testDisabledPlexSourceSkipsPINUntilReenabledOnMobile() async throws {
        let suite = "DisabledPlexSourceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountStore(secureStore: InMemorySecureStore())
        try store.add(Account(
            id: "plex", server: MediaServer(
                id: "fixture", name: "Fixture", baseURL: URL(string: "https://plex.example")!, provider: .plex
            ), userID: "owner", userName: "Owner", deviceID: "fixture"
        ), token: "FIXTURE-OWNER")
        let profileStore = ProfileStore(defaults: defaults)
        let profiles = ProfilesModel(store: profileStore)
        let enabledID = profiles.activeProfileID
        let disabled = profiles.add(name: "Disabled source", avatarSymbol: "person", colorIndex: 1)
        let binding = PlexHomeUserBinding(homeUserID: "parent", name: "Parent", requiresPIN: true,
                                         pinRequirementVerified: true)
        for profile in profiles.profiles {
            profiles.update(profile.settingHomeUserBinding(binding, forPlexAccount: "plex"))
        }
        profiles.setActiveAccountIDs(["plex"], for: enabledID)
        profiles.setActiveAccountIDs([], for: disabled.id)
        profiles.select(enabledID)
        let app = PlozziOSAppModel(accountStore: store, profileStore: profileStore)
        app.plexHomeUsers.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true)]
        }
        app.plexHomeUsers.plexHomeUserSwitch = { _, pin, _, _ in
            XCTAssertEqual(pin, "2468")
            return "FIXTURE-CLOUD"
        }
        app.plexHomeUsers.plexServerTokenResolve = { _, _, _ in "FIXTURE-SERVER" }
        XCTAssertFalse(app.accountsProviders.profileShowsPINLock(
            try XCTUnwrap(app.profiles.profiles.first { $0.id == disabled.id })
        ))
        app.selectProfile(disabled.id)
        XCTAssertNil(app.plexHomeUsers.pendingPlexPINRequest)
        XCTAssertTrue(app.accountsProviders.activeAccountIDs.isEmpty)
        XCTAssertNil(app.accountsProviders.tokenResolver("plex"))

        app.setAccount("plex", enabled: true, for: disabled.id)
        XCTAssertTrue(app.accountsProviders.profileShowsPINLock(app.profiles.activeProfile))
        XCTAssertEqual(app.plexHomeUsers.pendingPlexPINRequest?.accountID, "plex")
        XCTAssertNil(app.accountsProviders.provider(forAccountID: "plex"))
        await app.plexHomeUsers.waitForPlexPINRequirementCheck()
        app.plexHomeUsers.submitPlexPIN("2468")
        await app.plexHomeUsers.waitForPlexPINRequirementCheck()
        XCTAssertEqual(app.accountsProviders.tokenResolver("plex"), "FIXTURE-SERVER")

        app.setAccount("plex", enabled: false, for: disabled.id)
        XCTAssertFalse(app.accountsProviders.profileShowsPINLock(app.profiles.activeProfile))
        XCTAssertNil(app.plexHomeUsers.pendingPlexPINRequest)
        XCTAssertNil(app.plexHomeUsers.plexDiscoverTokens.token(for: "plex"))
        XCTAssertNil(app.accountsProviders.tokenResolver("plex"))
        XCTAssertEqual(app.profiles.activeProfile.homeUserBinding(forPlexAccount: "plex"), binding)
        app.selectProfile(enabledID)
        XCTAssertEqual(app.plexHomeUsers.pendingPlexPINRequest?.accountID, "plex")
        app.selectProfile(disabled.id)
        XCTAssertNil(app.plexHomeUsers.pendingPlexPINRequest)
        XCTAssertNil(app.accountsProviders.tokenResolver("plex"))
    }

    private func verifyShellTokenDenial(afterCredentialReplacement: Bool) async throws {
        let suite = "PlexPINSourceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        let accountID = "PlexPINPresentationTests.\(UUID())"
        let previousProfileID = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "PIN source fixture", avatarSymbol: "person", colorIndex: 1)
        app.profiles.select(profile.id)
        defer {
            app.plexHomeUsers.forgetAccount(accountID)
            do {
                try app.accountStore.remove(id: accountID)
            } catch {
                XCTFail("Failed to remove the owned account fixture: \(error)")
            }
            app.profiles.select(previousProfileID)
            app.profiles.remove(profile.id)
            app.accountsProviders.reloadAccounts()
        }
        try app.accountStore.add(Account(
            id: accountID, server: MediaServer(
                id: accountID, name: "Fixture", baseURL: URL(string: "https://plex.example")!, provider: .plex
            ), userID: "owner", userName: "Owner", deviceID: "fixture"
        ), token: "FIXTURE-OWNER")
        app.accountsProviders.reloadAccounts()
        app.plexHomeUsers.plexHomeUsersFetch = { _, _ in
            [PlexHomeUser(id: "protected", name: "Protected", requiresPIN: afterCredentialReplacement)]
        }
        app.plexHomeUsers.plexHomeUserSwitch = { _, pin, _, _ in
            XCTAssertEqual(pin, afterCredentialReplacement ? "2468" : nil)
            return "FIXTURE-HOME-CLOUD"
        }
        app.plexHomeUsers.plexServerTokenResolve = { _, _, _ in "FIXTURE-HOME-SERVER" }
        app.plexHomeUsers.setPlexHomeUserForActiveProfile(
            accountID: accountID,
            user: PlexHomeUser(id: "protected", name: "Protected", requiresPIN: afterCredentialReplacement)
        )
        await app.plexHomeUsers.waitForPlexPINRequirementCheck()
        if afterCredentialReplacement {
            app.plexHomeUsers.submitPlexPIN("2468")
            await app.plexHomeUsers.waitForPlexPINRequirementCheck()
        }
        XCTAssertEqual(app.accountsProviders.tokenResolver(accountID), "FIXTURE-HOME-SERVER")
        if afterCredentialReplacement {
            let account = try XCTUnwrap(app.accountsProviders.accounts.first(where: { $0.id == accountID }))
            try app.accountStore.add(account, token: "REPLACED-OWNER")
            app.accountsProviders.reloadAccounts()
        } else {
            app.plexHomeUsers.plexHomeUsersFetch = { _, _ in
                [PlexHomeUser(id: "protected", name: "Protected", requiresPIN: true)]
            }
            app.plexHomeUsers.plexHomeUserSwitch = { _, _, _, _ in
                XCTFail("A manual selection must not reuse the old unprotected authorization.")
                return "UNVERIFIED-CLOUD"
            }
            app.selectProfile(previousProfileID)
            app.selectProfile(profile.id)
            XCTAssertNotNil(app.plexHomeUsers.pendingPlexPINRequest)
            XCTAssertEqual(app.plexHomeUsers.plexPINEntryAvailability, .checking)
            await app.plexHomeUsers.waitForPlexPINRequirementCheck()
            XCTAssertEqual(app.plexHomeUsers.plexPINEntryAvailability, .available)
            XCTAssertNil(app.plexHomeUsers.discoverToken(for: accountID))
        }
        XCTAssertNil(app.plexHomeUsers.resolvedToken(for: accountID))
        XCTAssertNil(app.accountsProviders.tokenResolver(accountID), "The shell must preserve denial, not substitute the owner.")
        XCTAssertNil(app.accountsProviders.provider(forAccountID: accountID))
        XCTAssertEqual(app.profiles.activeProfile.homeUserBinding(forPlexAccount: accountID)?.homeUserID, "protected")
    }

    private func verifyPINPresentation(isChangingSelection: Bool, expiredAccount: Bool = false) async throws {
        let suite = "PlexPINPresentationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        try accounts.add(Account(
            id: "plex", server: MediaServer(
                id: "server", name: "Fixture", baseURL: URL(string: "https://plex.example")!, provider: .plex
            ), userID: "owner", userName: "Owner", deviceID: "fixture"
        ), token: "FIXTURE-ADMIN")
        let hub = AccountsProvidersModel(
            accountStore: accounts, registry: ProviderRegistry(), profilesModel: profiles
        )
        hub.reloadAccounts()
        let model = PlexHomeUsersModel(
            accountsProviders: hub, profilesModel: profiles,
            plexHomeUserTokenCache: PlexHomeUserTokenCache(store: InMemorySecureStore()),
            automaticSignInStore: AutomaticSignInStore(defaults: defaults, secureStore: InMemorySecureStore()),
            offlineSignInStore: .init(secureStore: InMemorySecureStore()),
            switchProfile: { _ in XCTFail("The default profile has no alternate fallback.") }
        )
        model.plexHomeUsersFetch = { _, _ in
            if expiredAccount { throw AppError.unauthorized }
            return [PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true)]
        }
        model.plexHomeUserSwitch = { _, _, _, _ in
            XCTFail("The PIN sheet must remain even if an owner-authorized switch would succeed.")
            return "UNVERIFIED-CLOUD"
        }
        if isChangingSelection {
            model.setPlexHomeUserForActiveProfile(
                accountID: "plex", user: PlexHomeUser(id: "parent", name: "Parent", requiresPIN: true)
            )
        } else {
            profiles.update(profiles.activeProfile.settingHomeUserBinding(
                .init(homeUserID: "parent", name: "Parent", requiresPIN: true), forPlexAccount: "plex"
            ))
            model.ensurePlexIdentityForActiveProfile()
        }
        await model.waitForPlexPINRequirementCheck()
        if expiredAccount {
            XCTAssertEqual(model.plexPINEntryAvailability, .unavailable)
            XCTAssertEqual(model.plexPINError, AppError.unauthorized.userMessage)
        }
        let request = try XCTUnwrap(model.pendingPlexPINRequest)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView:
            Color.clear.sheet(item: Binding(
                get: { model.pendingPlexPINRequest },
                set: { if $0 == nil { model.dismissPlexPINIfPresented() } }
            )) { request in
                PlozziOSPlexPINView(model: model, request: request)
                    .environment(\.locale, Locale(identifier: "en"))
            }
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil(window) { host.presentedViewController?.view.window != nil }
        let presented = try XCTUnwrap(host.presentedViewController)
        let presentation = try XCTUnwrap(presented.presentationController)
        try await waitUntil(window) {
            presented.isModalInPresentation
                || presentation.delegate?.presentationControllerShouldDismiss?(presentation) == false
        }
        presentation.delegate?.presentationControllerDidAttemptToDismiss?(presentation)
        XCTAssertEqual(model.pendingPlexPINRequest, request)

        model.cancelPlexPIN()
        if isChangingSelection {
            try await waitUntil(window) { host.presentedViewController == nil }
            XCTAssertNil(model.pendingPlexPINRequest)
            XCTAssertNil(profiles.activeProfile.homeUserBinding(forPlexAccount: "plex"))
            XCTAssertNil(ProfileStore(defaults: defaults).loadProfiles().first?.homeUserBinding(forPlexAccount: "plex"))
            return
        }
        let observationEnd = ContinuousClock.now + .milliseconds(500)
        repeat {
            XCTAssertEqual(model.pendingPlexPINRequest, request)
            XCTAssertTrue(host.presentedViewController === presented)
            XCTAssertFalse(presented.isBeingDismissed)
            XCTAssertFalse(model.isSubmittingPlexPIN)
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < observationEnd

    }

    private func waitUntil(
        _ window: UIWindow, file: StaticString = #filePath, line: UInt = #line,
        _ predicate: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            window.layoutIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTFail("The PIN presentation did not reach its expected state.", file: file, line: line)
        throw PresentationError.timedOut
    }

    private enum PresentationError: Error { case timedOut }
}
#endif
