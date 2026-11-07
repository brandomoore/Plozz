#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import SwiftUI
import Synchronization
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class HomeMultiServerLoadingTests: XCTestCase {
    func testPerformanceHomeLoadingAcrossTwentyServers() async throws {
        try PerformanceProbe.requireEnabled()
        try await PerformanceProbe.measure(self, scenario: "mobile-home-multi-server-loading") {
            try await self.exercise()
        }
    }

    func testHomeFinishesEveryServerRowWhileScrolling() async throws {
        _ = try await exercise()
    }

    private func exercise() async throws -> [String: Int] {
        let suite = "HomeMultiServer.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = AccountStore(secureStore: InMemorySecureStore())
        let app = PlozziOSAppModel(
            accountStore: store, profileStore: ProfileStore(defaults: defaults)
        )
        let profile = app.profiles.add(name: "Home loading", isAwaitingSetup: false)
        app.selectProfile(profile.id)
        app.profiles.markFirstRunProfileSetupComplete()
        app.settings.hero.settings.isEnabled = false
        let metadata = app.metadataProviderSettingsModel.settings
        app.metadataProviderSettingsModel.settings = MetadataProviderSettings(
            orderMode: .custom, preferOnlineArtwork: false,
            disabledOrder: MetadataSourceAttribution.all.map(\.id)
        )
        defer {
            app.metadataProviderSettingsModel.settings = metadata
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.components(separatedBy: ".").contains(profile.id) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let requests = MultiServerHomeRequests()
        for index in 0..<20 {
            let id = "server-\(index)"
            try store.add(Account(
                id: id,
                server: .init(id: id, name: "Server \(index)",
                              baseURL: URL(string: "https://server-\(index).invalid")!, provider: .jellyfin),
                userID: "viewer", userName: "Viewer", deviceID: "fixture"
            ), token: "fixture")
        }
        app.profiles.setActiveAccountIDs((0..<20).map { "server-\($0)" }, for: profile.id)
        app.accountsProviders.registry.register(.jellyfin) { context in
            MultiServerHomeProvider(session: context.session, requests: requests)
        }
        app.accountsProviders.tokenResolver = { _ in "fixture" }
        app.accountsProviders.reloadAccounts()
        await app.settings.homeVisibility.prepareServerDefaults(accounts: app.accountsProviders.homeAccounts)
        let model = HomeViewModel(
            accounts: app.accountsProviders.homeAccounts, profileNamespace: profile.id,
            contentStore: NoOpHomeContentStore(),
            currentVisibility: { app.settings.homeVisibility.visibility }
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.overrideUserInterfaceStyle = .dark
        var maximumGap = Duration.zero
        let heartbeat = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
                let now = ContinuousClock.now
                maximumGap = max(maximumGap, last.duration(to: now))
                last = now
            }
        }
        defer {
            heartbeat.cancel()
            model.invalidate()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let root = NavigationStack {
            PlozziOSHomeView(appModel: app, viewModel: model, onAddServer: {}, onShowSettings: {})
        }
        .environment(app)
        .environment(HeroTrailerController())
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.themePalette, .dark)
        .environment(\.plozzMetrics, .touch(density: .standard))
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while model.state.value?.serverRows.count != 40, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        var mountedScroll: UIScrollView?
        while mountedScroll == nil, ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            mountedScroll = scrollViews(window).first { $0.contentSize.height > $0.bounds.height }
            if mountedScroll == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let scroll = try XCTUnwrap(mountedScroll)
        for index in 1...8 {
            scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(index * 180)), animated: true)
            try await Task.sleep(for: .milliseconds(80))
        }
        while model.isRefreshing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isRefreshing)
        let content = try XCTUnwrap(model.state.value)
        XCTAssertEqual(content.serverRows.count, 40)
        XCTAssertTrue(content.serverRows.allSatisfy { !$0.isLoading && $0.failure == nil })
        let items = content.serverRows.reduce(0) { $0 + $1.items.count }
        XCTAssertEqual(items, 800)
        // Empty global rows can disappear during loading; preservation follows
        // their visible successor rather than retaining an absolute offset.
        XCTAssertGreaterThan(scroll.contentOffset.y, 0)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        scroll.setContentOffset(CGPoint(x: 0, y: 1440), animated: true)
        let scrollDeadline = ContinuousClock.now + .seconds(3)
        while abs(scroll.contentOffset.y - 1440) > 1, ContinuousClock.now < scrollDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        window.layoutIfNeeded()
        XCTAssertEqual(scroll.contentOffset.y, 1440, accuracy: 1)
        XCTAssertGreaterThan(scroll.contentSize.height, 8_000)
        let gap = maximumGap.components
        return [
            "servers": 20, "loadedRows": content.serverRows.count, "items": items,
            "providerRequests": requests.value.withLock { $0 }, "scrollTargets": 9,
            "maxMainActorGapMicroseconds": Int(gap.seconds) * 1_000_000 + Int(gap.attoseconds / 1_000_000_000_000)
        ]
    }
}

private final class MultiServerHomeRequests: Sendable {
    let value = Mutex(0)
}

private struct MultiServerHomeProvider: MediaProvider {
    let session: UserSession
    let requests: MultiServerHomeRequests
    var kind: ProviderKind { .jellyfin }

    func libraries() async throws -> [MediaLibrary] {
        requests.value.withLock { $0 += 1 }
        return [.init(id: "movies", title: "Movies", kind: .movie)]
    }
    func serverHomeLayout() async throws -> ServerHomeLayout? {
        .init(sections: [
            .init(id: "first", kind: .recentlyAdded, libraryID: "movies"),
            .init(id: "second", kind: .recommendations, libraryID: "movies")
        ], source: .server)
    }
    func serverHomeItems(
        section: ServerHomeSection, limit: Int, excludingLibraryIDs: Set<String>
    ) async throws -> [MediaItem] {
        try await delay()
        return media(section.id, limit: min(limit, 20))
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await delay()
        return []
    }
    func latest(limit: Int) async throws -> [MediaItem] {
        try await delay()
        return media("latest", limit: min(limit, 20))
    }
    private func delay() async throws {
        requests.value.withLock { $0 += 1 }
        let index = Int(session.server.id.split(separator: "-").last ?? "") ?? 0
        try await Task.sleep(for: .milliseconds(50 + index * 10))
    }
    private func media(_ section: String, limit: Int) -> [MediaItem] {
        (0..<limit).map { index in
            var item = MediaItem(
                id: "\(session.server.id)-\(section)-\(index)", title: "Movie \(index)", kind: .movie,
                overview: String(repeating: "A synthetic library title. ", count: 12),
                people: (0..<5).map { MediaPerson(id: "person-\($0)", name: "Person \($0)") },
                allowsTitleBasedMetadataMatching: false
            )
            item.libraryID = "movies"
            return item
        }
    }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
