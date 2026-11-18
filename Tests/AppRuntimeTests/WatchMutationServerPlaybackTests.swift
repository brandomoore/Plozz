import CoreModels
import CoreNetworking
import Foundation
import ProviderJellyfin
import ProviderPlex
import Synchronization
import XCTest
@testable import AppRuntime
@testable import TestSupportNetworking

final class WatchMutationServerPlaybackTests: XCTestCase {
    private let captured = Date(timeIntervalSince1970: 10_000)
    private let target = WatchMutationTarget(accountID: "account", itemID: "item")

    func testRestoredContainerIntentPreservesKindThroughRuntimeDelivery() async throws {
        for kind in [MediaItemKind.season, .series] {
            let provider = PlaybackProbeProvider(lastPlayedAt: .distantPast)
            var intent = mutation(true)
            intent.kind = kind
            let encoded = try JSONEncoder().encode(intent)
            let queue = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier(provider))
            await queue.enqueue(try JSONDecoder().decode(WatchMutation.self, from: encoded))
            await queue.drain()
            let kinds = await provider.receivedKinds
            XCTAssertEqual(kinds, [kind])
        }
    }

    private func mutation(_ played: Bool?, observed: Date? = nil) -> WatchMutation {
        WatchMutation(
            capturedAt: captured, canonicalMediaID: "fixture", played: played, clearResume: true,
            targets: [target], kind: .episode,
            observedLastPlayedAt: observed.map { [target.id: $0] } ?? [:],
            isExplicitReset: true
        )
    }

    private func applier(_ provider: any MediaProvider, active: PlaybackActivity? = nil) -> AppShellWatchMutationApplier {
        AppShellWatchMutationApplier(
            isActive: { active?.value.withLock { $0 } ?? true },
            resolveProvider: { _ in provider },
            applyTrakt: { _ in }, applySimkl: { _ in }, applyAniList: { _ in }, applyMAL: { _ in }
        )
    }

    func testProductionPlexRestoredResetsAndRetriedCompletionPreserveNewerPlayback() async throws {
        for kind in [MediaItemKind.movie, .episode] {
            for action in 0..<4 {
                let http = PlexWatchStateHTTP(kind: kind, lastViewedAt: captured.addingTimeInterval(1))
                let provider = plex(http)
                var intent = mutation(action == 0 ? nil : action >= 2)
                intent.kind = kind
                if action == 3 {
                    intent.isExplicitReset = false
                    intent.attempts = 1
                }
                let store = InMemoryWatchMutationStore()
                let first = WatchStateReconciler(store: store, applier: applier(provider))
                await first.enqueue(intent)
                let restoredState = try JSONDecoder().decode(
                    WatchOutboxState.self, from: JSONEncoder().encode(store.load())
                )
                let restored = WatchStateReconciler(
                    store: InMemoryWatchMutationStore(restoredState), applier: applier(provider)
                )
                await restored.drain()
                let reads = await http.metadataReads
                let writes = await http.writes
                let pending = await restored.pendingCount
                XCTAssertGreaterThan(reads, 0)
                XCTAssertTrue(writes.isEmpty, "A stale Plex action must not scrobble, clear progress, or dismiss: \(writes)")
                XCTAssertEqual(pending, 0)
            }
        }
    }

    func testProductionPlexCurrentResetStillWrites() async throws {
        for played in [nil, false, true] as [Bool?] {
            let http = PlexWatchStateHTTP(kind: .episode, lastViewedAt: captured.addingTimeInterval(-1))
            let queue = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier(plex(http)))
            await queue.enqueue(mutation(played))
            await queue.drain()
            let writes = await http.writes
            let pending = await queue.pendingCount
            XCTAssertFalse(writes.isEmpty, "Fresh actions must not be discarded with stale ones.")
            XCTAssertEqual(pending, 0)
        }
    }

    func testJellyfinResetDoesNotJoinAnOlderPendingDetailRead() async throws {
        try await assertResetPreservesNewerPlayback(kind: .jellyfin)
    }

    func testEmbyResetDoesNotJoinAnOlderPendingDetailRead() async throws {
        try await assertResetPreservesNewerPlayback(kind: .emby)
    }

    func testPlexResetDoesNotJoinAnOlderPendingDetailRead() async throws {
        try await assertResetPreservesNewerPlayback(kind: .plex)
    }

    private func assertResetPreservesNewerPlayback(kind: ProviderKind) async throws {
        let wire = PendingWatchMetadata(kind: kind, lastPlayedAt: captured.addingTimeInterval(-1))
        let server = try LoopbackHTTPServer { await wire.response($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let transport = URLSession(configuration: configuration)
        addTeardownBlock {
            await wire.release()
            await server.stop()
            transport.invalidateAndCancel()
        }
        let session = UserSession(
            server: .init(id: UUID().uuidString, name: "Fixture", baseURL: try await server.start(), provider: kind),
            userID: "viewer", userName: "Fixture", deviceID: "device", accessToken: "fixture"
        )
        let http = URLSessionHTTPClient(session: transport)
        let provider: any MediaProvider = kind == .plex
            ? PlexProvider(session: session, accountID: "account", http: http, interactiveHTTP: http)
            : JellyfinProvider(session: session, accountID: "account", http: http, interactiveHTTP: http)
        let oldDetail = Task { try await provider.item(id: "item") }
        defer { oldDetail.cancel() }
        try await waitForMetadata { await wire.reads == 1 }
        await wire.recordPlayback(at: captured.addingTimeInterval(1))

        let queue = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier(provider))
        await queue.enqueue(mutation(false))
        let drain = Task { await queue.drain() }
        defer { drain.cancel() }
        // The stale reset must be rejected before the older response is released.
        try await waitForMetadata { await wire.reads == 2 }
        await drain.value
        let writes = await wire.writes
        let pending = await queue.pendingCount
        XCTAssertTrue(writes.isEmpty, "A stale reset must not erase newer server playback: \(writes)")
        XCTAssertEqual(pending, 0)
        await wire.release()
        let old = try await oldDetail.value
        XCTAssertEqual(old.lastPlayedAt, captured.addingTimeInterval(-1))
    }

    private func waitForMetadata(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("The freshness check must start its own metadata transfer")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func plex(_ http: PlexWatchStateHTTP) -> PlexProvider {
        PlexProvider(
            session: UserSession(
                server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://plex.invalid")!, provider: .plex),
                userID: "viewer", userName: "Fixture", deviceID: "device", accessToken: "fixture"
            ),
            localMediaContext: .init(accountID: "account", profileID: "profile", profileNamespace: nil, serverUserID: "viewer"),
            http: http
        )
    }

    func testFullyLocalProviderDoesNotNeedServerFreshnessRead() async throws {
        let provider = PlaybackProbeProvider(lastPlayedAt: captured, usesLocalWatchStateOnly: true)
        await provider.setReadFailure(true)
        let superseded = try await applier(provider).serverPlaybackSupersedes(mutation(false), on: target)
        let reads = await provider.reads
        XCTAssertFalse(superseded)
        XCTAssertEqual(reads, 0)
    }

    func testAllResetActionsPreserveNewerServerPlaybackAcrossProviders() async throws {
        for kind in [ProviderKind.jellyfin, .plex, .emby] {
            for played in [nil, false, true] as [Bool?] {
                let provider = PlaybackProbeProvider(kind: kind, lastPlayedAt: captured.addingTimeInterval(1))
                let confirmed = Mutex(0)
                let reconciler = WatchStateReconciler(
                    store: InMemoryWatchMutationStore(), applier: applier(provider),
                    onServerStateApplied: { _ in confirmed.withLock { $0 += 1 } }
                )
                await reconciler.enqueue(mutation(played))
                await reconciler.drain()
                let state = await reconciler.snapshot()
                let writes = await provider.writes
                XCTAssertTrue(state.pending.isEmpty)
                XCTAssertTrue(writes.isEmpty)
                XCTAssertEqual(confirmed.withLock { $0 }, 0, "Skipping is not confirmation of the old reset.")
            }
        }
    }

    func testObservedFutureServerClockDoesNotInvalidateAnExplicitReset() async throws {
        let observed = captured.addingTimeInterval(60)
        for played in [nil, false, true] as [Bool?] {
            let provider = PlaybackProbeProvider(lastPlayedAt: observed)
            let intent = try JSONDecoder().decode(WatchMutation.self, from: JSONEncoder().encode(mutation(played, observed: observed)))
            let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier(provider))
            await reconciler.enqueue(intent)
            await reconciler.drain()
            let writes = await provider.writes
            XCTAssertEqual(writes, played.map { ["played:\($0)", "resume:0"] } ?? ["resume:0"])
            let pending = await reconciler.pendingCount
            XCTAssertEqual(pending, 0)
        }
    }

    func testFailedFreshnessReadRemainsQueuedAndRetriesAfterRestoration() async throws {
        let provider = PlaybackProbeProvider(lastPlayedAt: captured.addingTimeInterval(-1))
        await provider.setReadFailure(true)
        let clock = Mutex(captured)
        let store = InMemoryWatchMutationStore()
        let first = WatchStateReconciler(store: store, applier: applier(provider), now: { clock.withLock { $0 } })
        await first.enqueue(mutation(nil))
        await first.drain()
        let writesBeforeRetry = await provider.writes
        let pendingBeforeRetry = await first.pendingCount
        XCTAssertTrue(writesBeforeRetry.isEmpty)
        XCTAssertEqual(pendingBeforeRetry, 1)
        let encoded = try JSONEncoder().encode(store.load())
        let restored = WatchStateReconciler(
            store: InMemoryWatchMutationStore(try JSONDecoder().decode(WatchOutboxState.self, from: encoded)),
            applier: applier(provider), now: { clock.withLock { $0 } }
        )
        await provider.setReadFailure(false)
        clock.withLock { $0.addTimeInterval(60) }
        await restored.drain()
        let writes = await provider.writes
        let pending = await restored.pendingCount
        XCTAssertEqual(writes, ["resume:0"])
        XCTAssertEqual(pending, 0)
    }

    func testSupersededSourceStopsSuppressingHomeWhileAnotherAccountIsOffline() async throws {
        let newer = PlaybackProbeProvider(lastPlayedAt: captured.addingTimeInterval(1))
        let offline = PlaybackProbeProvider(lastPlayedAt: captured)
        await offline.setReadFailure(true)
        let applier = AppShellWatchMutationApplier(
            resolveProvider: { $0 == "account" ? newer : offline },
            applyTrakt: { _ in }, applySimkl: { _ in }, applyAniList: { _ in }, applyMAL: { _ in }
        )
        let store = InMemoryWatchMutationStore()
        let reconciler = WatchStateReconciler(store: store, applier: applier)
        var intent = mutation(nil)
        intent.targets.append(.init(accountID: "other", itemID: "item"))
        intent.optimisticTargets = intent.targets
        await reconciler.enqueue(intent)
        await reconciler.drain()
        let state = try JSONDecoder().decode(WatchOutboxState.self, from: JSONEncoder().encode(store.load()))
        let pending = try XCTUnwrap(state.pending.first)
        XCTAssertEqual(pending.targets.map(\.accountID), ["other"])
        XCTAssertEqual(pending.optimisticTargets.map(\.accountID), ["account", "other"],
                       "Origin history must survive for tracker identity recovery.")
        XCTAssertEqual(pending.effectiveOptimisticTargets.map(\.accountID), ["other"])
        XCTAssertTrue(pending.appliedTargetIDs.contains(target.id), "Expansion must not reintroduce the superseded source.")
        var newAction = mutation(nil)
        newAction.capturedAt = captured.addingTimeInterval(2)
        await reconciler.enqueue(newAction)
        await reconciler.drain()
        let writes = await newer.writes
        XCTAssertEqual(writes, ["resume:0"], "A new explicit action must not inherit the older intent's supersession.")
    }

    func testFreshnessReadRechecksProfileBeforeAuthorizingAnyWrite() async throws {
        let active = PlaybackActivity()
        let provider = PlaybackProbeProvider(lastPlayedAt: captured)
        await provider.setAfterRead { active.value.withLock { $0 = false } }
        let reconciler = WatchStateReconciler(store: InMemoryWatchMutationStore(), applier: applier(provider, active: active))
        await reconciler.enqueue(mutation(false))
        await reconciler.drain()
        let writes = await provider.writes
        let pending = await reconciler.pendingCount
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(pending, 1)
    }

    private final class PlaybackActivity: Sendable {
        let value = Mutex(true)
    }

    func testOrdinaryProgressAndContainerActionsDoNotAddMetadataReads() async throws {
        let provider = PlaybackProbeProvider(lastPlayedAt: captured.addingTimeInterval(1))
        let applier = applier(provider)
        for kind in [MediaItemKind.season, .series] {
            var container = mutation(true)
            container.kind = kind
            let superseded = try await applier.serverPlaybackSupersedes(container, on: target)
            XCTAssertFalse(superseded)
        }
        var progress = mutation(nil)
        progress.clearResume = false
        progress.resumePosition = 600
        let superseded = try await applier.serverPlaybackSupersedes(progress, on: target)
        var completion = mutation(true)
        completion.isExplicitReset = false
        let newerThanCompletion = try await applier.serverPlaybackSupersedes(completion, on: target)
        let reads = await provider.reads
        XCTAssertFalse(superseded)
        XCTAssertFalse(newerThanCompletion)
        XCTAssertEqual(reads, 0)
    }

    func testOlderRemovalPayloadAndRetriedCompletionStillCheckNewerPlayback() async throws {
        let provider = PlaybackProbeProvider(lastPlayedAt: captured.addingTimeInterval(1))
        var legacy = mutation(nil)
        legacy.isExplicitReset = false
        let superseded = try await applier(provider).serverPlaybackSupersedes(legacy, on: target)
        XCTAssertTrue(superseded)
        var retry = mutation(true)
        retry.isExplicitReset = false
        retry.attempts = 1
        let completionSuperseded = try await applier(provider).serverPlaybackSupersedes(retry, on: target)
        XCTAssertTrue(completionSuperseded)
    }
}

private actor PlaybackProbeProvider: MediaProvider, PlayedStateWriting, ResumeStateWriting {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    nonisolated let usesLocalWatchStateOnly: Bool
    let lastPlayedAt: Date
    private var readFailure = false
    private var afterRead: (@Sendable () -> Void)?
    private(set) var writes: [String] = []
    private(set) var receivedKinds: [MediaItemKind?] = []
    private(set) var reads = 0

    init(kind: ProviderKind = .jellyfin, lastPlayedAt: Date, usesLocalWatchStateOnly: Bool = false) {
        self.kind = kind
        self.usesLocalWatchStateOnly = usesLocalWatchStateOnly
        self.lastPlayedAt = lastPlayedAt
        session = UserSession(
            server: .init(id: "server", name: "Fixture", baseURL: URL(string: "https://server.invalid")!, provider: kind),
            userID: "user", userName: "Fixture", deviceID: "device", accessToken: "fixture"
        )
    }
    func setReadFailure(_ value: Bool) { readFailure = value }
    func setAfterRead(_ action: @escaping @Sendable () -> Void) { afterRead = action }
    func item(id: String) async throws -> MediaItem {
        reads += 1
        if readFailure { throw AppError.serverUnreachable }
        afterRead?()
        return MediaItem(id: id, title: "Fixture", kind: .episode, resumePosition: 900, lastPlayedAt: lastPlayedAt)
    }
    func setPlayed(_ played: Bool, itemID: String) async throws { writes.append("played:\(played)") }
    func setPlayed(_ played: Bool, itemID: String, capturedAt: Date) async throws {
        try await setPlayed(played, itemID: itemID)
    }
    func setPlayed(_ played: Bool, itemID: String, kind: MediaItemKind?, capturedAt: Date) async throws {
        receivedKinds.append(kind)
        try await setPlayed(played, itemID: itemID)
    }

    func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async throws { writes.append("resume:\(Int(seconds))") }
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

private actor PendingWatchMetadata {
    let kind: ProviderKind
    private var lastPlayedAt: Date
    private var pending: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var reads = 0
    private(set) var writes: [String] = []

    init(kind: ProviderKind, lastPlayedAt: Date) {
        self.kind = kind
        self.lastPlayedAt = lastPlayedAt
    }

    func recordPlayback(at date: Date) { lastPlayedAt = date }

    func response(_ request: LoopbackHTTPServer.Request) async -> LoopbackHTTPServer.Response {
        let path = URLComponents(string: "http://localhost" + request.target)?.path
        let detail = kind == .plex ? "/library/metadata/item" : "/Users/viewer/Items/item"
        guard request.method == "GET", path == detail else {
            writes.append(request.target)
            return .json("{}")
        }
        reads += 1
        let observed = lastPlayedAt
        if reads == 1, !released {
            await withCheckedContinuation { pending = $0 }
        }
        if kind == .plex {
            return .json("""
                {"MediaContainer":{"Metadata":[{"ratingKey":"item","type":"episode","title":"Fixture",
                "duration":1800000,"viewOffset":900000,"lastViewedAt":\(Int(observed.timeIntervalSince1970))}]}}
                """)
        }
        return .json("""
            {"Id":"item","Name":"Fixture","Type":"Episode","RunTimeTicks":18000000000,
            "UserData":{"PlaybackPositionTicks":9000000000,"LastPlayedDate":"\(observed.ISO8601Format())"}}
            """)
    }

    func release() {
        released = true
        let waiter = pending
        pending = nil
        waiter?.resume()
    }
}

private actor PlexWatchStateHTTP: HTTPClient {
    let kind: MediaItemKind
    let lastViewedAt: Date
    private(set) var metadataReads = 0
    private(set) var writes: [String] = []

    init(kind: MediaItemKind, lastViewedAt: Date) {
        self.kind = kind
        self.lastViewedAt = lastViewedAt
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let body: String
        if endpoint.path == "/library/metadata/item" {
            metadataReads += 1
            body = """
            {"MediaContainer":{"Metadata":[{"ratingKey":"item","type":"\(kind.rawValue)",
            "title":"Fixture","duration":1800000,"viewOffset":900000,
            "lastViewedAt":\(Int(lastViewedAt.timeIntervalSince1970))}]}}
            """
        } else {
            writes.append(endpoint.path)
            body = "{}"
        }
        return (Data(body.utf8), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
