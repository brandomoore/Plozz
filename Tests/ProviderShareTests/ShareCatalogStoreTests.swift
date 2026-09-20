import XCTest
@testable import ProviderShare
import CoreModels
import SQLite3

/// Coverage for the SQLite-backed share catalog — the index that makes a share's
/// Recently Added / Search / Movies-TV-Anime libraries work without a live SMB
/// walk. These are the on-device questions a server never had to answer:
/// does "date added" stay first-discovery across re-scans, does the index survive
/// a relaunch, and do the id shapes resolve back to rich items?
final class ShareCatalogStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-share-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func movie(_ path: String, title: String, year: Int?) -> CatalogAsset {
        CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1_000,
                     modifiedAt: Date(), kind: .movie, library: .movies,
                     title: title, year: year, seriesTitle: nil, seriesKey: nil, season: nil, episode: nil)
    }

    private func episode(_ path: String, series: String, season: Int, episode: Int, library: CatalogLibrary = .tv) -> CatalogAsset {
        CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1_000,
                     modifiedAt: Date(), kind: .episode, library: library,
                     title: "Episode \(episode)", year: nil,
                     seriesTitle: series, seriesKey: ShareCatalogID.seriesKey(fromTitle: series),
                     season: season, episode: episode)
    }

    func testImmediateTransactionRollsBackWhenDeferredCommitFails() throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = CatalogConnection(
            url: directory.appendingPathComponent("commit-failure.sqlite")
        )
        XCTAssertTrue(connection.ensureOpen { _ in true })
        XCTAssertTrue(connection.exec("PRAGMA foreign_keys=ON;"))
        XCTAssertTrue(connection.exec("CREATE TABLE parent(id INTEGER PRIMARY KEY);"))
        XCTAssertTrue(connection.exec("""
            CREATE TABLE child(
              parent_id INTEGER,
              FOREIGN KEY(parent_id) REFERENCES parent(id)
                DEFERRABLE INITIALLY DEFERRED
            );
            """))

        let result = connection.immediateTransaction {
            connection.exec("INSERT INTO child(parent_id) VALUES(42);")
        }

        XCTAssertEqual(result, .commitFailed)
        XCTAssertFalse(connection.isInTransaction)
        var childCount = -1
        connection.query("SELECT COUNT(*) FROM child;") {
            childCount = Int(sqlite3_column_int64($0, 0))
        }
        XCTAssertEqual(childCount, 0)
        XCTAssertTrue(connection.withImmediateTransaction {
            connection.exec("INSERT INTO parent(id) VALUES(42);")
        })
    }

    func testImmediateTransactionRollsBackWhenExternalReaderBlocksCommit() throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("commit-lock.sqlite")
        let connection = CatalogConnection(url: url)
        XCTAssertTrue(connection.ensureOpen { _ in true })
        XCTAssertTrue(connection.exec("PRAGMA journal_mode=DELETE;"))
        XCTAssertTrue(connection.exec("CREATE TABLE values_table(value INTEGER);"))
        XCTAssertTrue(connection.exec("INSERT INTO values_table(value) VALUES(1);"))

        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &reader), SQLITE_OK)
        defer { sqlite3_close(reader) }
        XCTAssertEqual(sqlite3_exec(reader, "BEGIN;", nil, nil, nil), SQLITE_OK)
        var readerStatement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                reader,
                "SELECT value FROM values_table;",
                -1,
                &readerStatement,
                nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(readerStatement), SQLITE_ROW)

        let result = connection.immediateTransaction {
            connection.exec("INSERT INTO values_table(value) VALUES(2);")
        }

        XCTAssertEqual(result, .commitFailed)
        XCTAssertFalse(connection.isInTransaction)
        XCTAssertEqual(sqlite3_finalize(readerStatement), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(reader, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        var values: [Int] = []
        connection.query("SELECT value FROM values_table ORDER BY value;") {
            values.append(Int(sqlite3_column_int64($0, 0)))
        }
        XCTAssertEqual(values, [1])
        XCTAssertTrue(connection.withImmediateTransaction {
            connection.exec("INSERT INTO values_table(value) VALUES(3);")
        })
    }

    func testImmediateTransactionRejectsNestedBeginWithoutClosingOuterTransaction() throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = CatalogConnection(
            url: directory.appendingPathComponent("nested.sqlite")
        )
        XCTAssertTrue(connection.ensureOpen { _ in true })
        XCTAssertTrue(connection.exec("CREATE TABLE values_table(value INTEGER);"))
        var nestedResult: CatalogConnection.ImmediateTransactionResult?

        let outerResult = connection.immediateTransaction {
            nestedResult = connection.immediateTransaction {
                connection.exec("INSERT INTO values_table(value) VALUES(1);")
            }
            return connection.exec("INSERT INTO values_table(value) VALUES(2);")
        }

        XCTAssertEqual(nestedResult, .nestedTransaction)
        XCTAssertEqual(outerResult, .committed)
        var values: [Int] = []
        connection.query("SELECT value FROM values_table;") {
            values.append(Int(sqlite3_column_int64($0, 0)))
        }
        XCTAssertEqual(values, [2])
    }

    @MainActor
    func testCancellationInterruptsSQLRollsBackAndLeavesConnectionReusable() async {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = CatalogConnection(
            url: directory.appendingPathComponent("cancelled-write.sqlite")
        )
        XCTAssertTrue(connection.ensureOpen { _ in true })
        XCTAssertTrue(connection.exec("CREATE TABLE values_table(value INTEGER);"))
        var longSQLCompleted = true

        let result = await Task { @MainActor in
            connection.immediateTransaction {
                guard connection.exec(
                    "INSERT INTO values_table(value) VALUES(1);"
                ) else { return false }
                withUnsafeCurrentTask { $0?.cancel() }
                longSQLCompleted = connection.exec("""
                    WITH RECURSIVE sequence(value) AS (
                      VALUES(1)
                      UNION ALL
                      SELECT value + 1 FROM sequence WHERE value < 1000000
                    )
                    INSERT INTO values_table(value) SELECT value FROM sequence;
                    """)
                return longSQLCompleted
            }
        }.value

        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(longSQLCompleted)
        XCTAssertFalse(connection.isInTransaction)
        var count = -1
        connection.query("SELECT COUNT(*) FROM values_table;") {
            count = Int(sqlite3_column_int64($0, 0))
        }
        XCTAssertEqual(count, 0)
        XCTAssertTrue(connection.withImmediateTransaction {
            connection.exec("INSERT INTO values_table(value) VALUES(2);")
        })
    }

    func testCloseForSuspensionNeverFinalizesCallerOwnedStatement() throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = CatalogConnection(
            url: directory.appendingPathComponent("busy-close.sqlite")
        )
        XCTAssertTrue(connection.ensureOpen { _ in true })
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(connection.db, "SELECT 42;", -1, &statement, nil),
            SQLITE_OK
        )

        connection.setAccessSuspended(true)
        XCTAssertFalse(connection.closeForSuspension())
        XCTAssertNil(connection.db)
        XCTAssertFalse(connection.isClosed)
        XCTAssertFalse(connection.exec("SELECT 1;"))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(statement, 0), 42)
        XCTAssertEqual(sqlite3_finalize(statement), SQLITE_OK)
        connection.setAccessSuspended(false)
        XCTAssertNotNil(connection.db)
        XCTAssertTrue(connection.closeForSuspension())
        XCTAssertNil(connection.db)
        XCTAssertTrue(connection.isClosed)
    }

    func testContendedInitialOpenClosesAndRetriesAfterLockRelease() throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("contended-open.sqlite")
        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        defer { sqlite3_close(blocker) }
        XCTAssertEqual(
            sqlite3_exec(
                blocker,
                "CREATE TABLE legacy(value INTEGER); BEGIN IMMEDIATE;",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        let connection = CatalogConnection(url: url)

        XCTAssertFalse(connection.ensureOpen { _ in true })
        XCTAssertNil(connection.db)
        XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(connection.ensureOpen { _ in true })
        XCTAssertNotNil(connection.db)
    }

    @MainActor
    func testAlreadyCancelledEnsureOpenDoesNotCreateCatalogAndLaterTaskCanOpen() async {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalogDirectory = directory.appendingPathComponent("unopened", isDirectory: true)
        let url = catalogDirectory.appendingPathComponent("cancelled-open.sqlite")
        let connection = CatalogConnection(url: url)
        var migrationInvoked = false

        let cancelledAttempt = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return connection.ensureOpen { _ in
                migrationInvoked = true
                return true
            }
        }.value

        XCTAssertFalse(cancelledAttempt)
        XCTAssertFalse(migrationInvoked)
        XCTAssertTrue(connection.isClosed)
        XCTAssertNil(connection.db)
        XCTAssertEqual(connection.schemaMigrationAttemptCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let subsequentAttempt = await Task { @MainActor in
            connection.ensureOpen { _ in
                migrationInvoked = true
                return true
            }
        }.value

        XCTAssertTrue(subsequentAttempt)
        XCTAssertTrue(migrationInvoked)
        XCTAssertNotNil(connection.db)
        XCTAssertFalse(connection.isClosed)
        XCTAssertFalse(connection.isInTransaction)
        XCTAssertEqual(connection.schemaMigrationAttemptCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testCancelledEnsureOpenPreservesExistingHandleAndTransaction() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = CatalogConnection(
            url: directory.appendingPathComponent("cancelled-existing-open.sqlite")
        )
        XCTAssertTrue(connection.ensureOpen { _ in true })
        let originalHandle = try XCTUnwrap(connection.db)
        let migrationAttempts = connection.schemaMigrationAttemptCount
        XCTAssertTrue(connection.exec("BEGIN IMMEDIATE;"))

        let cancelledAttempt = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return connection.ensureOpen { _ in
                XCTFail("An already-open cancelled request must not run migration.")
                return true
            }
        }.value

        XCTAssertFalse(cancelledAttempt)
        XCTAssertEqual(connection.db, originalHandle)
        XCTAssertFalse(connection.isClosed)
        XCTAssertTrue(connection.isInTransaction)
        XCTAssertEqual(connection.schemaMigrationAttemptCount, migrationAttempts)
        XCTAssertTrue(connection.exec("ROLLBACK;"))
        XCTAssertFalse(connection.isInTransaction)
    }

    @MainActor
    func testCancelledInitialMigrationClosesAndRetries() async {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = CatalogConnection(
            url: directory.appendingPathComponent("cancelled-migration.sqlite")
        )

        let firstAttempt = await Task { @MainActor in
            connection.ensureOpen { opened in
                XCTAssertTrue(opened.exec(
                    "INSERT INTO meta(key,value) VALUES('cancelled-migration','discarded');"
                ))
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }.value

        XCTAssertFalse(firstAttempt)
        XCTAssertNil(connection.db)
        XCTAssertTrue(connection.isClosed)
        XCTAssertFalse(connection.isInTransaction)
        XCTAssertEqual(connection.schemaMigrationAttemptCount, 1)

        let subsequentAttempt = await Task { @MainActor in
            connection.ensureOpen { _ in true }
        }.value

        XCTAssertTrue(subsequentAttempt)
        XCTAssertNotNil(connection.db)
        XCTAssertFalse(connection.isInTransaction)
        XCTAssertEqual(connection.schemaMigrationAttemptCount, 2)
        var cancelledWriteCount = -1
        connection.query("SELECT COUNT(*) FROM meta WHERE key='cancelled-migration';") {
            cancelledWriteCount = Int(sqlite3_column_int64($0, 0))
        }
        XCTAssertEqual(cancelledWriteCount, 0)
    }

    func testSuspensionClosesCatalogAndStaleResumeCannotReopenIt() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountKey = "suspension-\(UUID().uuidString)"
        let store = ShareCatalogStore(accountKey: accountKey, directory: directory)
        await store.upsert(
            [movie("Movies/Film.mkv", title: "Film", year: 2026)],
            scanID: 1
        )
        let migrationAttempts = await store.schemaMigrationAttemptCountForTesting()
        let priorCheckpointSaved = await store.setMeta("resume_scan_id", "7")
        XCTAssertTrue(priorCheckpointSaved)

        let closed = await store.prepareForSuspension(revision: 2)
        let suspended = await store.isSuspendedForTesting()
        XCTAssertTrue(closed)
        XCTAssertTrue(suspended)
        XCTAssertTrue(
            tryCanAcquireImmediateWriteLock(at: catalogURL(accountKey: accountKey, in: directory))
        )

        let staleResumeAccepted = await store.resumeAfterSuspension(revision: 1)
        let staleResumeSuspended = await store.isSuspendedForTesting()
        XCTAssertFalse(staleResumeAccepted)
        XCTAssertTrue(staleResumeSuspended)

        let pendingRead = Task {
            await store.movies(offset: 0, limit: 10)
        }
        let readDidSuspend = await waitForSuspendedReadWaiters(1, in: store)
        XCTAssertTrue(readDidSuspend)
        XCTAssertTrue(
            tryCanAcquireImmediateWriteLock(at: catalogURL(accountKey: accountKey, in: directory))
        )

        let cancelledRead = Task {
            await store.movies(offset: 0, limit: 10)
        }
        let secondReadDidSuspend = await waitForSuspendedReadWaiters(2, in: store)
        XCTAssertTrue(secondReadDidSuspend)
        cancelledRead.cancel()
        let cancelledMovies = await cancelledRead.value
        XCTAssertTrue(cancelledMovies.isEmpty)
        let cancellationRemovedWaiter = await waitForSuspendedReadWaiters(1, in: store)
        XCTAssertTrue(cancellationRemovedWaiter)

        let resumeAccepted = await store.resumeAfterSuspension(revision: 3)
        let resumed = await store.isSuspendedForTesting()
        let resumedMovies = await pendingRead.value
        let resumedMigrationAttempts = await store.schemaMigrationAttemptCountForTesting()
        let preservedCheckpoint = await store.meta("resume_scan_id")
        XCTAssertTrue(resumeAccepted)
        XCTAssertFalse(resumed)
        XCTAssertEqual(resumedMovies.map(\.title), ["Film"])
        XCTAssertEqual(preservedCheckpoint, "7")
        XCTAssertEqual(resumedMigrationAttempts, migrationAttempts)
    }

    func testReopenRevalidatesSchemaAfterSuspendedCatalogIsEvicted() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountKey = "evicted-\(UUID().uuidString)"
        let url = catalogURL(accountKey: accountKey, in: directory)
        let store = ShareCatalogStore(accountKey: accountKey, directory: directory)
        await store.upsert(
            [movie("Movies/Before.mkv", title: "Before", year: 2026)],
            scanID: 1
        )
        let initialAttempts = await store.schemaMigrationAttemptCountForTesting()

        let suspended = await store.prepareForSuspension(revision: 1)
        XCTAssertTrue(suspended)
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.removeItem(at: candidate)
            }
        }
        var replacement: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &replacement), SQLITE_OK)
        let replacementDB = try XCTUnwrap(replacement)
        XCTAssertEqual(
            sqlite3_exec(replacementDB, "PRAGMA user_version=4;", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_close(replacementDB), SQLITE_OK)
        let resumed = await store.resumeAfterSuspension(revision: 2)
        XCTAssertTrue(resumed)

        let afterEviction = await store.movies(offset: 0, limit: 10)
        let reopenedAttempts = await store.schemaMigrationAttemptCountForTesting()
        XCTAssertTrue(afterEviction.isEmpty)
        XCTAssertEqual(reopenedAttempts, initialAttempts + 1)

        await store.upsert(
            [movie("Movies/After.mkv", title: "After", year: 2026)],
            scanID: 2
        )
        let rebuilt = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(rebuilt.map(\.title), ["After"])
    }

    func testReopenRecreatesEvictedCacheDirectory() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShareCatalogStore(accountKey: UUID().uuidString, directory: directory)
        await store.upsert([movie("Before.mkv", title: "Before", year: 2026)], scanID: 1)
        let suspended = await store.prepareForSuspension(revision: 1)
        XCTAssertTrue(suspended)
        try FileManager.default.removeItem(at: directory)
        let resumed = await store.resumeAfterSuspension(revision: 2)
        XCTAssertTrue(resumed)
        await store.upsert([movie("After.mkv", title: "After", year: 2026)], scanID: 2)
        let rebuilt = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(rebuilt.map(\.title), ["After"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSuspensionAtChunkBoundaryClosesAndFencesOldGeneration() async throws {
        let directory = tempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accountKey = "chunk-suspension-\(UUID().uuidString)"
        let gate = CatalogWriteChunkGate()
        let store = ShareCatalogStore(
            accountKey: accountKey,
            directory: directory,
            writeChunkBoundary: { await gate.pause() }
        )
        let generation = UUID()
        await store.activateScanGeneration(generation)
        let assets = (0..<450).map {
            movie("Movies/Film \($0).mkv", title: "Film \($0)", year: 2026)
        }

        let write = Task {
            await store.upsert(
                assets,
                scanID: 9,
                scanGeneration: generation
            )
        }
        await gate.waitUntilPaused()

        let checkpoint = ShareScanResumeCheckpoint(
            scanGeneration: generation,
            scanID: 9,
            frontierJSON: "queued-frontier",
            savedAt: 123
        )
        let closed = await store.prepareForSuspension(
            revision: 1,
            checkpoint: checkpoint
        )
        XCTAssertTrue(closed)
        let redundantlyClosed = await store.prepareForSuspension(revision: 2)
        XCTAssertTrue(redundantlyClosed)
        XCTAssertTrue(
            tryCanAcquireImmediateWriteLock(at: catalogURL(accountKey: accountKey, in: directory))
        )
        let lateCheckpointSaved = await store.setMeta(
            "resume_scan_id",
            "late",
            scanGeneration: generation
        )
        XCTAssertFalse(lateCheckpointSaved)
        let ordinaryWriteSaved = await store.setMeta(
            "last_full_scan_at",
            "wrong-generation-write",
            scanGeneration: generation
        )
        XCTAssertFalse(ordinaryWriteSaved)
        let url = catalogURL(accountKey: accountKey, in: directory)
        XCTAssertNil(try sqliteText(
            at: url,
            "SELECT value FROM meta WHERE key='resume_scan_id';"
        ))
        XCTAssertEqual(try sqliteInt(at: url, "SELECT COUNT(*) FROM assets;"), 200)
        XCTAssertTrue(tryCanAcquireImmediateWriteLock(at: url))

        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &blocker), SQLITE_OK)
        defer {
            if let blocker {
                sqlite3_close(blocker)
            }
        }
        XCTAssertEqual(
            sqlite3_exec(blocker, "BEGIN IMMEDIATE;", nil, nil, nil),
            SQLITE_OK
        )
        let blockedResumeAccepted = await store.resumeAfterSuspension(revision: 3)
        XCTAssertFalse(blockedResumeAccepted)
        let remainedSuspended = await store.isSuspendedForTesting()
        XCTAssertTrue(remainedSuspended)
        XCTAssertNil(try sqliteText(
            at: url,
            "SELECT value FROM meta WHERE key='resume_scan_id';"
        ))
        XCTAssertEqual(sqlite3_exec(blocker, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(blocker), SQLITE_OK)
        blocker = nil

        let resumeAccepted = await store.resumeAfterSuspension(revision: 3)
        XCTAssertTrue(resumeAccepted)
        await gate.open()
        await write.value

        let resumedCount = await store.movieCount()
        let persistedCheckpoint = await store.meta("resume_scan_id")
        let frontier = await store.meta("resume_frontier")
        let savedAt = await store.meta("resume_saved_at")
        let staleWriteSaved = await store.setMeta(
            "resume_frontier",
            "stale",
            scanGeneration: generation
        )
        XCTAssertEqual(resumedCount, 200)
        XCTAssertEqual(persistedCheckpoint, "9")
        XCTAssertEqual(frontier, "queued-frontier")
        XCTAssertEqual(savedAt.flatMap(Double.init), 123)
        XCTAssertFalse(staleWriteSaved)

        let replacementGeneration = UUID()
        await store.activateScanGeneration(replacementGeneration)
        let staleInvalidationAccepted = await store.invalidateScanGeneration(revision: 2)
        XCTAssertFalse(staleInvalidationAccepted)
        let retiredScanInvalidationAccepted = await store.invalidateScanGeneration(
            revision: 3, scanGeneration: generation
        )
        XCTAssertFalse(retiredScanInvalidationAccepted)
        let replacementWriteSaved = await store.setMeta(
            "replacement_generation_probe",
            "1",
            scanGeneration: replacementGeneration
        )
        XCTAssertTrue(replacementWriteSaved)
        let currentInvalidationAccepted = await store.invalidateScanGeneration(
            revision: 3, scanGeneration: replacementGeneration
        )
        XCTAssertTrue(currentInvalidationAccepted)
    }

    private func catalogURL(accountKey: String, in directory: URL) -> URL {
        let allowed = CharacterSet.alphanumerics
        let mapped = String(accountKey.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        })
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in accountKey.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return directory.appendingPathComponent(
            "share-catalog-\(mapped.prefix(80))-\(String(hash, radix: 16)).sqlite"
        )
    }

    private func sqliteInt(at url: URL, _ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 10)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 11)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 12)
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func sqliteText(at url: URL, _ sql: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 13)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 14)
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    private func tryCanAcquireImmediateWriteLock(at url: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { return false }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            return false
        }
        return sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) == SQLITE_OK
    }

    private func waitForSuspendedReadWaiters(
        _ expectedCount: Int,
        in store: ShareCatalogStore
    ) async -> Bool {
        for _ in 0..<10_000 {
            if await store.suspendedReadWaiterCountForTesting() == expectedCount {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private func createLegacyCatalog(
        in directory: URL,
        withPartialNormalizedTables: Bool = false
    ) throws -> URL {
        let url = catalogURL(accountKey: "legacy", in: directory)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 1)
        }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE assets(
          rel_path TEXT PRIMARY KEY, basename TEXT NOT NULL, size INTEGER NOT NULL,
          modified_at REAL NOT NULL, first_seen_at REAL NOT NULL, last_scan INTEGER NOT NULL,
          kind TEXT NOT NULL, library TEXT NOT NULL, title TEXT NOT NULL,
          sort_title TEXT NOT NULL, year INTEGER, series_title TEXT, series_key TEXT,
          season INTEGER, episode INTEGER
        );
        CREATE TABLE enrichment(
          item_id TEXT PRIMARY KEY, provider_ids_json TEXT, overview TEXT,
          genres_json TEXT, runtime REAL, poster_url TEXT, backdrop_url TEXT,
          logo_url TEXT, enriched_at REAL NOT NULL, enrich_version INTEGER NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0, title TEXT
        );
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO assets VALUES
          ('Movies/Rich.mkv','Rich.mkv',100,10,10,1,'movie','movies','Rich','rich',2001,NULL,NULL,NULL,NULL),
          ('Movies/Sparse.mkv','Sparse.mkv',100,20,20,1,'movie','movies','Sparse','sparse',2002,NULL,NULL,NULL,NULL),
          ('Movies/Exhausted.mkv','Exhausted.mkv',100,30,30,1,'movie','movies','Exhausted','exhausted',2003,NULL,NULL,NULL,NULL),
          ('Movies/Retry.mkv','Retry.mkv',100,40,40,1,'movie','movies','Retry','retry',2004,NULL,NULL,NULL,NULL),
          ('TV/Anime Show/S01E01.mkv','S01E01.mkv',100,50,50,1,'episode','tv','Episode 1','episode 1',NULL,'Anime Show','anime-show',1,1);
        INSERT INTO enrichment VALUES
          ('f:Movies/Rich.mkv','{"Tvdb":"42","Imdb":"tt0042","AniList":"84"}',
           'Rich overview','["Drama","Mystery"]',7200,
           'https://example.com/poster.jpg','https://example.com/backdrop.jpg',
           'https://example.com/logo.png',1234,7,0,'Rich Show'),
          ('f:Movies/Sparse.mkv',NULL,'Sparse overview',NULL,NULL,NULL,NULL,NULL,2345,7,0,NULL),
          ('f:Movies/Exhausted.mkv',NULL,NULL,NULL,NULL,NULL,NULL,NULL,3456,7,3,NULL),
          ('f:Movies/Retry.mkv',NULL,NULL,NULL,NULL,NULL,NULL,NULL,4567,7,2,NULL),
          ('series:anime-show','{"AniList":"100","Tvdb":"200"}',NULL,NULL,NULL,NULL,NULL,NULL,5678,7,0,'Anime Show');
        PRAGMA user_version=2;
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "ShareCatalogStoreTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }
        if withPartialNormalizedTables {
            let partialSQL = """
            CREATE TABLE metadata_values(
              item_id TEXT NOT NULL, field TEXT NOT NULL, source TEXT NOT NULL,
              value_json TEXT NOT NULL, source_url TEXT, source_revision TEXT,
              refreshed_at REAL, expires_at REAL,
              PRIMARY KEY(item_id, field, source)
            );
            CREATE TABLE metadata_enrichment_state(
              item_id TEXT PRIMARY KEY, local_version INTEGER, external_version INTEGER,
              local_attempts INTEGER NOT NULL DEFAULT 0,
              external_attempts INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO metadata_values VALUES
              ('f:Movies/Rich.mkv','overview','futureProvider','"Rich overview"',
               'https://metadata.example/rich',NULL,9999,NULL),
              ('f:Movies/Rich.mkv','posterURL','futureProvider','{',
               NULL,NULL,9999,NULL);
            INSERT INTO metadata_enrichment_state VALUES
              ('f:Movies/Rich.mkv',NULL,NULL,0,0);
            """
            guard sqlite3_exec(db, partialSQL, nil, nil, nil) == SQLITE_OK else {
                throw NSError(
                    domain: "ShareCatalogStoreTests",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
                )
            }
        }
        return url
    }

    private struct MigrationState {
        var userVersion: Int
        var metadataValueCount: Int
        var enrichmentStateCount: Int
        var richLegacyValueCount: Int
        var enrichedAt: Double
        var enrichVersion: Int
        var attempts: Int
        var externalVersion: Int
        var externalAttempts: Int
    }

    private func queryMigrationState(at url: URL) throws -> MigrationState {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw NSError(domain: "ShareCatalogStoreTests", code: 3)
        }
        defer { sqlite3_close(db) }

        func integer(_ sql: String) -> Int {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT e.enriched_at, e.enrich_version, e.attempts,
               s.external_version, s.external_attempts
        FROM enrichment e
        JOIN metadata_enrichment_state s ON s.item_id=e.item_id
        WHERE e.item_id='f:Movies/Rich.mkv';
        """, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
            sqlite3_finalize(stmt)
            throw NSError(domain: "ShareCatalogStoreTests", code: 4)
        }
        defer { sqlite3_finalize(stmt) }
        return MigrationState(
            userVersion: integer("PRAGMA user_version;"),
            metadataValueCount: integer("SELECT COUNT(*) FROM metadata_values;"),
            enrichmentStateCount: integer("SELECT COUNT(*) FROM metadata_enrichment_state;"),
            richLegacyValueCount: integer("""
                SELECT COUNT(*) FROM metadata_values
                WHERE item_id='f:Movies/Rich.mkv' AND source='legacyUnknown';
                """),
            enrichedAt: sqlite3_column_double(stmt, 0),
            enrichVersion: Int(sqlite3_column_int64(stmt, 1)),
            attempts: Int(sqlite3_column_int64(stmt, 2)),
            externalVersion: Int(sqlite3_column_int64(stmt, 3)),
            externalAttempts: Int(sqlite3_column_int64(stmt, 4))
        )
    }

    func testLegacyCatalogMigrationPreservesMetadataAndPendingState() async throws {
        let directory = tempDir()
        let url = try createLegacyCatalog(in: directory)
        let store = ShareCatalogStore(accountKey: "legacy", directory: directory)

        let loadedRich = await store.item(id: "f:Movies/Rich.mkv")
        let rich = try XCTUnwrap(loadedRich)
        XCTAssertEqual(rich.title, "Rich Show")
        XCTAssertEqual(rich.overview, "Rich overview")
        XCTAssertEqual(rich.genres, ["Drama", "Mystery"])
        XCTAssertEqual(rich.runtime, 7_200)
        XCTAssertEqual(rich.providerIDs, ["Tvdb": "42", "Imdb": "tt0042", "AniList": "84"])
        XCTAssertEqual(rich.metadataProvenance[.overview]?.source, .legacyUnknown)
        XCTAssertEqual(rich.metadataProvenance[.providerID("Tvdb")]?.source, .legacyUnknown)
        XCTAssertEqual(rich.metadataProvenance[.posterURL]?.source, .legacyUnknown)
        let anime = await store.item(id: "series:anime-show")
        XCTAssertEqual(anime?.providerIDs, ["AniList": "100", "Tvdb": "200"])
        XCTAssertEqual(
            anime?.metadataProvenance[.providerID("AniList")]?.source,
            .legacyUnknown
        )

        // The one-shot repair clears attempt counts that the fast-track path
        // inflated, so a previously "exhausted" miss returns to the backlog with
        // its real budget. Retry.mkv (under the cap) was always pending.
        let pending = await store.pendingEnrichment(version: 7, limit: 20)
        XCTAssertEqual(pending.map(\.itemID).sorted(), [
            "f:Movies/Exhausted.mkv",
            "f:Movies/Retry.mkv"
        ])

        let state = try queryMigrationState(at: url)
        // v3 adds local-artwork inventory without changing the legacy normalized
        // metadata/enrichment lanes.
        XCTAssertEqual(state.userVersion, 4)
        XCTAssertEqual(state.metadataValueCount, 14)
        XCTAssertEqual(state.enrichmentStateCount, 5)
        XCTAssertEqual(state.richLegacyValueCount, 10)
        XCTAssertEqual(state.enrichedAt, 1_234)
        XCTAssertEqual(state.enrichVersion, 7)
        XCTAssertEqual(state.attempts, 0)
        XCTAssertEqual(state.externalVersion, 7)
        XCTAssertEqual(state.externalAttempts, 0)

        let reopened = ShareCatalogStore(accountKey: "legacy", directory: directory)
        let reopenedPending = await reopened.pendingEnrichment(version: 7, limit: 20)
        XCTAssertEqual(reopenedPending.map(\.itemID).sorted(), [
            "f:Movies/Exhausted.mkv",
            "f:Movies/Retry.mkv"
        ])
        XCTAssertEqual(try queryMigrationState(at: url).userVersion, 4)
    }

    func testPartiallyMigratedCatalogDecodesValidProvenanceAndInfersMissingEntries() async throws {
        let directory = tempDir()
        _ = try createLegacyCatalog(in: directory, withPartialNormalizedTables: true)
        let store = ShareCatalogStore(accountKey: "legacy", directory: directory)

        let loadedRich = await store.item(id: "f:Movies/Rich.mkv")
        let rich = try XCTUnwrap(loadedRich)
        XCTAssertEqual(
            rich.metadataProvenance[.overview]?.source,
            MetadataSource(rawValue: "futureProvider")
        )
        XCTAssertEqual(rich.metadataProvenance[.posterURL]?.source, .legacyUnknown)
        XCTAssertEqual(rich.metadataProvenance[.providerID("Imdb")]?.source, .legacyUnknown)
        XCTAssertEqual(rich.overview, "Rich overview")
        XCTAssertEqual(rich.posterURL, URL(string: "https://example.com/poster.jpg"))
    }

    func testFailedNormalizedMigrationKeepsFlatCatalogReadableAndRejectsWrites() async throws {
        let directory = tempDir()
        let url = try createLegacyCatalog(in: directory)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TABLE metadata_values(item_id TEXT PRIMARY KEY);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(db)

        let store = ShareCatalogStore(accountKey: "legacy", directory: directory)
        let loaded = await store.item(id: "f:Movies/Rich.mkv")
        let rich = try XCTUnwrap(loaded)
        XCTAssertEqual(rich.title, "Rich Show")
        XCTAssertEqual(rich.overview, "Rich overview")
        XCTAssertEqual(rich.providerIDs["Tvdb"], "42")
        XCTAssertEqual(rich.metadataProvenance[.overview]?.source, .legacyUnknown)
        let pending = await store.pendingEnrichment(version: 7, limit: 20)
        XCTAssertEqual(pending.map(\.itemID), ["f:Movies/Retry.mkv"])

        let writeAccepted = await store.saveEnrichment(
            itemID: "f:Movies/Rich.mkv",
            .init(overview: "Must not split the projection"),
            version: 7
        )
        XCTAssertFalse(writeAccepted)
        let unchanged = await store.item(id: "f:Movies/Rich.mkv")
        XCTAssertEqual(unchanged?.overview, "Rich overview")

        let failedAttempts = await store.schemaMigrationAttemptCountForTesting()
        let suspended = await store.prepareForSuspension(revision: 1)
        let resumed = await store.resumeAfterSuspension(revision: 2)
        XCTAssertTrue(suspended)
        XCTAssertTrue(resumed)
        let readableAfterRetry = await store.item(id: "f:Movies/Rich.mkv")
        let retriedAttempts = await store.schemaMigrationAttemptCountForTesting()
        XCTAssertEqual(readableAfterRetry?.overview, "Rich overview")
        XCTAssertEqual(retriedAttempts, failedAttempts + 1)
    }

    func testSourcedEnrichmentDualWritesAndRoundTripsExactAttribution() async throws {
        let directory = tempDir()
        let store = ShareCatalogStore(accountKey: "sourced", directory: directory)
        await store.upsert([
            movie("Movies/Sourced (2020).mkv", title: "Sourced", year: 2020)
        ], scanID: 1)
        let sourceURL = try XCTUnwrap(URL(string: "https://metadata.example/sourced"))
        let saved = await store.saveEnrichment(
            itemID: "f:Movies/Sourced (2020).mkv",
            .sourced(
                providerIDs: [
                    "Tvdb": SourcedValue(
                        value: "900",
                        source: .tvdb,
                        sourceURL: sourceURL
                    ),
                    "AniList": SourcedValue(
                        value: "901",
                        source: .anilist,
                        sourceURL: URL(string: "https://anilist.co/anime/901")
                    )
                ],
                overview: SourcedValue(
                    value: "Exact overview",
                    source: .tvmaze,
                    sourceURL: sourceURL
                ),
                posterURL: SourcedValue(
                    value: try XCTUnwrap(URL(string: "https://example.com/sourced.jpg")),
                    source: .tmdb,
                    sourceURL: sourceURL
                ),
                title: SourcedValue(
                    value: "Sourced Show",
                    source: .tvdb,
                    sourceURL: sourceURL
                )
            ),
            version: 7,
            now: Date(timeIntervalSince1970: 8_000)
        )
        XCTAssertTrue(saved)

        let reopened = ShareCatalogStore(accountKey: "sourced", directory: directory)
        let loaded = await reopened.item(id: "f:Movies/Sourced (2020).mkv")
        let item = try XCTUnwrap(loaded)
        XCTAssertEqual(item.title, "Sourced Show")
        XCTAssertEqual(item.overview, "Exact overview")
        XCTAssertEqual(item.providerIDs["Tvdb"], "900")
        XCTAssertEqual(item.metadataProvenance[.title]?.source, .tvdb)
        XCTAssertEqual(item.metadataProvenance[.overview]?.source, .tvmaze)
        XCTAssertEqual(item.metadataProvenance[.posterURL]?.source, .tmdb)
        XCTAssertEqual(item.metadataProvenance[.providerID("AniList")]?.source, .anilist)
        XCTAssertEqual(item.metadataProvenance[.title]?.sourceURL, sourceURL)
    }

    func testAnimeClassificationCommitsWithFlatAndNormalizedEnrichment() async throws {
        let accountKey = "atomic-anime"
        let directory = tempDir()
        let store = ShareCatalogStore(accountKey: accountKey, directory: directory)
        let series = "Atomic Anime"
        let seriesKey = ShareCatalogID.seriesKey(fromTitle: series)
        let seriesID = ShareCatalogID.series(seriesKey)
        await store.upsert([
            episode("TV/Atomic Anime/S01E01.mkv", series: series, season: 1, episode: 1)
        ], scanID: 1)

        let saved = await store.saveEnrichment(
            itemID: seriesID,
            .init(providerIDs: ["AniList": "100"]),
            version: 7
        )
        XCTAssertTrue(saved)
        let tvSeries = await store.series(in: .tv, offset: 0, limit: 10)
        let animeSeries = await store.series(in: .anime, offset: 0, limit: 10)
        XCTAssertTrue(tvSeries.isEmpty)
        XCTAssertEqual(animeSeries.count, 1)

        let url = catalogURL(accountKey: accountKey, in: directory)
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT COUNT(*) FROM assets
            WHERE series_key='\(seriesKey)' AND library='anime';
            """), 1)
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT COUNT(*) FROM enrichment WHERE item_id='\(seriesID)';
            """), 1)
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT COUNT(*) FROM metadata_values WHERE item_id='\(seriesID)';
            """), 1)
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT COUNT(*) FROM metadata_enrichment_state WHERE item_id='\(seriesID)';
            """), 1)
    }

    func testStrongIDReconciliationDeletesLoserFromEveryMetadataTable() async throws {
        let accountKey = "atomic-merge"
        let directory = tempDir()
        let store = ShareCatalogStore(accountKey: accountKey, directory: directory)
        let loserKey = ShareCatalogID.seriesKey(fromTitle: "Peaky Blinder")
        let canonicalKey = ShareCatalogID.seriesKey(fromTitle: "Peaky Blinders")
        await store.upsert([
            episode("TV/Peaky Blinder/S01E01.mkv", series: "Peaky Blinder", season: 1, episode: 1),
            episode("TV/Peaky Blinders/S01E01.mkv", series: "Peaky Blinders", season: 1, episode: 1)
        ], scanID: 1)

        let loserSaved = await store.saveEnrichment(
            itemID: ShareCatalogID.series(loserKey),
            .init(providerIDs: ["Tvdb": "270261"], title: "Peaky Blinders"),
            version: 7
        )
        let canonicalSaved = await store.saveEnrichment(
            itemID: ShareCatalogID.series(canonicalKey),
            .init(providerIDs: ["Tvdb": "270261"], title: "Peaky Blinders"),
            version: 7
        )
        XCTAssertTrue(loserSaved)
        XCTAssertTrue(canonicalSaved)

        let url = catalogURL(accountKey: accountKey, in: directory)
        let loserID = ShareCatalogID.series(loserKey)
        let canonicalID = ShareCatalogID.series(canonicalKey)
        let series = await store.series(in: .tv, offset: 0, limit: 10)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT COUNT(*) FROM assets WHERE series_key='\(canonicalKey)';
            """), 2)
        XCTAssertEqual(try sqliteText(at: url, """
            SELECT canonical_key FROM series_merge WHERE alias_key='\(loserKey)';
            """), canonicalKey)
        for table in ["enrichment", "metadata_values", "metadata_enrichment_state"] {
            XCTAssertEqual(try sqliteInt(at: url, """
                SELECT COUNT(*) FROM \(table) WHERE item_id='\(loserID)';
                """), 0, "\(table) must not retain loser rows")
            XCTAssertGreaterThan(try sqliteInt(at: url, """
                SELECT COUNT(*) FROM \(table) WHERE item_id='\(canonicalID)';
                """), 0, "\(table) must retain the canonical row")
        }
    }

    func testDerivedMutationFailureRollsBackProjectionMetadataAssetsAndAliases() async throws {
        let accountKey = "atomic-rollback"
        let directory = tempDir()
        let initialStore = ShareCatalogStore(accountKey: accountKey, directory: directory)
        let loserKey = ShareCatalogID.seriesKey(fromTitle: "Peaky Blinder")
        let canonicalKey = ShareCatalogID.seriesKey(fromTitle: "Peaky Blinders")
        let loserID = ShareCatalogID.series(loserKey)
        await initialStore.upsert([
            episode("TV/Peaky Blinder/S01E01.mkv", series: "Peaky Blinder", season: 1, episode: 1),
            episode("TV/Peaky Blinders/S01E01.mkv", series: "Peaky Blinders", season: 1, episode: 1)
        ], scanID: 1)
        let canonicalSaved = await initialStore.saveEnrichment(
            itemID: ShareCatalogID.series(canonicalKey),
            .init(providerIDs: ["Tvdb": "270261"], title: "Peaky Blinders"),
            version: 7
        )
        let loserSaved = await initialStore.saveEnrichment(
            itemID: loserID,
            .init(providerIDs: ["Tvdb": "999"], title: "Peaky Blinder"),
            version: 7
        )
        XCTAssertTrue(canonicalSaved)
        XCTAssertTrue(loserSaved)

        let failingStore = ShareCatalogStore(
            accountKey: accountKey,
            directory: directory,
            enrichmentSaveFailurePoint: .afterDerivedCatalogMutations
        )
        let saved = await failingStore.saveEnrichment(
            itemID: loserID,
            .init(
                providerIDs: ["Tvdb": "270261", "AniList": "100"],
                title: "Peaky Blinders"
            ),
            version: 8
        )
        XCTAssertFalse(saved)

        let url = catalogURL(accountKey: accountKey, in: directory)
        let tvSeries = await failingStore.series(in: .tv, offset: 0, limit: 10)
        let animeSeries = await failingStore.series(in: .anime, offset: 0, limit: 10)
        XCTAssertEqual(tvSeries.count, 2)
        XCTAssertTrue(animeSeries.isEmpty)
        XCTAssertEqual(try sqliteInt(at: url, "SELECT COUNT(*) FROM series_merge;"), 0)
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT COUNT(*) FROM assets WHERE series_key='\(loserKey)' AND library='tv';
            """), 1)
        XCTAssertEqual(try sqliteText(at: url, """
            SELECT provider_ids_json FROM enrichment WHERE item_id='\(loserID)';
            """), "{\"Tvdb\":\"999\"}")
        XCTAssertEqual(try sqliteText(at: url, """
            SELECT value_json FROM metadata_values
            WHERE item_id='\(loserID)' AND field='providerID.tvdb';
            """), "\"999\"")
        XCTAssertEqual(try sqliteInt(at: url, """
            SELECT external_version FROM metadata_enrichment_state WHERE item_id='\(loserID)';
            """), 7)
    }

    /// A large first-time regroup may take a few hundred milliseconds overall,
    /// but must yield the catalog actor so a Movies-grid page can complete without
    /// waiting for the whole regroup.
    ///
    /// Measures the CONTENTION the regroup adds, not the browse's absolute wall
    /// time. The query itself costs ~200ms against a synthetic 15k-file catalog
    /// on an Apple TV simulator, so the original absolute 100ms bound could never
    /// pass no matter how well the actor interleaved — it was measuring query
    /// cost, not blocking. Comparing against a baseline taken on the same store
    /// isolates the thing the test is named for and makes it machine-independent.
    func testLargeMovieRegroupDoesNotBlockBrowseReads() async {
        let store = ShareCatalogStore(accountKey: "perf", directory: tempDir())
        let assets: [CatalogAsset] = (0..<15_000).map { index in
            let title = "Movie \(index / 2)"
            let year = 2000 + (index % 2)
            return CatalogAsset(
                relPath: "Movies/\(title) (\(year)) \(index).mkv",
                basename: "\(title) (\(year)) \(index).mkv",
                size: 1_000, modifiedAt: Date(), kind: .movie, library: .movies,
                title: title, year: year, seriesTitle: nil, seriesKey: nil,
                season: nil, episode: nil,
                movieKey: ShareCatalogID.movieKey(fromTitle: title, year: year),
                movieTitleKey: ShareCatalogID.seriesKey(fromTitle: title)
            )
        }
        await store.upsert(assets, scanID: 1)

        let clock = ContinuousClock()

        // Baseline: the same page, with nothing else touching the actor.
        let baselineStart = clock.now
        _ = await store.movies(offset: 0, limit: 60)
        let baseline = baselineStart.duration(to: clock.now)

        let rebuildStart = clock.now
        let rebuild = Task { await store.rebuildMovieGroups() }
        await Task.yield()
        let browseStart = clock.now
        _ = await store.movies(offset: 0, limit: 60)
        let browseDuration = browseStart.duration(to: clock.now)
        await rebuild.value
        let rebuildDuration = rebuildStart.duration(to: clock.now)

        // The regroup must be long enough for the browse to land inside it,
        // otherwise this proves nothing.
        XCTAssertGreaterThan(
            rebuildDuration,
            browseDuration,
            "regroup finished too quickly to prove interleaving"
        )
        XCTAssertLessThan(
            browseDuration - baseline,
            .milliseconds(100),
            """
            a browse read must interleave with a large end-of-scan regroup rather \
            than queue behind it (baseline: \(baseline), during regroup: \
            \(browseDuration), regroup total: \(rebuildDuration))
            """
        )
    }

    /// One unusually large directory must not hold the catalog actor for its
    /// entire insert; the chunked upsert yields between bounded transactions.
    func testLargeDirectoryUpsertDoesNotBlockBrowseReads() async {
        let store = ShareCatalogStore(accountKey: "perf-upsert", directory: tempDir())
        await store.upsert([movie("Movies/Existing (2000).mkv", title: "Existing", year: 2000)], scanID: 1)
        let assets: [CatalogAsset] = (0..<15_000).map { index in
            movie("Movies/New \(index) (2020).mkv", title: "New \(index)", year: 2020)
        }

        let upsert = Task { await store.upsert(assets, scanID: 2) }
        await Task.yield()
        let clock = ContinuousClock()
        let browseStart = clock.now
        _ = await store.movies(offset: 0, limit: 60)
        let browseDuration = browseStart.duration(to: clock.now)
        await upsert.value

        XCTAssertLessThan(
            browseDuration,
            .milliseconds(100),
            "browse reads must interleave with a giant directory upsert"
        )
    }

    func testEmptyUntilPopulated() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let empty = await store.isEmpty()
        XCTAssertTrue(empty)
        let counts = await store.libraryCounts()
        XCTAssertEqual(counts.movies, 0)
        XCTAssertEqual(counts.tvSeries, 0)
        XCTAssertEqual(counts.animeSeries, 0)
        let latest = await store.latest(limit: 10)
        XCTAssertTrue(latest.isEmpty)
    }

    func testLatestOrdersByFirstSeenDescending() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        await store.upsert([movie("Movies/A (2000).mkv", title: "A", year: 2000)], scanID: 1, now: t1)
        await store.upsert([movie("Movies/B (2001).mkv", title: "B", year: 2001)], scanID: 1, now: t2)
        let latest = await store.latest(limit: 10)
        XCTAssertEqual(latest.map(\.title), ["B", "A"], "newest first-seen should lead Recently Added")
    }

    func testFirstSeenPreservedAcrossReUpsert() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let t1 = Date(timeIntervalSince1970: 1_000)
        let t2 = Date(timeIntervalSince1970: 2_000)
        let t3 = Date(timeIntervalSince1970: 3_000)
        await store.upsert([movie("Movies/A (2000).mkv", title: "A", year: 2000)], scanID: 1, now: t1)
        await store.upsert([movie("Movies/B (2001).mkv", title: "B", year: 2001)], scanID: 1, now: t2)
        // Re-scan sees A again at t3 — its first_seen must NOT jump to t3.
        await store.upsert([movie("Movies/A (2000).mkv", title: "A", year: 2000)], scanID: 2, now: t3)
        let latest = await store.latest(limit: 10)
        XCTAssertEqual(latest.map(\.title), ["B", "A"], "a re-seen file keeps its original date added")
    }

    func testSeriesGroupingSeasonsAndEpisodes() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let key = ShareCatalogID.seriesKey(fromTitle: "Breaking Bad")
        await store.upsert([
            episode("TV/Breaking Bad/S01/E01.mkv", series: "Breaking Bad", season: 1, episode: 1),
            episode("TV/Breaking Bad/S01/E02.mkv", series: "Breaking Bad", season: 1, episode: 2),
            episode("TV/Breaking Bad/S02/E01.mkv", series: "Breaking Bad", season: 2, episode: 1),
        ], scanID: 1)

        let series = await store.series(in: .tv, offset: 0, limit: 10)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series.first?.kind, .series)
        XCTAssertEqual(series.first?.id, ShareCatalogID.series(key))

        let seasons = await store.seasons(seriesKey: key)
        XCTAssertEqual(seasons.map(\.seasonNumber), [1, 2])

        let s1 = await store.episodes(seriesKey: key, season: 1)
        XCTAssertEqual(s1.map(\.episodeNumber), [1, 2], "episodes in episode order")
        XCTAssertTrue(s1.allSatisfy { $0.kind == .episode && $0.parentTitle == "Breaking Bad" })
    }

    /// Regression: normalized-equivalent episode titles/library classifications
    /// must not emit duplicate season tabs with identical ids (which makes tvOS
    /// focus collapse onto only one of the visually duplicated buttons).
    func testSeasonsDeduplicateVariantSeriesMetadataBySeasonNumber() async {
        let store = ShareCatalogStore(accountKey: "korra", directory: tempDir())
        let canonical = "The Legend of Korra"
        let key = ShareCatalogID.seriesKey(fromTitle: canonical)
        let variants: [(season: Int, title: String, library: CatalogLibrary)] = [
            (1, canonical, .tv),
            (2, canonical, .tv),
            (3, "The.Legend.of.Korra", .tv),
            (3, canonical, .anime),
            (4, "The.Legend.of.Korra", .tv),
            (4, canonical, .anime),
        ]
        let assets = variants.map { value in
            CatalogAsset(
                relPath: "TV/Korra/S\(value.season)/E01-\(value.title)-\(value.library.rawValue).mkv",
                basename: "E01.mkv", size: 1_000, modifiedAt: Date(),
                kind: .episode, library: value.library,
                title: "Episode 1", year: nil,
                seriesTitle: value.title, seriesKey: key,
                season: value.season, episode: 1
            )
        }
        await store.upsert(assets, scanID: 1)

        let seasons = await store.seasons(seriesKey: key)
        XCTAssertEqual(seasons.map(\.seasonNumber), [1, 2, 3, 4])
        XCTAssertEqual(Set(seasons.map(\.id)).count, 4, "season ids must be unique for stable focus")
        XCTAssertTrue(seasons.allSatisfy { $0.parentTitle == canonical })
        XCTAssertTrue(seasons.allSatisfy { $0.libraryID == ShareCatalogID.animeLibrary })
    }

    func testLibrarySortIgnoresLeadingTheAndUsesSeriesTitle() async {
        let store = ShareCatalogStore(accountKey: "sort", directory: tempDir())
        await store.upsert([
            movie("Movies/Zootopia (2016).mkv", title: "Zootopia", year: 2016),
            movie("Movies/The Batman (2022).mkv", title: "The Batman", year: 2022),
            movie("Movies/Avatar (2009).mkv", title: "Avatar", year: 2009),
            episode("TV/Yellowstone/S01E01.mkv", series: "Yellowstone", season: 1, episode: 1),
            // Episode titles intentionally sort differently; the grid must use the
            // SERIES title, not "Zulu"/"Alpha".
            CatalogAsset(
                relPath: "TV/The Bear/S01E01.mkv", basename: "S01E01.mkv",
                size: 1_000, modifiedAt: Date(), kind: .episode, library: .tv,
                title: "Zulu", year: nil, seriesTitle: "The Bear",
                seriesKey: ShareCatalogID.seriesKey(fromTitle: "The Bear"),
                season: 1, episode: 1
            ),
            CatalogAsset(
                relPath: "TV/Andor/S01E01.mkv", basename: "S01E01.mkv",
                size: 1_000, modifiedAt: Date(), kind: .episode, library: .tv,
                title: "Alpha", year: nil, seriesTitle: "Andor",
                seriesKey: ShareCatalogID.seriesKey(fromTitle: "Andor"),
                season: 1, episode: 1
            ),
        ], scanID: 1)

        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.map(\.title), ["Avatar", "The Batman", "Zootopia"])

        let series = await store.series(in: .tv, offset: 0, limit: 10)
        XCTAssertEqual(series.map(\.title), ["Andor", "The Bear", "Yellowstone"])
        XCTAssertEqual(ShareCatalogID.sortTitle(from: "Theodore"), "theodore")
        XCTAssertEqual(ShareCatalogID.sortTitle(from: "  THE   Thing  "), "thing")
    }

    func testAnimeAndTvLibrariesAreSeparate() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            episode("TV/Show/E01.mkv", series: "Some Show", season: 1, episode: 1, library: .tv),
            episode("Anime/Naruto/E01.mkv", series: "Naruto", season: 1, episode: 1, library: .anime),
        ], scanID: 1)
        let counts = await store.libraryCounts()
        XCTAssertEqual(counts.tvSeries, 1)
        XCTAssertEqual(counts.animeSeries, 1)
        let tv = await store.series(in: .tv, offset: 0, limit: 10)
        let anime = await store.series(in: .anime, offset: 0, limit: 10)
        XCTAssertEqual(tv.map(\.title), ["Some Show"])
        XCTAssertEqual(anime.map(\.title), ["Naruto"])
    }

    func testSearchFindsMoviesAndSeries() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            movie("Movies/The Matrix (1999).mkv", title: "The Matrix", year: 1999),
            episode("TV/Matrix Reloaded Show/E01.mkv", series: "Matrix Reloaded Show", season: 1, episode: 1),
            movie("Movies/Unrelated (2001).mkv", title: "Unrelated", year: 2001),
        ], scanID: 1)
        let hits = await store.search(query: "matrix", limit: 20)
        let titles = Set(hits.map(\.title))
        XCTAssertTrue(titles.contains("The Matrix"))
        XCTAssertTrue(titles.contains("Matrix Reloaded Show"))
        XCTAssertFalse(titles.contains("Unrelated"))

        let fullTitleHits = await store.search(query: "The Matrix", limit: 20)
        XCTAssertEqual(fullTitleHits.map(\.title), ["The Matrix"])
    }

    func testItemResolvesEveryIdShape() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let key = ShareCatalogID.seriesKey(fromTitle: "The Show")
        await store.upsert([
            movie("Movies/Film (2020).mkv", title: "Film", year: 2020),
            episode("TV/The Show/S01/E03.mkv", series: "The Show", season: 1, episode: 3),
        ], scanID: 1)

        let movieItem = await store.item(id: ShareCatalogID.file("Movies/Film (2020).mkv"))
        XCTAssertEqual(movieItem?.kind, .movie)
        XCTAssertEqual(movieItem?.productionYear, 2020)

        let seriesItem = await store.item(id: ShareCatalogID.series(key))
        XCTAssertEqual(seriesItem?.kind, .series)
        XCTAssertEqual(seriesItem?.title, "The Show")

        let seasonItem = await store.item(id: ShareCatalogID.season(key, 1))
        XCTAssertEqual(seasonItem?.kind, .season)
        XCTAssertEqual(seasonItem?.seasonNumber, 1)

        let episodeItem = await store.item(id: ShareCatalogID.file("TV/The Show/S01/E03.mkv"))
        XCTAssertEqual(episodeItem?.kind, .episode)
        XCTAssertEqual(episodeItem?.episodeNumber, 3)
        XCTAssertEqual(episodeItem?.seriesID, ShareCatalogID.series(key))

        let unknown = await store.item(id: "share:root")
        XCTAssertNil(unknown, "raw file-tree ids resolve via the browser, not the catalog")
    }

    func testPruneRemovesAssetsNotSeenInLatestScan() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        await store.upsert([
            movie("Movies/Keep (2000).mkv", title: "Keep", year: 2000),
            movie("Movies/Gone (2001).mkv", title: "Gone", year: 2001),
        ], scanID: 1)
        // Next full scan only re-saw "Keep".
        await store.upsert([movie("Movies/Keep (2000).mkv", title: "Keep", year: 2000)], scanID: 2)
        await store.pruneNotSeen(inScan: 2)
        let movies = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.map(\.title), ["Keep"])
    }

    func testCatalogSurvivesRelaunch() async {
        let dir = tempDir()
        let live = ShareCatalogStore(accountKey: "acct", directory: dir)
        await live.upsert([movie("Movies/Persisted (2010).mkv", title: "Persisted", year: 2010)], scanID: 1)

        // Fresh store on the same dir == a relaunch (only the DB file remains).
        let reopened = ShareCatalogStore(accountKey: "acct", directory: dir)
        let movies = await reopened.movies(offset: 0, limit: 10)
        XCTAssertEqual(movies.map(\.title), ["Persisted"])
    }

    func testSeasonIdRoundTripsWithColonInKey() {
        // seriesKey never contains a colon, but guard the decoder anyway.
        let key = "breaking-bad"
        let id = ShareCatalogID.season(key, 3)
        let decoded = ShareCatalogID.seasonComponents(forSeasonID: id)
        XCTAssertEqual(decoded?.seriesKey, key)
        XCTAssertEqual(decoded?.season, 3)
    }

    func testEpisodeSidecarAssociationRequiresEpisodeAssetKind() async {
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        let videoPath = "TV/Show/S01E01.mkv"
        let sidecar = PendingLocalMetadataFile(
            relPath: "TV/Show/S01E01.nfo",
            parentDir: "TV/Show",
            kind: .episodeStem,
            size: 100,
            associatedVideoRelPath: videoPath,
            processedItemID: nil,
            fingerprint: "etag:test",
            scanGenerationBound: false,
            status: "pending",
            attempts: 0
        )

        await store.upsert([movie(videoPath, title: "Reclassified", year: nil)], scanID: 1)
        var facts = await store.localMetadataAssociationFacts(for: sidecar)
        XCTAssertFalse(facts.associatedVideoExists)

        await store.upsert([
            episode(videoPath, series: "Show", season: 1, episode: 1),
        ], scanID: 2)
        facts = await store.localMetadataAssociationFacts(for: sidecar)
        XCTAssertTrue(facts.associatedVideoExists)
    }

    func testSeriesKeyNormalizesPunctuationAndCase() {
        XCTAssertEqual(ShareCatalogID.seriesKey(fromTitle: "Breaking Bad"),
                       ShareCatalogID.seriesKey(fromTitle: "breaking.bad"))
        XCTAssertEqual(ShareCatalogID.seriesKey(fromTitle: "Mr. Robot"), "mr-robot")
    }

    // MARK: - Reconciliation primitives

    func testLevenshtein() {
        XCTAssertEqual(ShareTitleSimilarity.levenshtein("peaky blinder", "peaky blinders"), 1)
        XCTAssertEqual(ShareTitleSimilarity.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(ShareTitleSimilarity.levenshtein("same", "same"), 0)
        XCTAssertEqual(ShareTitleSimilarity.levenshtein("", "abc"), 3)
    }

    func testTitlesNearlyIdentical() {
        // Typo / plural of one show.
        XCTAssertTrue(ShareTitleSimilarity.titlesNearlyIdentical("Peaky Blinder", "Peaky Blinders"))
        XCTAssertTrue(ShareTitleSimilarity.titlesNearlyIdentical("The Handmaids Tale", "The Handmaid's Tale"))
        // A digit difference is a deliberate distinction — never "nearly identical".
        XCTAssertFalse(ShareTitleSimilarity.titlesNearlyIdentical("1883", "1923"))
        // Too short / too different.
        XCTAssertFalse(ShareTitleSimilarity.titlesNearlyIdentical("Fargo", "Cargo"))
        XCTAssertFalse(ShareTitleSimilarity.titlesNearlyIdentical("Lost", "Loki"))
        XCTAssertFalse(ShareTitleSimilarity.titlesNearlyIdentical("The Office", "The Wire"))
    }

    func testResolveAliasFollowsChains() {
        let map = ["a": "b", "b": "c", "x": "y"]
        XCTAssertEqual(ShareSeriesReconciler.resolveAlias("a", in: map), "c")
        XCTAssertEqual(ShareSeriesReconciler.resolveAlias("b", in: map), "c")
        XCTAssertEqual(ShareSeriesReconciler.resolveAlias("x", in: map), "y")
        XCTAssertEqual(ShareSeriesReconciler.resolveAlias("z", in: map), "z")
        // A cycle terminates (rather than looping forever) at a cycle member.
        XCTAssertTrue(["a", "b"].contains(ShareSeriesReconciler.resolveAlias("a", in: ["a": "b", "b": "a"])))
    }

    func testAddsVariantWordBlocksParodyUpgrade() {
        // "sword art online" must never upgrade to "sword art online abridged".
        XCTAssertTrue(ShareTitleSimilarity.addsVariantWord(base: "sword art online", extended: "sword art online abridged"))
        // A genuine subtitle extension is allowed ("avatar" → "avatar the last airbender").
        XCTAssertFalse(ShareTitleSimilarity.addsVariantWord(base: "avatar", extended: "avatar the last airbender"))
    }

    func testEpisodeHintsSkipSyntheticPlaceholders() async {
        // A show with bare-numbered early seasons stores "S1·E01" placeholder titles;
        // those must be excluded from disambiguation hints so the real later-season
        // titles are used (the Outlander bug).
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        func ep(_ path: String, _ season: Int, _ episode: Int, title: String) -> CatalogAsset {
            CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1,
                         modifiedAt: Date(), kind: .episode, library: .tv,
                         title: title, year: nil, seriesTitle: "Outlander",
                         seriesKey: ShareCatalogID.seriesKey(fromTitle: "Outlander"),
                         season: season, episode: episode)
        }
        await store.upsert([
            ep("TV/Outlander/S01/o.s01e01.mkv", 1, 1, title: "S1·E01"),
            ep("TV/Outlander/S01/o.s01e02.mkv", 1, 2, title: "S1·E02"),
            ep("TV/Outlander/S02/o.s02e01.mkv", 2, 1, title: "Through a Glass, Darkly"),
            ep("TV/Outlander/S02/o.s02e02.mkv", 2, 2, title: "Not in Scotland Anymore"),
        ], scanID: 1)
        let key = ShareCatalogID.seriesKey(fromTitle: "Outlander")
        let hints = await store.episodeTitleHints(seriesKey: key)
        XCTAssertEqual(hints.map(\.title), ["Through a Glass, Darkly", "Not in Scotland Anymore"])
        XCTAssertFalse(hints.contains { $0.title.hasPrefix("S1·E") }, "placeholders excluded")
    }

    func testSearchAlternatesExcludeShorterAbbreviations() async {
        // A cryptic filename abbreviation ("TP" under a "The Punisher" folder) must
        // NOT be offered as a search alternate — only a RICHER (more-word) filename
        // title qualifies (the Punisher bug). A generic folder with a longer filename
        // title ("Avatar" folder, "Avatar The Last Airbender" files) still yields one.
        let store = ShareCatalogStore(accountKey: "a", directory: tempDir())
        func ep(_ path: String, series: String, key: String, _ s: Int, _ e: Int) -> CatalogAsset {
            CatalogAsset(relPath: path, basename: (path as NSString).lastPathComponent, size: 1,
                         modifiedAt: Date(), kind: .episode, library: .tv,
                         title: "t", year: nil, seriesTitle: series, seriesKey: key, season: s, episode: e)
        }
        let punisher = ShareCatalogID.seriesKey(fromTitle: "The Punisher")
        let avatar = ShareCatalogID.seriesKey(fromTitle: "Avatar")
        await store.upsert([
            ep("TV/The Punisher/TP.S01E01.3AM.mkv", series: "The Punisher", key: punisher, 1, 1),
            ep("TV/Avatar (2024)/Avatar.The.Last.Airbender.2024.S01E01.mkv", series: "Avatar", key: avatar, 1, 1),
        ], scanID: 1)
        let punisherAlts = await store.seriesSearchTitleAlternates(seriesKey: punisher, storedTitle: "The Punisher")
        XCTAssertFalse(punisherAlts.contains { $0.caseInsensitiveCompare("TP") == .orderedSame }, "abbreviation excluded")
        let avatarAlts = await store.seriesSearchTitleAlternates(seriesKey: avatar, storedTitle: "Avatar")
        XCTAssertTrue(avatarAlts.contains("Avatar The Last Airbender"), "richer filename title kept")
    }


    // MARK: - Incremental scan (directory state)

    /// THE safety invariant. `pruneNotSeen` deletes every row whose `last_scan`
    /// isn't the current scan, so a directory whose listing is skipped must still
    /// have its contents stamped — otherwise the optimization silently erases the
    /// library it was meant to speed up.
    func testTouchingSkippedDirectoryPreservesItsFilesThroughPrune() async {
        let store = ShareCatalogStore(accountKey: "incr", directory: tempDir())
        let assets = [
            CatalogAsset(
                relPath: "Movies/Alpha (2020).mkv", basename: "Alpha (2020).mkv",
                size: 1, modifiedAt: Date(), kind: .movie, library: .movies,
                title: "Alpha", year: 2020, seriesTitle: nil, seriesKey: nil,
                season: nil, episode: nil, movieKey: "mk-alpha", movieTitleKey: "mtk-alpha"
            ),
            CatalogAsset(
                relPath: "Movies/Deep/Beta (2021).mkv", basename: "Beta (2021).mkv",
                size: 1, modifiedAt: Date(), kind: .movie, library: .movies,
                title: "Beta", year: 2021, seriesTitle: nil, seriesKey: nil,
                season: nil, episode: nil, movieKey: "mk-beta", movieTitleKey: "mtk-beta"
            ),
        ]
        await store.upsert(assets, scanID: 1)
        let initial = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(initial.count, 2)

        // Scan 2 "skips" Movies/ — nothing is re-upserted, only touched.
        await store.touchDirectoryContents(relPath: "Movies", scanID: 2)
        await store.pruneNotSeen(inScan: 2)

        let titles = Set(await store.movies(offset: 0, limit: 10).map(\.title))
        XCTAssertTrue(titles.contains("Alpha"), "a skipped directory's file must survive the prune")
        // Beta lives one level deeper, so touching Movies/ must NOT have covered it:
        // the walk descends into subdirectories separately, and a touch that reached
        // them would mask a genuine deletion.
        XCTAssertFalse(titles.contains("Beta"), "touch must be direct children only")
    }

    /// The walk still has to descend: a directory's mtime only reflects its DIRECT
    /// children, so an unchanged folder's subdirectories must remain reachable.
    func testRecordedSubdirectoriesReturnsDirectChildrenOnly() async {
        let store = ShareCatalogStore(accountKey: "incr2", directory: tempDir())
        for path in ["Movies", "Movies/Deep", "Movies/Deep/Deeper", "TV"] {
            await store.recordDirectory(relPath: path, modifiedAt: Date(timeIntervalSince1970: 100), scanID: 1)
        }
        await store.recordDirectory(relPath: "", modifiedAt: Date(timeIntervalSince1970: 100), scanID: 1)

        let root = Set(await store.recordedSubdirectories(of: ""))
        XCTAssertEqual(root, ["Movies", "TV"], "root children only")
        let movies = Set(await store.recordedSubdirectories(of: "Movies"))
        XCTAssertEqual(movies, ["Movies/Deep"], "direct children only, not Deeper")
    }

    /// A server that doesn't report directory mtimes must keep scanning exactly as
    /// before rather than silently skipping everything.
    func testMissingDirectoryMTimeIsStoredAsNonMatching() async {
        let store = ShareCatalogStore(accountKey: "incr3", directory: tempDir())
        await store.recordDirectory(relPath: "Movies", modifiedAt: nil, scanID: 1)
        // Only a COMPLETED scan's rows are skippable, so mark it complete first.
        await store.markDirectoryStateComplete(scanID: 1)
        // Omitted entirely rather than returned as 0. The requirement is that a
        // directory whose mtime the server never reported can't be skipped, and
        // absence guarantees that more strongly than a sentinel value does —
        // there is nothing for a real mtime to be compared against.
        let stored = await store.directoryModifiedSeconds()["Movies"]
        XCTAssertNil(stored)
    }


    // MARK: Incremental skip: precision and batching

    /// A sub-second mtime must survive storage and still compare equal.
    ///
    /// This is why the comparison is done in raw seconds rather than on `Date`.
    /// `Date` counts from 2001 internally, so a round trip through
    /// `timeIntervalSince1970` adds and subtracts 978307200 — about nine
    /// significant digits of a double. Whole-second values survive that exactly;
    /// sub-second ones fail roughly half the time. Every directory whose mtime
    /// had a fractional part then looked changed on every pass and was re-listed
    /// forever, which is most of them on a real server.
    func testSubSecondDirectoryMTimeRoundTripsExactly() async {
        let store = ShareCatalogStore(accountKey: "incrPrecision", directory: tempDir())
        let mtime = Date(timeIntervalSince1970: 1_763_000_000.123456)
        await store.recordDirectory(relPath: "Movies", modifiedAt: mtime, scanID: 1)
        await store.markDirectoryStateComplete(scanID: 1)

        let stored = await store.directoryModifiedSeconds()["Movies"]
        XCTAssertEqual(
            stored,
            mtime.timeIntervalSince1970,
            "a stored mtime must compare equal to the value a listing reports"
        )
    }

    /// The batched stamp keeps the per-directory version's semantics: a skipped
    /// directory's own files survive the prune, and a deeper file does not — a
    /// touch that reached into subdirectories would mask a genuine deletion.
    func testBatchedTouchStampsDirectChildrenOnly() async {
        let store = ShareCatalogStore(accountKey: "incrBatch", directory: tempDir())
        let assets = [
            CatalogAsset(
                relPath: "Movies/Alpha (2020).mkv", basename: "Alpha (2020).mkv",
                size: 1, modifiedAt: Date(), kind: .movie, library: .movies,
                title: "Alpha", year: 2020, seriesTitle: nil, seriesKey: nil,
                season: nil, episode: nil, movieKey: "mk-alpha", movieTitleKey: "mtk-alpha"
            ),
            CatalogAsset(
                relPath: "Movies/Deep/Beta (2021).mkv", basename: "Beta (2021).mkv",
                size: 1, modifiedAt: Date(), kind: .movie, library: .movies,
                title: "Beta", year: 2021, seriesTitle: nil, seriesKey: nil,
                season: nil, episode: nil, movieKey: "mk-beta", movieTitleKey: "mtk-beta"
            )
        ]
        await store.upsert(assets, scanID: 1)
        let seeded = await store.movies(offset: 0, limit: 10)
        XCTAssertEqual(seeded.count, 2)

        await store.touchDirectoryContents(relPaths: ["Movies"], scanID: 2)
        await store.pruneNotSeen(inScan: 2)

        let titles = Set(await store.movies(offset: 0, limit: 10).map(\.title))
        XCTAssertTrue(titles.contains("Alpha"), "a skipped directory's own file must survive")
        XCTAssertFalse(titles.contains("Beta"), "the stamp must not reach into subdirectories")
    }

    /// Many directories in one call, which is the whole point of the batch.
    func testBatchedTouchHandlesManyDirectories() async {
        let store = ShareCatalogStore(accountKey: "incrBatchMany", directory: tempDir())
        let assets = (0..<50).map { index in
            CatalogAsset(
                relPath: "M\(index)/Film (2020).mkv", basename: "Film (2020).mkv",
                size: 1, modifiedAt: Date(), kind: .movie, library: .movies,
                title: "Film \(index)", year: 2020, seriesTitle: nil, seriesKey: nil,
                season: nil, episode: nil,
                movieKey: "mk-\(index)", movieTitleKey: "mtk-\(index)"
            )
        }
        await store.upsert(assets, scanID: 1)

        await store.touchDirectoryContents(
            relPaths: (0..<50).map { "M\($0)" },
            scanID: 2
        )
        await store.pruneNotSeen(inScan: 2)

        let survivors = await store.movies(offset: 0, limit: 100)
        XCTAssertEqual(
            survivors.count, 50,
            "every batched directory's file must survive the prune"
        )
    }

    /// An empty batch must be a no-op, not a statement that stamps everything or
    /// leaves a transaction open.
    func testBatchedTouchWithNoDirectoriesIsHarmless() async {
        let store = ShareCatalogStore(accountKey: "incrBatchEmpty", directory: tempDir())
        await store.upsert(
            [CatalogAsset(
                relPath: "Movies/Alpha (2020).mkv", basename: "Alpha (2020).mkv",
                size: 1, modifiedAt: Date(), kind: .movie, library: .movies,
                title: "Alpha", year: 2020, seriesTitle: nil, seriesKey: nil,
                season: nil, episode: nil, movieKey: "mk-alpha", movieTitleKey: "mtk-alpha"
            )],
            scanID: 1
        )
        await store.touchDirectoryContents(relPaths: [], scanID: 2)
        await store.pruneNotSeen(inScan: 2)
        let remaining = await store.movies(offset: 0, limit: 10)
        XCTAssertTrue(
            remaining.isEmpty,
            "an empty batch stamps nothing, so scan 1's rows are correctly pruned"
        )
    }

    /// Directory rows follow the same prune rule as everything else, so a folder
    /// removed from the share doesn't linger and keep its children "known".
    func testDirectoryStateIsPrunedWhenNotSeen() async {
        let store = ShareCatalogStore(accountKey: "incr4", directory: tempDir())
        await store.recordDirectory(relPath: "Gone", modifiedAt: Date(), scanID: 1)
        await store.recordDirectory(relPath: "Kept", modifiedAt: Date(), scanID: 2)
        await store.pruneDirectoryStateNotSeen(inScan: 2)
        await store.markDirectoryStateComplete(scanID: 2)
        let remaining = await store.directoryModifiedSeconds()
        XCTAssertNil(remaining["Gone"])
        XCTAssertNotNil(remaining["Kept"])
    }



    /// Directory state from an INTERRUPTED scan must never be skippable.
    ///
    /// A directory is recorded when it is listed, but its children are walked
    /// afterwards — so a scan that dies in between records the parent while part
    /// of its subtree never is. Trusting that row would skip the parent, yield an
    /// incomplete child set, leave the rest of the subtree unvisited, and then
    /// prune those files as missing. On device this deleted ~3,500 rows from a
    /// 13,818-file catalog before the completion gate was added.
    func testDirectoryStateFromIncompleteScanIsNotTrusted() async {
        let store = ShareCatalogStore(accountKey: "incr5", directory: tempDir())
        // Scan 1 listed these but never finished.
        await store.recordDirectory(relPath: "Movies", modifiedAt: Date(timeIntervalSince1970: 100), scanID: 1)
        let beforeCompletion = await store.directoryModifiedSeconds()
        XCTAssertTrue(beforeCompletion.isEmpty, "no completed scan yet — nothing may be skipped")

        // Scan 2 completed.
        await store.recordDirectory(relPath: "Movies", modifiedAt: Date(timeIntervalSince1970: 200), scanID: 2)
        await store.markDirectoryStateComplete(scanID: 2)
        let afterCompletion = await store.directoryModifiedSeconds()
        XCTAssertEqual(
            afterCompletion["Movies"], 200,
            "a completed scan's rows are trustworthy"
        )

        // Scan 3 was interrupted: its rows must not be trusted, and the stale
        // completed-scan rows must not resurface either.
        await store.recordDirectory(relPath: "Movies", modifiedAt: Date(timeIntervalSince1970: 300), scanID: 3)
        let afterInterruption = await store.directoryModifiedSeconds()
        XCTAssertNil(
            afterInterruption["Movies"],
            "an interrupted scan's rows must not be skippable"
        )
    }

    /// The retry budget bounds the BACKLOG. The fast-track path has its own
    /// limiter (a per-item cooldown), so it must not spend the counter —
    /// otherwise browsing alone exhausts an item the background never tried, and
    /// the item is then excluded from the backlog query forever. Field catalogs
    /// reached 55-72 attempts against a cap of 3 exactly this way, which is why a
    /// 2,185-title library sat at a few hundred posters.
    func testFastTrackMissesDoNotSpendTheBacklogRetryBudget() async {
        let directory = tempDir()
        let store = ShareCatalogStore(accountKey: "budget", directory: directory)
        await store.upsert([movie("Movies/Blank (2020).mkv", title: "Blank", year: 2020)], scanID: 1)
        let miss = EnrichmentRecord()

        for _ in 0..<8 {
            _ = await store.saveEnrichment(
                itemID: "f:Movies/Blank (2020).mkv",
                miss,
                version: 3,
                countsTowardRetryBudget: false
            )
        }
        let stillPending = await store.pendingEnrichment(version: 3, limit: 10)
        XCTAssertEqual(stillPending.map(\.itemID), ["f:Movies/Blank (2020).mkv"])

        // Background attempts DO spend it, and the item settles at the cap.
        for _ in 0..<EnrichmentRepository.maxEnrichAttempts {
            _ = await store.saveEnrichment(itemID: "f:Movies/Blank (2020).mkv", miss, version: 3)
        }
        let settled = await store.pendingEnrichment(version: 3, limit: 10)
        XCTAssertTrue(settled.isEmpty)
    }
    // MARK: Cast

    func testCastSurvivesTheRoundTripToDiskAndBack() async throws {
        // The feature shipped inert once: provenance was recorded but the value was
        // dropped when the record was built, so every share persisted an empty cast
        // while builds and tests stayed green.
        let directory = tempDir()
        let store = ShareCatalogStore(accountKey: "cast", directory: directory)
        await store.upsert([
            movie("Movies/Silo (2023).mkv", title: "Silo", year: 2023)
        ], scanID: 1)
        let people = [
            MediaPerson(id: "tmdb:person:1", name: "Rebecca Ferguson", role: "Juliette", kind: "Actor"),
            MediaPerson(id: "tmdb:person:2", name: "Common", role: "Robert Sims", kind: "Actor"),
        ]
        let saved = await store.saveEnrichment(
            itemID: "f:Movies/Silo (2023).mkv",
            .sourced(cast: SourcedValue(value: people, source: .tmdb)),
            version: 18
        )
        XCTAssertTrue(saved)

        let fetched = await store.item(id: "f:Movies/Silo (2023).mkv")
        let loaded = try XCTUnwrap(fetched)
        XCTAssertEqual(loaded.people.map(\.name), ["Rebecca Ferguson", "Common"])
        XCTAssertEqual(loaded.people.first?.role, "Juliette")
        XCTAssertEqual(loaded.metadataProvenance[.cast]?.source, .tmdb)
    }

    func testASecondEnrichmentPassAdoptsCastItDidNotHaveBefore() async {
        // Re-enriching at the same version merges into the existing record, so a
        // record written before cast existed has to be able to gain it.
        let directory = tempDir()
        let store = ShareCatalogStore(accountKey: "cast2", directory: directory)
        await store.upsert([
            movie("Movies/Silo (2023).mkv", title: "Silo", year: 2023)
        ], scanID: 1)
        _ = await store.saveEnrichment(
            itemID: "f:Movies/Silo (2023).mkv",
            .sourced(overview: SourcedValue(value: "A silo.", source: .tmdb)),
            version: 18
        )
        _ = await store.saveEnrichment(
            itemID: "f:Movies/Silo (2023).mkv",
            .sourced(cast: SourcedValue(
                value: [MediaPerson(id: "p", name: "Rebecca Ferguson")],
                source: .tmdb
            )),
            version: 18
        )
        let loaded = await store.item(id: "f:Movies/Silo (2023).mkv")
        XCTAssertEqual(loaded?.people.map(\.name), ["Rebecca Ferguson"])
        XCTAssertEqual(loaded?.overview, "A silo.", "the earlier pass's values survive")
    }

}

private actor CatalogWriteChunkGate {
    private var paused = false
    private var opened = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        paused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !opened else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func open() {
        opened = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
