#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class HomeModelLifetimeTests: XCTestCase {
    func testHomeStateBoxRetiresOnlyDiscardedScopes() {
        let box = LazyViewState<String>()
        var retired: [String] = []
        XCTAssertEqual(box.value(forKey: "a", onDiscard: { retired.append($0) }) { "first" }, "first")
        XCTAssertEqual(box.value(forKey: "a", onDiscard: { retired.append($0) }) { "unused" }, "first")
        XCTAssertTrue(retired.isEmpty)
        XCTAssertEqual(box.value(forKey: "b", onDiscard: { retired.append($0) }) { "second" }, "second")
        XCTAssertEqual(retired, ["first"])
        box.discard { retired.append($0) }
        XCTAssertEqual(retired, ["first", "second"])
        XCTAssertNil(box.existingValue(forKey: "b"))
    }

    func testPerformanceRetiredHomeModels() async throws {
        try PerformanceProbe.requireEnabled()
        let suite = "HomeModelLifetime.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = PlozziOSAppModel(
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        let original = app.profiles.activeProfileID
        let other = app.profiles.add(name: "Home lifetime fixture", isAwaitingSetup: false)
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.components(separatedBy: ".").contains(other.id) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let box = LazyViewState<HomeViewModel>()
        func model() -> HomeViewModel {
            PlozziOSTabShell(
                appModel: app, homeViewModelBox: box, onAddServer: {},
                showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
                deferredPairingURL: .constant(nil), systemColorScheme: .dark
            ).sharedHomeViewModel
        }
        await app.ensureTrackersScopedToActiveProfile()
        try await Task.sleep(for: .seconds(1))
        try await PerformanceProbe.measure(self, scenario: "mobile-home-lifecycle") {
            for _ in 0..<20 {
                weak var retired = model()
                weak var retiredSettings = app.settings
                weak var retiredDownloads = app.downloads
                app.selectProfile(app.profiles.activeProfileID == original ? other.id : original)
                _ = model()
                let deadline = ContinuousClock.now + .seconds(5)
                while (retired != nil || retiredSettings != nil || retiredDownloads != nil),
                      ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let released = retired == nil && retiredSettings == nil && retiredDownloads == nil
                _ = try XCTUnwrap(
                    released ? true : nil,
                    "Retained profile models: Home=\(retired != nil), settings=\(retiredSettings != nil), downloads=\(retiredDownloads != nil)"
                )
            }
            await app.ensureTrackersScopedToActiveProfile()
            try await Task.sleep(for: .seconds(1))
            return ["replacements": 20, "survivingModels": 0]
        }
        try await PerformanceProbe.attachMemoryAfterOneSecond(self, scenario: "mobile-home-lifecycle")
    }

    func testDefaultTabsKeepSettingsOptionalOnPhoneAndTablet() async throws {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Navigation defaults fixture", isAwaitingSetup: false)
        let store = NavigationLibraryLayoutStore(namespace: profile.id)
        store.save(.default)
        app.selectProfile(profile.id)
        defer {
            app.selectProfile(original)
            app.profiles.remove(profile.id)
            store.save(.default)
        }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let available = NavigationDestinationDefaults.iOS
        let automatic = NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys
        for (width, sizeClass) in [
            (CGFloat(390), UserInterfaceSizeClass.compact), (834, .regular)
        ] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
            let host = UIHostingController(rootView:
                PlozziOSTabShell(
                    appModel: app, homeViewModelBox: LazyViewState<HomeViewModel>(), onAddServer: {},
                    showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
                    deferredPairingURL: .constant(nil), systemColorScheme: .dark
                )
                .environment(app)
                .environment(HeroTrailerController())
                .environment(PlozziOSSidebarGeometryModel())
                .environment(\.themePalette, .dark)
                .environment(\.horizontalSizeClass, sizeClass)
                .environment(\.locale, Locale(identifier: "en"))
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await waitForTabs(in: host, window: window)
            let tabs = try XCTUnwrap(tabController(in: host))
            let initial = try XCTUnwrap(tabs.tabBar.items).compactMap(\.title)
            XCTAssertFalse(initial.contains("Settings"), "\(initial)")
            XCTAssertFalse(initial.contains("More"), "\(initial)")
            XCTAssertLessThanOrEqual(initial.count, 5)

            let navigation = app.settings.navigation
            let sections = navigation.librarySections(available: available, automaticallyHiddenKeys: automatic)
            XCTAssertTrue(sections.disabled.contains(NavigationLibraryLayout.settingsKey))
            navigation.applyLibrarySections(
                .init(enabled: sections.enabled + [NavigationLibraryLayout.settingsKey],
                      disabled: sections.disabled.filter { $0 != NavigationLibraryLayout.settingsKey }),
                available: available, automaticallyHiddenKeys: automatic
            )
            try await waitForSettingsTab(in: host, window: window, visible: true)
            XCTAssertTrue(store.load().shownKeys.contains(NavigationLibraryLayout.settingsKey))
            navigation.resetLibraryLayout()
            try await waitForSettingsTab(in: host, window: window, visible: false)
            XCTAssertEqual(store.load(), .default)
        }
    }

    private func waitForSettingsTab(in host: UIViewController, window: UIWindow, visible: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
            if let titles = tabController(in: host)?.tabBar.items?.compactMap(\.title),
               titles.contains("Settings") == visible { return }
        } while ContinuousClock.now < deadline
        XCTFail("Settings tab visibility did not become \(visible).")
    }

    func testTabShellProvidesProfilesToHomeLiveTVScopeOnPhoneAndTablet() async throws {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Home environment fixture")
        defer {
            app.profiles.select(original)
            app.profiles.remove(profile.id)
        }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for (width, sizeClass) in [
            (CGFloat(390), UserInterfaceSizeClass.compact), (834, .regular)
        ] {
            app.profiles.select(original)
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
            let host = UIHostingController(rootView:
                PlozziOSTabShell(
                    appModel: app, homeViewModelBox: LazyViewState<HomeViewModel>(), onAddServer: {},
                    showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
                    deferredPairingURL: .constant(nil), systemColorScheme: .dark
                )
                .environment(app)
                .environment(HeroTrailerController())
                .environment(PlozziOSSidebarGeometryModel())
                .environment(\.themePalette, .dark)
                .environment(\.horizontalSizeClass, sizeClass)
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await waitForTabs(in: host, window: window)

            app.profiles.select(profile.id)
            try await waitForTabs(in: host, window: window)
        }
    }

    private func waitForTabs(in host: UIViewController, window: UIWindow) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        repeat {
            try await Task.sleep(for: .milliseconds(16))
            window.layoutIfNeeded()
            if let tabs = tabController(in: host), tabs.view.window === window { return }
        } while ContinuousClock.now < deadline
        XCTFail("The tab shell must render its profile-dependent Live TV scope.")
    }

    private func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { self.tabController(in: $0) }.first
    }

    func testRootUpdatesReuseTheSameHomeModel() {
        let app = PlozziOSAppModel()
        let box = LazyViewState<HomeViewModel>()
        var models: [HomeViewModel] = []
        let start = ContinuousClock.now
        for index in 0..<24 {
            let shell = PlozziOSTabShell(
                appModel: app, homeViewModelBox: box, onAddServer: {},
                showingSettings: .constant(index.isMultiple(of: 2)),
                showingProfileSwitcher: .constant(false),
                deferredPairingURL: .constant(nil),
                systemColorScheme: index.isMultiple(of: 2) ? .dark : .light
            )
            models.append(shell.sharedHomeViewModel)
        }
        let constructions = Set(models.map(ObjectIdentifier.init)).count
        print("Home root updates: 24; models: \(constructions); elapsed: \(start.duration(to: .now))")
        XCTAssertEqual(constructions, 1, "Root presentation updates must not rehydrate disposable Home models.")
    }

    func testProfileSwitchReplacesTheModelBeforeRenderingTheNewScope() {
        let app = PlozziOSAppModel()
        let original = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Home lifetime fixture")
        defer {
            app.profiles.select(original)
            app.profiles.remove(profile.id)
        }
        let box = LazyViewState<HomeViewModel>()
        func model() -> HomeViewModel {
            PlozziOSTabShell(
                appModel: app, homeViewModelBox: box, onAddServer: {},
                showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
                deferredPairingURL: .constant(nil), systemColorScheme: .dark
            ).sharedHomeViewModel
        }
        let first = model()
        XCTAssertTrue(first === model())
        app.profiles.select(profile.id)
        let second = model()
        XCTAssertFalse(first === second)
        XCTAssertTrue(second === model())
        app.profiles.select(original)
        let restored = model()
        XCTAssertFalse(second === restored)
        XCTAssertFalse(first === restored, "Do not revive an obsolete credential/cache snapshot.")
    }
}
#endif
