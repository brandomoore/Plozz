#if os(iOS)
import AppRuntime
import CoreModels
import CoreNetworking
import FeatureAuth
import FeatureHomeCore
import Foundation
import ProviderJellyfin
import Synchronization
import XCTest

@MainActor
final class LiveJellyfinWatchActionTests: XCTestCase {
    func testEpisodeMenuActionsRecoverAfterDurableReplayAndLaterPlayback() async throws {
        let fixture = try await Fixture()
        for action in [MediaItemAction.markWatched, .markUnwatched, .removeFromContinueWatching] {
            try await fixture.prepare()
            let original = try await fixture.provider.item(id: fixture.config.firstEpisodeID)
                .taggingSource(fixture.accountID)
            let store = try fixture.makeStore()
            let clock = Mutex(Date())
            let reconciler = WatchStateReconciler(
                store: store, applier: fixture.applier, now: { clock.withLock { $0 } }
            )
            let mutation = try fixture.intent(action, item: original)
            await fixture.http.setOffline(true)
            await reconciler.enqueue(mutation)
            await reconciler.drain()
            let blocked = await fixture.http.blockedCount()
            XCTAssertEqual(blocked, 1)
            let persisted = try fixture.makeStore().load()
            XCTAssertEqual(persisted.pending.count, 1)
            XCTAssertTrue(HomeViewModel.reconcileContinueWatching([original], pending: persisted.pending).isEmpty)
            let other = MediaItem(id: "unrelated", title: "Other", kind: .episode,
                                  resumePosition: 300, sourceAccountID: "other-account")
            XCTAssertEqual(HomeViewModel.reconcileContinueWatching([other], pending: persisted.pending).count, 1)

            let restored = WatchStateReconciler(
                store: try fixture.makeStore(), applier: fixture.applier, now: { clock.withLock { $0 } }
            )
            await fixture.http.setOffline(false)
            clock.withLock { $0 = Date().addingTimeInterval(60) }
            await restored.drain()
            let final = await restored.snapshot()
            XCTAssertTrue(final.pending.isEmpty, "A successful retry must release the persisted suppression.")
            let after = try await fixture.provider.item(id: original.id)
            XCTAssertEqual(after.isPlayed, action == .markWatched)
            XCTAssertLessThanOrEqual(after.resumePosition ?? 0, 0)
            let feed = try await fixture.provider.continueWatching(limit: .max)
            if action == .markWatched {
                XCTAssertTrue(feed.contains { $0.id == fixture.config.secondEpisodeID })
            }
            // A fresh user play is independent of the old menu action.
            try await fixture.provider.setPlayed(false, itemID: original.id)
            try await fixture.provider.setResumePosition(900, itemID: original.id, capturedAt: Date())
            let resumed = try await fixture.provider.continueWatching(limit: .max)
            XCTAssertTrue(resumed.contains { $0.id == original.id && ($0.resumePosition ?? 0) >= 899 })
            let home = try await fixture.home(pending: final.pending)
            XCTAssertTrue(home.contains { $0.id == original.id })
            print("LIVE_WATCH_ACTION action=\(action.rawValue) failedWriteRetained=true restored=true laterPlaybackVisible=true")
            try fixture.resetStore()
            await fixture.http.resetCounters()
        }
    }

    func testNewerServerPlaybackWhileAnActionIsStillQueued() async throws {
        let fixture = try await Fixture()
        for action in [MediaItemAction.markWatched, .markUnwatched, .removeFromContinueWatching] {
            try await fixture.prepare()
            let original = try await fixture.provider.item(id: fixture.config.firstEpisodeID)
                .taggingSource(fixture.accountID)
            let clock = Mutex(Date())
            let queued = WatchStateReconciler(
                store: try fixture.makeStore(), applier: fixture.applier, now: { clock.withLock { $0 } }
            )
            let intent = try fixture.intent(action, item: original)
            await fixture.http.setOffline(true)
            await queued.enqueue(intent)
            await queued.drain()
            await fixture.http.setOffline(false)
            try await Task.sleep(for: .seconds(1.1))
            try await fixture.provider.setResumePosition(900, itemID: original.id, capturedAt: Date())
            let pending = await queued.snapshot().pending
            let homeBeforeDrain = try await fixture.home(pending: pending)
            XCTAssertTrue(homeBeforeDrain.contains { $0.id == original.id },
                          "Newer server playback must override the older local reset overlay.")
            let restored = WatchStateReconciler(
                store: try fixture.makeStore(), applier: fixture.applier, now: { clock.withLock { $0 } }
            )
            clock.withLock { $0 = Date().addingTimeInterval(60) }
            await restored.drain()
            let after = try await fixture.provider.item(id: original.id)
            XCTAssertGreaterThanOrEqual(after.resumePosition ?? 0, 899,
                                       "Replaying an old \(action.rawValue) must not erase a newer server play.")
            XCTAssertFalse(after.isPlayed)
            let final = await restored.snapshot()
            XCTAssertTrue(final.pending.isEmpty)
            let homeAfterDrain = try await fixture.home(pending: final.pending)
            XCTAssertTrue(homeAfterDrain.contains { $0.id == original.id })
            print("LIVE_WATCH_ACTION action=\(action.rawValue) newerServerPlaybackPreserved=\((after.resumePosition ?? 0) >= 899)")
            try fixture.resetStore()
        }
    }

    func testNewLocalPlaybackSupersedesAQueuedRemoval() async throws {
        let fixture = try await Fixture()
        try await fixture.prepare()
        let original = try await fixture.provider.item(id: fixture.config.firstEpisodeID)
            .taggingSource(fixture.accountID)
        let clock = Mutex(Date())
        let queue = WatchStateReconciler(
            store: try fixture.makeStore(), applier: fixture.applier, now: { clock.withLock { $0 } }
        )
        await fixture.http.setOffline(true)
        await queue.enqueue(try fixture.intent(.removeFromContinueWatching, item: original))
        await queue.drain()
        try await Task.sleep(for: .seconds(1.1))
        let playback = try XCTUnwrap(WatchMutationFactory.playbackStop(
            item: original, position: 900, watchedPercent: 20,
            primaryAccountID: fixture.accountID, crossServerSync: false
        ))
        await queue.enqueue(playback)
        await fixture.http.setOffline(false)
        let restored = WatchStateReconciler(
            store: try fixture.makeStore(), applier: fixture.applier, now: { clock.withLock { $0 } }
        )
        clock.withLock { $0 = Date().addingTimeInterval(60) }
        await restored.drain()
        let final = await restored.snapshot()
        XCTAssertTrue(final.pending.isEmpty)
        let item = try await fixture.provider.item(id: original.id)
        XCTAssertGreaterThanOrEqual(item.resumePosition ?? 0, 899)
        let home = try await fixture.home(pending: final.pending)
        XCTAssertTrue(home.contains { $0.id == original.id })
    }

    func testSeasonAndSeriesActionsCascadeButLaterPlaybackStillReturns() async throws {
        let fixture = try await Fixture()
        let seasons = try await fixture.provider.children(of: fixture.config.seriesID)
        let season = try XCTUnwrap(seasons.first { $0.kind == .season && $0.seasonNumber == 1 })
        let series = try await fixture.provider.item(id: fixture.config.seriesID)
        var allEpisodes: [MediaItem] = []
        for container in seasons where container.kind == .season {
            allEpisodes += try await fixture.provider.children(of: container.id)
            guard allEpisodes.count <= 300 else { throw XCTSkip("Live cascade fixture exceeds the bounded history scope.") }
        }
        XCTAssertFalse(allEpisodes.isEmpty)
        for container in [season, series] {
            try await fixture.prepare()
            let expected = container.kind == .series ? allEpisodes : try await fixture.provider.children(of: container.id)
            for action in [MediaItemAction.markWatched, .markUnwatched] {
                if action == .markUnwatched {
                    try await fixture.provider.setPlayed(true, itemID: fixture.config.firstEpisodeID)
                }
                let queue = WatchStateReconciler(store: try fixture.makeStore(), applier: fixture.applier)
                await queue.enqueue(try fixture.intent(action, item: container.taggingSource(fixture.accountID)))
                await queue.drain()
                let pending = await queue.pendingCount
                XCTAssertEqual(pending, 0)
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while ContinuousClock.now < deadline {
                    let sentinel = try await fixture.provider.item(id: fixture.config.firstEpisodeID)
                    if sentinel.isPlayed == (action == .markWatched), (sentinel.resumePosition ?? 0) <= 0 { break }
                    try await Task.sleep(for: .milliseconds(500))
                }
                for episode in expected {
                    let state = try await fixture.provider.item(id: episode.id)
                    XCTAssertEqual(state.isPlayed, action == .markWatched)
                    XCTAssertLessThanOrEqual(state.resumePosition ?? 0, 0)
                }
                try fixture.resetStore()
            }
            try await fixture.provider.setPlayed(false, itemID: fixture.config.firstEpisodeID)
            try await fixture.provider.setResumePosition(900, itemID: fixture.config.firstEpisodeID, capturedAt: Date())
            let home = try await fixture.home(pending: [])
            XCTAssertTrue(home.contains { $0.id == fixture.config.firstEpisodeID })
            print("LIVE_WATCH_ACTION container=\(container.kind.rawValue) episodes=\(expected.count) checkedCascadeAndRecovery")
        }
    }

    private struct Configuration: Decodable {
        let baseURL: URL
        let serverID: String
        let userID: String
        let username: String
        let deviceID: String
        let token: String
        let firstEpisodeID: String
        let secondEpisodeID: String
        let seriesID: String
    }

    @MainActor private final class Fixture {
        let broker: URL
        let config: Configuration
        let accountID = "live-jellyfin"
        let profileID = UUID().uuidString
        let backend = InMemorySecureStore()
        let http = WriteGateHTTP()
        let provider: JellyfinProvider
        let applier: AppShellWatchMutationApplier

        init() async throws {
            guard let address = ProcessInfo.processInfo.environment["PLOZZ_LIVE_REFRESH_BROKER"] else {
                throw XCTSkip("Requires the authorized internal history-mutation broker.")
            }
            guard let broker = URL(string: address), broker.scheme == "http", broker.host == "127.0.0.1",
                  broker.port != nil, broker.user == nil, broker.password == nil,
                  broker.query == nil, broker.fragment == nil else { throw AppError.invalidResponse }
            self.broker = broker
            let (data, response) = try await URLSession.shared.data(for: URLRequest(
                url: broker.appendingPathComponent("jellyfin/configuration/series"), timeoutInterval: 30
            ))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.invalidResponse }
            config = try JSONDecoder().decode(Configuration.self, from: data)
            let session = UserSession(
                server: .init(id: config.serverID, name: "Internal actions", baseURL: config.baseURL, provider: .jellyfin),
                userID: config.userID, userName: config.username, deviceID: config.deviceID, accessToken: config.token
            )
            let provider = JellyfinProvider(session: session, http: http)
            self.provider = provider
            applier = AppShellWatchMutationApplier(
                resolveProvider: { id in id == "live-jellyfin" ? provider : nil },
                applyTrakt: { _ in }, applySimkl: { _ in }, applyAniList: { _ in }, applyMAL: { _ in }
            )
        }

        func prepare() async throws {
            var request = URLRequest(url: broker.appendingPathComponent("jellyfin/prepare/series"), timeoutInterval: 90)
            request.httpMethod = "POST"
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError.invalidResponse }
        }

        func makeStore() throws -> DurableWatchMutationStore {
            try DurableWatchMutationStore(store: DurableLocalStateStore(secureStore: backend), profileID: profileID)
        }

        func resetStore() throws {
            let store = try makeStore()
            _ = store.load()
            try store.save(.empty)
        }

        func intent(_ action: MediaItemAction, item: MediaItem) throws -> WatchMutation {
            var pending: [WatchMutation] = []
            let coordinator = MediaItemActionCoordinator(
                providerResolver: { [provider] _ in provider }, primaryAccountID: { "live-jellyfin" },
                crossServerWatchSyncEnabled: { false }, enqueueWatchMutation: { pending.append($0) }
            )
            coordinator.perform(action, on: item, context: .none)
            XCTAssertEqual(pending.count, 1)
            return try XCTUnwrap(pending.first)
        }

        func home(pending: [WatchMutation]) async throws -> [MediaItem] {
            let model = HomeViewModel(
                accounts: [.init(account: Account(id: accountID, from: provider.session), provider: provider)],
                profileNamespace: profileID, layoutStore: InMemoryHomeLayoutStore(),
                contentStore: NoOpHomeContentStore(), pendingWatchMutations: { pending }
            )
            defer { model.invalidate() }
            await model.load()
            return try XCTUnwrap(model.state.value).continueWatching
        }
    }

    private actor WriteGateHTTP: HTTPClient {
        private let wrapped = URLSessionHTTPClient()
        private var offline = false
        private var blocked = 0
        func setOffline(_ value: Bool) { offline = value }
        func blockedCount() -> Int { blocked }
        func resetCounters() { blocked = 0 }

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            if offline && endpoint.method != .get {
                blocked += 1
                throw AppError.serverUnreachable
            }
            return try await wrapped.send(endpoint, baseURL: baseURL)
        }
    }
}
#endif
