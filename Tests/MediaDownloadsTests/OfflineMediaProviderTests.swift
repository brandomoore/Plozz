import XCTest
import CoreModels
@testable import MediaDownloads

final class OfflineMediaProviderTests: XCTestCase {
    private func account(_ id: String = "account1") -> Account {
        Account(
            id: id,
            server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://server.example")!, provider: .plex),
            userID: "viewer", userName: "Viewer", deviceID: "device"
        )
    }

    private func pin(
        _ item: MediaItem, registry: DownloadedMediaRegistry, root: URL,
        version: String = "download", status: DownloadStatus = .completed, fileExists: Bool = true,
        sourceUserID: String? = nil
    ) async throws -> DownloadedMediaRecord {
        var record = try DownloadTestFactory.record(
            identity: .external(source: "test", value: item.id), versionID: version, status: status
        )
        record.snapshot = PinnedMediaSnapshot(item: item, sourceUserID: sourceUserID)
        _ = try await registry.beginDownload(record)
        if fileExists {
            let file = try FixedDownloadStorageLocator(root: root).pinnedFileURL(for: record)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("local media".utf8).write(to: file)
        }
        return record
    }

    func testCatalogExcludesMissingIncompleteAndOtherAccountDownloads() async throws {
        let root = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let provider = OfflineMediaProvider(
            account: account(), registry: registry, storage: FixedDownloadStorageLocator(root: root), authorize: {}
        )
        for (index, status, file, source) in [
            (1, DownloadStatus.completed, true, "account1"),
            (2, .queued, true, "account1"),
            (3, .completed, false, "account1"),
            (4, .completed, true, "account2")
        ] {
            var item = DownloadTestFactory.movie(imdb: "tt\(index)")
            item.sourceAccountID = source
            _ = try await pin(item, registry: registry, root: root, status: status, fileExists: file)
        }
        let latest = try await provider.latest(limit: 100)
        XCTAssertEqual(latest.map(\.id), ["srv-tt1"])
        let search = try await provider.search(query: "Matrix", limit: 100)
        XCTAssertEqual(search.map(\.id), latest.map(\.id))
        let request = try await provider.playbackInfo(for: "srv-tt1")
        XCTAssertEqual(request.streamURL?.isFileURL, true)
        XCTAssertNil(provider.reauthenticatedImageURL(URL(string: "https://server.example/art")!, maxWidth: nil))
    }

    func testSeriesContainsOnlyDownloadedSeasonsAndEpisodes() async throws {
        let root = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let provider = OfflineMediaProvider(
            account: account(), registry: registry, storage: FixedDownloadStorageLocator(root: root), authorize: {}
        )
        for number in [1, 3] {
            let item = MediaItem(
                id: "episode\(number)", title: "Episode \(number)", kind: .episode,
                parentTitle: "Downloaded Show", seasonNumber: 2, episodeNumber: number,
                seriesID: "series", seasonID: "season2", providerIDs: ["tvdb": "\(number)"],
                sourceAccountID: "account1", libraryID: "shows"
            )
            _ = try await pin(item, registry: registry, root: root)
        }
        let libraries = try await provider.libraries()
        XCTAssertEqual(libraries.map(\.id), ["shows"])
        let shows = try await provider.children(of: "shows")
        XCTAssertEqual(shows.map(\.id), ["series"])
        let seasons = try await provider.children(of: "series")
        XCTAssertEqual(seasons.map(\.id), ["season2"])
        let episodes = try await provider.children(of: "season2")
        XCTAssertEqual(episodes.map(\.episodeNumber), [1, 3])
        let page = try await provider.items(
            in: "shows", kind: .episode, page: .init(startIndex: 1, limit: 1)
        )
        XCTAssertEqual(page.totalCount, 2)
        XCTAssertEqual(page.items.map(\.id), ["episode3"])
    }

    func testPinnedPostersStayDistinctAndFillParentsAcrossEpisodesAndVersions() async throws {
        let root = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FixedDownloadStorageLocator(root: root)
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let provider = OfflineMediaProvider(
            account: account(), registry: registry, storage: storage, sourceUserID: "viewer", authorize: {}
        )
        let episode = MediaItem(
            id: "episode", title: "Episode", kind: .episode, parentTitle: "Show",
            seasonNumber: 1, episodeNumber: 1, seriesID: "show", seasonID: "season1",
            sourceAccountID: "account1", libraryID: "shows"
        )
        let saved = try await pin(episode, registry: registry, root: root, version: "older", sourceUserID: "viewer")
        let folder = try storage.pinnedFolderURL(forKey: saved.identityKey)
        let landscape = folder.appendingPathComponent("landscape.jpg")
        let poster = folder.appendingPathComponent("poster.jpg")
        try Data("landscape fixture".utf8).write(to: landscape)
        try Data("portrait fixture".utf8).write(to: poster)
        try await registry.setArtworkFileName(identityKey: saved.identityKey, fileName: "landscape.jpg")
        try await registry.setArtworkFileName(identityKey: saved.identityKey, fileName: "poster.jpg", role: .poster)
        _ = try await pin(episode, registry: registry, root: root, version: "newer", sourceUserID: "viewer")
        var sibling = episode
        sibling.id = "sibling"
        sibling.seasonID = "season2"
        sibling.seasonNumber = 2
        let missing = try await pin(sibling, registry: registry, root: root, sourceUserID: "viewer")
        try await registry.setArtworkFileName(
            identityKey: missing.identityKey, fileName: "missing.jpg", role: .poster
        )

        let show = try await provider.item(id: "show")
        let seasons = try await provider.children(of: "show")
        let episodes = try await provider.latest(limit: 10)
        let local = try await provider.item(id: "episode")
        XCTAssertEqual(show.posterURL, poster)
        XCTAssertEqual(seasons.count, 2)
        XCTAssertTrue(seasons.allSatisfy { $0.posterURL == poster })
        XCTAssertEqual(episodes.count, 2)
        XCTAssertTrue(episodes.allSatisfy { $0.seriesPosterURL == poster })
        XCTAssertEqual(local.posterURL, landscape)
        XCTAssertEqual(Set(local.versions.map(\.id)), ["older", "newer"])
        let search = try await provider.search(query: "Show", limit: 10)
        XCTAssertEqual(search.first { $0.kind == .series }?.posterURL, poster)

        var movie = DownloadTestFactory.movie()
        movie.sourceAccountID = "account1"
        let movieRecord = try await pin(movie, registry: registry, root: root, sourceUserID: "viewer")
        let movieFolder = try storage.pinnedFolderURL(forKey: movieRecord.identityKey)
        let moviePoster = movieFolder.appendingPathComponent("poster.jpg")
        try Data("movie poster".utf8).write(to: moviePoster)
        try await registry.setArtworkFileName(
            identityKey: movieRecord.identityKey, fileName: "poster.jpg", role: .poster
        )
        let localMovie = try await provider.item(id: movie.id)
        XCTAssertEqual(localMovie.posterURL, moviePoster)
        XCTAssertNil(localMovie.seriesPosterURL)
        XCTAssertTrue([show.posterURL, local.posterURL, local.seriesPosterURL, localMovie.posterURL]
            .allSatisfy { $0?.isFileURL == true })
    }

    func testCatalogAndProgressAreFencedToTheAuthenticatedServerUser() async throws {
        let root = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        var item = DownloadTestFactory.movie()
        item.sourceAccountID = "account1"
        item.libraryID = "movies"
        let current = try await pin(item, registry: registry, root: root, version: "current", sourceUserID: "viewer")
        let another = try await pin(item, registry: registry, root: root, version: "another", sourceUserID: "other")
        let legacy = try await pin(item, registry: registry, root: root, version: "legacy")
        let provider = OfflineMediaProvider(
            account: account(), registry: registry, storage: FixedDownloadStorageLocator(root: root),
            sourceUserID: "viewer",
            libraries: [.init(id: "movies", title: "My Movies", kind: .movie)], authorize: {}
        )
        let libraries = try await provider.libraries()
        XCTAssertEqual(libraries.first?.title, "My Movies")
        let downloaded = try await provider.item(id: item.id)
        XCTAssertEqual(downloaded.versions.map(\.id), ["current"])
        try await provider.reportPlayback(
            .init(itemID: item.id, playSessionID: nil, positionSeconds: 30, isPaused: false), event: .progress
        )
        let records = await registry.all()
        XCTAssertEqual(records.first { $0.identityKey == current.identityKey }?.snapshot.resumePosition, 30)
        XCTAssertNil(records.first { $0.identityKey == another.identityKey }?.snapshot.resumePosition)
        XCTAssertNil(records.first { $0.identityKey == legacy.identityKey }?.snapshot.resumePosition)
        let resolver = RegistryOfflinePlaybackResolver(
            registry: registry, storage: FixedDownloadStorageLocator(root: root),
            authorizesRecord: { $0.snapshot.sourceUserID == "viewer" }
        )
        OfflineMode.shared.setEnabled(true)
        defer { OfflineMode.shared.setEnabled(false) }
        let wrongVersion = await resolver.localPlaybackURL(for: item, versionID: "another")
        XCTAssertNil(wrongVersion)
        let correctVersion = await resolver.localPlaybackURL(for: item, versionID: "current")
        XCTAssertNotNil(correctVersion)
    }

    func testAnAuthorizationFailureCannotReturnCachedLocalContent() async throws {
        let root = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        var item = DownloadTestFactory.movie()
        item.sourceAccountID = "account1"
        _ = try await pin(item, registry: registry, root: root)
        let provider = OfflineMediaProvider(
            account: account(), registry: registry, storage: FixedDownloadStorageLocator(root: root),
            authorize: { throw AppError.unauthorized }
        )
        do {
            _ = try await provider.latest(limit: 10)
            XCTFail("Locked or superseded profiles must not receive the catalog.")
        } catch { XCTAssertEqual(error as? AppError, .unauthorized) }
    }

    func testPlaybackProgressAndExactVersionRemainLocal() async throws {
        let root = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let provider = OfflineMediaProvider(
            account: account(), registry: registry, storage: FixedDownloadStorageLocator(root: root), authorize: {}
        )
        var item = DownloadTestFactory.movie()
        item.sourceAccountID = "account1"
        item.runtime = 100
        _ = try await pin(item, registry: registry, root: root, version: "hd")
        let uhd = try await pin(item, registry: registry, root: root, version: "uhd")
        let playback = try await provider.playbackInfo(for: item.id, mediaSourceID: "uhd", forceTranscode: false)
        XCTAssertEqual(playback.streamURL, try FixedDownloadStorageLocator(root: root).pinnedFileURL(for: uhd))
        try await provider.reportPlayback(
            .init(itemID: item.id, playSessionID: nil, positionSeconds: 30, isPaused: false), event: .progress
        )
        let resumed = try await provider.continueWatching(limit: 10)
        XCTAssertEqual(resumed.first?.resumePosition, 30)
        do {
            _ = try await provider.playbackInfo(for: item.id, mediaSourceID: "not-downloaded", forceTranscode: false)
            XCTFail("An unavailable version must not silently stream or substitute another version.")
        } catch { XCTAssertEqual(error as? AppError, .notFound) }
    }
}
