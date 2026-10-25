import Foundation

/// Actual player-clock evidence, never reconstructed from a library's watched flag.
public struct TrackerPlaybackSample: Codable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let startedAt: Date
    public let capturedAt: Date
    public let kind: MediaItemKind
    public let providerIDs: [String: String]
    public let season: Int?
    public let episode: Int?
    public let episodeEnd: Int?
    public let ordering: EpisodeOrdering?
    public let position: TimeInterval
    public let duration: TimeInterval
    public let isFinal: Bool
    public var isComplete: Bool { position / duration >= 0.9 }

    public init(
        sessionID: UUID, startedAt: Date, capturedAt: Date = Date(), item: MediaItem,
        position: TimeInterval, duration: TimeInterval, isFinal: Bool
    ) throws {
        guard item.kind == .movie || item.kind == .episode,
              position.isFinite, duration.isFinite, position >= 0, duration > 0,
              startedAt <= capturedAt else { throw AppError.invalidResponse }
        id = UUID()
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.capturedAt = capturedAt
        kind = item.kind
        providerIDs = item.providerIDs
        season = item.seasonNumber
        episode = item.episodeNumber
        episodeEnd = item.episodeNumberEnd
        ordering = item.episodeOrdering
        self.position = min(position, duration)
        self.duration = duration
        self.isFinal = isFinal
        try validate()
    }

    public func validate() throws {
        guard kind == .movie || kind == .episode,
              position.isFinite, duration.isFinite, position >= 0, position <= duration, duration > 0,
              startedAt.timeIntervalSinceReferenceDate.isFinite,
              capturedAt.timeIntervalSinceReferenceDate.isFinite,
              startedAt <= capturedAt else { throw AppError.invalidResponse }
    }
}

public enum TrackerPlaybackDeliveryError: Error, Codable, Equatable, Sendable {
    case connectionChanged, unsupportedIdentity, remoteConflict, unconfirmed
    case retryAfter(TimeInterval?)
}

/// Kept inside the watch outbox, independently of coalesced server-state mutations.
public struct TrackerPlaybackDelivery: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { sample.sessionID }
    public let trackerID: String
    public let connectionID: String
    public let serverScope: WatchMutationServerScope
    public var sample: TrackerPlaybackSample
    public var completedAt: Date?
    public var delivered = false
    public var blocked = false
    public var attempts = 0
    public var nextAttemptAt: Date?

    public init(
        sample: TrackerPlaybackSample, trackerID: String, connectionID: String,
        serverScope: WatchMutationServerScope
    ) {
        self.sample = sample
        self.trackerID = trackerID
        self.connectionID = connectionID
        self.serverScope = serverScope
        completedAt = sample.isComplete ? sample.capturedAt : nil
    }
}
