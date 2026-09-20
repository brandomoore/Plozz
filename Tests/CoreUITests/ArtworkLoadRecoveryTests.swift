#if canImport(UIKit)
import CoreModels
import Foundation
import UIKit
import XCTest
@testable import CoreUI

@MainActor
final class ArtworkLoadRecoveryTests: XCTestCase {
    func testExpiredRemoteLoadReleasesEveryWaiterAndAllowsFreshWork() async throws {
        try await checkExpiredLoad(networkFile: false)
    }

    func testExpiredNetworkFileLoadReleasesEveryWaiterAndAllowsFreshWork() async throws {
        try await checkExpiredLoad(networkFile: true)
    }

    func testCancellingOneWaiterKeepsTheOtherWaiterAndDeadlineAlive() async throws {
        let data = try imageData(.red)
        let loader = ControlledArtworkLoader(first: data, subsequent: data)
        let deadlines = ManualArtworkDeadlines()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkImageCache(
            derivedCache: LocalArtworkDerivedCache(directory: directory),
            remoteDataLoader: { _ in await loader.load() },
            loadDeadlineScheduler: deadlines.schedule
        )
        let reference = ArtworkReference.remote(URL(string: "https://artwork.example.test/\(UUID()).jpg")!)
        let first = Task { await cache.image(for: reference, variant: .posterCard) }
        let second = Task { await cache.image(for: reference, variant: .posterCard) }
        try await waitUntil { cache.pendingWaiterCount == 2 && deadlines.count == 1 }
        first.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(cache.pendingWaiterCount, 1)
        XCTAssertEqual(deadlines.count, 1)
        XCTAssertFalse(deadlines.isCancelled(at: 0))
        await loader.releaseAll()
        let image = await second.value
        XCTAssertNotNil(image)
        XCTAssertTrue(deadlines.isCancelled(at: 0))
        XCTAssertEqual(cache.pendingWaiterCount, 0)
        deadlines.fire(at: 0)
        XCTAssertTrue(cache.cachedImage(for: reference, variant: .posterCard) === image)
    }

    func testLastWaiterCancellationRetiresItsDeadlineWithoutPoisoningTheNextLoad() async throws {
        let loader = ControlledArtworkLoader(first: try imageData(.red), subsequent: try imageData(.blue))
        let deadlines = ManualArtworkDeadlines()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkImageCache(
            derivedCache: LocalArtworkDerivedCache(directory: directory),
            remoteDataLoader: { _ in await loader.load() },
            loadDeadlineScheduler: deadlines.schedule
        )
        let reference = ArtworkReference.remote(URL(string: "https://artwork.example.test/\(UUID()).jpg")!)
        let original = Task { await cache.image(for: reference, variant: .posterCard) }
        await loader.waitUntilStarted(1)
        try await waitUntil { deadlines.count == 1 }
        let originalWork = cache.inFlightTaskForTesting(reference: reference, variant: .posterCard)
        original.cancel()
        let cancelled = await original.value
        XCTAssertNil(cancelled)
        XCTAssertTrue(deadlines.isCancelled(at: 0))

        let replacement = Task { await cache.image(for: reference, variant: .posterCard) }
        await loader.waitUntilStarted(2)
        try await waitUntil { deadlines.count == 2 }
        deadlines.fire(at: 0)
        XCTAssertEqual(cache.pendingWaiterCount, 1)
        await loader.releaseAll()
        let image = await replacement.value
        await originalWork?.value
        XCTAssertNotNil(image)
        XCTAssertTrue(cache.cachedImage(for: reference, variant: .posterCard) === image)
    }

    private func checkExpiredLoad(networkFile: Bool) async throws {
        let loader = ControlledArtworkLoader(
            first: try imageData(.red), subsequent: try imageData(.blue)
        )
        let deadlines = ManualArtworkDeadlines()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkImageCache(
            derivedCache: LocalArtworkDerivedCache(directory: directory),
            remoteDataLoader: { _ in await loader.load() },
            loadDeadlineScheduler: deadlines.schedule
        )
        cache.configure(networkFileService: ArtworkNetworkFileService(loader: loader))
        let reference: ArtworkReference
        if networkFile {
            reference = .networkFile(try NetworkArtworkReference(
                accountID: UUID().uuidString,
                credentialRevision: CredentialRevision(),
                catalogArtworkID: "artwork",
                representation: RemoteFileRepresentation(
                    size: 1_024,
                    identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: .distantPast),
                    consistency: .changeDetecting
                ),
                sourceRevision: UUID().uuidString
            ))
        } else {
            reference = .remote(URL(string: "https://artwork.example.test/\(UUID()).jpg")!)
        }
        let released = expectation(description: "Both consumers released despite an uncooperative transfer")
        released.expectedFulfillmentCount = 2
        let first = Task {
            let value = await cache.image(for: reference, variant: .posterCard)
            released.fulfill()
            return value
        }
        let second = Task {
            let value = await cache.image(for: reference, variant: .posterCard)
            released.fulfill()
            return value
        }
        try await waitUntil { cache.pendingWaiterCount == 2 && deadlines.count == 1 }
        await loader.waitUntilStarted(1)
        let originalWork = cache.inFlightTaskForTesting(reference: reference, variant: .posterCard)
        XCTAssertNotNil(originalWork)
        XCTAssertEqual(deadlines.count, 1, "A coalesced load needs one deadline, not one per consumer.")
        guard deadlines.count == 1 else {
            first.cancel()
            second.cancel()
            await loader.releaseAll()
            _ = await first.value
            _ = await second.value
            await originalWork?.value
            await fulfillment(of: [released], timeout: 2)
            return
        }
        deadlines.fire(at: 0)
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(cache.pendingWaiterCount, 0)
        XCTAssertNil(cache.inFlightTaskForTesting(reference: reference, variant: .posterCard))
        first.cancel()
        second.cancel()
        let firstImage = await first.value
        let secondImage = await second.value
        XCTAssertNil(firstImage)
        XCTAssertNil(secondImage)

        let replacement = Task { await cache.image(for: reference, variant: .posterCard) }
        await loader.waitUntilStarted(2)
        XCTAssertEqual(cache.pendingWaiterCount, 1)
        XCTAssertEqual(deadlines.count, 2)
        deadlines.fire(at: 0)
        XCTAssertEqual(cache.pendingWaiterCount, 1, "An old deadline must not retire a replacement load.")
        await loader.release(2)
        let replacementImage = await replacement.value
        XCTAssertNotNil(replacementImage)
        XCTAssertTrue(deadlines.isCancelled(at: 1))
        await loader.releaseAll()
        await originalWork?.value
        XCTAssertTrue(cache.cachedImage(for: reference, variant: .posterCard) === replacementImage)
        let count = await loader.count
        XCTAssertEqual(count, 2, "A later screen must start fresh work instead of joining the retired request.")
    }

    private func imageData(_ color: UIColor) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image {
            color.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate())
    }
}

private final class ManualArtworkDeadlines: @unchecked Sendable {
    private struct Entry {
        let work: DispatchWorkItem
        let action: @Sendable () -> Void
    }
    private let lock = NSLock()
    private var entries: [Entry] = []

    var count: Int { lock.withLock { entries.count } }

    func schedule(_ action: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem {}
        lock.withLock { entries.append(Entry(work: work, action: action)) }
        return work
    }

    func fire(at index: Int) {
        let action = lock.withLock { entries.indices.contains(index) ? entries[index].action : nil }
        action?()
    }

    func isCancelled(at index: Int) -> Bool {
        lock.withLock { entries.indices.contains(index) && entries[index].work.isCancelled }
    }
}

private actor ControlledArtworkLoader: ArtworkNetworkFileLoading {
    let first: Data
    let subsequent: Data
    private(set) var count = 0
    private var released: Set<Int> = []
    private var allReleased = false
    private var blocked: [Int: CheckedContinuation<Void, Never>] = [:]
    private var starts: [(Int, CheckedContinuation<Void, Never>)] = []

    init(first: Data, subsequent: Data) {
        self.first = first
        self.subsequent = subsequent
    }

    func load() async -> Data {
        count += 1
        let current = count
        let ready = starts.filter { $0.0 <= count }
        starts.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
        if !allReleased, !released.contains(current) {
            await withCheckedContinuation { blocked[current] = $0 }
        }
        return current == 1 ? first : subsequent
    }

    func loadArtwork(_ reference: NetworkArtworkReference, maximumBytes: Int) async throws -> Data {
        await load()
    }

    func waitUntilStarted(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { starts.append((expected, $0)) }
    }

    func release(_ request: Int) {
        released.insert(request)
        blocked.removeValue(forKey: request)?.resume()
    }

    func releaseAll() {
        allReleased = true
        let waiters = Array(blocked.values)
        blocked.removeAll()
        waiters.forEach { $0.resume() }
    }
}
#endif
