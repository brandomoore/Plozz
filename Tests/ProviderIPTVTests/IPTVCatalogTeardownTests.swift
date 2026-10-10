import CoreModels
import Foundation
import os
import SQLite3
import XCTest
@testable import ProviderIPTV

final class IPTVCatalogTeardownTests: XCTestCase {
    @MainActor
    func testMainActorReleaseDoesNotWaitForSQLiteCloseAndPreservesCommittedRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("catalog.sqlite")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 3, count: 32)
        var catalog: IPTVCatalog? = try IPTVCatalog(url: url, key: key)
        let probe = try CatalogCloseProbe(db: XCTUnwrap(catalog?.db))
        weak var releasedCatalog = catalog
        try catalog?.execute("PRAGMA wal_autocheckpoint=0")
        try catalog?.insert(IPTVRecord(item: MediaItem(
            id: "committed", title: "Saved", kind: .movie, libraryID: "movies"
        )))
        try catalog?.setState("playlist", "committed")
        let wal = URL(fileURLWithPath: url.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))

        let started = ContinuousClock.now
        catalog = nil
        let releaseDuration = started.duration(to: .now)
        XCTAssertNil(releasedCatalog, "Background teardown must not retain the provider catalogue.")
        try await assertClosed(probe)
        XCTAssertLessThan(releaseDuration, .milliseconds(100))
        XCTAssertEqual(probe.state.withLock { $0 }, [.init(onMainThread: false)])

        try await Task.detached {
            let reopened = try IPTVCatalog(url: url, key: key)
            XCTAssertEqual(try reopened.record("committed").item.title, "Saved")
            XCTAssertEqual(try reopened.state("playlist"), "committed")
        }.value
    }

    @MainActor
    func testReleaseFinalizesCachedStatementsAndRollsBackUncommittedImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("catalog.sqlite")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 4, count: 32)
        var catalog: IPTVCatalog? = try IPTVCatalog(url: url, key: key)
        let probe = try CatalogCloseProbe(db: XCTUnwrap(catalog?.db))
        try catalog?.insert(IPTVRecord(item: MediaItem(
            id: "saved", title: "Saved", kind: .movie, libraryID: "movies"
        )))
        try catalog?.setState("playlist", "saved")
        try catalog?.beginImport()
        try catalog?.insert(IPTVRecord(item: MediaItem(
            id: "partial", title: "Partial", kind: .movie, libraryID: "movies"
        )), into: .incoming)
        try catalog?.execute("BEGIN IMMEDIATE")
        try catalog?.execute("DELETE FROM entries")
        try catalog?.setState("playlist", "partial")
        catalog = nil
        try await assertClosed(probe)
        XCTAssertEqual(probe.state.withLock { $0 }, [.init(onMainThread: false)])

        try await Task.detached {
            let reopened = try IPTVCatalog(url: url, key: key)
            XCTAssertEqual(try reopened.count(where: "1 = 1"), 1)
            XCTAssertEqual(try reopened.record("saved").item.title, "Saved")
            XCTAssertEqual(try reopened.state("playlist"), "saved")
            XCTAssertThrowsError(try reopened.record("partial"))
        }.value
    }

    func testBackgroundReleaseFinishesClosingBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try await Task.detached {
            var catalog: IPTVCatalog? = try IPTVCatalog(
                url: root.appendingPathComponent("catalog.sqlite"), key: Data(repeating: 5, count: 32)
            )
            let probe = try CatalogCloseProbe(db: XCTUnwrap(catalog?.db))
            catalog = nil
            XCTAssertEqual(probe.state.withLock { $0 }, [.init(onMainThread: false)])
        }.value
    }

    @MainActor
    func testImmediateReopenPreservesRowsWhilePriorConnectionCloses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("catalog.sqlite")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 6, count: 32)
        var catalog: IPTVCatalog? = try IPTVCatalog(url: url, key: key)
        let probe = try CatalogCloseProbe(db: XCTUnwrap(catalog?.db))
        try catalog?.insert(IPTVRecord(item: MediaItem(
            id: "saved", title: "Saved", kind: .movie, libraryID: "movies"
        )))
        catalog = nil
        try await Task.detached {
            let reopened = try IPTVCatalog(url: url, key: key)
            XCTAssertEqual(try reopened.record("saved").item.title, "Saved")
        }.value
        try await assertClosed(probe)
        XCTAssertEqual(probe.state.withLock { $0 }, [.init(onMainThread: false)])
    }

    @MainActor
    private func assertClosed(_ probe: CatalogCloseProbe) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if !probe.state.withLock({ $0.isEmpty }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("SQLite did not finish retiring its connection-owned resources.")
    }
}

private final class CatalogCloseProbe: Sendable {
    struct Observation: Equatable, Sendable {
        let onMainThread: Bool
    }

    let state = OSAllocatedUnfairLock(initialState: [Observation]())
    init(db: OpaquePointer) throws {
        // A connection-owned destructor measures the real SQLite close, not a test-only app callback.
        let result = sqlite3_create_function_v2(
            db, "plozz_teardown_probe", 0, SQLITE_UTF8, Unmanaged.passRetained(self).toOpaque(),
            { context, _, _ in sqlite3_result_null(context) }, nil, nil,
            { context in
                guard let context else { return }
                let probe = Unmanaged<CatalogCloseProbe>.fromOpaque(context).takeRetainedValue()
                let onMainThread = Thread.isMainThread
                Thread.sleep(forTimeInterval: 0.2)
                probe.state.withLock { $0.append(.init(onMainThread: onMainThread)) }
            }
        )
        guard result == SQLITE_OK else { throw NSError(domain: "SQLite", code: Int(result)) }
    }
}
