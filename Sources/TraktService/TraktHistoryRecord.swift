import CoreModels
import CoreNetworking
import Foundation

enum TraktHistoryDiagnostics {
    static func incomplete(_ source: StaticString, _ reason: StaticString) -> TrackerHistoryError {
        HandoffDiagnostics.emit("TRAKT_HISTORY incomplete source=\(source) reason=\(reason)")
        return .incompleteSnapshot
    }
}

struct TraktCorrectedWatchTotal: Error {
    let ids: Set<Int>
}

@MainActor
final class TraktHistoryReadCooldown {
    private var until = Date.distantPast
    func requireReady() throws {
        let remaining = until.timeIntervalSinceNow
        if remaining > 0 { throw AppError.rateLimited(retryAfter: remaining) }
    }
    func block(seconds: TimeInterval?) -> Date {
        until = max(until, Date().addingTimeInterval(max(1, seconds ?? 60)))
        return until
    }
}

@MainActor
final class TraktHistoryReadAttempt {
    let cooldown: TraktHistoryReadCooldown
    private var retried = false
    init(cooldown: TraktHistoryReadCooldown) { self.cooldown = cooldown }
    func pause(after delay: TimeInterval?) async throws {
        let until = cooldown.block(seconds: delay)
        let remaining = until.timeIntervalSinceNow
        // Only one short, server-directed retry per snapshot. Never restart pagination.
        guard !retried, delay != nil, remaining <= 15 else { throw AppError.rateLimited(retryAfter: remaining) }
        retried = true
        TrackerHistoryReadDetail.report?(.waiting(until: until))
        try await Task.sleep(for: .seconds(max(0, remaining)))
        try cooldown.requireReady()
        TrackerHistoryReadDetail.report?(nil)
    }
}

extension TraktClient {
    func readPage(_ endpoint: Endpoint, validate: @Sendable () async throws -> Void) async throws -> (Data, HTTPURLResponse) {
        guard let historyRead else { return try await http.sendRaw(endpoint, baseURL: config.apiBaseURL) }
        while true {
            try await historyRead.cooldown.requireReady()
            try await validate()
            try Task.checkCancellation()
            let result = try await http.sendRaw(endpoint, baseURL: config.apiBaseURL)
            guard result.1.statusCode == 429,
                  case .rateLimited(let delay) = oauthError(data: result.0, response: result.1) else { return result }
            HandoffDiagnostics.emit("TRAKT_HISTORY rate-limited")
            try await validate()
            try await historyRead.pause(after: delay)
        }
    }

    func verifyWatchRanges(
        _ correction: TraktCorrectedWatchTotal, accessToken: String,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> [TraktHistoryRecord] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .gmt
        guard let boundary = calendar.dateInterval(of: .year, for: Date())?.start else {
            throw TrackerHistoryError.incompleteSnapshot
        }
        // Open-ended halves cover all dates. Overlap by a second so boundary inclusivity
        // cannot drop a play. Only identical copies of the same play may overlap.
        let start = boundary.addingTimeInterval(-1)
        var verified: [Int: TraktHistoryRecord] = [:]
        for (field, cutoff) in [("end_at", boundary), ("start_at", start)] {
            let records: [TraktHistoryRecord] = try await paginatedGET(
                path: "/users/me/history", accessToken: accessToken, requiresCompleteEvidence: true,
                query: [URLQueryItem(name: field, value: cutoff.formatted(.iso8601))], validateScope: validateScope
            )
            for record in records {
                guard correction.ids.contains(record.id),
                      let date = record.watchedAt.flatMap(Self.parseTimestamp),
                      field == "end_at" ? date <= cutoff : date >= cutoff else {
                    throw TraktHistoryDiagnostics.incomplete("watches", "date-range")
                }
                if let previous = verified.updateValue(record, forKey: record.id) {
                    guard (start...boundary).contains(date), previous == record else {
                        throw TraktHistoryDiagnostics.incomplete("watches", "range-overlap")
                    }
                }
            }
        }
        guard verified.count == correction.ids.count else {
            throw TraktHistoryDiagnostics.incomplete("watches", "range-membership")
        }
        return verified.values.sorted { $0.id < $1.id }
    }
}

struct TraktHistoryRecord: Decodable, Equatable, Sendable {
    let id: Int
    let type: String
    let movie: TraktMovieRef?
    let show: TraktShowRef?
    let episode: TraktEpisodeRef?
    let watchedAt: String?
    let action: String?
    let pausedAt: String?
    let progress: Double?

    enum CodingKeys: String, CodingKey {
        case id, type, movie, show, episode, action, progress
        case watchedAt = "watched_at"
        case pausedAt = "paused_at"
    }

    func observation(playback: Bool) throws -> TrackerHistoryObservation {
        guard id > 0 else { throw TrackerHistoryError.invalidObservation }
        let fact: TrackerHistoryObservation.Fact
        if playback {
            guard let progress, let pausedAt, let date = TraktClient.parseTimestamp(pausedAt) else {
                throw TrackerHistoryError.invalidObservation
            }
            // Catalog runtimes cannot establish the duration of the played file.
            fact = .pausedProgress(progress, at: date)
        } else {
            guard let action, ["watch", "scrobble", "checkin"].contains(action),
                  let watchedAt, let date = TraktClient.parseTimestamp(watchedAt) else {
                throw TrackerHistoryError.invalidObservation
            }
            fact = .watched(at: date)
        }
        let recordID = "\(playback ? "resume" : "watched")/\(id)"
        return try observation(fact: fact, recordID: recordID)
    }

    func exportProtection() throws -> TrackerHistoryObservation {
        guard let action, ["watch", "scrobble", "checkin"].contains(action) else {
            throw TrackerHistoryError.invalidObservation
        }
        let date = watchedAt.flatMap(TraktClient.parseTimestamp)
        if date == nil {
            PlozzLog.networking.info("Trakt watch date unavailable; retaining only existing-watch protection")
        }
        return try observation(fact: .watched(at: date), recordID: "watched/\(id)")
    }

    func observation(fact: TrackerHistoryObservation.Fact, recordID: String) throws -> TrackerHistoryObservation {
        guard id > 0 else { throw TrackerHistoryError.invalidObservation }
        switch type {
        case "movie":
            guard let movie, show == nil, episode == nil else { throw TrackerHistoryError.invalidObservation }
            return try .init(
                recordID: recordID, kind: .movie, identities: movie.ids.historyIdentities(), fact: fact
            )
        case "episode":
            guard movie == nil, let show, let episode, let season = episode.season, let number = episode.number else {
                throw TrackerHistoryError.invalidObservation
            }
            let suffix = ":s\(season)e\(number)"
            return try .init(
                recordID: recordID, kind: .episode,
                identities: episode.ids.historyIdentities(suffix: suffix)
                    + show.ids.historyIdentities(prefix: "series-", suffix: suffix),
                season: season, episode: number, requiresExactEpisodeIdentity: true, fact: fact
            )
        default:
            throw TrackerHistoryError.invalidObservation
        }
    }
}

extension TraktIDs {
    func historyIdentities(prefix: String = "", suffix: String = "") throws -> [MediaIdentity] {
        var result: [MediaIdentity] = []
        for (source, id) in [("tmdb", tmdb), ("tvdb", tvdb), ("trakt", trakt)] {
            guard let id else { continue }
            guard id > 0 else { throw TrackerHistoryError.invalidObservation }
            result.append(.external(source: prefix + source + suffix, value: String(id)))
        }
        if let imdb {
            guard imdb.range(of: #"\Att[0-9]{1,16}\z"#, options: .regularExpression) != nil else {
                throw TrackerHistoryError.invalidObservation
            }
            result.append(.external(source: prefix + "imdb" + suffix, value: imdb))
        }
        return result
    }
}

struct TraktHistoryActivity: Decodable, Equatable, Sendable {
    struct MediaActivity: Decodable, Equatable, Sendable {
        let watchedAt: String
        let pausedAt: String
        enum CodingKeys: String, CodingKey {
            case watchedAt = "watched_at"
            case pausedAt = "paused_at"
        }
    }
    let all: String
    let movies: MediaActivity
    let episodes: MediaActivity

    func validate() throws {
        guard [all, movies.watchedAt, movies.pausedAt, episodes.watchedAt, episodes.pausedAt]
            .allSatisfy({ TraktClient.parseTimestamp($0) != nil }) else {
            throw TraktHistoryDiagnostics.incomplete("activity", "invalid-timestamp")
        }
    }
}
