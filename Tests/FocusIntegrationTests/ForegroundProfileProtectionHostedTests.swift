@testable import AppShell
import AppRuntime
import CoreModels
import CoreSecureStore
import CoreUI
import FeatureAuth
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class ForegroundProfileProtectionHostedTests: XCTestCase {
    func testForegroundPickerStartsOnTheActiveProfile() async throws {
        try await verifyPickerEntry(delayedInput: false)
    }

    func testForegroundPickerStartsOnAProfileWhenFocusBecomesAvailableLater() async throws {
        try await verifyPickerEntry(delayedInput: true)
    }

    private func verifyPickerEntry(delayedInput: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.pickerInputEnabled = !delayedInput
        fixture.app.profileFlow.lockForForegroundIfNeeded()
        try await waitUntil { !fixture.window.isUserInteractionEnabled }
        let shield = try XCTUnwrap(fixture.scene.windows.first {
            $0.isKeyWindow && $0 !== fixture.window
        })

        if delayedInput {
            // The picker can mount while the app is still returning to the foreground.
            try await Task.sleep(for: .milliseconds(300))
            fixture.model.pickerInputEnabled = true
            try await Task.sleep(for: .milliseconds(100))
        }
        shield.layoutIfNeeded()
        try await waitUntil { UIFocusSystem.focusSystem(for: shield)?.focusedItem != nil }
        let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: shield)?.focusedItem)
        let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: focused, relativeTo: shield))
        XCTAssertGreaterThan(frame.height, 150, "Entry focus must be on an avatar, not the Settings cog.")
        XCTAssertGreaterThan(frame.midY, shield.bounds.height / 3)
        XCTAssertLessThan(frame.midX, shield.bounds.width / 4, "The active profile leads the recency-ordered row.")
        XCTAssertTrue(fixture.app.profileFlow.isForegroundLocked)
        XCTAssertNil(fixture.app.profileFlow.pendingLockedProfile, "Focusing a profile must not select it.")
        let image = UIGraphicsImageRenderer(bounds: shield.bounds).image { _ in
            shield.drawHierarchy(in: shield.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "foreground-profile-picker-entry-focus-delayed-\(delayedInput)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPINShieldKeepsDetailAndPresentedSettingsUntilSameProfileUnlocks() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.path = ["movie"]
        let navigation = try XCTUnwrap(navigationController(in: fixture.host))
        try await waitUntil { navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil }
        let detail = try XCTUnwrap(navigation.topViewController)
        let settings = UIHostingController(rootView: Button("Retained setting") {})
        settings.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            fixture.host.present(settings, animated: false) { continuation.resume() }
        }

        fixture.app.profileFlow.lockForForegroundIfNeeded()
        try await waitUntil { !fixture.window.isUserInteractionEnabled }
        let shield = try XCTUnwrap(fixture.scene.windows.first {
            $0.isKeyWindow && $0 !== fixture.window
        })
        XCTAssertEqual(shield.bounds, fixture.window.bounds)
        XCTAssertGreaterThan(shield.windowLevel, fixture.window.windowLevel)
        XCTAssertTrue(fixture.window.accessibilityElementsHidden)
        XCTAssertTrue(fixture.host.presentedViewController === settings)
        XCTAssertTrue(navigation.topViewController === detail)
        try await waitUntil { UIFocusSystem.focusSystem(for: shield)?.focusedItem != nil }
        let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: shield)?.focusedItem)
        var environment: (any UIFocusEnvironment)? = focused
        while let current = environment, current !== shield {
            environment = current.parentFocusEnvironment
        }
        XCTAssertTrue(environment === shield, "Native focus must belong to the PIN window, not Settings.")

        let profileID = fixture.app.profilesModel.activeProfileID
        fixture.app.profileFlow.switchProfile(to: profileID)
        try await Task.sleep(for: .milliseconds(200))
        let wrong = await fixture.app.profileFlow.submitProfileLockPIN("0000")
        XCTAssertFalse(wrong)
        XCTAssertTrue(shield.isKeyWindow)
        XCTAssertFalse(fixture.window.isUserInteractionEnabled)
        fixture.app.profileFlow.cancelForegroundProfileSelection()
        XCTAssertTrue(fixture.app.profileFlow.isForegroundLocked)
        fixture.app.profileFlow.switchProfile(to: profileID)
        let accepted = await fixture.app.profileFlow.submitProfileLockPIN("2468")
        XCTAssertTrue(accepted)
        XCTAssertTrue(
            fixture.app.profileFlow.canFinishForegroundUnlock || !fixture.app.profileFlow.isForegroundLocked,
            "choice=\(fixture.app.profileFlow.isChoosingProfile) local=\(fixture.app.profileFlow.pendingLockedProfile != nil) plex=\(fixture.app.plexHomeUsers.pendingPlexPINRequest != nil) locked=\(fixture.app.profileFlow.activeProfileAwaitsUnlock)"
        )
        try await waitUntil { fixture.window.isUserInteractionEnabled && fixture.window.isKeyWindow }
        XCTAssertFalse(fixture.app.profileFlow.isForegroundLocked)
        XCTAssertFalse(fixture.window.accessibilityElementsHidden)
        XCTAssertTrue(navigation.topViewController === detail)
        XCTAssertTrue(fixture.host.presentedViewController === settings)
        XCTAssertEqual(fixture.model.path, ["movie"])

        try await Task.sleep(for: .milliseconds(100))
        fixture.app.profileFlow.lockForForegroundIfNeeded()
        try await waitUntil { !fixture.window.isUserInteractionEnabled }
        fixture.app.profileFlow.switchProfile(to: profileID)
        let acceptedAgain = await fixture.app.profileFlow.submitProfileLockPIN("2468")
        XCTAssertTrue(acceptedAgain)
        fixture.app.profileFlow.cancelForegroundProfileSelection()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(fixture.app.profileFlow.isForegroundLocked)
        XCTAssertFalse(fixture.window.isUserInteractionEnabled)
        XCTAssertTrue(fixture.window.accessibilityElementsHidden)
        fixture.app.profileFlow.switchProfile(to: profileID)
        let acceptedAfterRevocation = await fixture.app.profileFlow.submitProfileLockPIN("2468")
        XCTAssertTrue(acceptedAfterRevocation)
        try await waitUntil { fixture.window.isUserInteractionEnabled && fixture.window.isKeyWindow }
        XCTAssertTrue(navigation.topViewController === detail)
        XCTAssertTrue(fixture.host.presentedViewController === settings)
    }

    func testPlayerPresenceRemainsRegisteredBehindItsFullscreenCover() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        fixture.model.playerPresented = true
        try await waitUntil { fixture.host.presentedViewController != nil }
        XCTAssertFalse(fixture.foreground.shouldLock(after: .active))
        XCTAssertFalse(fixture.foreground.shouldLock(after: .inactive))
        XCTAssertFalse(fixture.foreground.shouldLock(after: .background))
        fixture.model.playerPresented = false
        try await waitUntil { fixture.host.presentedViewController == nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(fixture.foreground.shouldLock(after: .active))
        XCTAssertTrue(fixture.foreground.shouldLock(after: .background))
    }

    func testLockedProfileCannotConstructABuiltInPlayer() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        var factoryCalls = 0
        var preparationCalls = 0
        let player = PlayerPresentation(
            request: PlayRequest(item: MediaItem(id: "movie", title: "Movie", kind: .movie), startPosition: 0),
            make: { _, _, _ in
                factoryCalls += 1
                throw AppError.unauthorized
            },
            makeFailover: { _, _ in nil },
            showDiagnostics: false,
            themePalette: ThemePalette.palette(for: .system, systemColorScheme: .dark),
            versionPreferences: VersionPreferenceStore(namespace: fixture.suite),
            prepareVersion: { _, item in preparationCalls += 1; return item },
            versionAuthorizationScope: []
        )
        .environment(\.externalPlaybackContext, { fixture.app.externalPlaybackContext() })
        let host = UIHostingController(rootView: player)
        fixture.host.present(host, animated: false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(preparationCalls, 0)
    }

    private func makeFixture() async throws -> Fixture {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene)
        do {
            try await waitUntil { self.navigationController(in: fixture.host) != nil }
            try await Task.sleep(for: .milliseconds(250))
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigationController(in: $0) }.first
    }

    @MainActor
    private final class Fixture {
        let scene: UIWindowScene
        let window: UIWindow
        let previous: UIWindow?
        let host: UIHostingController<BrowsingRoot>
        let model = BrowsingModel()
        let foreground = TVProfileForegroundState()
        let app: AppState
        let defaults: UserDefaults
        let suite = "ForegroundProfileProtectionHostedTests.\(UUID().uuidString)"

        init(scene: UIWindowScene) {
            self.scene = scene
            defaults = UserDefaults(suiteName: suite)!
            let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
            var viewer = profiles.add(name: "PIN viewer")
            viewer.lock = ProfileLock.make(pin: "2468", iterations: 1)
            profiles.update(viewer)
            profiles.select(viewer.id)
            profiles.noteProfileUnlocked(viewer.id)
            app = AppState(
                accountStore: AccountStore(secureStore: InMemorySecureStore()),
                profilesModel: profiles
            )
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            host = UIHostingController(rootView: BrowsingRoot(model: model, app: app, foreground: foreground))
            window.rootViewController = host
            window.makeKeyAndVisible()
        }

        func close() {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @MainActor @Observable
    final class BrowsingModel {
        var path: [String] = []
        var playerPresented = false
        var pickerInputEnabled = true
    }

    private struct BrowsingRoot: View {
        @Bindable var model: BrowsingModel
        let app: AppState
        let foreground: TVProfileForegroundState

        var body: some View {
            NavigationStack(path: $model.path) {
                Button("Open movie") { model.path.append("movie") }
                    .navigationDestination(for: String.self) { _ in Button("Movie detail") {} }
            }
            .fullScreenCover(isPresented: $model.playerPresented) {
                Button("Paused player") {}
            }
            .background(TVProfilePlaybackPresence(isActive: model.playerPresented).frame(width: 0, height: 0))
            .environment(\.tvProfileForegroundState, foreground)
            .background(
                TVProfileForegroundShield(flow: app.profileFlow) { dismiss in
                    ForegroundProfileGateView(appState: app, onUnlock: dismiss)
                        .environment(app.profilesModel)
                        .modifier(PickerReadiness(model: model))
                }
                .frame(width: 0, height: 0)
            )
        }
    }

    private struct PickerReadiness: ViewModifier {
        let model: BrowsingModel

        func body(content: Content) -> some View {
            content.disabled(!model.pickerInputEnabled)
        }
    }
}
