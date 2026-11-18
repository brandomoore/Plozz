#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
import FeatureProfiles
import FeatureSettings
import SwiftUI
import Synchronization
import UIKit
import XCTest
@testable import AppRuntime
@testable import AppShelliOS

@MainActor
final class ProfileSelectionPerformanceTests: XCTestCase {
    func testPerformanceLibrarySelectionWithAppShell() async throws {
        try PerformanceProbe.requireEnabled()
        try await exerciseLibrarySelectionWithAppShell(measuring: true)
    }

    func testProfileLibrarySelectionDoesNotReloadCoveredHome() async throws {
        try await exerciseLibrarySelectionWithAppShell(measuring: false)
    }

    private func exerciseLibrarySelectionWithAppShell(measuring: Bool) async throws {
        let suite = "ProfileLibrariesShell.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = AccountStore(secureStore: InMemorySecureStore())
        let app = PlozziOSAppModel(
            appAdmissionStore: AppAdmissionStore(defaults: defaults),
            accountStore: store, profileStore: ProfileStore(defaults: defaults)
        )
        app.profiles.markFirstRunProfileSetupComplete()
        let requests = Mutex((home: 0, libraries: 0))
        for index in 0..<20 {
            let id = "shell-\(index)"
            try store.add(Account(
                id: id,
                server: .init(id: id, name: String(format: "Server %02d", index),
                              baseURL: URL(string: "https://server-\(index).invalid")!, provider: .jellyfin),
                userID: "viewer", userName: "Viewer", deviceID: "fixture"
            ), token: "fixture")
        }
        app.accountsProviders.registry.register(.jellyfin) { context in
            LibrarySelectionPerformanceProvider(
                session: context.session,
                onLibraries: { requests.withLock { $0.libraries += 1 } }, onItems: {},
                onHome: {
                    requests.withLock { $0.home += 1 }
                    try await Task.sleep(for: .milliseconds(150))
                }
            )
        }
        app.accountsProviders.tokenResolver = { _ in "fixture" }
        app.accountsProviders.reloadAccounts()
        app.saveProfile(.init(id: nil, name: "Library choices", avatarSymbol: "person.fill", colorIndex: 0))
        let profileID = app.profiles.activeProfileID
        let setupDeadline = ContinuousClock.now + .seconds(3)
        while app.profileOnboardingStep != .libraries, ContinuousClock.now < setupDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(app.profileOnboardingStep, .libraries)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView:
            PlozziOSRootView(appModel: app)
                .environment(\.horizontalSizeClass, .compact)
                .environment(\.locale, Locale(identifier: "en_US"))
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
            removeOwnedProfileSettings([profileID])
        }
        func switches(_ view: UIView) -> [UISwitch] {
            (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap(switches)
        }
        func setupController() -> UIViewController {
            var controller: UIViewController = host
            while let presented = controller.presentedViewController { controller = presented }
            return controller
        }
        let presentationDeadline = ContinuousClock.now + .seconds(5)
        while (switches(setupController().view).isEmpty
               || app.settings.discoveredLibraries.state.value?.count != 120),
              ContinuousClock.now < presentationDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(switches(setupController().view).isEmpty)
        XCTAssertEqual(app.settings.discoveredLibraries.state.value?.count, 120)
        try await Task.sleep(for: .milliseconds(500))

        func exercise() async throws -> [String: Int] {
            let before = requests.withLock { $0 }
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
                let control = try XCTUnwrap(switches(setupController().view).min {
                    $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
                })
                control.setOn(enabled, animated: false)
                control.sendActions(for: .valueChanged)
                XCTAssertEqual(app.activeAccountIDs(for: profileID).contains("shell-0"), enabled)
                try await Task.sleep(for: .milliseconds(400))
            }
            for index in 0..<12 {
                app.settings.homeVisibility.setEnabled(index.isMultiple(of: 2), for: "shell-0:library-0")
                try await Task.sleep(for: .milliseconds(30))
            }
            let after = requests.withLock { $0 }
            let parts = maxGap.components
            return [
                "servers": 20, "libraries": 120, "serverToggles": 4, "libraryToggles": 12,
                "homeRequests": after.home - before.home, "libraryRequests": after.libraries - before.libraries,
                "maxMainActorGapMicroseconds": Int(parts.seconds) * 1_000_000
                    + Int(parts.attoseconds / 1_000_000_000_000)
            ]
        }
        if measuring {
            try await PerformanceProbe.measure(self, scenario: "mobile-profile-library-shell", operation: exercise)
        } else {
            let counters = try await exercise()
            XCTAssertEqual(counters["homeRequests"], 0, "Home must not fan out behind the profile Libraries cover.")
            XCTAssertEqual(requests.withLock { $0.home }, 0, "Setup must discover names without loading Home feeds.")
        }
        XCTAssertEqual(app.accountsProviders.activeAccountIDs.count, 20)
        XCTAssertFalse(app.settings.homeVisibility.isEnabled("shell-0:library-0"))
        XCTAssertEqual(app.profileOnboardingStep, .libraries)
        if !measuring {
            while app.profileOnboardingStep != nil { app.advanceProfileOnboarding() }
            let homeDeadline = ContinuousClock.now + .seconds(5)
            while requests.withLock({ $0.home }) == 0, ContinuousClock.now < homeDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(app.profiles.activeProfile.needsSetup)
            XCTAssertGreaterThan(requests.withLock { $0.home }, 0, "Home must load after setup finishes.")

            app.screenshotDirector.tab = "settings"
            let settingsDeadline = ContinuousClock.now + .seconds(5)
            while !app.isSettingsPresented, ContinuousClock.now < settingsDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(app.isSettingsPresented)
            try await Task.sleep(for: .milliseconds(500))
            let coveredRequests = requests.withLock { $0.home }
            for enabled in [false, true, false, true] {
                app.setAccount("shell-0", enabled: enabled, for: profileID)
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(requests.withLock { $0.home }, coveredRequests,
                           "Ordinary Settings must also defer hidden Home reloads.")
            host.dismiss(animated: false)
            let dismissalDeadline = ContinuousClock.now + .seconds(5)
            while app.isSettingsPresented || requests.withLock({ $0.home }) == coveredRequests,
                  ContinuousClock.now < dismissalDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(app.isSettingsPresented)
            XCTAssertGreaterThan(requests.withLock { $0.home }, coveredRequests,
                                 "Dismissing Settings must load the final account selection.")
        }
    }

    func testPlexSourceToggleKeepsTheOriginalSettingsSheet() async throws {
        for requiresPIN in [false, true] {
            let suite = "PlexSettingsContinuity.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let store = AccountStore(secureStore: InMemorySecureStore())
            let app = PlozziOSAppModel(
                appAdmissionStore: AppAdmissionStore(defaults: defaults),
                accountStore: store, profileStore: ProfileStore(defaults: defaults)
            )
            let accountID = "plex-\(UUID())"
            let profile = app.profiles.add(
                name: "Settings continuity",
                plexHomeUserBindings: [accountID: .init(
                    homeUserID: "viewer", name: "Viewer", requiresPIN: requiresPIN,
                    pinRequirementVerified: true
                )]
            )
            app.profiles.select(profile.id)
            app.refreshActiveProfileSettings()
            app.profiles.markFirstRunProfileSetupComplete()
            app.profiles.setActiveAccountIDs([], for: profile.id)
            try store.add(Account(
                id: accountID,
                server: .init(id: accountID, name: "Plex fixture",
                              baseURL: URL(string: "https://plex.invalid")!, provider: .plex),
                userID: "owner", userName: "Owner", deviceID: "fixture"
            ), token: "FIXTURE-OWNER")
            app.accountsProviders.registry.register(.plex) { context in
                LibrarySelectionPerformanceProvider(
                    session: context.session, onLibraries: {}, onItems: {}
                )
            }
            app.accountsProviders.reloadAccounts()
            app.plexHomeUsers.plexHomeUsersFetch = { _, _ in
                try await Task.sleep(for: .milliseconds(250))
                return [PlexHomeUser(id: "viewer", name: "Viewer", requiresPIN: requiresPIN)]
            }
            app.plexHomeUsers.plexHomeUserSwitch = { _, pin, _, _ in
                XCTAssertEqual(pin, requiresPIN ? "2468" : nil)
                return "FIXTURE-CLOUD"
            }
            app.plexHomeUsers.plexServerTokenResolve = { _, _, _ in "FIXTURE-SERVER" }
            app.plexHomeUsers.ensurePlexIdentityForActiveProfile()
            XCTAssertFalse(app.requiresLaunchProfileSelection)
            XCTAssertFalse(app.didCompleteLaunchProfileSelection)

            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            let host = UIHostingController(rootView:
                PlozziOSRootView(appModel: app)
                    .environment(\.horizontalSizeClass, .compact)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                host.dismiss(animated: false)
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
                app.plexHomeUsers.forgetAccount(accountID)
                defaults.removePersistentDomain(forName: suite)
                removeOwnedProfileSettings([profile.id])
            }
            try await Task.sleep(for: .milliseconds(400))
            app.screenshotDirector.tab = "settings"
            let deadline = ContinuousClock.now + .seconds(5)
            while (host.presentedViewController?.view.window == nil || !app.isSettingsPresented),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let settings = try XCTUnwrap(host.presentedViewController)
            XCTAssertTrue(app.isSettingsPresented)
            try await Task.sleep(for: .milliseconds(400))

            app.setAccount(accountID, enabled: true, for: profile.id)
            XCTAssertNotNil(app.plexHomeUsers.pendingPlexPINRequest)
            XCTAssertNil(app.accountsProviders.tokenResolver(accountID),
                         "Keeping Settings open must not authorize the newly enabled source.")
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(20))
                XCTAssertTrue(host.presentedViewController === settings,
                              "Plex verification must not dismiss and recreate Settings.")
                XCTAssertFalse(settings.isBeingDismissed)
                XCTAssertNotNil(settings.view.window)
            }
            await app.plexHomeUsers.waitForPlexPINRequirementCheck()
            if requiresPIN {
                XCTAssertNotNil(app.plexHomeUsers.pendingPlexPINRequest)
                XCTAssertNil(app.accountsProviders.tokenResolver(accountID))
                XCTAssertNotNil(settings.presentedViewController,
                                "The required PIN must be presented above the existing Settings sheet.")
                app.plexHomeUsers.submitPlexPIN("2468")
                await app.plexHomeUsers.waitForPlexPINRequirementCheck()
            }
            XCTAssertNil(app.plexHomeUsers.pendingPlexPINRequest)
            XCTAssertEqual(app.accountsProviders.tokenResolver(accountID), "FIXTURE-SERVER")
            app.setAccount(accountID, enabled: false, for: profile.id)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertTrue(host.presentedViewController === settings)
            XCTAssertFalse(settings.isBeingDismissed)
            XCTAssertNotNil(settings.view.window)
            XCTAssertTrue(app.isSettingsPresented)
            XCTAssertNil(app.accountsProviders.tokenResolver(accountID))

            let other = app.profiles.add(name: "Different profile")
            defer { removeOwnedProfileSettings([other.id]) }
            app.selectProfile(other.id)
            let dismissalDeadline = ContinuousClock.now + .seconds(3)
            while settings.view.window != nil, ContinuousClock.now < dismissalDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(settings.view.window, "A different profile must not retain the old Settings presentation.")
        }
    }

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
    var onHome: @Sendable () async throws -> Void = {}
    var kind: ProviderKind { session.server.provider }
    func libraries() async throws -> [MediaLibrary] {
        onLibraries()
        return (0..<6).map { MediaLibrary(id: "library-\($0)", title: "Library \($0)", kind: .movie) }
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await onHome()
        return []
    }
    func latest(limit: Int) async throws -> [MediaItem] {
        try await onHome()
        return []
    }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        onItems()
        try await onHome()
        return .init(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
