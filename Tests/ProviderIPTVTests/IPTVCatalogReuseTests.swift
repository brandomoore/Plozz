import CoreModels
import Foundation
import SQLite3
import XCTest
@testable import ProviderIPTV

final class IPTVCatalogReuseTests: XCTestCase {
    func testCancellationInterruptsSQLiteWorkWithoutInterruptingSubsequentCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try await Task.detached {
            let catalog = try IPTVCatalog(url: root.appendingPathComponent("catalog.sqlite"), key: Data(repeating: 3, count: 32))
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try catalog.execute("""
                WITH RECURSIVE numbers(n) AS (
                    VALUES(0) UNION ALL SELECT n + 1 FROM numbers WHERE n < 100000
                ) SELECT sum(n) FROM numbers
                """, cancellable: true)) { XCTAssertTrue($0 is CancellationError) }
            // The cancelled task must still be able to execute rollback/cleanup SQL.
            try catalog.execute("CREATE TABLE cleanup (value INTEGER)")
            try catalog.execute("INSERT INTO cleanup VALUES(1)")
            try catalog.execute("DROP TABLE cleanup")
        }.value
    }

    func testWriteFailuresRestoreRowsIndexesAndFreshnessAndRetainOnlyTheSQLiteCode() throws {
        for diskFull in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            addTeardownBlock { try FileManager.default.removeItem(at: root) }
            let catalog = try IPTVCatalog(url: root.appendingPathComponent("catalog.sqlite"), key: Data(repeating: 3, count: 32))
            try catalog.insert(IPTVRecord(item: MediaItem(id: "old", title: "Original", kind: .movie, libraryID: "movies")))
            try catalog.setState("playlist", "old")
            try catalog.beginImport()
            defer { catalog.discardImport() }
            for index in 0..<1_005 {
                try catalog.insert(IPTVRecord(
                    item: MediaItem(id: "movie:\(index)", title: "Movie \(index)", kind: .movie, libraryID: "movies")
                ), into: .incoming)
            }
            if diskFull {
                try catalog.execute("PRAGMA main.max_page_count=20")
            } else {
                try catalog.execute("""
                    CREATE TRIGGER fail_import BEFORE INSERT ON entries WHEN NEW.id = 'movie:900'
                    BEGIN SELECT RAISE(ABORT, 'Private provider value'); END
                    """)
            }
            XCTAssertThrowsError(try catalog.commitImport(library: nil, scope: "playlist")) { error in
                guard case IPTVError.database(let code) = error else {
                    return XCTFail("Expected a typed SQLite failure.")
                }
                XCTAssertEqual(code, diskFull ? SQLITE_FULL : SQLITE_CONSTRAINT | (7 << 8))
                XCTAssertEqual((error as? IPTVError)?.setupFailure.sqliteCode, Int(code))
                XCTAssertFalse(error.localizedDescription.contains("Private provider value"))
                XCTAssertEqual(
                    error.localizedDescription,
                    diskFull
                        ? String(localized: "The IPTV catalogue could not be saved. Check the available device storage.")
                        : String(localized: "The IPTV catalogue could not be saved. Please try again.")
                )
            }
            XCTAssertEqual(try catalog.record("old").item.title, "Original")
            XCTAssertEqual(try catalog.state("playlist"), "old")
            XCTAssertEqual(try catalog.count(where: "1 = 1"), 1)
            // Exercise each restored index rather than allowing SQLite to fall back to a scan.
            for name in [
                "catalogue_browse", "catalogue_parent", "catalogue_recent", "catalogue_name",
                "catalogue_year", "catalogue_added", "catalogue_live"
            ] {
                try catalog.execute("SELECT id FROM entries INDEXED BY \(name)")
            }
            if diskFull { try catalog.execute("PRAGMA main.max_page_count=1000000") }
            else { try catalog.execute("DROP TRIGGER fail_import") }
            try catalog.commitImport(library: nil, scope: "playlist")
            XCTAssertEqual(try catalog.count(where: "1 = 1"), 1_005)
        }
    }

    func testRepeatedImportsPreserveFirstParentAndClearPriorBindings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 3, count: 32)
        let url = root.appendingPathComponent("catalog.sqlite")
        do {
            let catalog = try IPTVCatalog(url: url, key: key)
            for generation in 0..<3 {
                try catalog.beginImport()
                let original = IPTVRecord(
                    item: MediaItem(id: "series:one", title: "Original \(generation)", kind: .series, libraryID: "series"),
                    streamURL: URL(string: "https://provider.test/first")
                )
                var duplicate = original
                duplicate.item.title = "Ignored"
                try catalog.insert(original, overwrite: false, into: .incoming)
                for _ in 0..<20 { try catalog.insert(duplicate, overwrite: false, into: .incoming) }
                try catalog.insert(IPTVRecord(
                    item: MediaItem(id: "live:one", title: "Old", kind: .video, libraryID: "live"),
                    parentID: "old-parent", streamURL: URL(string: "https://provider.test/old"), isLive: true
                ), into: .incoming)
                try catalog.insert(IPTVRecord(
                    item: MediaItem(id: "live:one", title: "New", kind: .video, libraryID: "live"), isLive: true
                ), into: .incoming)
                try catalog.commitImport(library: nil, scope: "playlist")
                catalog.discardImport()
                XCTAssertEqual(try catalog.count(where: "1 = 1"), 2)
                XCTAssertEqual(try catalog.record("series:one").item.title, "Original \(generation)")
                let live = try catalog.record("live:one")
                XCTAssertEqual(live.item.title, "New")
                XCTAssertNil(live.parentID)
                XCTAssertNil(live.streamURL)
            }
        }
        let reopened = try IPTVCatalog(url: url, key: key)
        XCTAssertEqual(try reopened.count(where: "1 = 1"), 2)
        XCTAssertEqual(try reopened.record("series:one").item.title, "Original 2")
    }
}
