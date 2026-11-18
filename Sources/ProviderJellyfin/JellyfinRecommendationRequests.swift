import CoreModels
import Foundation

/// Exact request reuse only: changing itemLimit can change the server's ranking.
actor JellyfinRecommendationRequests {
    struct Key: Hashable, Sendable {
        let scope: UUID
        let revision: UUID
        let user: String
        let library: String
        let limit: Int
    }

    private struct Entry {
        let scope: HomeRecommendationScope
        let expires: ContinuousClock.Instant
        let rows: [MovieRecommendationDto]
        let count: Int
    }

    private struct Pending {
        let flight: UUID
        let lastReader: UUID
    }

    private let requests = JellyfinDiscoveryRequests<[MovieRecommendationDto]>()
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var pending: [Key: Pending] = [:]
    private let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    var waitingReaderCount: Int { get async { await requests.waitingReaderCount } }

    func load(
        scope: HomeRecommendationScope, user: String, library: String, limit: Int, refresh: Bool = false,
        fetch: @escaping @Sendable () async throws -> [MovieRecommendationDto]
    ) async throws -> [MovieRecommendationDto] {
        try Task.checkCancellation()
        guard scope.isActive else { throw CancellationError() }
        let key = Key(scope: scope.id, revision: scope.revision, user: user, library: library, limit: limit)
        prune()
        if refresh {
            entries[key] = nil
            order.removeAll { $0 == key }
        }
        if let entry = entries[key] {
            guard scope.isActive, scope.revision == key.revision else { throw CancellationError() }
            order.removeAll { $0 == key }
            order.append(key)
            return entry.rows
        }
        let flight = refresh ? UUID() : pending[key]?.flight ?? UUID()
        let reader = UUID()
        pending[key] = Pending(flight: flight, lastReader: reader)
        do {
            let rows = try await requests.run(key: flight.uuidString) {
                do {
                    let rows = try await fetch()
                    try await self.store(rows, key: key, scope: scope, flight: flight)
                    return rows
                } catch {
                    if !Task.isCancelled { await self.finish(key: key, flight: flight) }
                    throw error
                }
            }
            guard scope.isActive, scope.revision == key.revision else { throw CancellationError() }
            return rows
        } catch {
            if !(await requests.contains(key: flight.uuidString)), pending[key]?.lastReader == reader {
                finish(key: key, flight: flight)
            }
            throw error
        }
    }

    private func finish(key: Key, flight: UUID) {
        if pending[key]?.flight == flight { pending[key] = nil }
    }

    private func store(
        _ rows: [MovieRecommendationDto], key: Key, scope: HomeRecommendationScope, flight: UUID
    ) throws {
        try Task.checkCancellation()
        guard scope.isActive, scope.revision == key.revision, pending[key]?.flight == flight else {
            throw CancellationError()
        }
        finish(key: key, flight: flight)
        prune()
        let count = rows.reduce(0) { $0 + ($1.Items?.count ?? 0) }
        guard !rows.isEmpty, count <= 2_000 else { return }
        entries[key] = Entry(scope: scope, expires: now() + .seconds(60), rows: rows, count: count)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > 16 || entries.values.reduce(0, { $0 + $1.count }) > 2_000 {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    private func prune() {
        let instant = now()
        entries = entries.filter {
            $0.value.scope.isActive && $0.value.scope.revision == $0.key.revision && $0.value.expires > instant
        }
        order.removeAll { entries[$0] == nil }
    }
}
