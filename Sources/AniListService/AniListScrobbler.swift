import Foundation
import CoreModels
import CoreNetworking

/// Sends anime watch progress to AniList. Only fires for anime content
/// (items with an `anilist` or `mal` provider ID, indicating anime).
public protocol AniListScrobbling: TrackerPlaybackAdmitting {
    func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async
    func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws
}

public extension AniListScrobbling {
    func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws {
        await scrobble(item: item, progress: progress, event: event)
    }
}

/// No-op scrobbler when AniList is unconfigured/disconnected.
public struct DisabledAniListScrobbler: AniListScrobbling {
    public init() {}
    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {}
}

/// Live AniList scrobbler. Updates the user's anime list when an episode finishes.
public actor AniListScrobbler: AniListScrobbling {
    private let client: AniListClient
    private let tokenStore: AniListTokenStoring
    private let idMapper: AnimeIDMapper
    private let activation: TrackerActivationStore

    public nonisolated var playbackAdmissionID: String? {
        activation.admission(for: tokenStore.load()?.stableAccountIdentity)
    }

    public init(config: AniListConfig, http: HTTPClient, tokenStore: AniListTokenStoring, idMapper: AnimeIDMapper = .shared) {
        self.init(config: config, http: http, tokenStore: tokenStore, idMapper: idMapper, activation: .init("anilist"))
    }

    init(config: AniListConfig, http: HTTPClient, tokenStore: AniListTokenStoring, idMapper: AnimeIDMapper = .shared,
         activation: TrackerActivationStore) {
        self.client = AniListClient(config: config, http: http)
        self.tokenStore = tokenStore
        self.idMapper = idMapper
        self.activation = activation
    }

    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {
        guard event == .stop, progress >= 80 else { return }
        guard isAnime(item) else { return }
        guard let grant = activation.capture(tokenStore.load, identity: \.stableAccountIdentity) else { return }

        do {
            try await updateList(item: item, accessToken: grant.tokens.accessToken, admission: grant.admission)
            PlozzLog.playback.debug("AniList scrobble succeeded")
        } catch {
            PlozzLog.playback.debug("AniList scrobble failed (non-fatal)")
        }
    }

    public func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws {
        guard event == .stop, progress >= 80 else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "anilist", item: item, outcome: "skip(gate event=\(event) progress=\(Int(progress)))"))
            return
        }
        guard isAnime(item) else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "anilist", item: item, outcome: "skip(not anime)"))
            return
        }
        guard let grant = activation.capture(tokenStore.load, identity: \.stableAccountIdentity) else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "anilist", item: item, outcome: "skip(not connected)"))
            return
        }
        do {
            try await updateList(item: item, accessToken: grant.tokens.accessToken, admission: grant.admission)
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "anilist", item: item, outcome: "OK"))
        } catch {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "anilist", item: item, outcome: "THROW(\(error))"))
            throw error
        }
    }

    // MARK: - Internal

    private func updateList(item: MediaItem, accessToken: String, admission: String) async throws {
        // AniList needs an AniList or MAL id; most anime libraries tag only AniDB,
        // so translate on demand (cached) before falling back to a title search.
        let ids = await idMapper.enrich(extractMappedIDs(from: item.providerIDs))
        guard playbackAdmissionID == admission else { return }
        let mediaId = try await client.findAnime(
            anilistID: ids.anilist,
            malID: ids.mal,
            title: item.parentTitle ?? item.title,
            accessToken: accessToken
        )
        FanoutDiagnostics.emit("anilist.resolve title=\"\(item.parentTitle ?? item.title)\" mal=\(ids.mal.map(String.init) ?? "-") anilist=\(ids.anilist.map(String.init) ?? "-") media=\(mediaId.map(String.init) ?? "miss")")
        guard let mediaId, playbackAdmissionID == admission else { return }

        let episodeProgress = item.episodeNumber
        let status: AniListMediaListStatus = .current

        try await client.saveMediaListEntry(
            mediaId: mediaId,
            status: status,
            progress: episodeProgress,
            accessToken: accessToken
        )
    }

    /// Determines if a media item is anime by checking for anime-specific provider IDs.
    private func isAnime(_ item: MediaItem) -> Bool {
        let ids = item.providerIDs
        for (key, value) in ids {
            let k = key.lowercased()
            if (k == "anilist" || k == "mal" || k == "myanimelist" || k == "anidb" || k == "kitsu"),
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return true
            }
        }
        return false
    }

    private func extractMappedIDs(from providerIDs: [String: String]) -> AnimeMappedIDs {
        var ids = AnimeMappedIDs()
        for (key, rawValue) in providerIDs {
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, let n = Int(value) else { continue }
            switch key.lowercased() {
            case "anilist": ids.anilist = n
            case "mal", "myanimelist": ids.mal = n
            case "anidb": ids.anidb = n
            case "kitsu": ids.kitsu = n
            default: continue
            }
        }
        return ids
    }
}
