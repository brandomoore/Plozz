import CoreModels
import CoreNetworking
import Foundation

/// Plex does not reliably retain extra offsets. Only explicitly classified
/// extras receive a local fallback, isolated by profile, account and server user.
actor PlexExtraWatchState {
    private let store: LocalMediaWatchStore
    private var classifications: [String: Bool] = [:]

    init(context: LocalMediaContext, session: UserSession, durableStore: DurableLocalStateStore?) {
        let identity = [session.server.id, context.serverUserID ?? session.userID].map {
            Data($0.utf8).base64EncodedString()
        }.joined(separator: ":")
        store = LocalMediaWatchStore(
            localMediaContext: context, durableStore: durableStore,
            recordID: "plex-extras:\(identity)", refreshOnAccess: true
        )
    }

    private func remember(_ item: MediaItem) -> Bool {
        if classifications.count >= 256 { classifications.removeAll(keepingCapacity: true) }
        let isExtra = item.isExtra || item.isTrailer
        classifications[item.id] = isExtra
        return isExtra
    }

    func stamp(_ item: MediaItem) async -> MediaItem {
        guard remember(item), let record = await store.record(for: item.id) else { return item }
        if let serverDate = item.lastPlayedAt, serverDate > record.updatedAt,
           item.isPlayed || (item.resumePosition ?? 0) > 0 { return item }
        var result = item
        result.resumePosition = record.position > 0 ? record.position : nil
        result.isPlayed = record.played
        result.lastPlayedAt = record.updatedAt
        let duration = record.duration ?? item.runtime
        result.playedPercentage = record.played ? 1 : duration.flatMap {
            $0 > 0 ? min(1, record.position / $0) : nil
        }
        return result
    }

    private func admits(
        _ id: String, load: @Sendable () async throws -> MediaItem
    ) async throws -> Bool {
        if let known = classifications[id] { return known }
        return remember(try await load())
    }

    func isKnownExtra(_ itemID: String) -> Bool { classifications[itemID] == true }

    @discardableResult
    func setResume(
        _ seconds: TimeInterval, itemID: String, capturedAt: Date,
        duration: TimeInterval? = nil, load: @Sendable () async throws -> MediaItem
    ) async throws -> Bool {
        guard seconds.isFinite, seconds >= 0 else { throw AppError.invalidResponse }
        guard try await admits(itemID, load: load) else { return true }
        await store.setResume(seconds, itemID: itemID, capturedAt: capturedAt, duration: duration)
        return await store.record(for: itemID).map { $0.updatedAt <= capturedAt } ?? true
    }

    @discardableResult
    func setPlayed(
        _ played: Bool, itemID: String, capturedAt: Date,
        load: @Sendable () async throws -> MediaItem
    ) async throws -> Bool {
        guard try await admits(itemID, load: load) else { return true }
        await store.setPlayed(played, itemID: itemID, capturedAt: capturedAt)
        return await store.record(for: itemID).map { $0.updatedAt <= capturedAt } ?? true
    }
}
