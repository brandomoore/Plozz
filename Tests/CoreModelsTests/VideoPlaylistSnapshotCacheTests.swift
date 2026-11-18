import XCTest
@testable import CoreModels

@MainActor
final class VideoPlaylistSnapshotCacheTests: XCTestCase {
    func testDistinctLibrariesEvictOldSnapshotsAndKeepTheNewest() async throws {
        let cache = VideoPlaylistSnapshotCache()
        for index in 0..<64 {
            _ = try await cache.snapshot(key: "library-\(index)", refresh: false) {
                [MediaItem(id: "item-\(index)", title: "Fixture", kind: .movie)]
            }
        }
        for index in 56..<64 {
            let latest = try await cache.snapshot(key: "library-\(index)", refresh: false) {
                XCTFail("The newest eight snapshots must remain cached.")
                return []
            }
            XCTAssertEqual(latest.map(\.id), ["item-\(index)"])
        }
        let oldest = try await cache.snapshot(key: "library-55", refresh: false) {
            [MediaItem(id: "reloaded", title: "Fixture", kind: .movie)]
        }
        XCTAssertEqual(oldest.map(\.id), ["reloaded"])
    }

    func testCancelledRefreshDoesNotPublishOrReuseItsSnapshot() async throws {
        let cache = VideoPlaylistSnapshotCache()
        let old = MediaItem(id: "old", title: "Old", kind: .movie)
        let fresh = MediaItem(id: "fresh", title: "Fresh", kind: .movie)
        _ = try await cache.snapshot(key: "library", refresh: false) { [old] }

        let gate = SnapshotLoadGate()
        let cancelled = Task {
            try await cache.snapshot(key: "library", refresh: true) {
                await gate.load()
                return [fresh]
            }
        }
        await gate.waitUntilStarted()
        cancelled.cancel()
        await gate.release()
        do {
            _ = try await cancelled.value
            XCTFail("A canceled viewer must not observe a completed refresh")
        } catch is CancellationError {
            // Expected.
        }

        let cached = try await cache.snapshot(key: "library", refresh: false) {
            XCTFail("Cancellation must retain the preceding cached snapshot")
            return []
        }
        XCTAssertEqual(cached.map(\.id), ["old"])
        let refreshed = try await cache.snapshot(key: "library", refresh: true) { [fresh] }
        XCTAssertEqual(refreshed.map(\.id), ["fresh"])
    }

    func testFailedRefreshCanRetryWithoutLosingExistingSnapshot() async throws {
        let cache = VideoPlaylistSnapshotCache()
        let old = MediaItem(id: "old", title: "Old", kind: .movie)
        _ = try await cache.snapshot(key: "library", refresh: false) { [old] }
        do {
            _ = try await cache.snapshot(key: "library", refresh: true) {
                throw AppError.serverUnreachable
            }
            XCTFail("A failed refresh must not present stale content as a successful refresh")
        } catch {
            XCTAssertEqual(error as? AppError, .serverUnreachable)
        }
        let cached = try await cache.snapshot(key: "library", refresh: false) { [] }
        XCTAssertEqual(cached.map(\.id), ["old"])
    }
}

private actor SnapshotLoadGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func load() async {
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}
