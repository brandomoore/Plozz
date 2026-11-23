#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
import FeatureProfiles
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppRuntime
@testable import AppShelliOS

@MainActor
final class ProfileSwitchAuthorizationTests: XCTestCase {
    func testNewProfileWaitsForSettingsDismissalBeforeActivating() throws {
        let app = try makeApp()
        let original = app.profiles.activeProfileID
        let count = app.profiles.profiles.count
        let draft = ProfileDraft(
            id: nil, name: "New viewer", avatarSymbol: "person.fill", colorIndex: 1
        )
        app.noteSettingsPresented(true)

        app.saveProfile(draft, isKids: true)
        XCTAssertTrue(app.hasPendingProfileCreation)
        XCTAssertEqual(app.profiles.profiles.count, count)
        XCTAssertEqual(app.profiles.activeProfileID, original)
        XCTAssertNil(app.profileOnboardingID)
        app.completePendingProfileCreation()
        XCTAssertEqual(app.profiles.profiles.count, count)

        app.noteSettingsPresented(false)
        app.completePendingProfileCreation()
        XCTAssertFalse(app.hasPendingProfileCreation)
        XCTAssertEqual(app.profiles.profiles.count, count + 1)
        XCTAssertNotEqual(app.profiles.activeProfileID, original)
        XCTAssertEqual(app.profiles.activeProfile.name, draft.name)
        XCTAssertTrue(app.profiles.activeProfile.isKids)
        XCTAssertTrue(app.profiles.activeProfile.needsSetup)
        XCTAssertEqual(app.profileOnboardingID, app.profiles.activeProfileID)
        XCTAssertTrue(app.profileOnboardingOrigin == .launch)

        app.completePendingProfileCreation()
        XCTAssertEqual(app.profiles.profiles.count, count + 1)
    }

    func testSettingsDismissalWithoutSavingDoesNotCreateAProfile() throws {
        let app = try makeApp()
        let original = app.profiles.activeProfileID
        let count = app.profiles.profiles.count
        app.noteSettingsPresented(true)
        app.noteSettingsPresented(false)
        app.completePendingProfileCreation()
        XCTAssertFalse(app.hasPendingProfileCreation)
        XCTAssertEqual(app.profiles.profiles.count, count)
        XCTAssertEqual(app.profiles.activeProfileID, original)
        XCTAssertNil(app.profileOnboardingID)
    }

    func testEditingAnExistingProfileDoesNotWaitForSettingsDismissal() throws {
        let app = try makeApp()
        let original = app.profiles.activeProfileID
        let count = app.profiles.profiles.count
        app.noteSettingsPresented(true)
        app.saveProfile(ProfileDraft(
            id: original, name: "Renamed viewer", avatarSymbol: "person.fill", colorIndex: 2
        ))
        XCTAssertFalse(app.hasPendingProfileCreation)
        XCTAssertEqual(app.profiles.profiles.count, count)
        XCTAssertEqual(app.profiles.activeProfileID, original)
        XCTAssertEqual(app.profiles.activeProfile.name, "Renamed viewer")
        XCTAssertNil(app.profileOnboardingID)
    }

    func testCancelledVerificationCannotAuthorizeAReplacementRequest() async throws {
        let app = try makeApp()
        let original = app.profiles.activeProfileID
        var locked = try addLockedProfile(app)
        locked.lock = try XCTUnwrap(ProfileLock.make(pin: "1357"))
        app.profiles.update(locked)
        app.selectProfile(locked.id)
        let started = expectation(description: "Verification started")
        let first = Task {
            started.fulfill()
            return await app.submitProfileLockPIN("1357")
        }
        await fulfillment(of: [started], timeout: 2)
        app.cancelProfileLockPrompt()
        app.selectProfile(locked.id)
        let replacement = try XCTUnwrap(app.lockedSwitch)
        let accepted = await first.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(app.lockedSwitch?.id, replacement.id)
        XCTAssertEqual(app.profiles.activeProfileID, original)
        XCTAssertFalse(app.isUnlockedThisRun(locked.id))
    }

    func testProfileChangeDuringVerificationInvalidatesTheResultEvenAfterReturning() async throws {
        let app = try makeApp()
        let original = app.profiles.activeProfileID
        var locked = try addLockedProfile(app)
        locked.lock = try XCTUnwrap(ProfileLock.make(pin: "1357"))
        app.profiles.update(locked)
        app.selectProfile(locked.id)
        let started = expectation(description: "Verification started")
        let attempt = Task {
            started.fulfill()
            return await app.submitProfileLockPIN("1357")
        }
        await fulfillment(of: [started], timeout: 2)
        app.profiles.select(locked.id)
        app.profiles.select(original)
        let accepted = await attempt.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(app.profiles.activeProfileID, original)
        XCTAssertFalse(app.isUnlockedThisRun(locked.id))
    }

    func testChangingTheLockDuringVerificationCannotAuthorizeTheOldPIN() async throws {
        let app = try makeApp()
        let original = app.profiles.activeProfileID
        var locked = try addLockedProfile(app)
        locked.lock = try XCTUnwrap(ProfileLock.make(pin: "1357"))
        app.profiles.update(locked)
        app.selectProfile(locked.id)
        let started = expectation(description: "Verification started")
        let attempt = Task {
            started.fulfill()
            return await app.submitProfileLockPIN("1357")
        }
        await fulfillment(of: [started], timeout: 2)
        locked.replaceLock(with: ProfileLock.make(pin: "2468", iterations: 64))
        app.profiles.update(locked)
        let accepted = await attempt.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(app.profiles.activeProfileID, original)
        XCTAssertFalse(app.isUnlockedThisRun(locked.id))
        XCTAssertEqual(app.lockedSwitch?.error, ProfileLockCopy.profileChanged)
    }

    func testReturningFromAnotherProfileRequiresLocalPINAgain() async throws {
        let app = try makeApp()
        let original = app.profiles.activeProfileID
        let locked = try addLockedProfile(app)
        app.selectProfile(original)
        app.selectProfile(locked.id)
        let accepted = await app.submitProfileLockPIN("1357")
        XCTAssertTrue(accepted)
        XCTAssertTrue(app.isUnlockedThisRun(locked.id))
        app.selectProfile(original)
        XCTAssertFalse(app.isUnlockedThisRun(locked.id))
        app.selectProfile(locked.id)
        XCTAssertEqual(app.lockedSwitch?.target.id, locked.id)
        XCTAssertEqual(app.profiles.activeProfileID, original)
    }

    func testInvoluntaryProfileChangeCannotReusePreviousUnlock() async throws {
        let app = try makeApp()
        let original = app.profiles.activeProfileID
        let locked = try addLockedProfile(app)
        app.selectProfile(locked.id)
        let accepted = await app.submitProfileLockPIN("1357")
        XCTAssertTrue(accepted)
        app.profiles.select(original)
        app.profiles.select(locked.id)
        XCTAssertTrue(app.enforceActiveProfileLock())
        XCTAssertTrue(app.activeProfileNeedsUnlock)
    }

    func testCompletedLocalPINRemainsVisibleUntilPresentationDismisses() async throws {
        let app = try makeApp()
        let locked = try addLockedProfile(app)
        app.selectProfile(locked.id)
        try await withGate(app, profile: locked) { window in
            let accepted = await app.submitProfileLockPIN("1357")
            XCTAssertTrue(accepted)
            try await Task.sleep(for: .milliseconds(80))
            let text = try self.recognizedText(window)
            XCTAssertTrue(text.contains("Enter your PIN"), text)
            XCTAssertTrue(text.contains("Cancel"), text)
            XCTAssertNil(app.lockedSwitch)
        }
    }

    func testMatchedPlexVerificationRetainsLocalPINUntilNetworkFinishes() async throws {
        let app = try makeApp()
        try app.accountStore.add(Account(
            id: "plex", server: MediaServer(
                id: "fixture", name: "Fixture", baseURL: URL(string: "https://plex.example")!, provider: .plex
            ), userID: "owner", userName: "Owner", deviceID: "fixture"
        ), token: "FIXTURE-OWNER")
        app.accountsProviders.reloadAccounts()
        var locked = try addLockedProfile(app, matchesPlexPIN: true)
        locked = locked.settingHomeUserBinding(
            .init(homeUserID: "protected", name: "Protected", requiresPIN: true, pinRequirementVerified: true),
            forPlexAccount: "plex"
        )
        app.profiles.update(locked)
        app.profiles.setActiveAccountIDs(["plex"], for: locked.id)
        app.plexHomeUsers.plexHomeUsersFetch = { _, _ in
            XCTFail("The supplied matching PIN must go directly to authentication.")
            return []
        }
        app.plexHomeUsers.plexHomeUserSwitch = { _, pin, _, _ in
            XCTAssertEqual(pin, "1357")
            try await Task.sleep(for: .seconds(1))
            return "FIXTURE-CLOUD"
        }
        app.plexHomeUsers.plexServerTokenResolve = { _, _, _ in "FIXTURE-SERVER" }
        app.selectProfile(locked.id)
        try await withGate(app, profile: locked) { window in
            let accepted = await app.submitProfileLockPIN("1357")
            XCTAssertTrue(accepted)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertNotNil(app.plexHomeUsers.pendingPlexPINRequest)
            let text = try self.recognizedText(window)
            XCTAssertTrue(text.contains("Enter your PIN"), "Do not replace entered PIN with a blank check: \(text)")
            await app.plexHomeUsers.waitForPlexPINRequirementCheck()
            XCTAssertNil(app.plexHomeUsers.pendingPlexPINRequest)
            XCTAssertEqual(app.accountsProviders.tokenResolver("plex"), "FIXTURE-SERVER")
        }
    }

    private func makeApp() throws -> PlozziOSAppModel {
        let suite = "ProfileSwitchAuthorization.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
    }

    private func addLockedProfile(_ app: PlozziOSAppModel, matchesPlexPIN: Bool = false) throws -> Profile {
        var profile = app.profiles.add(name: "Local", avatarSymbol: "person.fill", colorIndex: 1)
        profile.lock = try XCTUnwrap(ProfileLock.make(pin: "1357", matchesPlexPIN: matchesPlexPIN, iterations: 64))
        app.profiles.update(profile)
        return profile
    }

    private func withGate(
        _ app: PlozziOSAppModel, profile: Profile, operation: (UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView:
            GateFixture(app: app, profile: profile)
                .environment(\.themePalette, .dark)
                .environment(\.locale, Locale(identifier: "en"))
                .preferredColorScheme(.dark)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        // Establish visible entry before testing what survives authorization.
        // A fixed delay can capture the first entrance frame on a busy simulator.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var initialText = try recognizedText(window, attaching: false)
        while (!initialText.contains("Enter your PIN") || !initialText.contains("Cancel")),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            initialText = try recognizedText(window, attaching: false)
        }
        guard initialText.contains("Enter your PIN"), initialText.contains("Cancel") else {
            _ = try recognizedText(window)
            XCTFail("Expected visible PIN entry before authorization: \(initialText)")
            return
        }
        try await operation(window)
    }

    private func recognizedText(_ window: UIWindow, attaching: Bool = true) throws -> String {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if attaching {
            let attachment = XCTAttachment(image: image)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
    }
}

private struct GateFixture: View {
    let app: PlozziOSAppModel
    let profile: Profile
    @Namespace private var identity

    var body: some View {
        PlozziOSProfileAccessGateView(appModel: app, profile: profile, onCancel: {})
            .environment(\.pinProfileTransition, PINProfileTransition(profileID: profile.id, namespace: identity))
            .background { AppBackground(palette: .dark).ignoresSafeArea() }
    }
}
#endif
