import CoreModels
import CoreNetworking
import Foundation

actor PublicMetaDBPlaybackReporter {
    private let client: PublicMetaDBClient
    private let store: DurableLocalStateStore
    private let operations = ConcurrencyLimiter(limit: 1)

    init(client: PublicMetaDBClient, store: DurableLocalStateStore) {
        self.client = client
        self.store = store
    }

    private struct ObservedResume: Codable, Equatable {
        let id: String
        let position: Double
        let duration: Double
        let updatedAt: Date?
    }

    private struct ResumeAttempt: Codable {
        let sampleID: UUID
        let capturedAt: Date
        let resume: PublicMetaDB.Resume
    }

    private struct Receipt: DurableLocalStateValue {
        static let durableLocalStateSchemaID = "com.plozz.publicmetadb-playback.v1"
        let content: PublicMetaDB.Content
        var resumeAttempt: ResumeAttempt?
        var lastResume: ObservedResume?
        var resumeCapturedAt: Date?
        var watchAttemptedAt: Date?
        var baselineWatchIDs: Set<String>?
        var confirmedWatchID: String?
    }

    func report(_ delivery: TrackerPlaybackDelivery) async throws {
        try await operations.run { [self] in
            do {
                try await client.withMutationTransaction {
                    try await self.deliver(delivery)
                }
            }
            catch let error as TrackerPlaybackDeliveryError { throw error }
            catch AppError.rateLimited(let delay) { throw TrackerPlaybackDeliveryError.retryAfter(delay) }
            catch let error as PublicMetaDB.Failure {
                switch error {
                case .invalidKey, .disconnected, .connectionChanged:
                    throw TrackerPlaybackDeliveryError.connectionChanged
                case .uncertainWrite: throw TrackerPlaybackDeliveryError.unconfirmed
                case .blocked: throw TrackerPlaybackDeliveryError.remoteConflict
                case .invalidInput: throw TrackerPlaybackDeliveryError.unsupportedIdentity
                default: throw error
                }
            }
        }
    }

    private func deliver(_ delivery: TrackerPlaybackDelivery) async throws {
        try delivery.sample.validate()
        let content = try Self.content(delivery.sample)
        let key = try DurableLocalStateKey(
            collection: .trackerDeliveryReceipt,
            scope: .source(profileID: delivery.serverScope.profileID, sourceID: delivery.connectionID),
            recordID: delivery.id.uuidString
        )
        var receipt = try store.load(Receipt.self, for: key) ?? Receipt(content: content)
        guard receipt.content == content else { throw TrackerPlaybackDeliveryError.unsupportedIdentity }
        try await reportResume(delivery.sample, receipt: &receipt, key: key)
        if let completedAt = delivery.completedAt {
            try await reportWatch(
                completedAt: completedAt, startedAt: delivery.sample.startedAt,
                receipt: &receipt, key: key
            )
        }
    }

    static func content(_ sample: TrackerPlaybackSample) throws -> PublicMetaDB.Content {
        let namespace: ProviderIDNamespace = sample.kind == .movie ? .tmdb : .seriesTmdb
        guard let id = PublicMetaDB.Content.resolvedTMDBID(sample.providerIDs, namespace: namespace) else {
            throw TrackerPlaybackDeliveryError.unsupportedIdentity
        }
        if sample.kind == .movie { return try .init(tmdbID: id, mediaType: .movie) }
        guard sample.kind == .episode, sample.ordering == .tmdb,
              sample.episodeEnd == nil || sample.episodeEnd == sample.episode,
              let season = sample.season, let episode = sample.episode else {
            throw TrackerPlaybackDeliveryError.unsupportedIdentity
        }
        return try .init(tmdbID: id, mediaType: .tv, season: season, episode: episode)
    }

    private func reportResume(
        _ sample: TrackerPlaybackSample, receipt: inout Receipt, key: DurableLocalStateKey
    ) async throws {
        guard receipt.resumeCapturedAt.map({ sample.capturedAt > $0 }) ?? true else { return }
        let desired = try PublicMetaDB.Resume(
            content: receipt.content, positionMilliseconds: sample.position * 1_000,
            runtimeMilliseconds: sample.duration * 1_000
        )
        guard desired.expectedDisposition != .ignored else { return }
        var observed = try await readResume(receipt.content)
        if let attempted = receipt.resumeAttempt {
            guard Self.matches(observed, attempted.resume) else { throw TrackerPlaybackDeliveryError.unconfirmed }
            receipt.lastResume = observed
            receipt.resumeCapturedAt = attempted.capturedAt
            receipt.resumeAttempt = nil
            try store.save(receipt, for: key)
            if sample.capturedAt <= attempted.capturedAt { return }
        }
        if Self.matches(observed, desired) {
            receipt.resumeCapturedAt = sample.capturedAt
            try store.save(receipt, for: key)
            return
        }
        if let observed, observed != receipt.lastResume,
           observed.updatedAt.map({ $0 > sample.capturedAt }) ?? true {
            throw TrackerPlaybackDeliveryError.remoteConflict
        }
        let history = try await readHistory(receipt.content)
        guard !history.contains(where: { $0.value.watchedAt.map { $0 > sample.capturedAt } ?? false }) else {
            throw TrackerPlaybackDeliveryError.remoteConflict
        }
        receipt.resumeAttempt = ResumeAttempt(sampleID: sample.id, capturedAt: sample.capturedAt, resume: desired)
        try store.save(receipt, for: key)
        do { _ = try await client.saveResume(desired) }
        catch PublicMetaDB.Failure.uncertainWrite {
            // The receipt remains attempted until an independent read proves the result.
        } catch {
            receipt.resumeAttempt = nil
            try store.save(receipt, for: key)
            throw error
        }
        do {
            observed = try await readResume(receipt.content)
            guard Self.matches(observed, desired) else { throw TrackerPlaybackDeliveryError.unconfirmed }
            receipt.lastResume = observed
            receipt.resumeCapturedAt = sample.capturedAt
            receipt.resumeAttempt = nil
            try store.save(receipt, for: key)
        } catch {
            throw TrackerPlaybackDeliveryError.unconfirmed
        }
    }

    private static func matches(_ observed: ObservedResume?, _ desired: PublicMetaDB.Resume) -> Bool {
        if desired.expectedDisposition == .completed { return observed == nil }
        guard let observed else { return false }
        return abs(observed.position - desired.positionMilliseconds) < 1
            && abs(observed.duration - desired.runtimeMilliseconds) < 1
    }

    private func readResume(_ content: PublicMetaDB.Content) async throws -> ObservedResume? {
        let rows = try await client.completePages(maximumPages: 2) {
            try await self.client.resumePoints(content: content, page: $0, perPage: 500)
        }
        guard rows.count <= 1, rows.allSatisfy({ $0.value.content == content }) else {
            throw PublicMetaDB.Failure.incompleteResponse
        }
        guard let row = rows.first else { return nil }
        let updated: Date?
        if let value = row.updated {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
                throw PublicMetaDB.Failure.incompleteResponse
            }
            updated = date
        } else { updated = nil }
        return ObservedResume(
            id: row.id, position: row.value.positionMilliseconds,
            duration: row.value.runtimeMilliseconds, updatedAt: updated
        )
    }

    private func reportWatch(
        completedAt: Date, startedAt: Date, receipt: inout Receipt, key: DurableLocalStateKey
    ) async throws {
        guard receipt.confirmedWatchID == nil else { return }
        let history = try await readHistory(receipt.content)
        if let attempted = receipt.watchAttemptedAt {
            try confirmWatch(history, at: attempted, receipt: &receipt, key: key)
            return
        }
        // A server plugin or another client may already have reported this viewing.
        guard !history.contains(where: { $0.value.watchedAt.map { $0 >= startedAt } ?? false }) else {
            throw TrackerPlaybackDeliveryError.remoteConflict
        }
        receipt.baselineWatchIDs = Set(history.map(\.id))
        receipt.watchAttemptedAt = completedAt
        try store.save(receipt, for: key)
        do { _ = try await client.recordWatch(receipt.content, at: .known(completedAt)) }
        catch PublicMetaDB.Failure.uncertainWrite {
            // Never replay an attempted watched POST, even after process death.
        } catch {
            receipt.watchAttemptedAt = nil
            receipt.baselineWatchIDs = nil
            try store.save(receipt, for: key)
            throw error
        }
        do {
            try confirmWatch(try await readHistory(receipt.content), at: completedAt, receipt: &receipt, key: key)
        } catch { throw TrackerPlaybackDeliveryError.unconfirmed }
    }

    private func readHistory(_ content: PublicMetaDB.Content) async throws -> [PublicMetaDB.Record<PublicMetaDB.Watch>] {
        let history = try await client.completePages(maximumPages: 100) {
            try await self.client.history(content: content, page: $0, perPage: 500)
        }
        guard history.allSatisfy({ $0.value.content == content }) else { throw PublicMetaDB.Failure.incompleteResponse }
        return history
    }

    private func confirmWatch(
        _ history: [PublicMetaDB.Record<PublicMetaDB.Watch>], at date: Date,
        receipt: inout Receipt, key: DurableLocalStateKey
    ) throws {
        guard let baseline = receipt.baselineWatchIDs else { throw TrackerPlaybackDeliveryError.unconfirmed }
        let added = history.filter { !baseline.contains($0.id) }
        guard added.count == 1, let added = added.first, PublicMetaDB.WatchDate.known(date).matches(added.value.watchedAt) else {
            throw TrackerPlaybackDeliveryError.unconfirmed
        }
        receipt.confirmedWatchID = added.id
        try store.save(receipt, for: key)
    }
}
