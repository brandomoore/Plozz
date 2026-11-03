import XCTest
import CoreModels
@testable import ProviderShare

/// Container actions and indicators share the indexed episode-file watch state.
final class ShareSeasonWatchStateTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-share-season-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDurableStore() throws -> DurableLocalStateStore {
        try DurableLocalStateStore(secureStore: MemorySecureStore())
    }

    /// Local in-memory secure store (the equivalent in `ShareProviderWatchTests`
    /// is private to that file).
    private final class MemorySecureStore: SecureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: String] = [:]

        func setString(_ value: String, for key: String) throws {
            lock.lock(); storage[key] = value; lock.unlock()
        }

        func string(for key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return storage[key]
        }

        func readString(for key: String) throws -> String? { string(for: key) }

        func removeValue(for key: String) throws {
            lock.lock(); storage[key] = nil; lock.unlock()
        }
    }

    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(
                id: "share:nas.local/Media",
                name: "NAS",
                baseURL: URL(string: "smb://nas.local/Media")!,
                provider: .mediaShare
            ),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: ""
        )
    }

    private let seriesKey = ShareCatalogID.seriesKey(fromTitle: "Test Show")

    /// Two seasons of two episodes each.
    private func makeCatalog() async -> ShareCatalogStore {
        let directory = makeTempDir()
        let catalog = ShareCatalogStore(accountKey: "season-watch", directory: directory)
        addTeardownBlock {
            let closed = await catalog.prepareForSuspension(revision: .max)
            XCTAssertTrue(closed)
            if closed { try FileManager.default.removeItem(at: directory) }
        }
        var assets: [CatalogAsset] = []
        for season in 1...2 {
            for episode in 1...2 {
                let rel = "TV/Test Show/S0\(season)/Test Show - s0\(season)e0\(episode).mkv"
                assets.append(
                    CatalogAsset(
                        relPath: rel, basename: "s0\(season)e0\(episode).mkv",
                        size: 1_000, modifiedAt: Date(), kind: .episode, library: .tv,
                        title: "Episode \(episode)", year: 2020,
                        seriesTitle: "Test Show", seriesKey: seriesKey,
                        season: season, episode: episode,
                        movieKey: nil, movieTitleKey: nil
                    )
                )
            }
        }
        await catalog.upsert(assets, scanID: 1)
        return catalog
    }

    private func makeWatchStore(_ durableStore: DurableLocalStateStore) -> ShareWatchStore {
        ShareWatchStore(
            localMediaContext: LocalMediaContext(
                accountID: "share:nas.local/Media",
                profileID: ProfileStore.defaultProfileID,
                profileNamespace: nil
            ),
            durableStore: durableStore
        )
    }

    private func fileID(season: Int, episode: Int) -> String {
        ShareCatalogID.file("TV/Test Show/S0\(season)/Test Show - s0\(season)e0\(episode).mkv")
    }

    private func seasons(
        catalog: ShareCatalogStore,
        durableStore: DurableLocalStateStore
    ) async throws -> [MediaItem] {
        let provider = ShareProvider(
            session: makeSession(),
            durableLocalStateStore: durableStore,
            catalogStore: catalog
        )
        return try await provider.children(of: ShareCatalogID.series(seriesKey))
    }

    func testFullyWatchedSeasonReportsPlayed() async throws {
        let durableStore = try makeDurableStore()
        let catalog = await makeCatalog()
        let watch = makeWatchStore(durableStore)
        for episode in 1...2 {
            await watch.setPlayed(true, itemID: fileID(season: 1, episode: episode), capturedAt: Date())
        }

        let result = try await seasons(catalog: catalog, durableStore: durableStore)
        let s1 = try XCTUnwrap(result.first { $0.seasonNumber == 1 })
        XCTAssertTrue(s1.isPlayed, "every episode watched must mark the season played")
        XCTAssertEqual(s1.playedPercentage, 1.0)
        XCTAssertEqual(s1.unwatchedEpisodeCount, 0)
    }

    func testRecentlyAddedRollsUpSeriesAndKeepsUnwatchedEpisodes() async throws {
        let durableStore = try makeDurableStore()
        let catalog = await makeCatalog()
        let watch = makeWatchStore(durableStore)
        let provider = ShareProvider(
            session: makeSession(), durableLocalStateStore: durableStore, catalogStore: catalog
        )
        let series = MediaItem(id: ShareCatalogID.series(seriesKey), title: "Test Show", kind: .series)
        for season in 1...2 {
            for episode in 1...2 {
                await watch.setPlayed(true, itemID: fileID(season: season, episode: episode), capturedAt: Date())
            }
        }
        let complete = try await provider.recentlyAddedWatchState([series])
        XCTAssertTrue(try XCTUnwrap(complete.first).isPlayed)
        XCTAssertEqual(complete.first?.unwatchedEpisodeCount, 0)
        XCTAssertTrue(HomeRecentlyAddedPolicy.items(complete, hideWatched: true).isEmpty)
        try await provider.setPlayed(false, itemID: fileID(season: 2, episode: 2))
        let partial = try await provider.recentlyAddedWatchState([series])
        XCTAssertEqual(partial.first?.unwatchedEpisodeCount, 1)
        XCTAssertEqual(HomeRecentlyAddedPolicy.items(partial, hideWatched: true).map(\.id), [series.id])
    }

    func testPartlyWatchedSeasonReportsProgressNotPlayed() async throws {
        let durableStore = try makeDurableStore()
        let catalog = await makeCatalog()
        let watch = makeWatchStore(durableStore)
        await watch.setPlayed(true, itemID: fileID(season: 2, episode: 1), capturedAt: Date())

        let result = try await seasons(catalog: catalog, durableStore: durableStore)
        let s2 = try XCTUnwrap(result.first { $0.seasonNumber == 2 })
        XCTAssertFalse(s2.isPlayed)
        XCTAssertEqual(try XCTUnwrap(s2.playedPercentage), 0.5, accuracy: 0.0001)
        XCTAssertTrue(s2.hasBeenPlayed)
        XCTAssertEqual(s2.unwatchedEpisodeCount, 1)
    }

    func testUntouchedSeasonReportsNothing() async throws {
        let durableStore = try makeDurableStore()
        let catalog = await makeCatalog()
        let watch = makeWatchStore(durableStore)
        await watch.setPlayed(true, itemID: fileID(season: 1, episode: 1), capturedAt: Date())

        let result = try await seasons(catalog: catalog, durableStore: durableStore)
        let s2 = try XCTUnwrap(result.first { $0.seasonNumber == 2 })
        XCTAssertFalse(s2.isPlayed)
        XCTAssertFalse(s2.hasBeenPlayed)
        XCTAssertNil(s2.playedPercentage, "no progress must be nil, not a zeroed bar")
        XCTAssertEqual(s2.unwatchedEpisodeCount, 2)
    }

    /// The bug this fixes, stated as behaviour: with S1 complete and S2 started,
    /// "which season is the viewer on" must answer S2, not Season 1.
    func testSeasonsResolveToTheOneBeingWatched() async throws {
        let durableStore = try makeDurableStore()
        let catalog = await makeCatalog()
        let watch = makeWatchStore(durableStore)
        for episode in 1...2 {
            await watch.setPlayed(true, itemID: fileID(season: 1, episode: episode), capturedAt: Date())
        }
        await watch.setResume(300, itemID: fileID(season: 2, episode: 1), capturedAt: Date(), duration: 3_000)

        let result = try await seasons(catalog: catalog, durableStore: durableStore)
        XCTAssertEqual(
            result.first { !$0.isPlayed }?.seasonNumber, 2,
            "S1 is complete, so the season being watched is S2 — not Season 1"
        )
    }

    /// One episode can exist as several files (a 1080p and a 4K rip). Episode ids
    /// are deliberately not folded together the way movie versions are, so
    /// counting raw files would report more episodes than the season has.
    func testMultipleFilesForOneEpisodeCountOnce() async throws {
        let durableStore = try makeDurableStore()
        let catalog = ShareCatalogStore(accountKey: "season-watch-versions", directory: makeTempDir())
        let base = "TV/Test Show/S01/Test Show - s01e01"
        await catalog.upsert(
            ["\(base) 1080p.mkv", "\(base) 2160p.mkv"].map { rel in
                CatalogAsset(
                    relPath: rel, basename: "s01e01.mkv",
                    size: 1_000, modifiedAt: Date(), kind: .episode, library: .tv,
                    title: "Episode 1", year: 2020,
                    seriesTitle: "Test Show", seriesKey: seriesKey,
                    season: 1, episode: 1,
                    movieKey: nil, movieTitleKey: nil
                )
            },
            scanID: 1
        )
        let watch = makeWatchStore(durableStore)
        // Watched only the 1080p rip — the episode has still been seen.
        await watch.setPlayed(true, itemID: ShareCatalogID.file("\(base) 1080p.mkv"), capturedAt: Date())

        let result = try await seasons(catalog: catalog, durableStore: durableStore)
        let s1 = try XCTUnwrap(result.first { $0.seasonNumber == 1 })
        XCTAssertTrue(
            s1.isPlayed,
            "two files of one episode are one episode — watching either completes the season"
        )
        XCTAssertEqual(s1.playedPercentage, 1.0)

        let provider = ShareProvider(
            session: makeSession(), durableLocalStateStore: durableStore, catalogStore: catalog
        )
        let series = MediaItem(id: ShareCatalogID.series(seriesKey), title: "Test Show", kind: .series)
        let complete = try await provider.recentlyAddedWatchState([series])
        XCTAssertTrue(HomeRecentlyAddedPolicy.items(complete, hideWatched: true).isEmpty)
        try await provider.setResumePosition(
            300, itemID: ShareCatalogID.file("\(base) 2160p.mkv"), capturedAt: Date()
        )
        let rewatch = try await provider.recentlyAddedWatchState([series])
        XCTAssertEqual(rewatch.first?.unwatchedEpisodeCount, 1)
        XCTAssertEqual(HomeRecentlyAddedPolicy.items(rewatch, hideWatched: true).map(\.id), [series.id])
        let unchangedSeasons = try await provider.children(of: series.id)
        XCTAssertTrue(try XCTUnwrap(unchangedSeasons.first).isPlayed)
    }

    /// No watch records means all known catalog episodes are unwatched.
    func testNoHistoryLeavesSeasonsUntouched() async throws {
        let durableStore = try makeDurableStore()
        let catalog = await makeCatalog()

        let result = try await seasons(catalog: catalog, durableStore: durableStore)
        XCTAssertEqual(result.count, 2)
        for season in result {
            XCTAssertFalse(season.isPlayed)
            XCTAssertFalse(season.hasBeenPlayed)
            XCTAssertNil(season.playedPercentage)
            XCTAssertEqual(season.unwatchedEpisodeCount, 2)
        }
    }

    func testWholeShowActionPersistsEpisodesAndEveryContainerRead() async throws {
        let durable = try makeDurableStore()
        let catalog = await makeCatalog()
        let provider = ShareProvider(session: makeSession(), durableLocalStateStore: durable, catalogStore: catalog)
        let seriesID = ShareCatalogID.series(seriesKey)
        try await provider.setPlayed(true, itemID: seriesID)
        try await provider.setResumePosition(0, itemID: seriesID, capturedAt: Date())

        let reopened = ShareProvider(session: makeSession(), durableLocalStateStore: durable, catalogStore: catalog)
        let detail = try await reopened.item(id: seriesID)
        let grid = try await reopened.items(in: ShareCatalogID.library(.tv), kind: .series, page: .init())
        let search = try await reopened.search(query: "Test Show", limit: 10)
        let query = try await reopened.libraryQueryItem(.init(id: seriesID))
        for item in [detail, try XCTUnwrap(grid.items.first), try XCTUnwrap(search.first { $0.id == seriesID }), query] {
            XCTAssertTrue(item.isPlayed)
            XCTAssertEqual(item.unwatchedEpisodeCount, 0)
            XCTAssertEqual(item.playedPercentage, 1)
            XCTAssertFalse(LibraryQueryRecord(item).matches(.init(filter: .unwatched)))
            XCTAssertNil(item.resumePosition)
        }
        for season in try await reopened.children(of: seriesID) {
            XCTAssertTrue(season.isPlayed)
            let detail = try await reopened.item(id: season.id)
            XCTAssertTrue(detail.isPlayed)
            let episodes = try await reopened.children(of: season.id)
            XCTAssertEqual(episodes.count, 2)
            XCTAssertTrue(episodes.allSatisfy(\.isPlayed))
        }
        let records = await makeWatchStore(durable).recordsSnapshot()
        XCTAssertEqual(Set(records.keys), Set((1...2).flatMap { season in
            (1...2).map { fileID(season: season, episode: $0) }
        }))
    }

    func testSeasonUnwatchDoesNotChangeOtherSeasonsAndShowUnwatchClearsAll() async throws {
        let durable = try makeDurableStore()
        let catalog = await makeCatalog()
        let provider = ShareProvider(session: makeSession(), durableLocalStateStore: durable, catalogStore: catalog)
        let seriesID = ShareCatalogID.series(seriesKey)
        try await provider.setPlayed(true, itemID: seriesID)
        try await provider.setPlayed(false, itemID: ShareCatalogID.season(seriesKey, 2))
        let partial = try await provider.item(id: seriesID)
        XCTAssertFalse(partial.isPlayed)
        XCTAssertEqual(partial.unwatchedEpisodeCount, 2)
        XCTAssertEqual(partial.playedPercentage, 0.5)
        XCTAssertTrue(LibraryQueryRecord(partial).matches(.init(filter: .unwatched)))
        let seasons = try await provider.children(of: seriesID)
        XCTAssertEqual(seasons.first { $0.seasonNumber == 1 }?.isPlayed, true)
        XCTAssertEqual(seasons.first { $0.seasonNumber == 2 }?.isPlayed, false)

        try await provider.setPlayed(false, itemID: seriesID)
        let reopened = ShareProvider(session: makeSession(), durableLocalStateStore: durable, catalogStore: catalog)
        let unwatched = try await reopened.item(id: seriesID)
        XCTAssertEqual(unwatched.unwatchedEpisodeCount, 4)
        XCTAssertFalse(unwatched.hasBeenPlayed)
        XCTAssertNil(unwatched.playedPercentage)
        for season in try await reopened.children(of: seriesID) {
            let episodes = try await reopened.children(of: season.id)
            XCTAssertTrue(episodes.allSatisfy { !$0.isPlayed && $0.resumePosition == nil })
        }
    }

    func testContainerActionIncludesSpecialsAndEveryAlternateFileWithoutDoubleCounting() async throws {
        let durable = try makeDurableStore()
        let catalog = await makeCatalog()
        let extraPaths = ["Specials/S00E01.mkv", "Specials/S00E01 alternate.mkv"]
        await catalog.upsert(extraPaths.map { path in
            CatalogAsset(
                relPath: path, basename: path, size: 1_000, modifiedAt: Date(),
                kind: .episode, library: .tv, title: "Special", year: 2020,
                seriesTitle: "Test Show", seriesKey: seriesKey, season: 0, episode: 1
            )
        }, scanID: 1)
        let provider = ShareProvider(session: makeSession(), durableLocalStateStore: durable, catalogStore: catalog)
        let specialID = ShareCatalogID.season(seriesKey, 0)
        try await provider.setPlayed(true, itemID: specialID)
        try await provider.setResumePosition(0, itemID: specialID, capturedAt: Date())
        let special = try await provider.item(id: specialID)
        XCTAssertTrue(special.isPlayed)
        XCTAssertEqual(special.unwatchedEpisodeCount, 0)
        let partial = try await provider.item(id: ShareCatalogID.series(seriesKey))
        XCTAssertEqual(partial.unwatchedEpisodeCount, 4)
        XCTAssertEqual(partial.playedPercentage, 0.2)
        let records = await makeWatchStore(durable).recordsSnapshot()
        XCTAssertEqual(Set(records.keys), Set(extraPaths.map(ShareCatalogID.file)))
        XCTAssertTrue(records.values.allSatisfy(\.played))

        try await provider.setPlayed(false, itemID: specialID)
        let unwatched = try await provider.item(id: specialID)
        XCTAssertFalse(unwatched.isPlayed)
        XCTAssertEqual(unwatched.unwatchedEpisodeCount, 1)
        let after = await makeWatchStore(durable).recordsSnapshot()
        XCTAssertTrue(after.values.allSatisfy { !$0.played })
    }

    func testContainerActionPreservesNewerEpisodeAndKnownRuntime() async throws {
        let durable = try makeDurableStore()
        let catalog = await makeCatalog()
        let provider = ShareProvider(session: makeSession(), durableLocalStateStore: durable, catalogStore: catalog)
        let now = Date()
        let newer = now.addingTimeInterval(60)
        let newestEpisode = fileID(season: 1, episode: 1)
        try await provider.reportPlayback(
            PlaybackProgress(itemID: newestEpisode, playSessionID: "test", positionSeconds: 100,
                             isPaused: true, durationSeconds: 1_000), event: .pause
        )
        try await provider.setResumePosition(200, itemID: newestEpisode, capturedAt: newer)
        try await provider.setPlayed(true, itemID: ShareCatalogID.series(seriesKey), capturedAt: now)
        try await provider.setResumePosition(0, itemID: ShareCatalogID.series(seriesKey), capturedAt: now)
        let state = await makeWatchStore(durable).recordsSnapshot()
        XCTAssertEqual(state.count, 4)
        XCTAssertEqual(state[newestEpisode]?.position, 200)
        XCTAssertEqual(state[newestEpisode]?.duration, 1_000)
        XCTAssertEqual(state[newestEpisode]?.updatedAt, newer)
        XCTAssertEqual(state.values.filter(\.played).count, 3)
        let show = try await provider.item(id: ShareCatalogID.series(seriesKey))
        XCTAssertEqual(show.unwatchedEpisodeCount, 1)
        XCTAssertFalse(show.isPlayed)

        try await provider.setPlayed(true, itemID: ShareCatalogID.series(seriesKey), capturedAt: newer.addingTimeInterval(1))
        let after = await makeWatchStore(durable).recordsSnapshot()
        XCTAssertEqual(after[newestEpisode]?.duration, 1_000)
        XCTAssertEqual(after[newestEpisode]?.position, 0)
        XCTAssertTrue(after.values.allSatisfy(\.played))
    }

    func testEmptyContainerActionDoesNotPersistSyntheticRecord() async throws {
        let durable = try makeDurableStore()
        let catalog = await makeCatalog()
        let provider = ShareProvider(session: makeSession(), durableLocalStateStore: durable, catalogStore: catalog)
        try await provider.setPlayed(true, itemID: ShareCatalogID.series("missing"))
        try await provider.setPlayed(true, itemID: ShareCatalogID.season(seriesKey, 99))
        try await provider.setResumePosition(0, itemID: ShareCatalogID.series("missing"), capturedAt: Date())
        try await provider.setResumePosition(0, itemID: ShareCatalogID.season(seriesKey, 99), capturedAt: Date())
        let records = await makeWatchStore(durable).recordsSnapshot()
        XCTAssertTrue(records.isEmpty)
    }

    func testWholeShowActionStaysWithinProfileAndSeries() async throws {
        let durable = try makeDurableStore()
        let catalog = await makeCatalog()
        let provider = ShareProvider(session: makeSession(), durableLocalStateStore: durable, catalogStore: catalog)
        let otherProfile = ShareProvider(
            session: makeSession(),
            localMediaContext: .init(accountID: makeSession().server.id, profileID: "other", profileNamespace: "other"),
            durableLocalStateStore: durable, catalogStore: catalog
        )
        try await provider.setResumePosition(75, itemID: "f:unrelated.mkv", capturedAt: Date())
        try await provider.setPlayed(true, itemID: ShareCatalogID.series(seriesKey))
        let otherShow = try await otherProfile.item(id: ShareCatalogID.series(seriesKey))
        XCTAssertFalse(otherShow.isPlayed)
        XCTAssertEqual(otherShow.unwatchedEpisodeCount, 4)
        let records = await makeWatchStore(durable).recordsSnapshot()
        XCTAssertEqual(records["f:unrelated.mkv"]?.position, 75)
        XCTAssertEqual(records["f:unrelated.mkv"]?.played, false)
    }
}
