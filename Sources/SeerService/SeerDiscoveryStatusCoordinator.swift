import CoreModels
import CoreNetworking
import Foundation

/// Separates a carousel's response lifetime from native HTTP work. The shared
/// limiter keeps its permits until HTTP actually returns, even after retirement.
@MainActor
final class SeerDiscoveryStatusCoordinator {
    private struct Reply: Sendable {
        let index: Int
        let item: MediaItem
    }

    private final class Batch {
        let candidates: [MediaItem]
        let client: SeerClient
        let expiresAt: ContinuousClock.Instant
        let continuation: AsyncStream<Reply>.Continuation
        var nextIndex = 0
        var completedCount = 0
        var workers: [Task<Void, Never>] = []
        var deadline: Task<Void, Never>?

        init(
            candidates: [MediaItem],
            client: SeerClient,
            expiresAt: ContinuousClock.Instant,
            continuation: AsyncStream<Reply>.Continuation
        ) {
            self.candidates = candidates
            self.client = client
            self.expiresAt = expiresAt
            self.continuation = continuation
        }
    }

    private let limiter = ConcurrencyLimiter(limit: 4)
    private let responseBudget: Duration
    private var client: SeerClient
    private var batches: [UUID: Batch] = [:]

    init(client: SeerClient, responseBudget: Duration) {
        self.client = client
        self.responseBudget = max(.zero, responseBudget)
    }

    func replaceClient(with client: SeerClient) {
        self.client = client
        for id in Array(batches.keys) { finish(id) }
    }

    func updates(for candidates: [MediaItem]) async -> [MediaItem] {
        guard !candidates.isEmpty, !Task.isCancelled else { return [] }
        let id = UUID()
        let expiresAt = ContinuousClock.now.advanced(by: responseBudget)
        let channel = AsyncStream<Reply>.makeStream(
            bufferingPolicy: .bufferingNewest(candidates.count)
        )
        let batch = Batch(
            candidates: candidates, client: client, expiresAt: expiresAt,
            continuation: channel.continuation
        )
        batches[id] = batch

        let workers = (0..<min(4, candidates.count)).map { _ in
            Task {
                while !Task.isCancelled {
                    let more = try? await limiter.runUnlessCancelled {
                        () async throws -> Bool in
                        await self.loadNext(in: id)
                    }
                    guard more == true else { return }
                }
            }
        }
        batch.workers = workers
        channel.continuation.onTermination = { [weak self] _ in
            // AsyncStream invokes this synchronously on caller cancellation;
            // cancel queued workers before scheduling actor-owned bookkeeping.
            workers.forEach { $0.cancel() }
            Task { @MainActor in self?.finish(id) }
        }
        batch.deadline = Task { [weak self] in
            do { try await ContinuousClock().sleep(until: expiresAt) }
            catch { return }
            self?.finish(id, expired: true)
        }

        var replies: [Int: MediaItem] = [:]
        for await reply in channel.stream {
            replies[reply.index] = reply.item
        }
        finish(id)
        guard !Task.isCancelled else { return [] }
        return candidates.indices.compactMap { replies[$0] }
    }

    /// Called only while holding a permit, so admission is rechecked after any
    /// wait behind another batch's cancelled-but-still-running transport.
    private func loadNext(in id: UUID) async -> Bool {
        guard !Task.isCancelled, let batch = liveBatch(id),
              batch.nextIndex < batch.candidates.count else { return false }
        let index = batch.nextIndex
        batch.nextIndex += 1
        let item = batch.candidates[index]
        guard let mediaType = SeerMapper.requestMediaType(for: item),
              let tmdbID = SeerMapper.tmdbID(for: item), tmdbID > 0 else {
            complete(id, batch: batch)
            return true
        }

        do {
            let details = try await batch.client.mediaDetails(
                mediaType: mediaType, tmdbID: tmdbID
            )
            guard !Task.isCancelled, liveBatch(id) === batch else { return false }
            let availability = SeerMapper.requestAvailability(from: details)
            var updated = item
            updated.availability = availability.status
            updated.downloadProgress = availability.downloadProgress
            batch.continuation.yield(Reply(index: index, item: updated))
        } catch {
            guard !Task.isCancelled, liveBatch(id) === batch else { return false }
            PlozzLog.discovery.error(
                "Featured Seerr status lookup failed; keeping completed statuses"
            )
        }
        complete(id, batch: batch)
        return batch.nextIndex < batch.candidates.count
    }

    private func liveBatch(_ id: UUID) -> Batch? {
        guard let batch = batches[id] else { return nil }
        guard ContinuousClock.now < batch.expiresAt else {
            finish(id, expired: true)
            return nil
        }
        return batch
    }

    private func complete(_ id: UUID, batch: Batch) {
        batch.completedCount += 1
        if batch.completedCount == batch.candidates.count { finish(id) }
    }

    private func finish(_ id: UUID, expired: Bool = false) {
        guard let batch = batches.removeValue(forKey: id) else { return }
        batch.deadline?.cancel()
        batch.deadline = nil
        batch.workers.forEach { $0.cancel() }
        batch.workers = []
        batch.continuation.finish()
        if expired {
            PlozzLog.discovery.error(
                "Featured Seerr status reached its response deadline; keeping completed statuses"
            )
        }
    }
}
