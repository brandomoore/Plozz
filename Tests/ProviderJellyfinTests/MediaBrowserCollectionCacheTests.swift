import CoreModels
import XCTest
@testable import ProviderJellyfin

final class MediaBrowserCollectionCacheTests: XCTestCase {
    func testCancellingOneConsumerIsPromptAndDoesNotCancelRemainingConsumer() async throws {
        let cache = MediaBrowserCollectionLibraryCache()
        let gate = CollectionCacheLoadGate(itemID: "shared")
        let finished = CollectionCacheCompletions()
        let first = collectionCacheRequest(cache, finished: finished, label: "first") {
            try await gate.load()
        }
        let started = await collectionCacheWait { await gate.loadCount == 1 }
        XCTAssertTrue(started)
        let second = collectionCacheRequest(cache, finished: finished, label: "second") {
            try await gate.load()
        }
        let joined = await collectionCacheWait { await cache.activeConsumerCount(for: "scope") == 2 }
        XCTAssertTrue(joined)
        first.cancel()
        let cancelledPromptly = await collectionCacheWait { await finished.contains("first") }
        XCTAssertTrue(cancelledPromptly, "First caller must finish while shared work remains gated")
        let remaining = await cache.activeConsumerCount(for: "scope")
        let cancelledLoads = await gate.cancelledCount
        let loadCount = await gate.loadCount
        XCTAssertEqual(remaining, 1)
        XCTAssertEqual(cancelledLoads, 0)
        XCTAssertEqual(loadCount, 1)
        await gate.release()
        await assertCollectionCacheCancelled(first)
        let items = try await second.value
        XCTAssertEqual(items.map(\.id), ["shared"])
    }

    func testLastConsumerCancellationStopsUnderlyingProbes() async {
        let cache = MediaBrowserCollectionLibraryCache()
        let firstProbe = CollectionCacheLoadGate(itemID: "one")
        let secondProbe = CollectionCacheLoadGate(itemID: "two")
        let finished = CollectionCacheCompletions()
        let request = collectionCacheRequest(cache, finished: finished, label: "only") {
            try await withThrowingTaskGroup(of: [MediaItem].self) { group in
                group.addTask { try await firstProbe.load() }
                group.addTask { try await secondProbe.load() }
                var items: [MediaItem] = []
                for try await result in group { items.append(contentsOf: result) }
                return items
            }
        }
        let started = await collectionCacheWait {
            let first = await firstProbe.loadCount
            let second = await secondProbe.loadCount
            return first == 1 && second == 1
        }
        XCTAssertTrue(started)
        request.cancel()
        let cancelled = await collectionCacheWait {
            let first = await firstProbe.cancelledCount
            let second = await secondProbe.cancelledCount
            return first == 1 && second == 1
        }
        XCTAssertTrue(cancelled)
        let detached = await cache.activeConsumerCount(for: "scope")
        XCTAssertEqual(detached, 0)
        await firstProbe.release()
        await secondProbe.release()
        await assertCollectionCacheCancelled(request)
    }

    func testNewConsumerStartsHealthyFlightBeforeCancelledWorkFinishes() async throws {
        let cache = MediaBrowserCollectionLibraryCache()
        let oldGate = CollectionCacheLoadGate(itemID: "old", honorsCancellation: false)
        let newGate = CollectionCacheLoadGate(itemID: "new")
        let finished = CollectionCacheCompletions()
        let old = collectionCacheRequest(cache, finished: finished, label: "old") {
            try await oldGate.load()
        }
        let oldStarted = await collectionCacheWait { await oldGate.loadCount == 1 }
        XCTAssertTrue(oldStarted)
        old.cancel()
        let oldCallerFinished = await collectionCacheWait { await finished.contains("old") }
        XCTAssertTrue(oldCallerFinished, "Cancellation cannot await a non-cooperative loader")
        let newer = collectionCacheRequest(cache, finished: finished, label: "new") {
            try await newGate.load()
        }
        let newStarted = await collectionCacheWait { await newGate.loadCount == 1 }
        XCTAssertTrue(newStarted, "New caller must not join the cancelled flight")
        await oldGate.release()
        let oldWorkFinished = await collectionCacheWait { await oldGate.completedCount == 1 }
        XCTAssertTrue(oldWorkFinished)
        let active = await cache.activeConsumerCount(for: "scope")
        XCTAssertEqual(active, 1, "Old-flight cleanup must leave the replacement consumer registered")
        await newGate.release()
        await assertCollectionCacheCancelled(old)
        let items = try await newer.value
        XCTAssertEqual(items.map(\.id), ["new"])
        let cached = try await cache.snapshot(key: "scope", refresh: false) {
            throw AppError.invalidResponse
        }
        XCTAssertEqual(cached.map(\.id), ["new"])
    }
}

private func collectionCacheRequest(
    _ cache: MediaBrowserCollectionLibraryCache,
    finished: CollectionCacheCompletions,
    label: String,
    load: @escaping @Sendable () async throws -> [MediaItem]
) -> Task<[MediaItem], Error> {
    Task {
        do {
            let result = try await cache.snapshot(key: "scope", refresh: true, load: load)
            await finished.mark(label)
            return result
        } catch {
            await finished.mark(label)
            throw error
        }
    }
}

private func assertCollectionCacheCancelled(
    _ task: Task<[MediaItem], Error>, file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await task.value
        XCTFail("Expected caller cancellation", file: file, line: line)
    } catch is CancellationError {
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private func collectionCacheWait(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private actor CollectionCacheCompletions {
    private var labels = Set<String>()
    func mark(_ label: String) { labels.insert(label) }
    func contains(_ label: String) -> Bool { labels.contains(label) }
}

private actor CollectionCacheLoadGate {
    private let items: [MediaItem]
    private let honorsCancellation: Bool
    private var isReleased = false
    private var waiters: [UUID: CheckedContinuation<[MediaItem], Error>] = [:]
    private var cancelled = Set<UUID>()
    private(set) var loadCount = 0
    private(set) var completedCount = 0
    var cancelledCount: Int { cancelled.count }

    init(itemID: String, honorsCancellation: Bool = true) {
        items = [MediaItem(id: itemID, title: itemID, kind: .collection)]
        self.honorsCancellation = honorsCancellation
    }

    func load() async throws -> [MediaItem] {
        let id = UUID()
        loadCount += 1
        defer { completedCount += 1 }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if honorsCancellation, Task.isCancelled || cancelled.contains(id) {
                    cancelled.insert(id)
                    continuation.resume(throwing: CancellationError())
                } else if isReleased {
                    continuation.resume(returning: items)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        isReleased = true
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: items) }
    }

    private func cancel(_ id: UUID) {
        cancelled.insert(id)
        if honorsCancellation {
            waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }
}
