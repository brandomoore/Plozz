import CoreModels
import Foundation
import SQLite3
import XCTest
@testable import FeatureLiveTVCore
@testable import ProviderIPTV

final class StorageSuspensionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    // A successful checkpoint does not prove that the WAL connection released
    // its main-file SHARED lock. Exclusive locking probes that actual lock.
    private func exclusiveAccess(_ url: URL) throws -> Int32 {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA locking_mode=EXCLUSIVE", nil, nil, nil), SQLITE_OK)
        let result = sqlite3_exec(handle, "BEGIN EXCLUSIVE", nil, nil, nil)
        if result == SQLITE_OK {
            XCTAssertEqual(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        }
        return result
    }

    func testIPTVSuspensionReleasesIdleLocksAndPreservesSavedCatalogAcrossResume() async throws {
        let directory = try directory()
        let lifecycle = ApplicationStorageLifecycle()
        let credential = try IPTVCredential(
            mode: .file, address: XCTUnwrap(URL(string: "https://example.test/list"))
        )
        let url = directory.appendingPathComponent(credential.identity.uuidString + ".sqlite")
        do {
            let saved = try IPTVCatalog(url: url, key: credential.catalogKey)
            try saved.insert(IPTVRecord(item: .init(
                id: "saved", title: "Saved", kind: .movie, libraryID: "movies"
            )))
            try saved.setState("playlist", "saved")
        }
        let client = try IPTVClient(
            credential: credential, directory: directory, storageLifecycle: lifecycle
        )
        try await client.authenticate()
        XCTAssertEqual(try exclusiveAccess(url), SQLITE_BUSY)
        await lifecycle.setApplicationActive(false, revision: 1)
        XCTAssertEqual(try exclusiveAccess(url), SQLITE_OK)
        do {
            try await client.authenticate()
            XCTFail("Inactive work must not reopen the database.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try exclusiveAccess(url), SQLITE_OK)
        await lifecycle.setApplicationActive(true, revision: 2)
        let record = try await client.record("saved")
        XCTAssertEqual(record.item.title, "Saved")
        await lifecycle.setApplicationActive(false, revision: 1)
        XCTAssertTrue(lifecycle.isActive, "An old suspension cannot override foreground activity.")
        await lifecycle.setApplicationActive(false, revision: 3)
        XCTAssertEqual(try exclusiveAccess(url), SQLITE_OK)
    }

    func testInactiveClientPreparesDirectoryWithoutOpeningItsDatabase() async throws {
        let directory = try directory().appendingPathComponent("client")
        let lifecycle = ApplicationStorageLifecycle()
        await lifecycle.setApplicationActive(false, revision: 1)
        let credential = try IPTVCredential(
            mode: .file, address: XCTUnwrap(URL(string: "https://example.test/list"))
        )
        let client = try IPTVClient(
            credential: credential, directory: directory, storageLifecycle: lifecycle
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let url = directory.appendingPathComponent(credential.identity.uuidString + ".sqlite")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        do {
            try await client.authenticate()
            XCTFail("An inactive client must not open storage.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testInterruptedImportCannotCommitOrDiscardANewerImport() async throws {
        let url = try directory().appendingPathComponent("catalog.sqlite")
        let lifecycle = ApplicationStorageLifecycle()
        let catalog = try IPTVCatalog(url: url, key: Data(repeating: 7, count: 32), storageLifecycle: lifecycle)
        try catalog.insert(IPTVRecord(item: .init(id: "saved", title: "Saved", kind: .movie)))
        let interrupted = try catalog.beginImport()
        for index in 0..<3_000 {
            try catalog.insert(IPTVRecord(item: .init(
                id: "incoming-\(index)", title: String(repeating: "x", count: 1_000), kind: .movie
            )), into: .incoming)
        }
        XCTAssertEqual(sqlite3_get_autocommit(catalog.db), 1)
        XCTAssertEqual(sqlite3_txn_state(catalog.db, "main"), SQLITE_TXN_NONE)
        XCTAssertEqual(try exclusiveAccess(url), SQLITE_BUSY)
        await lifecycle.setApplicationActive(false, revision: 1)
        try catalog.closeForSuspension()
        XCTAssertNil(catalog.db)
        XCTAssertEqual(try exclusiveAccess(url), SQLITE_OK)
        XCTAssertThrowsError(try catalog.checkImport(interrupted)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try catalog.record("saved")) { XCTAssertTrue($0 is CancellationError) }
        await lifecycle.setApplicationActive(true, revision: 2)
        XCTAssertEqual(try catalog.record("saved").item.title, "Saved")
        let next = try catalog.beginImport()
        try catalog.insert(IPTVRecord(item: .init(id: "next", title: "Next", kind: .movie)), into: .incoming)
        catalog.discardImport(interrupted)
        try catalog.checkImport(next)
        try catalog.commitImport(library: nil, scope: "playlist")
        catalog.discardImport(next)
        XCTAssertEqual(try catalog.count(where: "1 = 1"), 1)
        XCTAssertEqual(try catalog.record("next").item.title, "Next")
        try catalog.closeForSuspension()
    }

    func testImportUnwindsBeforeQueuedCleanupAndCanRefreshAfterRapidResume() async throws {
        let url = try directory().appendingPathComponent("catalog.sqlite")
        let lifecycle = ApplicationStorageLifecycle()
        let catalog = try IPTVCatalog(url: url, key: Data(repeating: 7, count: 32), storageLifecycle: lifecycle)
        let abandoned = try catalog.beginImport()
        try catalog.insert(IPTVRecord(item: .init(id: "old", title: "Old", kind: .movie)), into: .incoming)
        await lifecycle.setApplicationActive(false, revision: 1)
        catalog.discardImport(abandoned)
        XCTAssertEqual(try exclusiveAccess(url), SQLITE_OK)
        await lifecycle.setApplicationActive(true, revision: 2)
        let next = try catalog.beginImport()
        try catalog.insert(IPTVRecord(item: .init(id: "new", title: "New", kind: .movie)), into: .incoming)
        catalog.discardImport(abandoned)
        try catalog.checkImport(next)
        try catalog.commitImport(library: nil, scope: "playlist")
        catalog.discardImport(next)
        XCTAssertEqual(try catalog.record("new").item.title, "New")
        try catalog.closeForSuspension()
    }

    func testSuspensionInterruptsRunningGuideTransactionEvenWhenCleanupTaskIsCancelled() async throws {
        let url = try directory().appendingPathComponent("guide.sqlite")
        let lifecycle = ApplicationStorageLifecycle()
        let cache = LiveTVIndexedCache(
            url: url, namespace: "profile", authorizationScope: "scope",
            secureStore: SuspensionSecureStore(), storageLifecycle: lifecycle
        )
        let playlist = try LiveTVPlaylistParser().parse(Data(
            "#EXTM3U\n#EXTINF:-1 tvg-id=\"g\",Station\nhttps://example.test/live\n".utf8
        ))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func document(_ count: Int) -> Data {
            let programs = (0..<count).map {
                "<programme channel=\"g\" start=\"20231114220000 +0000\" stop=\"20231114230000 +0000\"><title>Item \($0)</title></programme>"
            }.joined()
            return Data(("<tv><channel id=\"g\"><display-name>Station</display-name></channel>" + programs + "</tv>").utf8)
        }
        _ = try await cache.importGuide(data: document(1), sourceID: "guide", channels: playlist.channels,
                                        provider: nil, now: now)
        let entered = expectation(description: "Real transaction has staged ten thousand programs")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await cache.setGuideImportProgressForTesting { count in
            if count == 10_000 {
                entered.fulfill()
                guard release.wait(timeout: .now() + 10) == .success else { throw URLError(.timedOut) }
            }
        }
        let replacement = document(20_000)
        let importing = Task {
            try await cache.importGuide(
                data: replacement, sourceID: "guide", channels: playlist.channels, provider: nil, now: now
            )
        }
        await fulfillment(of: [entered], timeout: 10)
        let suspension = Task { await lifecycle.setApplicationActive(false, revision: 1) }
        let deadline = ContinuousClock.now + .seconds(2)
        while lifecycle.isActive, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(lifecycle.isActive)
        suspension.cancel()
        release.signal()
        do {
            _ = try await importing.value
            XCTFail("The running import must observe suspension, not just its task's cancellation.")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? LiveTVSourceImportError) == .cancelled)
        }
        await suspension.value
        await lifecycle.setApplicationActive(false, revision: 1)
        XCTAssertEqual(try exclusiveAccess(url), SQLITE_OK)
        await lifecycle.setApplicationActive(true, revision: 2)
        let saved = try await cache.guide(sourceID: "guide")
        XCTAssertEqual(saved?.programCount, 1, "The interrupted replacement must roll back.")
        await lifecycle.setApplicationActive(false, revision: 3)
    }

    func testGuideAndSnapshotStoresReleaseLocksAndRestoreDataAndRevisions() async throws {
        let directory = try directory()
        let lifecycle = ApplicationStorageLifecycle()
        let guideURL = directory.appendingPathComponent("guide.sqlite")
        let snapshotURL = directory.appendingPathComponent("snapshots.sqlite")
        let guide = LiveTVIndexedCache(
            url: guideURL, namespace: "profile", authorizationScope: "scope",
            secureStore: SuspensionSecureStore(), storageLifecycle: lifecycle
        )
        let snapshots = LibraryChannelSnapshotStore(databaseURL: snapshotURL, storageLifecycle: lifecycle)
        let source = LiveTVPlaylistSource(
            id: "source", name: "Source", playlistURL: try XCTUnwrap(URL(string: "https://example.test/list"))
        )
        let playlist = try LiveTVPlaylistParser().parse(Data(
            "#EXTM3U\n#EXTINF:-1,Station\nhttps://example.test/live\n".utf8
        ))
        try await guide.storePlaylist(playlist, source: source, now: Date())
        let item = try LibraryChannelItem(
            item: MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 60),
            library: .init(accountID: "account", libraryID: "movies"), serverID: "server", userID: "user"
        )
        let snapshot = try LibraryChannelSnapshot(items: [item], createdAt: Date())
        try await snapshots.insert(snapshot, profileID: "profile")
        let guideRevision = try await guide.portableSyncRevision(configuration: .init(playlists: [source]))
        let snapshotRevision = try await snapshots.changeRevision()
        XCTAssertEqual(try exclusiveAccess(guideURL), SQLITE_BUSY)
        XCTAssertEqual(try exclusiveAccess(snapshotURL), SQLITE_BUSY)
        await lifecycle.setApplicationActive(false, revision: 1)
        for url in [guideURL, snapshotURL] { XCTAssertEqual(try exclusiveAccess(url), SQLITE_OK) }
        do {
            _ = try await guide.playlist(source: source)
            XCTFail("Late guide work must not reopen storage.")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await snapshots.snapshot(id: snapshot.id, profileID: "profile")
            XCTFail("Late snapshot work must not reopen storage.")
        } catch { XCTAssertTrue(error is CancellationError) }
        let late = LibraryChannelSnapshotStore(databaseURL: snapshotURL, storageLifecycle: lifecycle)
        do {
            _ = try await late.changeRevision()
            XCTFail("A store created while inactive must also be fenced.")
        } catch { XCTAssertTrue(error is CancellationError) }
        for url in [guideURL, snapshotURL] { XCTAssertEqual(try exclusiveAccess(url), SQLITE_OK) }
        await lifecycle.setApplicationActive(true, revision: 2)
        let restoredPlaylist = try await guide.playlist(source: source)
        let restoredSnapshot = try await snapshots.snapshot(id: snapshot.id, profileID: "profile")
        XCTAssertEqual(restoredPlaylist?.channels.count, 1)
        XCTAssertEqual(restoredSnapshot, snapshot)
        let resumedGuideRevision = try await guide.portableSyncRevision(configuration: .init(playlists: [source]))
        let resumedSnapshotRevision = try await snapshots.changeRevision()
        XCTAssertNotEqual(resumedGuideRevision, guideRevision)
        XCTAssertNotEqual(resumedSnapshotRevision, snapshotRevision)
        await lifecycle.setApplicationActive(false, revision: 3)
        for url in [guideURL, snapshotURL] { XCTAssertEqual(try exclusiveAccess(url), SQLITE_OK) }
    }
}

private final class SuspensionSecureStore: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func readString(for key: String) throws -> String? { lock.withLock { values[key] } }
    func string(for key: String) -> String? { lock.withLock { values[key] } }
    func setString(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    func removeValue(for key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
}
