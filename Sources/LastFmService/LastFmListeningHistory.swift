import CoreModels
import CoreNetworking
import Foundation

public struct LastFmListeningHistoryPage: Sendable {
    public struct Track: Sendable {
        public let title: String
        public let artist: String
        public let album: String?
        public let musicBrainzID: UUID?
        public let playedAt: Date?
    }
    public let page: Int
    public let totalPages: Int
    public let totalPlays: Int
    public let plays: [Track]
    public let nowPlaying: Track?
}

extension LastFmClient {
    func listeningHistory(
        username: String, page: Int, before: Int,
        validateScope: @escaping @Sendable () async throws -> Void
    ) async throws -> LastFmListeningHistoryPage {
        guard !username.isEmpty, page > 0, page <= Int.max / 50, before >= 0,
              let key = config.apiKey, !key.isEmpty else { throw TrackerHistoryError.invalidSelection }
        try Task.checkCancellation()
        try await validateScope()
        var endpoint = Endpoint(
            method: .get, path: "/2.0/",
            queryItems: [
                .init(name: "method", value: "user.getRecentTracks"), .init(name: "user", value: username),
                .init(name: "api_key", value: key), .init(name: "format", value: "json"),
                .init(name: "page", value: String(page)), .init(name: "limit", value: "50"),
                .init(name: "to", value: String(before)), .init(name: "extended", value: "0")
            ],
            redirectPolicy: .sameOrigin
        )
        endpoint.redactsURLForLogging = true
        endpoint.maximumResponseBytes = 2 * 1_024 * 1_024
        let (data, response) = try await http.send(endpoint, baseURL: config.apiBaseURL)
        try Task.checkCancellation()
        try await validateScope()
        guard response.statusCode == 200, data.count <= 2 * 1_024 * 1_024 else {
            throw TrackerHistoryError.incompleteSnapshot
        }
        let errors: LastFmHistoryErrors
        do { errors = try JSONDecoder().decode(LastFmHistoryErrors.self, from: data) }
        catch { throw TrackerHistoryError.invalidObservation }
        if let code = errors.error {
            PlozzLog.networking.error("Last.fm listening history request was rejected")
            if code == 29 { throw AppError.rateLimited(retryAfter: nil) }
            if [4, 9, 10, 26].contains(code) { throw AppError.unauthorized }
            throw AppError.invalidResponse
        }
        let result: LastFmHistoryResponse
        do { result = try JSONDecoder().decode(LastFmHistoryResponse.self, from: data) }
        catch {
            PlozzLog.networking.error("Last.fm listening history could not be interpreted safely")
            throw TrackerHistoryError.invalidObservation
        }
        return try result.recenttracks.page(username: username, requestedPage: page, before: before)
    }
}

private struct LastFmHistoryErrors: Decodable { let error: Int? }

private struct LastFmHistoryResponse: Decodable {
    let recenttracks: LastFmHistoryRecords
}

private struct LastFmHistoryRecords: Decodable {
    struct Attributes: Decodable {
        let user: String
        let page: String
        let perPage: String
        let totalPages: String
        let total: String
    }
    let track: [LastFmHistoryTrack]
    let attributes: Attributes
    enum CodingKeys: String, CodingKey { case track, attributes = "@attr" }

    func page(username: String, requestedPage: Int, before: Int) throws -> LastFmListeningHistoryPage {
        guard attributes.user.caseInsensitiveCompare(username) == .orderedSame else { throw TrackerHistoryError.scopeChanged }
        guard let page = Int(attributes.page), page == requestedPage, attributes.perPage == "50",
              let total = Int(attributes.total), total >= 0,
              let pages = Int(attributes.totalPages), pages >= 0, track.count <= 51,
              (total == 0 ? (pages == 0 || pages == 1) && page == 1
               : pages == total / 50 + (total % 50 == 0 ? 0 : 1) && page <= pages) else {
            throw TrackerHistoryError.incompleteSnapshot
        }
        var plays: [LastFmListeningHistoryPage.Track] = []
        var nowPlaying: LastFmListeningHistoryPage.Track?
        var previousTime: Date?
        for entry in track {
            let value = try entry.value(before: before)
            if let timestamp = value.playedAt {
                guard previousTime.map({ timestamp <= $0 }) ?? true else { throw TrackerHistoryError.incompleteSnapshot }
                previousTime = timestamp
                plays.append(value)
            } else {
                guard nowPlaying == nil else { throw TrackerHistoryError.invalidObservation }
                nowPlaying = value
            }
        }
        guard plays.count == min(50, total - (page - 1) * 50) else { throw TrackerHistoryError.incompleteSnapshot }
        return .init(page: page, totalPages: pages, totalPlays: total, plays: plays, nowPlaying: nowPlaying)
    }
}

private struct LastFmHistoryTrack: Decodable {
    struct Label: Decodable {
        let text: String
        enum CodingKeys: String, CodingKey { case text = "#text" }
    }
    struct Timestamp: Decodable { let uts: String }
    struct Attributes: Decodable { let nowplaying: String? }
    let name: String
    let artist: Label
    let album: Label?
    let mbid: String?
    let date: Timestamp?
    let attributes: Attributes?
    enum CodingKeys: String, CodingKey { case name, artist, album, mbid, date, attributes = "@attr" }

    func value(before: Int) throws -> LastFmListeningHistoryPage.Track {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !artist.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              attributes?.nowplaying == nil || ["true", "false"].contains(attributes?.nowplaying ?? "") else {
            throw TrackerHistoryError.invalidObservation
        }
        let playedAt: Date?
        if attributes?.nowplaying == "true" {
            guard date == nil else { throw TrackerHistoryError.invalidObservation }
            playedAt = nil
        } else {
            let timestamp = try listeningTimestamp(date?.uts)
            guard timestamp <= before else { throw TrackerHistoryError.incompleteSnapshot }
            playedAt = Date(timeIntervalSince1970: Double(timestamp))
        }
        let id: UUID?
        if let mbid, !mbid.isEmpty {
            guard let value = UUID(uuidString: mbid) else { throw TrackerHistoryError.invalidObservation }
            id = value
        } else { id = nil }
        return .init(title: name, artist: artist.text, album: album?.text, musicBrainzID: id, playedAt: playedAt)
    }
}

private func listeningTimestamp(_ raw: String?) throws -> Int {
    guard let raw, let value = Int(raw), value >= 0 else { throw TrackerHistoryError.invalidObservation }
    return value
}
