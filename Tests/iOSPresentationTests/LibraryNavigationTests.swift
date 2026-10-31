#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
@testable import FeatureHomeCore
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS
@testable import FeatureSettings

@MainActor
final class LibraryNavigationTests: XCTestCase {
    func testDefaultTabsRemainHomeDownloadsAndSearchAfterDiscoveryOnPhoneAndTablet() async throws {
        let app = try makeApp()
        XCTAssertEqual(PlozziOSTabShell.configuredDestinations(appModel: app), [.home, .downloads, .search])
        await app.refreshNavigationLibraries()
        app.settings.navigation.hasWatchlistItems = true
        XCTAssertEqual(PlozziOSTabShell.configuredDestinations(appModel: app), [.home, .downloads, .search])
        try await withTabs(app: app) { tabs, window in
            try await waitUntil(window: window) { self.tabTitles(tabs).count == 3 }
            XCTAssertEqual(self.tabTitles(tabs), ["Home", "Downloads", "Search"])
            XCTAssertFalse(tabs.tabBar.items?.contains { $0.title == "More" } ?? false)
        }
    }

    func testAllLibrariesUsesBothProvidersAndHonorsContentVisibility() async throws {
        let fixture = LibraryNavigationFixture()
        let app = try makeApp(fixture: fixture)
        await app.refreshNavigationLibraries()
        showLibraryShortcuts(in: app)
        XCTAssertTrue(PlozziOSTabShell.configuredDestinations(appModel: app).contains(.allLibraries))
        let provider = try XCTUnwrap(resolveAllLibrariesBrowse(
            libraries: app.visibleNavigationLibraries,
            in: app.accountsProviders.homeAccounts,
            identitySources: { _ in [] }
        ) as? AggregatedLibraryProvider)
        XCTAssertEqual(Set(provider.sources.map(\.accountID)), ["plex", "jellyfin"])
        XCTAssertEqual(Set(provider.sources.compactMap(\.kind)), [.movie, .series])
        _ = try await provider.items(
            in: AllLibrariesBrowse.containerID, kind: .unknown,
            page: .init(startIndex: 0, limit: 20)
        )
        let requests = await fixture.browseRequests
        XCTAssertTrue(requests.contains("plex:library"))
        XCTAssertTrue(requests.contains("jellyfin:library"))

        app.settings.homeVisibility.setEnabled(false, for: "plex:library")
        XCTAssertFalse(PlozziOSTabShell.configuredDestinations(appModel: app).contains(.allLibraries))
        let filtered = try XCTUnwrap(resolveAllLibrariesBrowse(
            libraries: app.visibleNavigationLibraries,
            in: app.accountsProviders.homeAccounts,
            identitySources: { _ in [] }
        ) as? AggregatedLibraryProvider)
        XCTAssertEqual(filtered.sources.map(\.accountID), ["jellyfin"])
        XCTAssertNil(resolveAllLibrariesBrowse(
            libraries: app.visibleNavigationLibraries, in: [], identitySources: { _ in [] }
        ))
    }

    func testAllLibrariesCanBeHiddenReorderedAndRestoredPerProfile() async throws {
        let app = try makeApp()
        await app.refreshNavigationLibraries()
        let key = NavigationLibraryLayout.allLibrariesKey
        let available = NavigationDestinationDefaults.iOS(visibleLibraries: app.visibleNavigationLibraries)
        app.settings.navigation.applyLibrarySections(
            .init(enabled: [key], disabled: available.filter { $0 != key }), available: available,
            automaticallyHiddenKeys: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: available)
        )
        XCTAssertEqual(PlozziOSTabShell.configuredDestinations(appModel: app), [.allLibraries])
        let originalProfile = app.profiles.activeProfileID
        let next = app.profiles.add(name: "No libraries", isAwaitingSetup: false)
        app.profiles.select(next.id)
        app.refreshActiveProfileSettings()
        app.profiles.setActiveAccountIDs([], for: next.id)
        app.accountsProviders.reloadAccounts()
        XCTAssertFalse(PlozziOSTabShell.configuredDestinations(appModel: app).contains(.allLibraries))
        app.profiles.select(originalProfile)
        app.refreshActiveProfileSettings()
        app.accountsProviders.reloadAccounts()
        await app.refreshNavigationLibraries()
        XCTAssertEqual(PlozziOSTabShell.configuredDestinations(appModel: app), [.allLibraries])
        app.settings.navigation.applyLibrarySections(
            .init(enabled: [NavigationLibraryLayout.homeKey],
                  disabled: available.filter { $0 != NavigationLibraryLayout.homeKey }), available: available,
            automaticallyHiddenKeys: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: available)
        )
        XCTAssertFalse(PlozziOSTabShell.configuredDestinations(appModel: app).contains(.allLibraries))
    }

    func testAllLibrariesNativeTabLoadsBothLibraries() async throws {
        let fixture = LibraryNavigationFixture()
        let app = try makeApp(fixture: fixture)
        await app.refreshNavigationLibraries()
        let available = NavigationDestinationDefaults.iOS(visibleLibraries: app.visibleNavigationLibraries)
        app.settings.navigation.applyLibrarySections(
            .init(enabled: [NavigationLibraryLayout.homeKey, NavigationLibraryLayout.allLibrariesKey],
                  disabled: available.filter {
                      ![NavigationLibraryLayout.homeKey, NavigationLibraryLayout.allLibrariesKey].contains($0)
                  }), available: available,
            automaticallyHiddenKeys: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: available)
        )
        try await withTabs(app: app) { tabs, window in
            try await waitUntil(window: window) { self.tabTitles(tabs).contains("All Libraries") }
            await fixture.clearBrowseRequests()
            if let tab = tabs.tabs.first(where: { $0.title == "All Libraries" }) {
                tabs.selectedTab = tab
            } else {
                tabs.selectedViewController = try XCTUnwrap(
                    tabs.viewControllers?.first { $0.tabBarItem.title == "All Libraries" }
                )
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while await fixture.browseRequests.count < 2, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            let requests = await fixture.browseRequests
            XCTAssertTrue(requests.contains("plex:library"))
            XCTAssertTrue(requests.contains("jellyfin:library"))
        }
    }

    func testLibraryIconsMatchTVNavigationAndServerNamesUseSubtitles() async throws {
        let app = try makeApp()
        await app.refreshNavigationLibraries()
        let shell = makeShell(app: app)
        let libraries = app.visibleNavigationLibraries
        XCTAssertEqual(libraries.count, 2)
        let rows = NavigationLibrariesDetailView.rowsByKey(visible: libraries)
        for library in libraries {
            let symbol = library.library.navigationSymbolName
            XCTAssertEqual(shell.destinationSystemImage(.library(library.key)), symbol)
            XCTAssertNotNil(UIImage(systemName: symbol))
            let row = try XCTUnwrap(rows[library.key])
            XCTAssertEqual(row.title, library.library.displayName)
            XCTAssertEqual(row.symbolName, symbol)
            XCTAssertNil(row.detail, "Server names must not compete with the drag handle.")
            XCTAssertEqual(row.subtitle, Text(verbatim: library.serverName))
            XCTAssertEqual(row.providerKind, library.providerKind)
            XCTAssertTrue(row.providerMarkInSubtitle)
        }
        XCTAssertEqual(shell.destinationSystemImage(.home), "house")
        XCTAssertEqual(shell.destinationSystemImage(.search), "magnifyingglass")
    }

    func testSameNamedLibrariesKeepShortSeparateNativeTabs() async throws {
        let app = try makeApp(usesDuplicateLibraryNames: true)
        await app.refreshNavigationLibraries()
        showLibraryShortcuts(in: app)
        try await withTabs(app: app) { tabs, window in
            try await waitUntil(window: window) {
                self.tabTitles(tabs).filter { $0 == "Videos" }.count == 2
            }
            let titles = tabTitles(tabs)
            XCTAssertEqual(titles.filter { $0 == "Videos" }.count, 2, "\(titles)")
            XCTAssertFalse(titles.contains { $0.contains(" · ") }, "\(titles)")
            let destinations = PlozziOSTabShell.configuredDestinations(appModel: app)
            XCTAssertTrue(destinations.contains(.library("plex:library")))
            XCTAssertTrue(destinations.contains(.library("jellyfin:library")))
        }
    }

    func testArrangementRendersServerBelowLibraryOnPhoneAndTablet() async throws {
        let library = AggregatedLibrary(
            accountID: "plex", accountName: "Viewer", serverName: "Brandoland", providerKind: .plex,
            library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
        )
        let rows = NavigationLibrariesDetailView.rowsByKey(visible: [library])
        let row = try XCTUnwrap(rows[library.key])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for (width, typeSize) in [
            (CGFloat(390), DynamicTypeSize.large), (390, .accessibility1), (834, .large)
        ] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            let host = UIHostingController(rootView:
                ScrollView {
                    LiftableReorderList(
                        sections: .init(enabled: [library.key], disabled: []),
                        disabledSectionTitle: "Hidden", disabledPlaceholder: "Hidden items",
                        isLifting: .constant(false), row: { _ in row }, onChange: { _ in }
                    )
                    .padding(24)
                }
                .background(Color.black)
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
                .environment(\.dynamicTypeSize, typeSize)
                .environment(\.locale, Locale(identifier: "en"))
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            let deadline = ContinuousClock.now + .seconds(5)
            var titleBounds: CGRect?
            var serverBounds: CGRect?
            var image: UIImage?
            repeat {
                window.layoutIfNeeded()
                let capture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                image = capture
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(capture.cgImage)).perform([request])
                titleBounds = request.results?.first {
                    $0.topCandidates(1).first?.string.contains("Movies") == true
                }?.boundingBox
                serverBounds = request.results?.first {
                    $0.topCandidates(1).first?.string.contains("Brandoland") == true
                }?.boundingBox
                if titleBounds != nil && serverBounds != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            let attachment = XCTAttachment(image: try XCTUnwrap(image))
            attachment.name = "navigation-arrangement-\(Int(width))-\(typeSize)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let title = try XCTUnwrap(titleBounds)
            let server = try XCTUnwrap(serverBounds)
            XCTAssertLessThan(server.maxY, title.minY, "The server belongs on a separate line below the library.")
            XCTAssertLessThan(server.minX - title.minX, 0.12, "The source stays beside its provider, not the drag handle.")
        }
    }

    func testExplicitlyShownLibrariesAppearInNativePhoneAndTabletNavigation() async throws {
        let app = try makeApp()
        await app.refreshNavigationLibraries()
        showLibraryShortcuts(in: app)
        try await withTabs(app: app) { tabs, window in
            try await waitUntil(window: window) {
                app.settings.navigation.contentLibraries.count == 2
            }
            try await waitUntil(window: window) {
                Set(self.tabTitles(tabs)).isSuperset(of: ["Plex Movies", "Jellyfin Shows"])
            }
            XCTAssertTrue(tabTitles(tabs).contains("Plex Movies"), "\(tabTitles(tabs))")
            XCTAssertTrue(tabTitles(tabs).contains("Jellyfin Shows"), "\(tabTitles(tabs))")
        }
    }

    func testLibraryTabBrowsesItsOwningProvider() async throws {
        let fixture = LibraryNavigationFixture()
        let app = try makeApp(fixture: fixture)
        await app.refreshNavigationLibraries()
        let available = NavigationDestinationDefaults.iOS(visibleLibraries: app.visibleNavigationLibraries)
        let enabled = [NavigationLibraryLayout.downloadsKey, "plex:library", "jellyfin:library"]
        app.settings.navigation.applyLibrarySections(
            .init(enabled: enabled, disabled: available.filter { !enabled.contains($0) }),
            available: available,
            automaticallyHiddenKeys: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: available)
        )
        try await withTabs(app: app) { tabs, window in
            try await waitUntil(window: window) { self.tabTitles(tabs).contains("Plex Movies") }
            await fixture.clearBrowseRequests()
            if let libraryTab = tabs.tabs.first(where: { $0.title == "Plex Movies" }) {
                tabs.selectedTab = libraryTab
            } else {
                tabs.selectedViewController = try XCTUnwrap(
                    tabs.viewControllers?.first { $0.tabBarItem.title == "Plex Movies" }
                )
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while await !fixture.browseRequests.contains("plex:library"), ContinuousClock.now < deadline {
                window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let requests = await fixture.browseRequests
            XCTAssertTrue(requests.contains("plex:library"), "\(requests)")
            XCTAssertFalse(requests.contains("jellyfin:library"), "\(requests)")
        }
    }

    func testNativeOverflowRetainsEveryLibrary() async throws {
        let fixture = LibraryNavigationFixture(libraryCount: 10)
        let app = try makeApp(fixture: fixture)
        await app.refreshNavigationLibraries()
        showLibraryShortcuts(in: app)
        try await withTabs(app: app) { tabs, window in
            try await waitUntil(window: window) {
                self.tabTitles(tabs).filter { $0.hasPrefix("Plex Movies") || $0.hasPrefix("Jellyfin Shows") }.count == 20
            }
            XCTAssertEqual(Set(tabTitles(tabs)).count, tabTitles(tabs).count)
            XCTAssertTrue(tabTitles(tabs).contains("Plex Movies 10"), "\(tabTitles(tabs))")
            XCTAssertTrue(tabTitles(tabs).contains("Jellyfin Shows 10"), "\(tabTitles(tabs))")
        }
    }

    func testSettingsRecoveryUpdatesNavigationWithoutErasingHides() async throws {
        let fixture = LibraryNavigationFixture()
        await fixture.setFailure(.serverUnreachable)
        let app = try makeApp(fixture: fixture)
        let initial = await app.refreshNavigationLibraries()
        XCTAssertTrue(initial)
        XCTAssertEqual(app.settings.discoveredLibraries.unreachableAccountIDs, ["plex"])
        XCTAssertFalse(PlozziOSTabShell.configuredDestinations(appModel: app).contains(.library("plex:library")))

        await fixture.setFailure(nil)
        let recovered = await app.refreshNavigationLibraries()
        XCTAssertTrue(recovered)
        XCTAssertEqual(app.settings.discoveredLibraries.state.value, app.settings.navigation.contentLibraries)
        XCTAssertEqual(PlozziOSTabShell.configuredDestinations(appModel: app), [.home, .downloads, .search])
        showLibraryShortcuts(in: app)
        XCTAssertTrue(PlozziOSTabShell.configuredDestinations(appModel: app).contains(.library("plex:library")))
        let navigation = app.settings.navigation
        let keys = NavigationDestinationDefaults.iOS(visibleLibraries: app.visibleNavigationLibraries)
        let sections = navigation.librarySections(available: keys)
        navigation.applyLibrarySections(
            .init(enabled: sections.enabled.filter { $0 != "plex:library" }, disabled: sections.disabled + ["plex:library"]),
            available: keys
        )
        let layout = navigation.libraryLayout
        await app.refreshNavigationLibraries()
        XCTAssertEqual(navigation.libraryLayout, layout)
        XCTAssertFalse(PlozziOSTabShell.configuredDestinations(appModel: app).contains(.library("plex:library")))
        XCTAssertTrue(navigation.librarySections(available: keys).disabled.contains("plex:library"))
    }

    func testDisabledAndExcludedLibrariesNeverBecomeDestinations() async throws {
        let app = try makeApp()
        await app.refreshNavigationLibraries()
        showLibraryShortcuts(in: app)
        app.settings.homeVisibility.setEnabled(false, for: "plex:library")
        XCTAssertFalse(PlozziOSTabShell.configuredDestinations(appModel: app).contains(.library("plex:library")))
        app.profiles.setActiveAccountIDs(["plex"], for: app.profiles.activeProfileID)
        app.accountsProviders.reloadAccounts()
        XCTAssertFalse(PlozziOSTabShell.configuredDestinations(appModel: app).contains(.library("jellyfin:library")),
                       "A removed account must disappear before asynchronous discovery completes.")
        let profile = app.profiles.add(name: "Separate", isAwaitingSetup: false)
        app.profiles.select(profile.id)
        app.refreshActiveProfileSettings()
        app.profiles.setActiveAccountIDs([], for: profile.id)
        app.accountsProviders.reloadAccounts()
        XCTAssertTrue(app.visibleNavigationLibraries.isEmpty)
        XCTAssertFalse(app.settings.homeVisibility.visibility.disabledKeys.contains("plex:library"))
    }

    func testProfileChangeRejectsInFlightMobileDiscovery() async throws {
        let fixture = LibraryNavigationFixture()
        let app = try makeApp(fixture: fixture)
        let started = expectation(description: "Plex library request started")
        await fixture.pause(started: started)
        let previousSettings = app.settings
        let task = Task { await app.refreshNavigationLibraries() }
        await fulfillment(of: [started], timeout: 5)
        let next = app.profiles.add(name: "Next", isAwaitingSetup: false)
        app.profiles.select(next.id)
        app.refreshActiveProfileSettings()
        app.profiles.setActiveAccountIDs([], for: next.id)
        app.accountsProviders.reloadAccounts()
        await fixture.resume()
        let published = await task.value
        XCTAssertFalse(published)
        XCTAssertTrue(previousSettings.navigation.contentLibraries.isEmpty)
        XCTAssertTrue(app.settings.navigation.contentLibraries.isEmpty)
        XCTAssertNil(app.settings.discoveredLibraries.state.value)
    }

    func testCancelledSettingsRefreshPreservesPendingMobileDiscovery() async throws {
        let fixture = LibraryNavigationFixture()
        let app = try makeApp(fixture: fixture)
        let started = expectation(description: "Shell library request started")
        await fixture.pause(started: started)
        let shell = Task { await app.refreshNavigationLibraries() }
        await fulfillment(of: [started], timeout: 5)
        let settings = Task { await app.refreshNavigationLibraries() }
        settings.cancel()
        let settingsPublished = await settings.value
        XCTAssertFalse(settingsPublished)
        XCTAssertTrue(app.settings.discoveredLibraries.state.isLoading)
        await fixture.resume()
        let shellPublished = await shell.value
        XCTAssertTrue(shellPublished)
        XCTAssertTrue(app.visibleNavigationLibraries.contains { $0.key == "plex:library" })
        XCTAssertEqual(PlozziOSTabShell.configuredDestinations(appModel: app), [.home, .downloads, .search])
        XCTAssertEqual(app.settings.discoveredLibraries.state.value, app.settings.navigation.contentLibraries)
        XCTAssertTrue(app.settings.discoveredLibraries.refreshingAccountIDs.isEmpty)
    }

    func testLibraryIdentityAndDiagnosticsRemainSeparate() {
        XCTAssertEqual(PlozziOSDestination(rawValue: PlozziOSDestination.allLibraries.rawValue), .allLibraries)
        XCTAssertEqual(PlozziOSDestination.allLibraries.diagnosticCategory, "library")
        let first = PlozziOSDestination.library("plex:library")
        let second = PlozziOSDestination.library("jellyfin:library")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(PlozziOSDestination(rawValue: first.rawValue), first)
        XCTAssertEqual(first.diagnosticCategory, "library")
        XCTAssertEqual(second.diagnosticCategory, "library")
    }

    private func makeApp(
        fixture: LibraryNavigationFixture = LibraryNavigationFixture(),
        usesDuplicateLibraryNames: Bool = false
    ) throws -> PlozziOSAppModel {
        let suite = "LibraryNavigationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = AccountStore(secureStore: InMemorySecureStore())
        let profiles = ProfileStore(defaults: defaults)
        let app = PlozziOSAppModel(accountStore: store, profileStore: profiles)
        let profile = app.profiles.add(name: "Libraries fixture", isAwaitingSetup: false)
        app.profiles.select(profile.id)
        app.refreshActiveProfileSettings()
        let libraries: [(String, ProviderKind, String, MediaItemKind)] = [
            ("plex", .plex, "Plex Movies", .movie),
            ("jellyfin", .jellyfin, "Jellyfin Shows", .series)
        ]
        for (id, kind, title, mediaKind) in libraries {
            try store.add(Account(
                id: id,
                server: MediaServer(
                    id: id, name: id, baseURL: URL(string: "https://fixture.invalid")!, provider: kind
                ),
                userID: "viewer", userName: "Viewer", deviceID: "fixture"
            ), token: "fixture")
            app.accountsProviders.registry.register(kind) { context in
                LibraryNavigationProvider(
                    session: context.session,
                    library: MediaLibrary(
                        id: "library", title: usesDuplicateLibraryNames ? "Videos" : title, kind: mediaKind
                    ),
                    fixture: fixture
                )
            }
        }
        app.profiles.setActiveAccountIDs(["plex", "jellyfin"], for: profile.id)
        app.accountsProviders.tokenResolver = { _ in "fixture" }
        app.accountsProviders.reloadAccounts()
        return app
    }

    private func makeShell(app: PlozziOSAppModel) -> PlozziOSTabShell {
        PlozziOSTabShell(
            appModel: app, homeViewModelBox: LazyViewState<HomeViewModel>(), onAddServer: {},
            showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
            deferredPairingURL: .constant(nil), systemColorScheme: .dark
        )
    }

    private func showLibraryShortcuts(in app: PlozziOSAppModel) {
        let available = NavigationDestinationDefaults.iOS(visibleLibraries: app.visibleNavigationLibraries)
        app.settings.navigation.applyLibrarySections(
            .init(enabled: available, disabled: []), available: available,
            automaticallyHiddenKeys: NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: available)
        )
    }

    private func withTabs(
        app: PlozziOSAppModel,
        operation: (UITabBarController, UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for (width, sizeClass) in [(CGFloat(390), UserInterfaceSizeClass.compact), (834, .regular)] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
            let host = UIHostingController(rootView:
                makeShell(app: app)
                .environment(app)
                .environment(HeroTrailerController())
                .environment(PlozziOSSidebarGeometryModel())
                .environment(\.themePalette, .dark)
                .environment(\.horizontalSizeClass, sizeClass)
                .environment(\.locale, Locale(identifier: "en"))
            )
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await waitUntil(window: window) { self.tabController(in: host) != nil }
            let tabs = try XCTUnwrap(tabController(in: host))
            try await operation(tabs, window)
        }
    }

    private func waitUntil(window: UIWindow, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            window.layoutIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTFail("Expected native library navigation did not appear.")
    }

    private func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { self.tabController(in: $0) }.first
    }

    private func tabTitles(_ tabs: UITabBarController) -> [String] {
        tabs.tabs.isEmpty ? (tabs.viewControllers ?? []).compactMap(\.tabBarItem.title) : tabs.tabs.map(\.title)
    }
}

private struct LibraryNavigationProvider: MediaProvider {
    let session: UserSession
    let library: MediaLibrary
    let fixture: LibraryNavigationFixture
    var kind: ProviderKind { session.server.provider }
    func libraries() async throws -> [MediaLibrary] {
        try await fixture.libraries(accountID: session.server.id, library: library)
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        await fixture.recordBrowse(accountID: session.server.id, containerID: containerID)
        return .init(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private actor LibraryNavigationFixture {
    let libraryCount: Int
    private var failure: AppError?
    private var started: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var browseRequests: [String] = []

    init(libraryCount: Int = 1) { self.libraryCount = libraryCount }
    func setFailure(_ failure: AppError?) { self.failure = failure }
    func pause(started: XCTestExpectation) { self.started = started }
    func resume() { continuation?.resume(); continuation = nil }
    func clearBrowseRequests() { browseRequests.removeAll() }
    func recordBrowse(accountID: String, containerID: String) { browseRequests.append("\(accountID):\(containerID)") }

    func libraries(accountID: String, library: MediaLibrary) async throws -> [MediaLibrary] {
        if accountID == "plex" {
            if let started {
                self.started = nil
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
            if let failure { throw failure }
        }
        return (1...libraryCount).map { index in
            guard libraryCount > 1 else { return library }
            var next = library
            next.id = "\(library.id)-\(index)"
            next.title = "\(library.title) \(index)"
            return next
        }
    }
}
#endif
