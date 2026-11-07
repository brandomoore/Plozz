#if os(iOS)
import CoreModels
import CoreNetworking
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

    func testPerformanceScrollingAcrossTwentyServers() async throws {
        try PerformanceProbe.requireEnabled()
        try await PerformanceProbe.measure(self, scenario: "mobile-home-multi-server-scroll") {
            try await self.exercise(scrollsLoadedContent: true)
        }
    }

    func testPerformanceScrollingWhileTwentyServersLoad() async throws {
        try PerformanceProbe.requireEnabled()
        try await PerformanceProbe.measure(self, scenario: "mobile-home-multi-server-startup-scroll") {
            try await self.exercise(scrollsWhileLoading: true)
        }
    }

    func testHomeFinishesEveryServerRowDuringStartupScrolling() async throws {
        _ = try await exercise(scrollsWhileLoading: true)
    }

    func testConfiguredRowsAreReservedBeforeAnyServerResponds() async throws {
        let gate = HomeStartupResponseGate()
        defer { gate.opened.withLock { $0 = true } }
        let requests = MultiServerHomeRequests()
        let accounts = (0..<20).map { index -> ResolvedAccount in
            let id = "server-\(index)"
            let account = Account(
                id: id, server: .init(id: id, name: "Server", baseURL: URL(string: "https://example.invalid")!,
                                     provider: .jellyfin),
                userID: "viewer", userName: "Viewer", deviceID: "fixture"
            )
            let provider = MultiServerHomeProvider(
                session: UserSession(server: account.server, userID: account.userID,
                                     userName: account.userName, deviceID: account.deviceID, accessToken: "fixture"),
                requests: requests, artwork: nil, slowLoading: false, gate: gate
            )
            return ResolvedAccount(account: account, provider: provider)
        }
        let definitions = accounts.flatMap { account in
            ["first", "second"].map {
                HomeServerRowDefinition(
                    accountID: account.account.id, serverName: "Server", providerKind: .jellyfin,
                    section: .init(id: $0, kind: .recommendations, libraryID: "movies")
                )
            }
        }
        let unavailable = HomeServerRowDefinition(
            accountID: "absent", serverName: "Absent", providerKind: .plex,
            section: .init(id: "first", kind: .recommendations)
        )
        let collection = CollectionSection(source: .init(
            accountID: "server-0", collectionID: "collection", title: "Collection", serverUserID: "viewer"
        ))
        let otherViewer = CollectionSection(source: .init(
            accountID: "server-0", collectionID: "private", title: "Private", serverUserID: "other"
        ))
        let visibility = HomeLibraryVisibility(
            rowCustomization: .init(
                defaults: .custom, order: definitions.map(\.id),
                shown: Set(definitions.map(\.id) + [unavailable.id, collection.rowID, otherViewer.rowID]),
                serverRows: definitions + [unavailable]
            ),
            collectionSections: [collection, otherViewer]
        )
        let model = HomeViewModel(
            accounts: accounts, layoutStore: InMemoryHomeLayoutStore(), contentStore: NoOpHomeContentStore(),
            currentVisibility: { visibility }
        )
        defer { model.invalidate() }
        let loading = Task { await model.load() }
        defer { loading.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while model.state.value?.serverRows.count != 40, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let initial = try XCTUnwrap(model.state.value)
        XCTAssertEqual(initial.serverRows.map(\.definition.id), definitions.map(\.id))
        XCTAssertTrue(initial.serverRows.allSatisfy { $0.isLoading && $0.items.isEmpty && $0.failure == nil })
        XCTAssertEqual(initial.collectionRows.map(\.definition.id), [collection.id])
        XCTAssertTrue(initial.collectionRows.allSatisfy(\.isLoading))
        XCTAssertTrue(model.isRefreshing)
        gate.opened.withLock { $0 = true }
        await loading.value
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.state.value?.serverRows.reduce(0) { $0 + $1.items.count }, 800)
    }

    private func exercise(
        scrollsLoadedContent: Bool = false, scrollsWhileLoading: Bool = false
    ) async throws -> [String: Int] {
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
        let artwork = scrollsLoadedContent || scrollsWhileLoading ? try await cachedArtwork() : nil
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
            MultiServerHomeProvider(
                session: context.session, requests: requests, artwork: artwork,
                slowLoading: scrollsWhileLoading
            )
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
        var lastHeartbeat = ContinuousClock.now
        var scrollingStarted: ContinuousClock.Instant?
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
                let now = ContinuousClock.now
                let gap = lastHeartbeat.duration(to: now)
                maximumGap = max(maximumGap, gap)
                if scrollsWhileLoading, let scrollingStarted, gap > .milliseconds(50) {
                    print("HomeStartupScrollGap elapsed=\(scrollingStarted.duration(to: now)) gap=\(gap)")
                }
                lastHeartbeat = now
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
        let deadline = ContinuousClock.now + .seconds(40)
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
        var loadingScrollTargets = 0
        var finishedRowsWhileScrolling = 0
        var scrollingGap = Duration.zero
        var scrollingWall = Duration.zero
        var scrollingCPU = 0
        if scrollsWhileLoading {
            let before = try PerformanceProbe.usage()
            maximumGap = .zero
            lastHeartbeat = .now
            let started = ContinuousClock.now
            scrollingStarted = started
            print("HomeStartupScrollTrace start rows=40")
            for step in (1...12).map({ $0 }) + (0..<12).reversed() {
                if model.isRefreshing { loadingScrollTargets += 1 }
                let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                scroll.setContentOffset(CGPoint(x: 0, y: bottom * CGFloat(step) / 12), animated: true)
                try await Task.sleep(for: .milliseconds(400))
                finishedRowsWhileScrolling = max(
                    finishedRowsWhileScrolling,
                    model.state.value?.serverRows.filter { !$0.isLoading }.count ?? 0
                )
            }
            scrollingGap = maximumGap
            scrollingWall = started.duration(to: .now)
            scrollingCPU = Int(((try PerformanceProbe.usage()).cpuMilliseconds - before.cpuMilliseconds) * 1_000)
            scrollingStarted = nil
            XCTAssertGreaterThanOrEqual(loadingScrollTargets, 8)
            XCTAssertGreaterThan(finishedRowsWhileScrolling, 0)
        } else {
            for index in 1...8 {
                scroll.setContentOffset(CGPoint(x: 0, y: CGFloat(index * 180)), animated: true)
                try await Task.sleep(for: .milliseconds(80))
            }
        }
        while model.isRefreshing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isRefreshing)
        let content = try XCTUnwrap(model.state.value)
        XCTAssertEqual(content.serverRows.count, 40)
        XCTAssertTrue(content.serverRows.allSatisfy { !$0.isLoading && $0.failure == nil })
        XCTAssertEqual(requests.value.withLock { $0 }, 100)
        let items = content.serverRows.reduce(0) { $0 + $1.items.count }
        XCTAssertEqual(items, 800)
        // Confirmed-empty global rows may disappear; Home does not command a
        // replacement offset when that changes the document.
        if !scrollsWhileLoading { XCTAssertGreaterThan(scroll.contentOffset.y, 0) }
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
        if scrollsLoadedContent {
            maximumGap = .zero
            lastHeartbeat = .now
            let before = try PerformanceProbe.usage()
            let started = ContinuousClock.now
            let height = scroll.contentSize.height
            let bottom = height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            print("HomeScrollTrace start rows=40 items=800")
            for step in (1...12).map({ $0 }) + (0..<12).reversed() {
                let target = bottom * CGFloat(step) / 12
                scroll.setContentOffset(CGPoint(x: 0, y: target), animated: true)
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertEqual(scroll.contentOffset.y, target, accuracy: 1)
            }
            XCTAssertEqual(scroll.contentSize.height, height, accuracy: 1)
            XCTAssertEqual(model.state.value?.serverRows.reduce(0) { $0 + $1.items.count }, 800)
            let usage = try PerformanceProbe.usage()
            let elapsed = started.duration(to: .now).components
            let gap = maximumGap.components
            return [
                "servers": 20, "loadedRows": 40, "items": 800, "scrollTargets": 24,
                "providerRequests": requests.value.withLock { $0 },
                "scrollCPUTimeMicroseconds": Int((usage.cpuMilliseconds - before.cpuMilliseconds) * 1_000),
                "scrollWallMicroseconds": Int(elapsed.seconds) * 1_000_000 + Int(elapsed.attoseconds / 1_000_000_000_000),
                "maxMainActorGapMicroseconds": Int(gap.seconds) * 1_000_000 + Int(gap.attoseconds / 1_000_000_000_000)
            ]
        }
        let gap = (scrollsWhileLoading ? scrollingGap : maximumGap).components
        let elapsed = scrollingWall.components
        var counters = [
            "servers": 20, "loadedRows": content.serverRows.count, "items": items,
            "providerRequests": requests.value.withLock { $0 }, "scrollTargets": scrollsWhileLoading ? 25 : 9,
            "maxMainActorGapMicroseconds": Int(gap.seconds) * 1_000_000 + Int(gap.attoseconds / 1_000_000_000_000)
        ]
        if scrollsWhileLoading {
            counters["loadingScrollTargets"] = loadingScrollTargets
            counters["finishedRowsWhileScrolling"] = finishedRowsWhileScrolling
            counters["scrollCPUTimeMicroseconds"] = scrollingCPU
            counters["scrollWallMicroseconds"] =
                Int(elapsed.seconds) * 1_000_000 + Int(elapsed.attoseconds / 1_000_000_000_000)
        }
        return counters
    }

    private func cachedArtwork() async throws -> URL {
        let url = try XCTUnwrap(URL(string: "https://example.invalid/home-scroll-fixture.png"))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 300)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        }
        let data = try XCTUnwrap(image.pngData())
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        for variant in ArtworkImageVariant.allCases {
            let requestURL = variant.requestURL(for: url)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
            ))
            cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: URLRequest(url: requestURL))
            let decoded = await ArtworkImageCache.shared.image(for: url, variant: variant)
            _ = try XCTUnwrap(decoded)
        }
        return url
    }
}

private final class MultiServerHomeRequests: Sendable {
    let value = Mutex(0)
}

private final class HomeStartupResponseGate: Sendable {
    let opened = Mutex(false)

    func wait() async throws {
        while !opened.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct MultiServerHomeProvider: MediaProvider {
    let session: UserSession
    let requests: MultiServerHomeRequests
    let artwork: URL?
    let slowLoading: Bool
    var gate: HomeStartupResponseGate? = nil
    var kind: ProviderKind { .jellyfin }

    func libraries() async throws -> [MediaLibrary] {
        try await gate?.wait()
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
        try await gate?.wait()
        requests.value.withLock { $0 += 1 }
        let index = Int(session.server.id.split(separator: "-").last ?? "") ?? 0
        try await Task.sleep(for: .milliseconds(slowLoading ? 150 + index * 100 : 50 + index * 10))
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
            item.posterURL = artwork
            item.backdropURL = artwork
            return item
        }
    }
    func item(id: String) async throws -> MediaItem {
        try await gate?.wait()
        throw AppError.notFound
    }
    func children(of itemID: String) async throws -> [MediaItem] {
        try await gate?.wait()
        return []
    }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        try await gate?.wait()
        return .init(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
