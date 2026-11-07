#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
import FeatureSettings
import SwiftUI
import Synchronization
import UIKit
import XCTest
@testable import AppRuntime
@testable import AppShelliOS

@MainActor
final class ProfileSelectionPerformanceTests: XCTestCase {
    func testPerformanceManyServerLibrarySelection() async throws {
        try PerformanceProbe.requireEnabled()
        try await exerciseManyServerLibrarySelection(measuring: true)
    }

    func testRapidServerSwitchesCommitEachChoiceWithoutDelayedProfileWrites() async throws {
        try await exerciseManyServerLibrarySelection(measuring: false)
    }

    private func exerciseManyServerLibrarySelection(measuring: Bool) async throws {
        let suite = "ProfileLibrariesPerformance.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = AccountStore(secureStore: InMemorySecureStore())
        let app = PlozziOSAppModel(
            appAdmissionStore: AppAdmissionStore(defaults: defaults),
            accountStore: store, profileStore: ProfileStore(defaults: defaults)
        )
        let profile = app.profiles.add(name: "Library choices", isAwaitingSetup: true)
        app.profiles.select(profile.id)
        app.refreshActiveProfileSettings()
        let counts = Mutex((providers: 0, requests: 0))
        let indexedAccounts = Mutex<Set<String>>([])
        for index in 0..<20 {
            let id = "selection-\(index)"
            try store.add(Account(
                id: id,
                server: MediaServer(
                    id: id, name: "Server \(index)",
                    baseURL: URL(string: "https://server-\(index).invalid")!, provider: .jellyfin
                ),
                userID: "viewer", userName: "Viewer", deviceID: "fixture"
            ), token: "fixture")
        }
        app.accountsProviders.registry.register(.jellyfin) { context in
            counts.withLock { $0.providers += 1 }
            return LibrarySelectionPerformanceProvider(
                session: context.session,
                onLibraries: { counts.withLock { $0.requests += 1 } },
                onItems: { indexedAccounts.withLock { _ = $0.insert(context.accountID) } }
            )
        }
        let accountIDs = Set((0..<20).map { "selection-\($0)" })
        app.profiles.setActiveAccountIDs(Array(accountIDs), for: profile.id)
        app.accountsProviders.tokenResolver = { _ in "fixture" }
        app.accountsProviders.reloadAccounts()
        await app.refreshNavigationLibraries()

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack {
                PlozziOSMyLibrariesSettingsView(appModel: app, onAddServer: {}, presentation: .profileSetup)
            }
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
        )
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
            removeOwnedProfileSettings([profile.id])
        }
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()

        func switches(_ view: UIView) -> [UISwitch] {
            (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap(switches)
        }
        func microseconds(_ duration: Duration) -> Int {
            let parts = duration.components
            return Int(parts.seconds) * 1_000_000 + Int(parts.attoseconds / 1_000_000_000_000)
        }
        if !measuring {
            let requests = counts.withLock { $0.requests }
            app.identityIndex.warmIdentityIndex()
            await app.identityIndex.waitForIdentityWarm()
            XCTAssertEqual(counts.withLock { $0.requests }, requests,
                           "Profile setup may discover library names, not start a full identity scan.")
            let control = try XCTUnwrap(switches(window).min {
                $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
            })
            app.settings.homeVisibility.setEnabled(false, for: "selection-0:library-0")
            for enabled in [false, true, false, true, false, true, false] {
                control.setOn(enabled, animated: false)
                control.sendActions(for: .valueChanged)
                XCTAssertEqual(app.activeAccountIDs(for: profile.id).contains("selection-0"), enabled)
                XCTAssertEqual(app.profiles.storedActiveAccountIDs(for: profile.id)?.contains("selection-0"), enabled)
            }
            XCTAssertFalse(app.settings.homeVisibility.isEnabled("selection-0:library-0"),
                           "Turning a server off and on must retain its individual library choices.")
            app.resumeProfileOnboardingIfNeeded()
            XCTAssertEqual(app.profileOnboardingID, profile.id)
            XCTAssertEqual(app.profileOnboardingStep, .libraries)
            app.advanceProfileOnboarding()
            await app.identityIndex.waitForIdentityWarm()
            XCTAssertFalse(app.profiles.activeProfile.needsSetup)
            XCTAssertEqual(indexedAccounts.withLock { $0 }, accountIDs.subtracting(["selection-0"]),
                           "Completing setup must index only the final source selection.")
            let other = app.profiles.add(name: "Other", activeAccountIDs: [], isAwaitingSetup: true)
            defer { removeOwnedProfileSettings([other.id]) }
            app.profiles.setActiveAccountIDs([], for: other.id)
            app.selectProfile(other.id)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(app.profiles.activeProfileID, other.id)
            XCTAssertEqual(app.profiles.storedActiveAccountIDs(for: other.id), [])
            XCTAssertEqual(Set(app.profiles.storedActiveAccountIDs(for: profile.id) ?? []),
                           accountIDs.subtracting(["selection-0"]))
            return
        }
        try await PerformanceProbe.measure(self, scenario: "mobile-profile-library-selection") {
            counts.withLock { $0 = (0, 0) }
            var maxGap = Duration.zero
            let heartbeat = Task { @MainActor in
                var previous = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
                    let now = ContinuousClock.now
                    maxGap = max(maxGap, previous.duration(to: now))
                    previous = now
                }
            }
            defer { heartbeat.cancel() }
            for enabled in [false, true, false, true] {
                let control = try XCTUnwrap(switches(window).min {
                    $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
                })
                control.setOn(enabled, animated: false)
                control.sendActions(for: .valueChanged)
                try await Task.sleep(for: .milliseconds(400))
                window.layoutIfNeeded()
                XCTAssertEqual(app.activeAccountIDs(for: profile.id).contains("selection-0"), enabled)
            }
            for index in 0..<12 {
                app.settings.homeVisibility.setEnabled(index.isMultiple(of: 2), for: "selection-0:library-0")
                try await Task.sleep(for: .milliseconds(30))
                window.layoutIfNeeded()
            }
            XCTAssertEqual(app.accountsProviders.activeAccountIDs, accountIDs)
            XCTAssertEqual(app.settings.discoveredLibraries.state.value?.count, 120)
            XCTAssertFalse(app.settings.homeVisibility.isEnabled("selection-0:library-0"))
            XCTAssertTrue(app.settings.homeVisibility.isEnabled("selection-1:library-0"))
            let work = counts.withLock { $0 }
            return [
                "servers": 20, "libraries": 120, "serverToggles": 4, "libraryToggles": 12,
                "providerConstructions": work.providers, "libraryRequests": work.requests,
                "maxMainActorGapMicroseconds": microseconds(maxGap)
            ]
        }
    }

    func testPerformanceLocalPINHandoff() async throws {
        try PerformanceProbe.requireEnabled()
        let lock = try XCTUnwrap(ProfileLock.make(pin: "1357"))
        let suite = "ProfilePINPerformance.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        let original = app.profiles.activeProfileID
        let targets = (0..<15).map { index in
            app.profiles.add(name: "Viewer \(index)", avatarSymbol: "person.fill", colorIndex: index % 5)
        }
        defer { removeOwnedProfileSettings(targets.map(\.id)) }
        var target = targets[0]
        target.lock = lock
        app.profiles.update(target)
        // Measure switching within one household, not fresh-profile migrations
        // and app construction on every sample.
        try await Task.sleep(for: .milliseconds(200))
        try await PerformanceProbe.measure(self, scenario: "mobile-profile-pin-handoff") {
            app.selectProfile(original)
            app.selectProfile(target.id)
            XCTAssertEqual(app.lockedSwitch?.target.id, target.id)
            XCTAssertFalse(app.isUnlockedThisRun(target.id))

            var maxGap = Duration.zero
            let heartbeat = Task { @MainActor in
                var previous = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
                    let now = ContinuousClock.now
                    maxGap = max(maxGap, previous.duration(to: now))
                    previous = now
                }
            }
            defer { heartbeat.cancel() }
            try await Task.sleep(for: .milliseconds(10))
            let start = ContinuousClock.now
            let accepted = await app.submitProfileLockPIN("1357")
            let elapsed = start.duration(to: .now)
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertTrue(accepted)
            XCTAssertNil(app.lockedSwitch)
            XCTAssertEqual(app.profiles.activeProfileID, target.id)
            XCTAssertFalse(app.activeProfileNeedsUnlock)
            func microseconds(_ duration: Duration) -> Int {
                let parts = duration.components
                return Int(parts.seconds) * 1_000_000 + Int(parts.attoseconds / 1_000_000_000_000)
            }
            return [
                "profiles": app.profiles.profiles.count,
                "verifierIterations": lock.iterations,
                "verificationMicroseconds": microseconds(elapsed),
                "maxMainActorGapMicroseconds": microseconds(maxGap)
            ]
        }
    }

    func testPerformanceProfileSelection() async throws {
        try PerformanceProbe.requireEnabled()
        let suite = "ProfileSelectionPerformance.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileStore(defaults: defaults)
        let profiles = ProfilesModel(store: store)
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        try accounts.add(Account(
            id: "profile-performance-plex",
            server: MediaServer(
                id: "fixture", name: "Fixture",
                baseURL: URL(string: "https://plex.example")!, provider: .plex
            ), userID: "owner", userName: "Owner", deviceID: "fixture"
        ), token: "FIXTURE-OWNER")
        let binding = PlexHomeUserBinding(
            homeUserID: "protected", name: "Protected", requiresPIN: true, pinRequirementVerified: true
        )
        let targets = (0..<16).map { index in
            var profile = profiles.add(name: "Viewer \(index)", avatarSymbol: "person.fill", colorIndex: index % 5)
            profile = profile.settingHomeUserBinding(binding, forPlexAccount: "profile-performance-plex")
            profiles.update(profile)
            profiles.setActiveAccountIDs(["profile-performance-plex"], for: profile.id)
            return profile.id
        }
        defer { removeOwnedProfileSettings(targets) }
        let app = PlozziOSAppModel(accountStore: accounts, profileStore: store)
        app.plexHomeUsers.plexHomeUsersFetch = { _, _ in
            try await Task.sleep(for: .milliseconds(5))
            return [PlexHomeUser(id: "protected", name: "Protected", requiresPIN: true)]
        }
        app.plexHomeUsers.plexHomeUserSwitch = { _, _, _, _ in
            XCTFail("A selection may not authenticate without a PIN.")
            throw CancellationError()
        }
        try await PerformanceProbe.measure(self, scenario: "mobile-profile-selection") {
            var selectionMicroseconds = 0
            var maxSelectionMicroseconds = 0
            for id in targets {
                let start = ContinuousClock.now
                app.selectProfile(id)
                let elapsed = start.duration(to: .now).components
                let microseconds = Int(elapsed.seconds) * 1_000_000 + Int(elapsed.attoseconds / 1_000_000_000_000)
                selectionMicroseconds += microseconds
                maxSelectionMicroseconds = max(maxSelectionMicroseconds, microseconds)
                XCTAssertEqual(app.profiles.activeProfileID, id)
                XCTAssertNotNil(app.plexHomeUsers.pendingPlexPINRequest)
                await app.plexHomeUsers.waitForPlexPINRequirementCheck()
                XCTAssertEqual(app.plexHomeUsers.plexPINEntryAvailability, .available)
                XCTAssertNil(app.accountsProviders.tokenResolver("profile-performance-plex"))
            }
            return [
                "selections": targets.count, "selectionMicroseconds": selectionMicroseconds,
                "maxSelectionMicroseconds": maxSelectionMicroseconds
            ]
        }
    }

    private func removeOwnedProfileSettings(_ profileIDs: [String]) {
        let owned = Set(profileIDs)
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.components(separatedBy: ".").contains(where: owned.contains) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private struct LibrarySelectionPerformanceProvider: MediaProvider {
    let session: UserSession
    let onLibraries: @Sendable () -> Void
    let onItems: @Sendable () -> Void
    var kind: ProviderKind { session.server.provider }
    func libraries() async throws -> [MediaLibrary] {
        onLibraries()
        return (0..<6).map { MediaLibrary(id: "library-\($0)", title: "Library \($0)", kind: .movie) }
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        onItems()
        return .init(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
