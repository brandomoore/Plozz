import AppRuntime
import CoreModels
import FeatureAuthCore
import FeatureHomeCore
import Foundation
import ProviderJellyfin
import ProviderPlex
import XCTest

/// Opt-in protocol checks. The private broker must authorize disposable test-user
/// history and keep all credentials in memory.
final class LiveWatchProgressTests: XCTestCase {
    func testJellyfinSavedProgressAndHomeAdmission() async throws {
        try await verify(.jellyfin)
    }

    func testEmbySavedProgressAndHomeAdmission() async throws {
        try await verify(.emby)
    }

    func testPlexSavedProgressAndHomeAdmission() async throws {
        try await verify(.plex)
    }

    @MainActor
    func testJellyfinUnwatchedResetPersistsAcrossHomeAndOutboxRecreation() async throws {
        try await verifyUnwatchedReset(.jellyfin)
    }

    @MainActor
    func testEmbyUnwatchedResetPersistsAcrossHomeAndOutboxRecreation() async throws {
        try await verifyUnwatchedReset(.emby)
    }

    @MainActor
    func testPlexUnwatchedResetPersistsAcrossHomeAndOutboxRecreation() async throws {
        try await verifyUnwatchedReset(.plex)
    }

    private struct Configuration: Decodable {
        let baseURL: URL
        let username: String
        let userID: String
        let serverID: String
        let deviceID: String
        let token: String
        let allowWatchStateWrites: Bool
        let resetEpisodeIDs: [String]?
    }

    private struct InvalidConfiguration: Error {}

    private struct Fixture {
        let provider: any MediaProvider
        let raw: any MediaProvider
        var rebuild: (() throws -> PlexProvider)?
        var resetEpisodeIDs: [String] = []
    }

    private func provider(_ kind: ProviderKind) async throws -> Fixture {
        guard let input = ProcessInfo.processInfo.environment["PLOZZ_LIVE_WATCH_BROKER"] else {
            throw XCTSkip("Set PLOZZ_LIVE_WATCH_BROKER for explicitly authorized internal watch-history tests.")
        }
        guard let broker = URL(string: input), broker.scheme == "http", broker.host == "127.0.0.1",
              broker.user == nil, broker.password == nil, broker.query == nil else {
            throw InvalidConfiguration()
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(
            url: broker.appendingPathComponent(kind.rawValue), timeoutInterval: 10
        ))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InvalidConfiguration() }
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        guard config.allowWatchStateWrites, !config.token.isEmpty,
              ["http", "https"].contains(config.baseURL.scheme),
              config.baseURL.host != nil, config.baseURL.user == nil,
              config.baseURL.password == nil, config.baseURL.query == nil else {
            throw InvalidConfiguration()
        }
        let session = UserSession(
            server: .init(id: config.serverID, name: "Internal watch verification", baseURL: config.baseURL, provider: kind),
            userID: config.userID, userName: config.username, deviceID: config.deviceID, accessToken: config.token
        )
        if kind == .plex {
            try await PlexProvider.verifyAddress(config.baseURL, serverID: config.serverID)
            let backend = InMemorySecureStore()
            let context = LocalMediaContext(
                accountID: "test-origin", profileID: UUID().uuidString,
                profileNamespace: nil, serverUserID: config.userID
            )
            let rebuild = {
                try PlexProvider(
                    session: session, localMediaContext: context,
                    durableStore: DurableLocalStateStore(secureStore: backend)
                )
            }
            return Fixture(provider: try rebuild(), raw: PlexProvider(session: session), rebuild: rebuild)
        }
        let provider = JellyfinProvider(session: session, playbackRequests: .init())
        return Fixture(provider: provider, raw: provider, resetEpisodeIDs: config.resetEpisodeIDs ?? [])
    }

    private func verify(_ kind: ProviderKind) async throws {
        let fixture = try await provider(kind)
        let provider = fixture.provider
        let writer = try XCTUnwrap(provider as? any ResumeStateWriting)
        let watched = try XCTUnwrap(provider as? any WatchStateProviding)
        let libraries = try await provider.libraries()
        let library = try XCTUnwrap(libraries.first { $0.kind == .movie && !$0.isMusic })
        let candidates = try await provider.items(in: library.id, kind: .movie, page: .init(limit: 20)).items
        let movie = try XCTUnwrap(candidates.first {
            $0.kind == .movie && !$0.isTrailer && ($0.runtime ?? 0) >= 1_200
        }, "The approved test library must expose a long movie in the bounded sample.")
        let baseline = try await provider.item(id: movie.id)
        do {
            try await watched.setPlayed(false, itemID: movie.id)
            for position in [2.0, 59, 60, 61, 90] {
                let mutation = try XCTUnwrap(WatchMutationFactory.playbackStop(
                    item: movie, position: position, watchedPercent: position / (movie.runtime ?? 1) * 100,
                    primaryAccountID: "test-origin"
                ))
                XCTAssertEqual(mutation.targets.map(\.itemID), [movie.id])
                try await writer.setResumePosition(
                    try XCTUnwrap(mutation.resumePosition), itemID: movie.id, capturedAt: mutation.capturedAt
                )
                // This Plex server drops stopped offsets <=60 seconds. Its
                // persisted feed is authoritative; client curation cannot add them.
                let expectedPosition = kind == .plex && position <= 60 ? 0 : position
                let persisted = try await readPosition(expectedPosition, itemID: movie.id, provider: provider)
                XCTAssertEqual(persisted.resumePosition ?? 0, expectedPosition, accuracy: 0.1)
                if expectedPosition > 0 {
                    XCTAssertEqual(ContinueWatchingPolicy.admits(persisted), position >= 60)
                }
                let feed = try await provider.continueWatching(limit: 100)
                let curated = HomeViewModel.reconcileContinueWatching(feed, pending: [])
                if position < 60 || expectedPosition == 0 {
                    XCTAssertFalse(curated.contains { $0.id == movie.id })
                } else {
                    XCTAssertTrue(curated.contains { $0.id == movie.id },
                                  "Eligible saved progress must reach the actual provider Home feed.")
                }
            }
            try await verifyTrailer(
                candidates: [movie] + candidates.filter { $0.id != movie.id },
                fixture: fixture, writer: writer, watched: watched
            )
            try await restore(baseline, writer: writer, watched: watched)
        } catch {
            try await restore(baseline, writer: writer, watched: watched)
            throw error
        }
        print("Live \(kind.rawValue): checked 2/59/60/61/90-second writes and actual Home-feed admission; original watched/resume state restored.")
        if kind == .plex {
            print("Live plex limitation: this server discards stopped resume offsets <=60 seconds, independently of Plozz's adaptive Home threshold.")
        }
    }

    private func readPosition(
        _ position: TimeInterval, itemID: String, provider: any MediaProvider
    ) async throws -> MediaItem {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let item = try await provider.item(id: itemID)
            if abs((item.resumePosition ?? 0) - position) <= 1 || ContinuousClock.now >= deadline { return item }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    private func verifyUnwatchedReset(_ kind: ProviderKind) async throws {
        let fixture = try await provider(kind)
        let provider = fixture.provider
        let writer = try XCTUnwrap(provider as? any ResumeStateWriting)
        let watched = try XCTUnwrap(provider as? any WatchStateProviding)
        let libraries = try await provider.libraries()
        for itemKind in [MediaItemKind.movie, .episode] {
            let libraryKind: MediaItemKind = itemKind == .movie ? .movie : .series
            let library = try XCTUnwrap(libraries.first { $0.kind == libraryKind && !$0.isMusic })
            let candidates: [MediaItem]
            if itemKind == .episode, !fixture.resetEpisodeIDs.isEmpty {
                var episodes: [MediaItem] = []
                for id in fixture.resetEpisodeIDs.prefix(2) {
                    let episode = try await provider.item(id: id)
                    XCTAssertEqual(episode.kind, .episode)
                    episodes.append(episode)
                }
                candidates = episodes
            } else {
                candidates = try await resetCandidates(provider, libraryID: library.id, kind: itemKind)
            }
            let selected = try XCTUnwrap(candidates.first, "A bounded sample must contain the requested fixture.")
            let control = try XCTUnwrap(candidates.dropFirst().first, "A second item verifies reset isolation.")
            let baseline = try await provider.item(id: selected.id)
            let controlBefore = try await provider.item(id: control.id)
            do {
                for previouslyWatched in [false, true] {
                    let failuresBefore = testRun?.failureCount
                    try await watched.setPlayed(previouslyWatched, itemID: selected.id)
                    let marked = try await provider.item(id: selected.id)
                    XCTAssertEqual(marked.isPlayed, previouslyWatched)
                    try await writer.setResumePosition(120, itemID: selected.id, capturedAt: Date())
                    var started = try await readPosition(120, itemID: selected.id, provider: provider)
                    XCTAssertEqual(started.resumePosition ?? 0, 120, accuracy: 1)
                    started.sourceAccountID = "test-origin"
                    let backend = InMemorySecureStore()
                    let profileID = UUID().uuidString
                    let store = try DurableWatchMutationStore(
                        store: DurableLocalStateStore(secureStore: backend), profileID: profileID
                    )
                    let applier = AppShellWatchMutationApplier(
                        resolveProvider: { $0 == "test-origin" ? provider : nil },
                        applyTrakt: { _ in throw InvalidConfiguration() },
                        applySimkl: { _ in throw InvalidConfiguration() },
                        applyAniList: { _ in throw InvalidConfiguration() },
                        applyMAL: { _ in throw InvalidConfiguration() },
                        allAccountIDs: { ["test-origin"] }
                    )
                    let outbox = WatchStateReconciler(store: store, applier: applier)
                    let home = resetHome(provider, pending: { await outbox.snapshot().pending })
                    await home.load()
                    XCTAssertTrue(home.state.value?.continueWatching.contains {
                        $0.id == selected.id && ($0.resumePosition ?? 0) > 0
                    } == true, "The seeded item must be on the actual Home row before resetting it.")
                    var queued: [WatchMutation] = []
                    let coordinator = MediaItemActionCoordinator(
                        providerResolver: { $0 == "test-origin" ? provider : nil },
                        providerCapabilityResolver: { accountID in
                            guard accountID == "test-origin" else { return nil }
                            return (provider is any WatchStateProviding, provider is any WatchlistProviding, false)
                        },
                        primaryAccountID: { "test-origin" },
                        crossServerWatchSyncEnabled: { false },
                        enqueueWatchMutation: { queued.append($0) }
                    )
                    let menu = coordinator.actions(for: started, context: .none)
                    XCTAssertTrue(menu.contains(.markWatched))
                    XCTAssertTrue(menu.contains(.markUnwatched))
                    XCTAssertTrue(menu.contains(.removeFromContinueWatching))
                    let observer = NotificationCenter.default.addObserver(
                        forName: .mediaItemDidMutate, object: nil, queue: .main
                    ) { note in
                        MainActor.assumeIsolated {
                            if let mutation = MediaItemMutation.from(note) {
                                home.applyWatchedState(mutation)
                            }
                        }
                    }
                    coordinator.perform(.markUnwatched, on: started, context: .none)
                    NotificationCenter.default.removeObserver(observer)
                    XCTAssertFalse(home.state.value?.continueWatching.contains { $0.id == selected.id } == true)
                    let mutation = try XCTUnwrap(queued.first)
                    XCTAssertEqual(queued.count, 1)
                    XCTAssertEqual(mutation.targets.map(\.id), ["test-origin:\(selected.id)"])
                    XCTAssertTrue(mutation.clearResume)
                    XCTAssertNil(mutation.trakt)
                    let enqueued = await outbox.enqueue(mutation)
                    XCTAssertTrue(enqueued)

                    let restoredStore = try DurableWatchMutationStore(
                        store: DurableLocalStateStore(secureStore: backend), profileID: profileID
                    )
                    let restored = WatchStateReconciler(store: restoredStore, applier: applier)
                    let pendingHome = resetHome(provider, pending: { await restored.snapshot().pending })
                    await pendingHome.load()
                    let persistedPending = await restored.snapshot().pending
                    if let stale = pendingHome.state.value?.continueWatching.first(where: { $0.id == selected.id }) {
                        print("Live \(kind.rawValue): pending=\(persistedPending.count), accountMatches=\(stale.sourceAccountID == "test-origin"), serverTimeAhead=\(stale.lastPlayedAt?.timeIntervalSince(mutation.capturedAt) ?? 0).")
                    }
                    XCTAssertFalse(pendingHome.state.value?.continueWatching.contains {
                        $0.id == selected.id && ($0.resumePosition ?? 0) > 0
                    } == true, "A recreated outbox must suppress the real server's still-stale progress.")
                    await restored.drain()
                    let remaining = await restored.snapshot().pending
                    XCTAssertTrue(remaining.isEmpty, "Both real server writes must finish, not merely queue.")

                    let fresh = try await self.provider(kind)
                    let persisted = try await readPosition(0, itemID: selected.id, provider: fresh.raw)
                    XCTAssertFalse(persisted.isPlayed)
                    XCTAssertEqual(persisted.resumePosition ?? 0, 0, accuracy: 0.1)
                    let reopenedHome = resetHome(fresh.provider)
                    await reopenedHome.load()
                    XCTAssertFalse(reopenedHome.state.value?.continueWatching.contains {
                        $0.id == selected.id && ($0.resumePosition ?? 0) > 0
                    } == true, "Fresh server data must not restore the old progress after reopening Home.")
                    let controlAfter = try await fresh.raw.item(id: control.id)
                    XCTAssertEqual(controlAfter.isPlayed, controlBefore.isPlayed)
                    XCTAssertEqual(controlAfter.resumePosition, controlBefore.resumePosition)
                    if testRun?.failureCount == failuresBefore {
                        print("Live \(kind.rawValue) \(itemKind.rawValue), previouslyWatched=\(previouslyWatched): menu, immediate Home removal, durable replay, server reset, fresh Home and other-item isolation verified.")
                    }
                }
                try await restore(baseline, writer: writer, watched: watched)
            } catch {
                try await restore(baseline, writer: writer, watched: watched)
                throw error
            }
        }
    }

    private func resetCandidates(
        _ provider: any MediaProvider, libraryID: String, kind: MediaItemKind
    ) async throws -> [MediaItem] {
        if kind == .movie {
            return try await provider.items(in: libraryID, kind: .movie, page: .init(limit: 20))
                .items.filter { $0.kind == .movie && !$0.isExtra && ($0.runtime ?? 0) >= 600 }
        }
        let shows = try await provider.items(in: libraryID, kind: .series, page: .init(limit: 3)).items
        for show in shows.prefix(3) {
            let seasons = try await provider.children(of: show.id).filter { $0.kind == .season }
            for season in seasons.prefix(2) {
                let episodes = try await provider.children(of: season.id).prefix(20).filter {
                    $0.kind == .episode && !$0.isExtra && ($0.runtime ?? 0) >= 600
                }
                if episodes.count >= 2 { return episodes }
            }
        }
        return []
    }

    @MainActor
    private func resetHome(
        _ provider: any MediaProvider,
        pending: @escaping @Sendable () async -> [WatchMutation] = { [] }
    ) -> HomeViewModel {
        HomeViewModel(
            accounts: [.init(account: .init(id: "test-origin", from: provider.session), provider: provider)],
            profileNamespace: "live-reset-\(UUID().uuidString)",
            layoutStore: InMemoryHomeLayoutStore(), contentStore: InMemoryHomeContentStore(),
            currentVisibility: { .init(mergeLibrariesOnHome: true) },
            pendingWatchMutations: pending
        )
    }

    private func verifyTrailer(
        candidates: [MediaItem], fixture: Fixture,
        writer: any ResumeStateWriting, watched: any WatchStateProviding
    ) async throws {
        let provider = fixture.provider
        var selected: (parent: MediaItem, trailer: MediaItem)?
        for parent in candidates.prefix(5) {
            let trailers = try await provider.trailers(for: parent.id)
            if let trailer = trailers.filter({ !$0.isYouTubeTrailer && ($0.runtime ?? 0) > 20 })
                .min(by: { ($0.runtime ?? 0) < ($1.runtime ?? 0) }) {
                selected = (parent, trailer)
                break
            }
        }
        guard let (parent, trailer) = selected else {
            print("Live \(provider.kind.rawValue): no provider trailer over 20 seconds in five sampled titles; trailer server writes not exercised.")
            return
        }
        XCTAssertTrue(trailer.isTrailer)
        XCTAssertNotEqual(trailer.id, parent.id)
        let baseline = try await fixture.raw.item(id: trailer.id)
        let rawWriter = try XCTUnwrap(fixture.raw as? any ResumeStateWriting)
        let rawWatched = try XCTUnwrap(fixture.raw as? any WatchStateProviding)
        let parentBefore = try await provider.item(id: parent.id)
        do {
            let position = 15.0
            let mutation = try XCTUnwrap(WatchMutationFactory.playbackStop(
                item: trailer, position: position, watchedPercent: position / (trailer.runtime ?? 1) * 100,
                primaryAccountID: "test-origin", reportTraktProgress: true
            ))
            XCTAssertEqual(mutation.targets.map(\.itemID), [trailer.id])
            XCTAssertNil(mutation.traktProgress)
            XCTAssertFalse(mutation.expansionPending)
            try await writer.setResumePosition(
                try XCTUnwrap(mutation.resumePosition), itemID: trailer.id, capturedAt: mutation.capturedAt
            )
            let persisted = try await readPosition(position, itemID: trailer.id, provider: provider)
            XCTAssertEqual(persisted.resumePosition ?? 0, position, accuracy: 0.1)
            XCTAssertTrue(persisted.isTrailer, "A fresh provider lookup must retain trailer classification.")
            XCTAssertFalse(ContinueWatchingPolicy.admits(persisted))
            if let rebuild = fixture.rebuild {
                let raw = try await fixture.raw.item(id: trailer.id)
                XCTAssertNotEqual(raw.resumePosition, position, "This fixture must exercise the actual Plex omission.")
                let restored = try await rebuild().item(id: trailer.id)
                XCTAssertEqual(restored.resumePosition, position)
                let listed = try await rebuild().trailers(for: parent.id)
                XCTAssertEqual(listed.first { $0.id == trailer.id }?.resumePosition, position)
                print("Live plex: short trailer offset survived provider/store reconstruction despite missing native offset.")
            }
            let parentAfter = try await provider.item(id: parent.id)
            XCTAssertEqual(parentAfter.resumePosition, parentBefore.resumePosition)
            XCTAssertEqual(parentAfter.isPlayed, parentBefore.isPlayed)
            let feed = try await provider.continueWatching(limit: 100)
            XCTAssertFalse(ContinueWatchingPolicy.default.curated(feed).contains { $0.id == trailer.id })
            try await restore(baseline, writer: rawWriter, watched: rawWatched)
        } catch {
            try await restore(baseline, writer: rawWriter, watched: rawWatched)
            throw error
        }
        print("Live \(provider.kind.rawValue): checked trailer-only progress, parent isolation and Home exclusion.")
    }

    private func restore(
        _ item: MediaItem, writer: any ResumeStateWriting, watched: any WatchStateProviding
    ) async throws {
        try await watched.setPlayed(item.isPlayed, itemID: item.id)
        try await writer.setResumePosition(
            item.resumePosition ?? 0, itemID: item.id, capturedAt: item.lastPlayedAt ?? Date()
        )
    }
}
