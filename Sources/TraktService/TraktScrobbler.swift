import Foundation
import CoreModels
import CoreNetworking

/// Sends playback state to Trakt so the user's watches sync to their history.
///
/// Best-effort by contract — like the in-app progress report, a scrobble must
/// never interrupt or fail playback, so `scrobble(...)` is non-throwing and
/// swallows every error.
public protocol TraktScrobbling: TrackerPlaybackAdmitting {
    /// Records a playback event for `item` at `progress` (watched percent, 0...100).
    func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async

    /// Durable variant for the watch-state outbox: performs the same scrobble but
    /// **surfaces a failure** (so the reconciler can retry it) while treating
    /// "already scrobbled" (Trakt 409) and disconnected/unsupported targets as
    /// no-ops. Missing identity throws so metadata can be refreshed before retry.
    func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws
}

public extension TraktScrobbling {
    /// Default bridges to the best-effort `scrobble` (success unless overridden).
    func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws {
        await scrobble(item: item, progress: progress, event: event)
    }
}

/// No-op scrobbler used when Trakt is unconfigured or disconnected, so callers
/// can always inject a non-optional value.
public struct DisabledTraktScrobbler: TraktScrobbling {
    public init() {}
    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {}
}

public enum TraktScrobbleError: Error, Equatable, Sendable {
    case unidentifiableItem
}

/// Live scrobbler. An `actor` so token refresh is serialized and the type is
/// `Sendable` for use from the `@MainActor` player.
public actor TraktScrobbler: TraktScrobbling {
    private let client: TraktClient
    private let auth: TraktAuthService
    private let tokenStore: TraktTokenStoring
    private let profileGeneration: TraktProfileGeneration
    private let activation: TrackerActivationStore

    public nonisolated var playbackAdmissionID: String? {
        activation.admission(for: tokenStore.load()?.stableAccountIdentity)
    }

    public init(
        config: TraktConfig,
        http: HTTPClient,
        tokenStore: TraktTokenStoring
    ) {
        self.init(
            config: config,
            http: http,
            tokenStore: tokenStore,
            profileGeneration: TraktProfileGeneration()
        )
    }

    init(
        config: TraktConfig,
        http: HTTPClient,
        tokenStore: TraktTokenStoring,
        profileGeneration: TraktProfileGeneration,
        activation: TrackerActivationStore = .init("trakt")
    ) {
        self.client = TraktClient(config: config, http: http)
        self.auth = TraktAuthService(config: config, http: http)
        self.tokenStore = tokenStore
        self.profileGeneration = profileGeneration
        self.activation = activation
    }

    public func scrobble(item: MediaItem, progress: Double, event: PlaybackEvent) async {
        // Trakt only models start/pause/stop; periodic progress is inferred, so
        // we deliberately skip `.progress` to avoid spamming the scrobble API.
        guard let action = Self.action(for: event) else { return }
        guard let body = Self.scrobbleBody(for: item, progress: progress) else { return }
        do {
            guard let token = try await validAccessToken() else { return }
            try await client.scrobble(action: action, body: body, accessToken: token)
            PlozzLog.playback.debug("Trakt scrobble \(action) succeeded")
        } catch {
            PlozzLog.playback.debug("Trakt scrobble failed (non-fatal)")
        }
    }

    /// Missing metadata remains pending just like a transport failure; the outbox
    /// can reload the original server item instead of recording a false success.
    public func scrobbleResult(item: MediaItem, progress: Double, event: PlaybackEvent) async throws {
        guard let action = Self.action(for: event) else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "trakt", item: item, outcome: "skip(event=\(event) not scrobbled)"))
            return
        }
        guard item.kind == .movie || item.kind == .video || item.kind == .episode else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "trakt", item: item, outcome: "skip(unsupported kind)"))
            return
        }
        guard let token = try await validAccessToken() else {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "trakt", item: item, outcome: "skip(not connected)"))
            return
        }
        guard let body = Self.scrobbleBody(for: item, progress: progress) else {
            PlozzLog.playback.error("Trakt watch delivery deferred: missing media identity.")
            throw TraktScrobbleError.unidentifiableItem
        }
        do {
            try await client.scrobble(action: action, body: body, accessToken: token)
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "trakt", item: item, outcome: "OK(\(action))"))
        } catch {
            FanoutDiagnostics.emit(FanoutDiagnostics.scrobbleLine(tracker: "trakt", item: item, outcome: "THROW(\(error))"))
            throw error
        }
    }

    /// Returns a usable access token, refreshing (and persisting) an expired one.
    /// Only a missing credential is disconnected. Refresh failures must retry.
    private func validAccessToken() async throws -> String? {  // l10n:content — returns an OAuth access token
        let generation = profileGeneration.current
        guard let admission = playbackAdmissionID else { return nil }
        let token = try await TraktTokenCoordinator.shared.accessToken(
            store: tokenStore.snapshot(), auth: auth
        )
        try Task.checkCancellation()
        guard generation == profileGeneration.current else { throw CancellationError() }
        guard admission == playbackAdmissionID else { return nil }
        return token
    }

    // MARK: - Mapping

    public static func canIdentify(_ item: MediaItem) -> Bool {
        scrobbleBody(for: item, progress: 0) != nil
    }

    /// Maps an in-app playback event to a Trakt scrobble action. `.progress`
    /// maps to `nil` (skipped).
    static func action(for event: PlaybackEvent) -> String? {
        switch event {
        case .start, .unpause: return "start"
        case .pause: return "pause"
        case .stop: return "stop"
        case .progress: return nil
        }
    }

    /// Builds a scrobble body from a `MediaItem`, or `nil` when the item can't be
    /// identified on Trakt (no usable external ids).
    static func scrobbleBody(for item: MediaItem, progress: Double) -> TraktScrobbleBody? {
        let clamped = min(max(progress, 0), 100)

        switch item.kind {
        case .episode:
            guard let season = item.seasonNumber, let number = item.episodeNumber else {
                return nil
            }
            let seriesIDs = traktSeriesIDs(from: item.providerIDs)
            if !seriesIDs.isEmpty {
                // Plex and some Jellyfin metadata agents put SHOW ids in an
                // episode's plain ID namespace. Passing those as episode ids makes
                // Trakt resolve an unrelated episode whose id happens to match.
                // The Series* namespace is explicit: identify the show there, then
                // identify its episode only by season/number.
                let show = TraktShowRef(
                    title: item.parentTitle,
                    year: item.productionYear,
                    ids: seriesIDs
                )
                let episode = TraktEpisodeRef(
                    season: season,
                    number: number,
                    ids: TraktIDs()
                )
                return TraktScrobbleBody(
                    show: show,
                    episode: episode,
                    progress: clamped
                )
            }
            let episodeIDs = traktIDs(from: item.providerIDs)
            guard !episodeIDs.isEmpty else { return nil }
            let episode = TraktEpisodeRef(
                season: season,
                number: number,
                ids: episodeIDs
            )
            return TraktScrobbleBody(episode: episode, progress: clamped)
        case .movie, .video:
            let ids = traktIDs(from: item.providerIDs)
            guard !ids.isEmpty else { return nil }
            let movie = TraktMovieRef(title: item.title, year: item.productionYear, ids: ids)
            return TraktScrobbleBody(movie: movie, progress: clamped)
        default:
            // Series/seasons/folders aren't directly playable scrobble targets.
            return nil
        }
    }

    /// Extracts Trakt-shaped ids from a provider's id map, tolerating the
    /// differing key casing across providers (`Imdb`/`imdb`, `Tmdb`/`tmdb`, …).
    static func traktIDs(from providerIDs: [String: String]) -> TraktIDs {
        var ids = TraktIDs()
        for (key, rawValue) in providerIDs {
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key.lowercased() {
            case "imdb":
                if value.hasPrefix("tt") { ids.imdb = value }
            case "tmdb":
                ids.tmdb = Int(value)
            case "tvdb":
                ids.tvdb = Int(value)
            case "trakt":
                ids.trakt = Int(value)
            default:
                continue
            }
        }
        return ids
    }

    /// Extracts explicit show-level IDs stamped under the `Series*` namespace.
    /// These must never be passed as episode IDs.
    static func traktSeriesIDs(from providerIDs: [String: String]) -> TraktIDs {
        var ids = TraktIDs()
        for (key, rawValue) in providerIDs {
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key.lowercased() {
            case "seriesimdb":
                if value.hasPrefix("tt") { ids.imdb = value }
            case "seriestmdb":
                ids.tmdb = Int(value)
            case "seriestvdb":
                ids.tvdb = Int(value)
            case "seriestrakt":
                ids.trakt = Int(value)
            default:
                continue
            }
        }
        return ids
    }
}
