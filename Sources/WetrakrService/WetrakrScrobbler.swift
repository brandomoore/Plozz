import CoreModels
import CoreNetworking
import CoreTrackerAuth
import Foundation

public actor WetrakrScrobbler: TrackerPlaybackAdmitting {
    private let client: WetrakrClient
    private let auth: WetrakrAuthService
    private let tokenStore: any TrackerTokenStoring
    private let coordinator: TrackerTokenCoordinator
    private let playbackIdentity: String?
    private let activation: TrackerActivationStore
    private let realtimeOperations = ConcurrencyLimiter(limit: 1)

    init(client: WetrakrClient, tokenStore: any TrackerTokenStoring, coordinator: TrackerTokenCoordinator,
         activation: TrackerActivationStore = .init("wetrakr")) {
        self.client = client
        self.auth = WetrakrAuthService(client: client)
        self.tokenStore = tokenStore
        self.coordinator = coordinator
        self.playbackIdentity = tokenStore.load()?.stableAccountIdentity
        self.activation = activation
    }

    public nonisolated var accountIdentity: String? {
        client.config.isConfigured ? tokenStore.load()?.stableAccountIdentity : nil
    }

    public nonisolated var playbackAdmissionID: String? { activation.admission(for: accountIdentity) }

    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {
        guard event != .progress, let admission = playbackAdmissionID else { return }
        await realtimeOperations.runUnlessCancelled { [self] in
            await sendScrobble(item: item, progress: progress, event: event, admission: admission)
        }
    }

    private func sendScrobble(item: MediaItem, progress: Double, event: PlaybackEvent, admission: String) async {
        guard client.config.isConfigured, event != .progress,
              let expected = playbackIdentity, expected == accountIdentity else { return }
        guard let body = Self.body(for: item, progress: progress) else {
            PlozzLog.playback.debug("WeTrakr scrobble skipped: no supported media identity")
            return
        }
        let action: String
        switch event {
        case .start, .unpause: action = "start"
        case .pause: action = "pause"
        case .stop: action = "stop"
        case .progress: return
        }
        do {
            guard let token = try await accessToken(expectedIdentity: expected, admission: admission) else { return }
            let response = try await client.decode(WetrakrScrobbleResponse.self, endpoint: Endpoint(
                method: .post, path: "/scrobble/\(action)",
                queryItems: [.init(name: "min_progress", value: "90")]
            ).jsonBody(body), accessToken: token, validateScope: validate(admission))
            guard response.ignored != true, response.success != false, response.action != nil
            else { throw WetrakrError.itemRejected }
        } catch {
            PlozzLog.playback.debug("WeTrakr realtime scrobble failed; playback continues")
        }
    }

    public func recordWatch(
        item: MediaItem, capturedAt: Date, idempotencyKey: String, expectedAccountIdentity: String
    ) async throws {
        guard let admission = playbackAdmissionID,
              let token = try await accessToken(expectedIdentity: expectedAccountIdentity, admission: admission) else {
            PlozzLog.playback.debug("WeTrakr queued watch skipped: connection changed or disconnected")
            return
        }
        guard let body = Self.historyBody(for: item, capturedAt: capturedAt) else {
            PlozzLog.playback.debug("WeTrakr queued watch skipped: no supported media identity")
            return
        }
        try await client.tracking(body, idempotencyKey: idempotencyKey, accessToken: token, validateScope: validate(admission))
    }

    private func validate(_ admission: String) -> @Sendable () async throws -> Void {
        { [self] in guard admission == playbackAdmissionID else { throw CancellationError() } }
    }

    private func accessToken(expectedIdentity: String, admission: String) async throws -> String? {
        guard client.config.isConfigured, expectedIdentity == accountIdentity,
              admission == playbackAdmissionID else { return nil }
        let token = try await coordinator.accessToken(store: tokenStore, auth: auth)
        try Task.checkCancellation()
        guard expectedIdentity == accountIdentity else { throw CancellationError() }
        guard admission == playbackAdmissionID else { return nil }
        return token
    }

    static func body(for item: MediaItem, progress: Double) -> WetrakrScrobbleBody? {
        guard progress.isFinite else { return nil }
        let percent = min(100, max(0, progress))
        switch item.kind {
        case .movie, .video:
            var ids = WetrakrIDs.from(item.providerIDs)
            // Realtime scrobbling accepts these catalogs only.
            ids.trakt = nil; ids.anilist = nil; ids.myanimelist = nil; ids.anidb = nil
            guard !ids.externalIDs.isEmpty else { return nil }
            return .init(movie: .init(ids: ids), progress: percent)
        case .episode:
            guard let season = item.seasonNumber, season >= 0,
                  let number = item.episodeNumber, number > 0 else { return nil }
            var ids = WetrakrIDs.from(item.providerIDs, series: true)
            ids.trakt = nil; ids.anilist = nil; ids.myanimelist = nil; ids.anidb = nil
            guard !ids.externalIDs.isEmpty else { return nil }
            return .init(show: .init(ids: ids), episode: .init(season: season, number: number), progress: percent)
        default: return nil
        }
    }

    static func historyBody(for item: MediaItem, capturedAt: Date) -> WetrakrTrackingBody? {
        let date = WetrakrDate.string(capturedAt)
        switch item.kind {
        case .movie, .video:
            let ids = WetrakrIDs.from(item.providerIDs)
            guard !ids.externalIDs.isEmpty else { return nil }
            return .init(movies: [.init(ids: ids, status: "watched", trackedAt: date)], allowRewatch: true)
        case .episode:
            guard let season = item.seasonNumber, season >= 0,
                  let number = item.episodeNumber, number > 0 else { return nil }
            let ids = WetrakrIDs.from(item.providerIDs, series: true)
            if ids.externalIDs.isEmpty {
                var episodeIDs = WetrakrIDs.from(item.providerIDs)
                episodeIDs.trakt = nil
                episodeIDs.anilist = nil
                episodeIDs.myanimelist = nil
                episodeIDs.anidb = nil
                guard !episodeIDs.externalIDs.isEmpty else { return nil }
                return .init(
                    episodes: [.init(ids: episodeIDs, status: "watched", trackedAt: date)],
                    allowRewatch: true
                )
            }
            return .init(shows: [.init(ids: ids, seasons: [
                .init(number: season, episodes: [.init(number: number, status: "watched", trackedAt: date)])
            ])], allowRewatch: true)
        default: return nil
        }
    }
}
