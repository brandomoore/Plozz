import Foundation
import SQLite3
import XCTest
@testable import ProviderShare

final class CatalogArtworkDirectoryScopeTests: XCTestCase {
    private let legacyPredicate = "(metadata_root=? OR substr(rel_path,1,length(?)+1)=?||'/')"

    func testDirectoryRangePreservesExactCaseUnicodeAndWildcardCharacters() throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let connection = CatalogConnection(url: fixture.catalogURL)
        XCTAssertTrue(connection.ensureOpen(legacyMetadataMigration: { _ in true }))
        let db = try XCTUnwrap(connection.db)
        for directory in ["Movies/Film", "Movies/film", "Movies/100%_Done", "Movies/[A]", "Movies/L'été", "Movies/日本語", "Movies/Cafe\u{301}"] {
            let paths = [
                directory, directory + "/movie.mkv", directory + "/Season 01/episode.mkv",
                directory + "0/other.mkv", directory + "-extra/movie.mkv"
            ]
            for path in paths {
                try insert(path: path, metadataRoot: nil, connection: connection)
            }
            let outside = "Elsewhere/\(UUID().uuidString).mkv"
            try insert(path: outside, metadataRoot: directory, connection: connection)
            let actual = try query(db, predicate: CatalogArtworkDirectoryScope.predicate,
                                   bindings: CatalogArtworkDirectoryScope(directory: directory).bindings)
            let expected = try query(db, predicate: legacyPredicate, bindings: [directory, directory, directory])
            XCTAssertEqual(actual.paths, expected.paths, directory)
            XCTAssertEqual(actual.paths, [directory + "/movie.mkv", directory + "/Season 01/episode.mkv", outside])
        }
    }

    func testAssociationLookupDoesNotScanUnrelatedAssets() throws {
        let fixture = ShareCatalogSQLiteFixture()
        defer { fixture.cleanup() }
        let connection = CatalogConnection(url: fixture.catalogURL)
        XCTAssertTrue(connection.ensureOpen(legacyMetadataMigration: { _ in true }))
        let db = try XCTUnwrap(connection.db)
        XCTAssertTrue(connection.withImmediateTransaction {
            for index in 0..<10_000 {
                guard self.insertForTransaction(
                    path: "Unrelated/\(index)/movie.mkv", metadataRoot: "Unrelated/\(index)",
                    connection: connection
                ) else { return false }
            }
            return true
        })
        try insert(path: "Movies/Film/movie.mkv", metadataRoot: "Movies/Film", connection: connection)
        let old = try query(db, predicate: legacyPredicate,
                            bindings: ["Movies/Film", "Movies/Film", "Movies/Film"])
        let indexed = try query(
            db, predicate: CatalogArtworkDirectoryScope.predicate,
            bindings: CatalogArtworkDirectoryScope(directory: "Movies/Film").bindings
        )
        XCTAssertEqual(indexed.paths, old.paths)
        XCTAssertGreaterThanOrEqual(old.fullScanSteps, 10_000)
        XCTAssertEqual(indexed.fullScanSteps, 0, "Both OR branches must remain indexable.")
        XCTAssertLessThan(indexed.vmSteps * 100, old.vmSteps)
    }

    private func insert(path: String, metadataRoot: String?, connection: CatalogConnection) throws {
        XCTAssertTrue(insertForTransaction(path: path, metadataRoot: metadataRoot, connection: connection))
    }

    private func insertForTransaction(path: String, metadataRoot: String?, connection: CatalogConnection) -> Bool {
        connection.runUpdate("""
            INSERT INTO assets(
                rel_path, basename, size, modified_at, first_seen_at, last_scan,
                kind, library, title, sort_title, metadata_root
            ) VALUES(?, 'movie.mkv', 100, 1, 1, 1, 'movie', 'movies', 'Movie', 'movie', ?);
            """) {
            CatalogConnection.bindText($0, 1, path)
            if let metadataRoot { CatalogConnection.bindText($0, 2, metadataRoot) }
            else { sqlite3_bind_null($0, 2) }
        }
    }

    private func query(_ db: OpaquePointer, predicate: String, bindings: [String]) throws
        -> (paths: Set<String>, fullScanSteps: Int32, vmSteps: Int32) {
        var prepared: OpaquePointer?
        let result = sqlite3_prepare_v2(db, """
            SELECT rel_path, kind, COALESCE(movie_group_key,movie_key), series_key, season, metadata_root
            FROM assets WHERE \(predicate);
            """, -1, &prepared, nil)
        XCTAssertEqual(result, SQLITE_OK)
        let statement = try XCTUnwrap(prepared)
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            CatalogConnection.bindText(statement, Int32(index + 1), value)
        }
        var paths = Set<String>()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            paths.insert(try XCTUnwrap(CatalogConnection.columnText(statement, 0)))
            status = sqlite3_step(statement)
        }
        XCTAssertEqual(status, SQLITE_DONE)
        return (paths, sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0),
                sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
    }
}
