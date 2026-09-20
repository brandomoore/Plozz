import Foundation
import Observation
import CoreModels
import CoreNetworking

/// The state of the device's connection to a Seerr (Overseerr / Jellyseerr)
/// instance, rendered by Settings.
public enum SeerConnectionPhase: Equatable, Sendable {
    /// Status not yet determined (initial).
    case unknown
    /// No server URL / API key saved — show the entry fields.
    case unconfigured
    /// A connect/test attempt is in flight.
    case connecting
    /// Connected; `summary` is a short label (server version) for the UI.
    case connected(summary: LocalizedStringResource)
    /// A connect/test attempt failed; the message is user-facing.
    case failed(LocalizedStringResource)
}

/// App-level façade for the Seerr integration — the concrete backing for the
/// Home hero's `FeaturedContentProviding` seam plus the Settings connect flow.
///
/// Owns the connection lifecycle (save/test/disconnect + per-profile scoping) and
/// exposes the read paths the app uses: ``trending(limit:)`` for featured hero
/// content, ``search(_:)``, and one-tap ``request(_:)``. Provider-agnostic
/// `MediaItem`s come out, so nothing above this layer imports Seerr types.
///
/// Mirrors `TraktService`'s shape (observable phase, `setActiveProfile`,
/// `refreshStatus`, factory) so it slots into the existing Settings + AppState
/// wiring with no new patterns.
@MainActor
@Observable
public final class SeerService {
    public private(set) var phase: SeerConnectionPhase = .unknown
    /// Changes whenever the adopted connection is replaced. Views can use this
    /// as a reload key without observing the secret-bearing config itself.
    public private(set) var connectionRevision = UUID()

    @ObservationIgnored private var config: SeerConfig
    /// The shared **household** connection store (URL + admin key), backed in
    /// production by the user-independent Keychain so every tvOS system user and
    /// every profile requests against the same server. The acting Seerr user is
    /// NOT stored here — it's passed per request from the active profile.
    @ObservationIgnored private let connectionStore: SeerConnectionStoring
    /// Legacy per-profile credential store, used ONLY to migrate an existing
    /// per-profile connection into the household slot on first launch. `nil` in
    /// contexts with nothing to migrate (tests/previews).
    @ObservationIgnored private let legacyCredentialStore: SeerCredentialStoring?
    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored let discoveryStatusCoordinator: SeerDiscoveryStatusCoordinator
    /// Invalidates in-flight lifecycle work without changing the revision of the
    /// last successfully adopted connection.
    @ObservationIgnored private var connectionAttemptGeneration: UInt64 = 0

    /// Cached default Radarr/Sonarr servers, used ONLY by the admin (unmapped)
    /// request path to seed `serverId`/`profileId`/`rootFolder` (a mapped user
    /// lets Overseerr apply their own defaults). Each entry is tied to the
    /// connection revision that fetched it.
    @ObservationIgnored private var cachedRadarr: ServerCache?
    @ObservationIgnored private var cachedSonarr: ServerCache?

    private struct ServerCache {
        let revision: UUID
        let server: SeerServiceServer?
    }

    public init(
        connectionStore: SeerConnectionStoring,
        legacyCredentialStore: SeerCredentialStoring? = nil,
        http: HTTPClient = URLSessionHTTPClient(),
        discoveryStatusResponseBudget: Duration = .seconds(5)
    ) {
        self.connectionStore = connectionStore
        self.legacyCredentialStore = legacyCredentialStore
        self.http = http
        let config = Self.loadConfig(from: connectionStore)
        self.config = config
        self.discoveryStatusCoordinator = SeerDiscoveryStatusCoordinator(
            client: SeerClient(config: config, http: http),
            responseBudget: discoveryStatusResponseBudget
        )
    }

    /// Whether a server URL + API key are saved (feature is set up). The hero
    /// gates its featured Request affordances on this: since featured content is
    /// only fetched (via `trending`) when a server is configured and reachable,
    /// this is the reliable, immediately-correct-at-launch signal for "there is a
    /// Seerr to request from" — and it flips to hide Request if the user
    /// disconnects Seerr while stale featured items are still on screen.
    public var isConfigured: Bool {
        _ = connectionRevision
        return Self.hasUsableEndpoint(config)
    }

    /// The saved server URL, for pre-filling the Settings field on re-entry.
    public var savedBaseURLString: String? {
        _ = connectionRevision
        return config.baseURL?.absoluteString
    }

    /// Canonical endpoint identity used to bind profile-level Seerr user IDs.
    public var serverIdentity: SeerServerIdentity? {
        _ = connectionRevision
        return config.baseURL.flatMap(SeerServerIdentity.init(baseURL:))
    }

    /// Browser URL for managing the title in Seerr. Uses Seerr's public
    /// `/movie/{tmdbId}` and `/tv/{tmdbId}` routes, preserving any reverse-proxy
    /// base path while removing URL credentials, query items, and fragments.
    public func mediaManagementURL(for item: MediaItem) -> URL? {
        _ = connectionRevision
        guard config.isConfigured,
              let mediaType = SeerMapper.requestMediaType(for: item),
              let tmdbID = SeerMapper.tmdbID(for: item),
              tmdbID > 0,
              let baseURL = config.baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else { return nil }

        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        components.percentEncodedPath = "\(basePath)/\(mediaType)/\(tmdbID)"
        return components.url
    }

    private var client: SeerClient { SeerClient(config: config, http: http) }

    private static func loadConfig(from store: SeerConnectionStoring) -> SeerConfig {
        guard let connection = store.load() else { return SeerConfig() }
        // Acting user is per-request now, never baked into the connection config.
        return SeerConfig(baseURL: connection.baseURL, apiKey: connection.apiKey, userId: nil)
    }

    private static func hasUsableEndpoint(_ config: SeerConfig) -> Bool {
        config.isConfigured && config.baseURL.flatMap(SeerServerIdentity.init(baseURL:)) != nil
    }

    private static var invalidAddressMessage: LocalizedStringResource {
        "Enter a valid HTTP or HTTPS server address without credentials or a query."
    }

    // MARK: - Lifecycle

    /// Called when the active household profile changes. The Seerr **connection**
    /// is household-wide (one shared slot), so switching profiles does NOT reload
    /// or re-namespace it — only the acting user changes, and that is read
    /// per-request from the active profile. This just re-probes reachability so
    /// the Settings row / hero gating stay fresh.
    public func setActiveProfile(namespace: String?) async {
        await refreshStatus()
    }

    /// One-time migration of a legacy per-profile Seerr connection into the shared
    /// household slot. Pass `[nil] + household profile ids` (nil = default/primary
    /// profile). Promotes the first configured connection found; no-op once the
    /// household slot is set. Reloads config + status after a promotion so the app
    /// reflects the now-shared connection immediately.
    @discardableResult
    public func migrateLegacyConnectionIfNeeded(namespaces: [String?]) async -> SeerConnectionMigrationResult {
        guard let legacyCredentialStore else {
            return SeerConnectionMigrationResult(connection: connectionStore.load(), didPromote: false)
        }
        let result = SeerConnectionMigration.migrateIfNeeded(
            into: connectionStore,
            legacy: legacyCredentialStore,
            namespaces: namespaces
        )
        if result.didPromote {
            let attempt = beginConnectionIntent()
            let loaded = Self.loadConfig(from: connectionStore)
            replaceConfig(with: loaded)
            await probe(
                configSnapshot: loaded,
                revision: connectionRevision,
                attempt: attempt
            )
        }
        return result
    }

    /// Re-read the household connection from the store and re-probe.
    ///
    /// `config` is cached at `init`, so a connection written to the Keychain by
    /// something OTHER than this service — the iCloud-Keychain adopt path or an
    /// incoming pairing bundle, both of which run AFTER the service is built —
    /// would otherwise stay invisible until the next launch. Call this after
    /// installing a connection out-of-band.
    public func reloadConnection() async {
        let attempt = beginConnectionIntent()
        let loaded = Self.loadConfig(from: connectionStore)
        replaceConfig(with: loaded)
        await probe(
            configSnapshot: loaded,
            revision: connectionRevision,
            attempt: attempt
        )
    }

    /// Resolves the current status: probes `/api/v1/status` when a connection is
    /// saved (so the Settings row reflects reachability). Safe to call repeatedly.
    public func refreshStatus() async {
        await probe(
            configSnapshot: config,
            revision: connectionRevision,
            attempt: connectionAttemptGeneration
        )
    }

    /// Validates + saves the household connection ("Connect / Test"). Probes the
    /// server first and only persists when it responds; a bad URL/key surfaces as
    /// `.failed` and nothing is stored.
    public func connect(baseURL: URL, apiKey: String) async {
        let attempt = beginConnectionIntent()
        let trial = SeerConfig(baseURL: baseURL, apiKey: apiKey, userId: nil)
        guard trial.isConfigured else {
            phase = .failed("Enter both a server address and an API key.")
            return
        }
        guard trial.baseURL.flatMap(SeerServerIdentity.init(baseURL:)) != nil else {
            phase = .failed(Self.invalidAddressMessage)
            return
        }
        phase = .connecting
        do {
            let status = try await SeerClient(config: trial, http: http).status()
            guard connectionAttemptGeneration == attempt else { return }
            let connection = SeerConnection(baseURL: baseURL, apiKey: trial.apiKey ?? apiKey)
            do {
                try connectionStore.save(connection)
            } catch {
                phase = .failed("Couldn’t save the Seerr connection.")
                return
            }
            replaceConfig(with: trial)
            phase = .connected(summary: Self.summary(from: status))
        } catch {
            guard connectionAttemptGeneration == attempt else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    /// Disconnects: clears the shared household connection and resets to
    /// unconfigured (for the whole household).
    public func disconnect() {
        _ = beginConnectionIntent()
        do {
            try connectionStore.clear()
            replaceConfig(with: SeerConfig())
            phase = .unconfigured
        } catch {
            phase = .failed("Couldn’t remove the Seerr connection.")
        }
    }

    private func probe(configSnapshot: SeerConfig, revision: UUID, attempt: UInt64) async {
        guard configSnapshot.isConfigured else {
            if connectionAttemptGeneration == attempt, connectionRevision == revision {
                phase = .unconfigured
            }
            return
        }
        guard Self.hasUsableEndpoint(configSnapshot) else {
            if connectionAttemptGeneration == attempt, connectionRevision == revision {
                phase = .failed(Self.invalidAddressMessage)
            }
            return
        }
        phase = .connecting
        do {
            let status = try await SeerClient(config: configSnapshot, http: http).status()
            guard connectionAttemptGeneration == attempt, connectionRevision == revision else { return }
            phase = .connected(summary: Self.summary(from: status))
        } catch {
            guard connectionAttemptGeneration == attempt, connectionRevision == revision else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    @discardableResult
    private func beginConnectionIntent() -> UInt64 {
        connectionAttemptGeneration &+= 1
        return connectionAttemptGeneration
    }

    private func replaceConfig(with newConfig: SeerConfig) {
        config = newConfig
        cachedRadarr = nil
        cachedSonarr = nil
        connectionRevision = UUID()
        discoveryStatusCoordinator.replaceClient(with: client)
    }

    private static func summary(from status: SeerStatus) -> LocalizedStringResource {
        if let version = status.version, !version.isEmpty {
            return "Version \(version)"
        }
        return "Connected"
    }

    private static func message(for error: Error) -> LocalizedStringResource {
        if let appError = error as? AppError { return appError.userMessage }
        return AppError.unknown("").userMessage
    }

    // MARK: - Discovery

    /// Featured hero content in upstream order, deduplicated by title identity.
    /// Fetches up to five pages to backfill unmappable/duplicate entries, returning
    /// at most `min(limit, 100)` titles. Empty/repeated content or the reported last
    /// page ends the pool early. Returns `[]` when unconfigured or `limit <= 0`.
    /// Request/decoding failures propagate; cancellation or a replaced connection
    /// discards the whole in-flight pool instead of returning stale partial data.
    public func trending(limit: Int) async throws -> [MediaItem] {
        let activeConfig = config
        let activeRevision = connectionRevision
        guard Self.hasUsableEndpoint(activeConfig), limit > 0 else { return [] }
        let activeClient = SeerClient(config: activeConfig, http: http)
        let candidateLimit = min(limit, 100)
        let maximumPages = 5
        var collected: [MediaItem] = []
        var seenItemIDs: Set<String> = []
        var seenResultIDs: Set<String> = []

        for pageNumber in 1...maximumPages {
            try Task.checkCancellation()
            let page = try await activeClient.trending(page: pageNumber)
            try Task.checkCancellation()
            guard connectionRevision == activeRevision else { throw CancellationError() }
            guard page.page == pageNumber, page.totalPages >= 0, page.totalResults >= 0 else {
                throw AppError.invalidResponse
            }
            guard !page.results.isEmpty else { break }
            guard page.totalPages >= pageNumber else { throw AppError.invalidResponse }

            var madeProgress = false
            for result in page.results {
                try Task.checkCancellation()
                // Rejected titles/people still count as page progress, allowing
                // a wholly unmappable page to backfill from the next one.
                if seenResultIDs.insert("\(result.mediaType.lowercased()):\(result.id)").inserted {
                    madeProgress = true
                }
                guard let item = SeerMapper.mediaItem(from: result),
                      seenItemIDs.insert(item.id).inserted else { continue }
                madeProgress = true
                collected.append(item)
                if collected.count == candidateLimit { return collected }
            }
            guard madeProgress, pageNumber < page.totalPages else { break }
        }
        return collected
    }

    /// Multi-search for movies/TV via Seerr's discovery backend.
    public func search(_ query: String) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.hasUsableEndpoint(config), !trimmed.isEmpty else { return [] }
        let page = try await client.search(query: trimmed)
        return SeerMapper.mediaItems(from: page)
    }

    /// The current request/availability state for a discovery title, fetched fresh
    /// from Seerr by its TMDB id. Lets a discovery detail page refresh itself on
    /// (re)open so a title requested in an earlier visit shows "Requested"/
    /// "Downloading" instead of a stale "Request" seeded from the search result.
    ///
    /// Returns `nil` when unconfigured, when the item isn't a movie/series with a
    /// TMDB id, or when the lookup fails — the caller then just keeps the seeded
    /// state. An untracked (never-requested) title decodes as `.unknown`.
    public func availability(for item: MediaItem) async -> (MediaAvailabilityStatus, Double?)? {
        guard let availability = await requestAvailability(for: item) else { return nil }
        return (availability.status, availability.downloadProgress)
    }

    /// Current title and season-level request coverage. For TV this combines
    /// Seerr's tracked seasons with the complete TMDB season list so Plozz can
    /// offer only seasons that are truly absent or already in flight.
    public func requestAvailability(for item: MediaItem) async -> MediaRequestAvailability? {
        let activeConfig = config
        let activeRevision = connectionRevision
        guard Self.hasUsableEndpoint(activeConfig),
              let mediaType = SeerMapper.requestMediaType(for: item),
              let tmdbID = SeerMapper.tmdbID(for: item)
        else { return nil }
        let activeClient = SeerClient(config: activeConfig, http: http)
        guard let details = try? await activeClient.mediaDetails(
            mediaType: mediaType,
            tmdbID: tmdbID
        ), connectionRevision == activeRevision else { return nil }
        return SeerMapper.requestAvailability(from: details)
    }

    /// Complete metadata-only episode roster for one TV season. Unlike the
    /// upcoming schedule, Seerr's season endpoint returns past and future
    /// episodes together. Any malformed or internally inconsistent entry fails
    /// the response rather than publishing a truncated authoritative roster.
    public func seasonEpisodeRoster(
        for item: MediaItem,
        seasonNumber: Int
    ) async -> SeasonEpisodeRosterResult {
        let activeConfig = config
        let activeRevision = connectionRevision
        let activeConnectionAttempt = connectionAttemptGeneration
        guard !Task.isCancelled,
              Self.hasUsableEndpoint(activeConfig),
              item.kind == .series,
              seasonNumber >= 0,
              let tmdbID = SeerMapper.tmdbID(for: item),
              tmdbID > 0
        else { return .unavailable }

        let activeClient = SeerClient(config: activeConfig, http: http)
        do {
            let season = try await activeClient.tvSeason(
                tmdbID: tmdbID,
                seasonNumber: seasonNumber
            )
            guard !Task.isCancelled,
                  connectionRevision == activeRevision,
                  connectionAttemptGeneration == activeConnectionAttempt
            else {
                return .unavailable
            }
            guard season.seasonNumber == seasonNumber else { return .failed }

            var seenCoordinates: Set<EpisodeCoordinate> = []
            var seenIDs: Set<Int> = []
            var episodes: [SeasonEpisodeMetadata] = []
            episodes.reserveCapacity(season.episodes.count)

            for episode in season.episodes {
                guard episode.id > 0,
                      episode.seasonNumber == seasonNumber,
                      episode.episodeNumber > 0,
                      seenIDs.insert(episode.id).inserted,
                      seenCoordinates.insert(
                        EpisodeCoordinate(
                            seasonNumber: episode.seasonNumber,
                            episodeNumber: episode.episodeNumber
                        )
                      ).inserted
                else { return .failed }

                let airDate: Date?
                if let rawAirDate = episode.airDate?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !rawAirDate.isEmpty {
                    guard let parsed = MediaItem.calendarDayReleaseDate(from: rawAirDate) else {
                        return .failed
                    }
                    airDate = parsed
                } else {
                    airDate = nil
                }

                let trimmedTitle = episode.name?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let title = trimmedTitle?.isEmpty == false ? trimmedTitle : nil
                episodes.append(
                    SeasonEpisodeMetadata(
                        id: episode.id,
                        seasonNumber: episode.seasonNumber,
                        episodeNumber: episode.episodeNumber,
                        title: title,
                        airDate: airDate,
                        stillURL: SeerMapper.imageURL(path: episode.stillPath, size: "w500")
                    )
                )
            }

            guard !Task.isCancelled,
                  connectionRevision == activeRevision,
                  connectionAttemptGeneration == activeConnectionAttempt
            else {
                return .unavailable
            }
            return .loaded(
                SeasonEpisodeRoster(
                    seriesTMDbID: tmdbID,
                    seasonNumber: seasonNumber,
                    episodes: episodes
                )
            )
        } catch {
            if Task.isCancelled
                || connectionRevision != activeRevision
                || connectionAttemptGeneration != activeConnectionAttempt
            {
                return .unavailable
            }
            return .failed
        }
    }

    private struct EpisodeCoordinate: Hashable {
        let seasonNumber: Int
        let episodeNumber: Int
    }

    // MARK: - Users

    /// All Seerr users, for the "requests are made as" mapping in Settings.
    /// Fetched as **admin** (the acting user only matters for `request`), paged to
    /// completion, and sorted by display name. Returns `[]` when unconfigured.
    public func users() async throws -> [SeerUser] {
        let activeConfig = config
        let activeRevision = connectionRevision
        guard Self.hasUsableEndpoint(activeConfig) else { return [] }
        let activeClient = SeerClient(config: activeConfig, http: http)
        let activeServerIdentity = activeConfig.baseURL.flatMap(SeerServerIdentity.init(baseURL:))
        var collected: [SeerUserDTO] = []
        var skip = 0
        let take = 100
        while true {
            let page = try await activeClient.users(take: take, skip: skip)
            guard connectionRevision == activeRevision else { throw CancellationError() }
            collected.append(contentsOf: page.results)
            skip += page.results.count
            // Terminate on an empty/short page always. When the server reports a
            // total (`pageInfo.results`), also stop once we've collected it. Do NOT
            // fall back to `collected.count` as the total — that would make the
            // "collected >= total" check trivially true and stop after page one for
            // any payload missing `pageInfo`.
            if page.results.isEmpty || page.results.count < take { break }
            if let total = page.pageInfo?.results, collected.count >= total { break }
            if skip > 5000 { break } // safety cap for pathological instances
        }
        return collected
            .map {
                SeerUser.from(
                    $0,
                    baseURL: activeConfig.baseURL,
                    serverIdentity: activeServerIdentity
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Requests

    /// Whether an UNMAPPED request — one that would run as the unrestricted
    /// Seerr admin — must be refused.
    ///
    /// Set while an enforced Kids Profile is active. A Kids Profile that never
    /// got a Seerr user mapped otherwise fell through to the admin path, so a
    /// child could request anything at all with the household's full permissions,
    /// quota and approval bypass — the one restriction people would most assume
    /// a "Kids Profile" already had.
    ///
    /// Enforced HERE rather than in the views: every request funnels through this
    /// method, and the detail/search screens reach it by several routes.
    ///
    /// A live closure rather than a stored flag, so it can't go stale: the answer
    /// depends on the ACTIVE profile, which changes without this service being
    /// told. Defaults to "allowed" so tests and previews behave normally.
    @ObservationIgnored
    public var refusesAdminRequests: () -> Bool = { false }

    /// One-tap request for a not-in-library title, made as the supplied identity.
    ///
    /// - **Mapped user:** omits `serverId`/`profileId`/`rootFolder` so Overseerr
    ///   applies *that user's* defaults (never silently seeds the admin default —
    ///   that would file under the user with the admin's server/profile).
    /// - **Admin (unmapped):** seeds the default Radarr/Sonarr server itself, since
    ///   Seerr won't apply defaults for an omitted body with no user context.
    ///
    /// Returns a ``SeerRequestOutcome`` — success carries the resulting
    /// availability (`.pending` = created, awaiting approval), failure a specific
    /// user-facing reason. Never throws; transport errors map to `.unreachable`.
    @discardableResult
    public func request(
        _ item: MediaItem,
        seasons: [Int]? = nil,
        identity: SeerRequestIdentity = .admin
    ) async -> SeerRequestOutcome {
        // Snapshot first. Requests already in flight are intentionally allowed to
        // finish against this endpoint after a reconnect, but a mapping must
        // match this captured endpoint before any HTTP/default lookup occurs.
        let activeConfig = config
        let activeRevision = connectionRevision
        guard activeConfig.isConfigured else { return .failure(.unknown("Seerr isn’t connected.")) }
        let activeServerIdentity = activeConfig.baseURL.flatMap(SeerServerIdentity.init(baseURL:))
        guard activeServerIdentity != nil else {
            return .failure(
                .unknown("The saved Seerr server address is invalid. Update it in Settings.")
            )
        }
        guard !identity.requiresRelink(to: activeServerIdentity) else {
            return .failure(.mappingNeedsRelink)
        }
        if identity == .admin, refusesAdminRequests() {
            return .failure(.unknown("Ask a grown-up to request this."))
        }
        guard let mediaType = SeerMapper.requestMediaType(for: item),
              let tmdbID = SeerMapper.tmdbID(for: item)
        else { return .failure(.unknown("This title can’t be requested.")) }

        let isTV = mediaType == "tv"
        let requestedSeasons = seasons.map { Array(Set($0.filter { $0 > 0 })).sorted() }
        if isTV, let requestedSeasons, requestedSeasons.isEmpty {
            return .failure(.unknown("Choose at least one season to request."))
        }
        let activeClient = SeerClient(config: activeConfig, http: http)
        let actingUserID = identity.userID

        // Only the admin path seeds a server; a mapped user lets
        // Overseerr resolve their own defaults from the omitted body.
        let server: SeerServiceServer? = identity == .admin
            ? (isTV ? await defaultSonarr(using: activeClient, revision: activeRevision)
                    : await defaultRadarr(using: activeClient, revision: activeRevision))
            : nil

        let body = SeerRequestBody(
            mediaType: mediaType,
            mediaId: tmdbID,
            seasons: isTV ? requestedSeasons.map(SeerSeasons.list) ?? .all : nil,
            is4k: false,
            serverId: server?.id,
            profileId: server?.activeProfileId,
            rootFolder: server?.activeDirectory,
            languageProfileId: isTV ? server?.activeLanguageProfileId : nil
        )

        do {
            let result = try await activeClient.createRequest(body, actingUserID: actingUserID)
            switch result {
            case let .created(response, status, rawBody):
                return interpretCreate(response: response, status: status, rawBody: rawBody)
            case let .failed(status, message):
                // A 409 means Overseerr already has a request for this title. If
                // that existing request is FAILED or DECLINED it's a dead artifact
                // that blocks re-requesting — clear it and recreate a fresh one so
                // the user's tap actually results in a live request.
                if status == 409 {
                    return await recoverFromConflict(
                        mediaType: mediaType,
                        tmdbID: tmdbID,
                        body: body,
                        client: activeClient,
                        actingUserID: actingUserID
                    )
                }
                return .failure(.classify(status: status, message: message, actingUserSent: actingUserID != nil))
            }
        } catch {
            return .failure(.unreachable)
        }
    }

    /// Turns a 2xx `POST /request` (or retry) response into an outcome. A real
    /// request was created only when Seerr returns a request object with an id; a
    /// 2xx that carries no request (e.g. a 202 "nothing to request") means nothing
    /// was queued — surfaced as a failure rather than a fake "Requested".
    private func interpretCreate(
        response: SeerRequestResponse?,
        status: Int,
        rawBody: String?
    ) -> SeerRequestOutcome {
        guard response?.id != nil else {
            let snippet = rawBody?.prefix(300).trimmingCharacters(in: .whitespacesAndNewlines)
            PlozzLog.networking.error(
                "Seerr accepted the call (HTTP \(status)) but created no request. Response: "
                    + (snippet?.isEmpty == false ? snippet! : "empty")
            )
            return .failure(.unknown(nil))
        }
        if let raw = response?.media?.status,
           let mediaStatus = MediaAvailabilityStatus(rawValue: raw) {
            return .success(mediaStatus)
        }
        return .success(.pending)
    }

    /// Recovers from a 409 "already requested" by inspecting the existing request.
    /// FAILED/DECLINED requests are dead — delete and recreate. A genuinely
    /// PENDING/APPROVED request is reported as ``SeerRequestFailure/alreadyRequested``
    /// (the CTA should show "Requested"). An available title reports success.
    private func recoverFromConflict(
        mediaType: String,
        tmdbID: Int,
        body: SeerRequestBody,
        client: SeerClient,
        actingUserID: Int?
    ) async -> SeerRequestOutcome {
        // MediaRequestStatus: pending=1, approved=2, declined=3, failed=4,
        // completed=5. Non-4k only — Plozz never requests 4k.
        guard let details = try? await client.mediaDetails(mediaType: mediaType, tmdbID: tmdbID) else {
            return .failure(.alreadyRequested)
        }
        // If the title is already available in the library, that's a "success".
        if let raw = details.mediaInfo?.status,
           let mediaStatus = MediaAvailabilityStatus(rawValue: raw),
           mediaStatus == .available || mediaStatus == .partiallyAvailable {
            return .success(mediaStatus)
        }
        let request = (details.mediaInfo?.requests ?? []).first { $0.is4k != true }
        guard let request, let requestID = request.id else {
            // A conflict with no inspectable request — treat as already requested.
            return .failure(.alreadyRequested)
        }
        switch request.status {
        case 4: // FAILED — try Overseerr's retry first (reuses the existing row).
            if let retry = try? await client.retryRequest(id: requestID, actingUserID: actingUserID) {
                switch retry {
                case let .created(response, status, rawBody):
                    let outcome = interpretCreate(response: response, status: status, rawBody: rawBody)
                    if case .success = outcome { return outcome }
                case .failed:
                    break
                }
            }
            // Retry unavailable/ineffective — delete the dead request and recreate.
            return await deleteAndRecreate(requestID: requestID, body: body, client: client, actingUserID: actingUserID)
        case 3: // DECLINED — recreate fresh (retry doesn't apply to declined).
            return await deleteAndRecreate(requestID: requestID, body: body, client: client, actingUserID: actingUserID)
        default: // pending / approved / completed — a live request already exists.
            return .failure(.alreadyRequested)
        }
    }

    /// Deletes a stale request then recreates a fresh one, returning the recreate
    /// outcome. If the recreate still conflicts, reports already-requested.
    private func deleteAndRecreate(
        requestID: Int,
        body: SeerRequestBody,
        client: SeerClient,
        actingUserID: Int?
    ) async -> SeerRequestOutcome {
        _ = try? await client.deleteRequest(id: requestID)
        guard let result = try? await client.createRequest(body, actingUserID: actingUserID) else {
            return .failure(.unreachable)
        }
        switch result {
        case let .created(response, status, rawBody):
            return interpretCreate(response: response, status: status, rawBody: rawBody)
        case let .failed(status, message):
            if status == 409 { return .failure(.alreadyRequested) }
            return .failure(.classify(status: status, message: message, actingUserSent: actingUserID != nil))
        }
    }

    private func defaultRadarr(using client: SeerClient, revision: UUID) async -> SeerServiceServer? {
        if let cachedRadarr, cachedRadarr.revision == revision {
            return cachedRadarr.server
        }
        // Only cache a *successful* fetch. A transient failure (timeout, 401,
        // network blip) must stay uncached so the next request retries — caching
        // it would masquerade as "no servers" and permanently drop the default
        // serverId/profileId/rootFolder for the rest of the session.
        guard let resolved = try? await client.radarrServers() else { return nil }
        let chosen = Self.pickDefault(resolved)
        if connectionRevision == revision {
            cachedRadarr = ServerCache(revision: revision, server: chosen)
        }
        return chosen
    }

    private func defaultSonarr(using client: SeerClient, revision: UUID) async -> SeerServiceServer? {
        if let cachedSonarr, cachedSonarr.revision == revision {
            return cachedSonarr.server
        }
        guard let resolved = try? await client.sonarrServers() else { return nil }
        let chosen = Self.pickDefault(resolved)
        if connectionRevision == revision {
            cachedSonarr = ServerCache(revision: revision, server: chosen)
        }
        return chosen
    }

    /// Picks the `isDefault` (non-4K) server, falling back to the first entry.
    private static func pickDefault(_ servers: [SeerServiceServer]?) -> SeerServiceServer? {
        guard let servers, !servers.isEmpty else { return nil }
        if let def = servers.first(where: { ($0.isDefault ?? false) && !($0.is4k ?? false) }) {
            return def
        }
        if let def = servers.first(where: { $0.isDefault ?? false }) {
            return def
        }
        return servers.first
    }
}

/// Builds the app's `SeerService`. In production `AppState` injects the shared
/// household connection store (user-independent Keychain); the in-memory default
/// here is only for tests/previews.
public enum SeerServiceFactory {
    @MainActor
    public static func make(
        http: HTTPClient = URLSessionHTTPClient(),
        connectionStore: SeerConnectionStoring? = nil,
        legacyCredentialStore: SeerCredentialStoring? = nil
    ) -> SeerService {
        SeerService(
            connectionStore: connectionStore ?? InMemorySeerConnectionStore(),
            legacyCredentialStore: legacyCredentialStore ?? defaultLegacyCredentialStore(),
            http: http
        )
    }

    /// Legacy per-profile credential store, used ONLY for the one-time migration
    /// of an existing connection into the shared household slot.
    public static func defaultLegacyCredentialStore() -> SeerCredentialStoring {
        #if canImport(Security)
        return KeychainSeerCredentialStore()
        #else
        return InMemorySeerCredentialStore()
        #endif
    }
}
