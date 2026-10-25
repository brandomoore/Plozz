import Foundation

/// A title-level list entry, not a log of individual episode plays.
public struct TrackerAnimeListProgress: Encodable, Hashable, Sendable {
    public enum Status: Encodable, Hashable, Sendable {
        case planning, watching, completed, paused, dropped, rewatching
    }

    public let status: Status?
    public let episodesWatched: Int?
    public let repeats: Int?
    public let score: Double?
    public let updatedAt: Date?

    public init(
        status: Status?, episodesWatched: Int?, repeats: Int?, score: Double?, updatedAt: Date?
    ) throws {
        guard episodesWatched.map({ $0 >= 0 }) ?? true, repeats.map({ $0 >= 0 }) ?? true,
              score.map({ $0.isFinite && (0...10).contains($0) }) ?? true,
              updatedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
            throw TrackerHistoryError.invalidObservation
        }
        self.status = status
        self.episodesWatched = episodesWatched
        self.repeats = repeats
        self.score = score == 0 ? nil : score
        self.updatedAt = updatedAt
    }
}
