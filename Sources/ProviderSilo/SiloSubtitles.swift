import CoreModels
import CoreNetworking
import Foundation

struct SiloRemoteSubtitle: Decodable, Sendable {
    let id: String
    let provider: String
    let language: String
    let release_name: String
    let format: String
    let score: Double
    let downloads: Int
    let hearing_impaired: Bool

    func presentation(id: String) -> RemoteSubtitle {
        RemoteSubtitle(id: id, name: release_name, providerName: provider, language: language,
                       format: format, downloadCount: downloads, isHearingImpaired: hearing_impaired,
                       matchScore: score)
    }
}

private struct SiloStoredSubtitle: Decodable, Sendable {
    let id: String
    let media_file_id: String
    let provider: String
    let language: String
    let format: String
    let release_name: String
    let hearing_impaired: Bool
}

extension SiloProvider {
    public func remoteSubtitleSearch(itemID: String, language: String,
                                     preference: SubtitleSearchPreference) async throws -> [RemoteSubtitle] {
        try await remoteSubtitleSearch(context: playback.subtitleContext(itemID: itemID),
                                       language: language, preference: preference)
    }

    public func downloadRemoteSubtitle(itemID: String, subtitleID: String) async throws {
        _ = try await downloadRemoteSubtitle(context: playback.subtitleContext(itemID: itemID), subtitleID: subtitleID)
    }

    public func subtitleTracks(forItemID itemID: String) async throws -> [MediaTrack] {
        try await subtitleTracks(context: playback.subtitleContext(itemID: itemID))
    }

    public func remoteSubtitleSearch(context: RemoteSubtitleContext, language: String,
                                     preference: SubtitleSearchPreference) async throws -> [RemoteSubtitle] {
        let (_, session) = try await subtitleSession(context)
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.isEmpty, language.count <= 64 else { throw AppError.invalidResponse }
        try await requireSubtitleProviders()
        struct Body: Encodable { let media_file_id: String; let languages: [String] }
        struct Response: Decodable, Sendable { let results: [SiloRemoteSubtitle]; let warnings: [String] }
        let response: Response = try await client.request(
            "/subtitles/search", method: .post,
            body: JSONEncoder().encode(Body(media_file_id: session.sourceID, languages: [language])))
        if !response.warnings.isEmpty {
            PlozzLog.playback.error("Silo subtitle search returned provider warnings count=\(response.warnings.count)")
            if response.results.isEmpty { throw RemoteSubtitleError.incompleteSearch }
        }
        let results = response.results.filter { Self.supportsSubtitleFormat($0.format) }
        guard results.allSatisfy({
            !$0.id.isEmpty && !$0.provider.isEmpty && !$0.language.isEmpty && $0.score.isFinite
        }) else { throw AppError.invalidResponse }
        return try await playback.cacheSubtitleCandidates(results, context: context).applying(preference)
    }

    public func downloadRemoteSubtitle(context: RemoteSubtitleContext, subtitleID: String) async throws -> MediaTrack? {
        let (_, session) = try await subtitleSession(context)
        try await requireSubtitleProviders()
        // A download has no replay receipt. Consume this result before POST so an
        // uncertain response cannot trigger a second upstream provider download.
        let candidate = try await playback.takeSubtitleCandidate(subtitleID, context: context)
        struct Body: Encodable {
            let media_file_id: String
            let provider: String
            let subtitle_id: String
            let language: String
            let release_name: String
            let score: Double
            let hearing_impaired: Bool
        }
        struct Response: Decodable, Sendable { let subtitle: SiloStoredSubtitle }
        let response: Response
        do {
            response = try await client.request(
                "/subtitles/download", method: .post,
                body: JSONEncoder().encode(Body(
                    media_file_id: session.sourceID, provider: candidate.provider, subtitle_id: candidate.id,
                    language: candidate.language, release_name: candidate.release_name,
                    score: candidate.score, hearing_impaired: candidate.hearing_impaired)))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            PlozzLog.playback.error("Silo subtitle download could not be confirmed; not replaying")
            throw RemoteSubtitleError.uncertainDownload
        }
        guard response.subtitle.media_file_id == session.sourceID,
              response.subtitle.provider == candidate.provider,
              response.subtitle.language.caseInsensitiveCompare(candidate.language) == .orderedSame else {
            throw AppError.invalidResponse
        }
        return try await subtitleTrack(response.subtitle, context: context)
    }

    public func subtitleTracks(context: RemoteSubtitleContext) async throws -> [MediaTrack] {
        let (_, session) = try await subtitleSession(context)
        struct Response: Decodable, Sendable { let subtitles: [SiloStoredSubtitle] }
        let response: Response = try await client.request("/subtitles/\(try SiloAPI.pathComponent(session.sourceID))")
        guard response.subtitles.count <= 512,
              response.subtitles.allSatisfy({ $0.media_file_id == session.sourceID }) else {
            throw AppError.invalidResponse
        }
        var tracks: [MediaTrack] = []
        for subtitle in response.subtitles where Self.supportsSubtitleFormat(subtitle.format) {
            tracks.append(try await subtitleTrack(subtitle, context: context))
        }
        return tracks
    }

    private func requireSubtitleProviders() async throws {
        struct Status: Decodable, Sendable {
            let enabled: Bool
            let allowed: Bool
            let state: String
            let providers: [String]
        }
        let status: Status = try await client.request("/subtitles/providers/status")
        guard status.enabled, status.allowed, status.state == "available", !status.providers.isEmpty else {
            throw RemoteSubtitleError.unavailable
        }
    }

    private func subtitleSession(_ context: RemoteSubtitleContext) async throws -> (String, SiloPlaybackSessions.Session) {
        try await client.validateLogin()
        let (id, session) = try await playback.subtitleSession(context)
        _ = try SiloAPI.pathComponent(id)
        return (id, session)
    }

    private func subtitleTrack(_ subtitle: SiloStoredSubtitle, context: RemoteSubtitleContext) async throws -> MediaTrack {
        let (id, active) = try await subtitleSession(context)
        guard subtitle.media_file_id == active.sourceID,
              let trackID = Int(subtitle.id), trackID > 0,
              Self.supportsSubtitleFormat(subtitle.format) else { throw AppError.invalidResponse }
        if let existing = active.downloadedTracks[subtitle.id] { return existing }
        guard var url = URLComponents(url: session.server.baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.invalidResponse
        }
        let basePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // The native API serves stored sidecars even when a node serves the movie.
        // The stable row pin selects the track; the server checks the session/file.
        url.path = (basePath.isEmpty ? "" : "/" + basePath) + "/api/v2/stream/\(id)/subtitles/0.vtt"
        url.queryItems = [
            URLQueryItem(name: "file_id", value: active.sourceID),
            URLQueryItem(name: "downloaded_subtitle_id", value: subtitle.id)
        ]
        let signedFields = URLComponents(url: active.streamURL, resolvingAgainstBaseURL: false)?
            .percentEncodedQuery?.split(separator: "&").filter {
                $0.split(separator: "=", maxSplits: 1).first.map(String.init)?.removingPercentEncoding == "st"
            } ?? []
        guard signedFields.count <= 1 else { throw AppError.invalidResponse }
        if let signed = signedFields.first {
            url.percentEncodedQuery = (url.percentEncodedQuery ?? "") + "&" + signed
        }
        guard let deliveryURL = url.url else { throw AppError.invalidResponse }
        let locator = try AuthenticatedHTTPPlaybackLocator(
            provider: .silo, accountID: accountID, credentialRevision: credentialRevision,
            itemID: context.itemID, mediaSourceID: active.sourceID, deliveryMode: .directFile,
            formatHint: .init(container: "vtt"), purpose: .subtitle,
            resource: .init(pathBase: .configuredBaseURL, path: "silo/\(id)/downloaded/\(subtitle.id)"),
            playSessionID: id)
        let track = MediaTrack(
            id: trackID, kind: .subtitle,
            displayTitle: subtitle.release_name.isEmpty ? subtitle.language : subtitle.release_name,
            language: subtitle.language, codec: "webvtt", isHearingImpaired: subtitle.hearing_impaired,
            deliverySource: .authenticatedHTTP(locator), isExternal: true)
        return try await playback.registerSubtitle(track, storedID: subtitle.id, url: deliveryURL, context: context)
    }

    private static func supportsSubtitleFormat(_ format: String) -> Bool {
        ["srt", "subrip", "vtt", "webvtt", "ass", "ssa"].contains(format.lowercased())
    }
}
