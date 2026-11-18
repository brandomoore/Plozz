import CoreModels
import Foundation
import SQLite3
import XCTest
@testable import ProviderIPTV

final class IPTVCatalogStorageTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)

    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("catalog.sqlite")
    }

    private func importRows(_ count: Int, into catalog: IPTVCatalog) throws {
        try catalog.beginImport()
        defer { catalog.discardImport() }
        for index in 0..<count {
            try catalog.insert(IPTVRecord(item: .init(
                id: "movie-\(index)", title: String(repeating: "x", count: 1_000),
                kind: .movie, libraryID: "movies"
            )), into: .incoming)
        }
        try catalog.commitImport(library: nil, scope: "playlist")
    }

    private func walBytes(_ url: URL) throws -> Int {
        try URL(fileURLWithPath: url.path + "-wal").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    func testPausedStagingAndFailedCommitLeaveNoMainDatabaseTransactionOrBusyStatement() throws {
        let url = try location()
        let catalog = try IPTVCatalog(url: url, key: key)
        try importRows(1, into: catalog)
        let revision = try XCTUnwrap(catalog.state("playlist-revision"))
        let db = try XCTUnwrap(catalog.db)
        try catalog.beginImport()
        defer { catalog.discardImport() }
        for index in 0..<3_000 {
            try catalog.insert(IPTVRecord(item: .init(
                id: "incoming-\(index)", title: String(repeating: "x", count: 1_000),
                kind: .movie, libraryID: "movies"
            )), into: .incoming)
        }
        XCTAssertEqual(sqlite3_get_autocommit(db), 1)
        XCTAssertEqual(sqlite3_txn_state(db, "main"), SQLITE_TXN_NONE)
        var statement = sqlite3_next_stmt(db, nil)
        while let current = statement {
            XCTAssertEqual(sqlite3_stmt_busy(current), 0)
            statement = sqlite3_next_stmt(db, current)
        }
        var observer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &observer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let observerDB = try XCTUnwrap(observer)
        defer { sqlite3_close(observerDB) }
        XCTAssertEqual(sqlite3_wal_checkpoint_v2(observerDB, "main", SQLITE_CHECKPOINT_TRUNCATE, nil, nil), SQLITE_OK)

        enum InterruptedCommit: Error { case interrupted }
        XCTAssertThrowsError(try catalog.commitImport(library: nil, scope: "playlist") { copied in
            if copied > 0 { throw InterruptedCommit.interrupted }
        })
        XCTAssertEqual(sqlite3_get_autocommit(db), 1)
        XCTAssertEqual(sqlite3_txn_state(db, "main"), SQLITE_TXN_NONE)
        XCTAssertEqual(try catalog.count(where: "1 = 1"), 1)
        XCTAssertEqual(try catalog.record("movie-0").item.id, "movie-0")
        XCTAssertEqual(try catalog.state("playlist-revision"), revision)
        XCTAssertEqual(sqlite3_wal_checkpoint_v2(observerDB, "main", SQLITE_CHECKPOINT_TRUNCATE, nil, nil), SQLITE_OK)
    }

    func testImportRevisionChangesOnReplacementAndSurvivesReopen() throws {
        let url = try location()
        let catalog = try IPTVCatalog(url: url, key: key)
        try importRows(1, into: catalog)
        let first = try XCTUnwrap(catalog.state("playlist-revision"))
        try importRows(1, into: catalog)
        let replacement = try XCTUnwrap(catalog.state("playlist-revision"))
        XCTAssertNotEqual(replacement, first)
        let reopened = try IPTVCatalog(url: url, key: key)
        XCTAssertEqual(try reopened.state("playlist-revision"), replacement)
    }

    func testRepeatedImportsBoundTheRetainedJournalWithoutLosingRows() throws {
        let url = try location()
        let catalog = try IPTVCatalog(url: url, key: key)
        for count in [2_000, 2_000, 10, 2_000] {
            try importRows(count, into: catalog)
            XCTAssertLessThanOrEqual(try walBytes(url), IPTVCatalog.maximumRetainedJournalBytes)
            XCTAssertEqual(try catalog.count(where: "1 = 1"), count)
            XCTAssertEqual(try catalog.record("movie-0").item.title.count, 1_000)
        }
        let reopened = try IPTVCatalog(url: url, key: key)
        XCTAssertEqual(try reopened.count(where: "1 = 1"), 2_000)
        XCTAssertEqual(try reopened.record("movie-1999").item.title.count, 1_000)
    }

    func testPinnedReaderDefersReclamationWithoutBlockingOrInvalidatingItsSnapshot() throws {
        let url = try location()
        let catalog = try IPTVCatalog(url: url, key: key)
        try importRows(1, into: catalog)
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &reader, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(reader)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN; SELECT * FROM entries", nil, nil, nil), SQLITE_OK)
        try importRows(2_000, into: catalog)
        XCTAssertGreaterThan(try walBytes(url), IPTVCatalog.maximumRetainedJournalBytes)
        let start = ContinuousClock.now
        catalog.reclaimJournal()
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM entries", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
        sqlite3_finalize(statement)
        XCTAssertEqual(try catalog.count(where: "1 = 1"), 2_000)
        XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
        catalog.reclaimJournal()
        XCTAssertLessThanOrEqual(try walBytes(url), IPTVCatalog.maximumRetainedJournalBytes)
        XCTAssertEqual(try catalog.record("movie-1999").item.title.count, 1_000)
    }

    func testOpeningLegacyOversizedJournalCanReclaimItWithoutRedownloading() throws {
        let url = try location()
        let legacy = try IPTVCatalog(url: url, key: key)
        try legacy.execute("PRAGMA wal_autocheckpoint=0; PRAGMA journal_size_limit=-1; BEGIN IMMEDIATE")
        for index in 0..<2_000 {
            try legacy.insert(IPTVRecord(item: .init(
                id: "movie-\(index)", title: String(repeating: "x", count: 1_000), kind: .movie
            )))
        }
        try legacy.execute("COMMIT")
        XCTAssertGreaterThan(try walBytes(url), IPTVCatalog.maximumRetainedJournalBytes)
        let opened = try IPTVCatalog(url: url, key: key)
        opened.reclaimJournal()
        XCTAssertLessThanOrEqual(try walBytes(url), IPTVCatalog.maximumRetainedJournalBytes)
        XCTAssertEqual(try opened.record("movie-1999").item.title.count, 1_000)
    }

    func testDiscardedImportReclaimsRolledBackJournalAndPreservesCommittedRows() throws {
        let url = try location()
        let catalog = try IPTVCatalog(url: url, key: key)
        try importRows(1, into: catalog)
        try catalog.execute("PRAGMA wal_autocheckpoint=0; PRAGMA journal_size_limit=-1")
        try catalog.beginImport()
        try catalog.execute("BEGIN IMMEDIATE; DELETE FROM entries")
        for index in 0..<2_000 {
            try catalog.insert(IPTVRecord(item: .init(
                id: "partial-\(index)", title: String(repeating: "x", count: 1_000), kind: .movie
            )))
        }
        try catalog.execute("ROLLBACK")
        XCTAssertGreaterThan(try walBytes(url), IPTVCatalog.maximumRetainedJournalBytes)
        catalog.discardImport()
        XCTAssertLessThanOrEqual(try walBytes(url), IPTVCatalog.maximumRetainedJournalBytes)
        XCTAssertEqual(try catalog.count(where: "1 = 1"), 1)
        XCTAssertEqual(try catalog.record("movie-0").item.title.count, 1_000)
    }

    func testMaintenanceCheckpointPreservesRowsAndDefersToPinnedReaders() throws {
        let url = try location()
        let catalog = try IPTVCatalog(url: url, key: key)
        try importRows(1, into: catalog)
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &reader, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(reader)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN; SELECT * FROM entries", nil, nil, nil), SQLITE_OK)
        try importRows(2_000, into: catalog)
        XCTAssertFalse(catalog.reclaimJournal())
        let start = ContinuousClock.now
        XCTAssertFalse(try IPTVCatalogStorage.reclaimJournal(at: url))
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertGreaterThan(try walBytes(url), IPTVCatalog.maximumRetainedJournalBytes)
        XCTAssertEqual(sqlite3_exec(db, "COMMIT", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(try IPTVCatalogStorage.reclaimJournal(at: url))
        XCTAssertLessThanOrEqual(try walBytes(url), IPTVCatalog.maximumRetainedJournalBytes)
        XCTAssertEqual(try catalog.count(where: "1 = 1"), 2_000)
        XCTAssertEqual(try catalog.record("movie-1999").item.title.count, 1_000)
    }

    func testCleanupPreservesSavedAndRecentCatalogsButRemovesOldOrphansAndSidecars() throws {
        let root = try location().deletingLastPathComponent()
        let saved = try cacheFiles(in: root, old: true)
        let recent = try cacheFiles(in: root, old: false)
        let orphan = try cacheFiles(in: root, old: true)
        let removed = try cacheFiles(in: root, old: false)
        let sidecarOnly = try cacheFiles(in: root, old: true)
        try FileManager.default.removeItem(at: sidecarOnly)
        let unknown = root.appendingPathComponent("not-a-catalog.sqlite")
        try Data([1]).write(to: unknown)
        try IPTVCatalogStorage.removeUnreferenced(
            IPTVCatalogStorage.catalogs(in: root),
            retaining: [try identity(saved)], removed: [try identity(removed)], retryAfterClose: {}
        )
        for url in [saved, recent, unknown] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
        for url in [orphan, removed, sidecarOnly] {
            for suffix in ["", "-wal", "-shm"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix))
            }
        }
    }

    func testCleanupProtectsEveryConnectionUntilTheLastReleaseAndRechecksOwnership() throws {
        let root = try location().deletingLastPathComponent()
        let url = try cacheFiles(in: root, old: true)
        let retried = expectation(description: "Retry only after last connection closes")
        IPTVCatalogStorage.retain(url)
        IPTVCatalogStorage.retain(url)
        try IPTVCatalogStorage.removeUnreferenced(
            [url], retaining: [], removed: [], retryAfterClose: { retried.fulfill() }
        )
        IPTVCatalogStorage.release(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        IPTVCatalogStorage.release(url)
        wait(for: [retried], timeout: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Closing only requests a fresh inventory.")
        try IPTVCatalogStorage.removeUnreferenced(
            [url], retaining: [try identity(url)], removed: [], retryAfterClose: {}
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCleanupRejectsSymlinksAndNeverTraversesUnknownDirectories() throws {
        let root = try location().deletingLastPathComponent()
        let target = root.appendingPathComponent("keep")
        try Data([7]).write(to: target)
        let url = root.appendingPathComponent(UUID().uuidString + ".sqlite")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try IPTVCatalogStorage.removeUnreferenced(
            [url], retaining: [], removed: [try identity(url)], retryAfterClose: {}
        ))
        XCTAssertEqual(try Data(contentsOf: target), Data([7]))
        let nested = root.appendingPathComponent(UUID().uuidString + ".sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        XCTAssertThrowsError(try IPTVCatalogStorage.removeUnreferenced(
            [nested], retaining: [], removed: [try identity(nested)], retryAfterClose: {}
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    private func identity(_ url: URL) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: url.deletingPathExtension().lastPathComponent))
    }

    private func cacheFiles(in root: URL, old: Bool) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            try Data([1]).write(to: URL(fileURLWithPath: path))
            if old {
                let date = Date(timeIntervalSinceNow: -172_800)
                try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: path)
            }
        }
        return url
    }
}
