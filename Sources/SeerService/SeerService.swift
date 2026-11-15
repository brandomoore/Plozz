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
    /// Explicit profile/credential changes invalidate results; remembering a
    /// successful destination changes browsing state without revoking its receipt.
    public var requestAuthorizationGeneration: UInt64 { connectionAttemptGeneration }

    @ObservationIgnored private var storedConfig: SeerConfig
    private var config: SeerConfig {
        if let profileSource, profileSource().id != activeProfileID { return .init() }
        return storedConfig
    }
    public private(set) var profileConnections = SeerProfileConnections()
    public private(set) var activeProfileID: String?
    public private(set) var pendingDestination: UUID?
    public private(set) var storageFailure: LocalizedStringResource?
    @ObservationIgnored private var destinationContinuation: CheckedContinuation<UUID?, Never>?
    @ObservationIgnored private var profileSource: (() -> Profile)?
    @ObservationIgnored private var accountConnectionStore: SeerAccountConnectionStoring = InMemorySeerAccountConnectionStore()
    @ObservationIgnored public var loginOptions: () -> [SeerLoginOption] = { [] }
    @ObservationIgnored public var suggestedAddresses: () async throws -> [URL] = { [] }
    @ObservationIgnored public var localDiscoveryHosts: () -> [String] = { [] }
    @ObservationIgnored public var plexSignIn: ((URL, @escaping @MainActor (URL) -> Void) async throws -> SeerAuthenticatedAccount)?
    /// Retained only for migration and legacy callers. Profile-aware app code
    /// uses `accountConnectionStore`; new profiles never inherit this key.
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
        http: HTTPClient = SeerAuthentication.makeHTTPClient(),
        discoveryStatusResponseBudget: Duration = .seconds(5)
    ) {
        self.connectionStore = connectionStore
        self.legacyCredentialStore = legacyCredentialStore
        self.http = http
        let config = Self.loadConfig(from: connectionStore)
        self.storedConfig = config
        self.discoveryStatusCoordinator = SeerDiscoveryStatusCoordinator(
            client: SeerClient(config: config, http: http),
            responseBudget: discoveryStatusResponseBudget
        )
    }

    /// Whether a server URL and credential are saved (feature is set up). The hero
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

    public var requestIdentity: SeerRequestIdentity {
        let userID = config.session?.userID ?? config.userId
        return userID.map { .user(id: $0, server: serverIdentity) } ?? .admin
    }

    public var requestAccountName: String? { profileConnections.selected?.accountName }

    public var needsAdminConfirmation: Bool {
        !profileConnections.offersChoice && config.session == nil && requestIdentity == .admin
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

    /// Re-scope credentials before probing the active profile's connection.
    public func setActiveProfile(namespace: String?) async {
        synchronizeProfile()
        await refreshStatus()
    }

    public func configureProfiles(
        store: SeerAccountConnectionStoring, profiles: [Profile],
        current: @escaping () -> Profile
    ) {
        accountConnectionStore = store
        profileSource = current
        do {
            _ = try connectionStore.read()
            if let legacyCredentialStore {
                _ = SeerConnectionMigration.migrateIfNeeded(
                    into: connectionStore, legacy: legacyCredentialStore,
                    namespaces: [nil] + profiles.map { Optional($0.id) }
                )
            }
            try store.migrateLegacy(try connectionStore.read(), profiles: profiles)
            storageFailure = nil
        }
        catch {
            PlozzLog.sync.error("Seerr profile connection migration failed")
            storageFailure = "Couldn’t save the Seerr connection."
            phase = .failed("Couldn’t save the Seerr connection.")
        }
        activeProfileID = nil
        synchronizeProfile()
    }

    public func synchronizeProfile() {
        guard let profile = profileSource?(), profile.id != activeProfileID else { return }
        chooseDestination(nil)
        _ = beginConnectionIntent()
        activeProfileID = profile.id
        do {
            profileConnections = try accountConnectionStore.load(profileID: profile.id)
            replaceConfig(with: profileConnections.selected?.config ?? .init())
            phase = storedConfig.isConfigured ? .unknown : .unconfigured
        } catch {
            profileConnections = .init()
            replaceConfig(with: .init())
            PlozzLog.sync.error("Seerr profile connections could not be loaded")
            storageFailure = "Couldn’t read the saved Seerr connections."
            phase = .failed("Couldn’t read the saved Seerr connections.")
        }
    }

    public func saveAccount(
        _ account: SeerAuthenticatedAccount, expectedProfileID: String,
        expectedRevision: UUID, replacing: UUID? = nil
    ) throws {
        synchronizeProfile()
        guard activeProfileID == expectedProfileID, connectionRevision == expectedRevision else { throw CancellationError() }
        if case let .session(session) = account.credential, refusesAdminRequests(), session.permissions & 2 != 0 {
            throw AppError.unauthorized
        }
        var state = profileConnections
        if let replacing, !state.connections.contains(where: { $0.id == replacing }) { throw AppError.notFound }
        let existing = state.connections.first(where: { $0.id == replacing })
        var credential = account.credential
        if let existing,
           SeerServerIdentity(baseURL: existing.baseURL) == SeerServerIdentity(baseURL: account.baseURL),
           case let .apiKey(_, userID, userName) = existing.credential,
           case let .apiKey(key, _, _) = credential {
            credential = .apiKey(key: key, userID: userID, userName: userName)
        }
        var saved = SeerAccountConnection(
            id: replacing ?? UUID(), baseURL: account.baseURL,
            name: existing?.name ?? "",
            credential: credential
        )
        if case .apiKey = credential, let existing {
            saved.requiresRelink = existing.requiresRelink
        }
        if replacing == nil, let duplicate = state.connections.first(where: {
            SeerServerIdentity(baseURL: $0.baseURL) == SeerServerIdentity(baseURL: saved.baseURL)
                && $0.config.session?.userID == saved.config.session?.userID
                && $0.config.userId == saved.config.userId
                && ($0.config.session != nil) == (saved.config.session != nil)
        }) {
            saved.id = duplicate.id
            saved.name = duplicate.name
            saved.requiresRelink = duplicate.requiresRelink
        }
        state.connections.removeAll { $0.id == saved.id }
        state.connections.append(saved)
        state.repairSelection()
        state.configured = true
        try persist(state)
    }

    public func updateSelection(defaultID: UUID?, rememberLastUsed: Bool, askEachTime: Bool) throws {
        synchronizeProfile()
        guard let defaultID, profileConnections.connections.contains(where: { $0.id == defaultID }) else { throw AppError.notFound }
        var state = profileConnections
        state.defaultID = defaultID
        state.rememberLastUsed = rememberLastUsed
        state.askEachTime = askEachTime
        try persist(state)
    }

    public func removeConnection(_ id: UUID) throws {
        synchronizeProfile()
        var state = profileConnections
        state.connections.removeAll { $0.id == id }
        state.repairSelection()
        state.configured = true
        try persist(state)
    }

    public func users(for connectionID: UUID) async throws -> [SeerUser] {
        synchronizeProfile()
        let revision = connectionRevision
        guard let saved = profileConnections.connections.first(where: { $0.id == connectionID }),
              case .apiKey = saved.credential else { throw AppError.unauthorized }
        var config = saved.config
        config.userId = nil
        return try await users(config: config, revision: revision)
    }

    public func setRequestUser(_ user: SeerUser?, connectionID: UUID) throws {
        synchronizeProfile()
        var state = profileConnections
        guard let index = state.connections.firstIndex(where: { $0.id == connectionID }),
              case let .apiKey(key, _, _) = state.connections[index].credential else { throw AppError.unauthorized }
        if let user {
            guard user.serverIdentity == SeerServerIdentity(baseURL: state.connections[index].baseURL),
                  user.id > 0 else { throw AppError.unauthorized }
        } else if refusesAdminRequests() { throw AppError.unauthorized }
        state.connections[index].credential = .apiKey(key: key, userID: user?.id, userName: user?.name)
        state.connections[index].requiresRelink = false
        try persist(state)
    }

    public func chooseDestination(_ id: UUID?) {
        pendingDestination = nil
        let continuation = destinationContinuation
        destinationContinuation = nil
        continuation?.resume(returning: id)
    }

    private func persist(_ state: SeerProfileConnections) throws {
        guard let activeProfileID else { throw AppError.unauthorized }
        try accountConnectionStore.save(state, profileID: activeProfileID)
        chooseDestination(nil)
        storageFailure = nil
        profileConnections = state
        _ = beginConnectionIntent()
        replaceConfig(with: state.selected?.config ?? .init())
        phase = storedConfig.isConfigured ? .unknown : .unconfigured
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

    /// Re-read the active profile's connections after an out-of-band import.
    ///
    /// Unchanged records do not invalidate a pending sign-in. Legacy callers
    /// without profile configuration still reload the household slot.
    public func reloadConnection() async {
        if profileSource != nil {
            if let profileID = profileSource?().id, profileID == activeProfileID {
                do {
                    guard try accountConnectionStore.load(profileID: profileID) != profileConnections else { return }
                } catch {
                    PlozzLog.sync.error("Seerr profile connections could not be reloaded")
                    storageFailure = "Couldn’t read the saved Seerr connections."
                    return
                }
            }
            activeProfileID = nil
            synchronizeProfile()
            await refreshStatus()
            return
        }
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
        synchronizeProfile()
        if let activeProfileID {
            let revision = connectionRevision
            do {
                let account = try await SeerAuthentication(baseURL: baseURL, http: http).apiKey(apiKey)
                try saveAccount(account, expectedProfileID: activeProfileID, expectedRevision: revision)
                await refreshStatus()
            } catch is CancellationError { return }
            catch { phase = .failed(Self.message(for: error)) }
            return
        }
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
        if profileSource != nil {
            do {
                var empty = SeerProfileConnections()
                empty.configured = true
                try persist(empty)
            } catch { phase = .failed("Couldn’t remove the Seerr connection.") }
            return
        }
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
            if profileSource != nil || configSnapshot.session != nil {
                let me = try await SeerClient(config: configSnapshot, http: http).currentUser()
                guard me.id == (configSnapshot.session?.userID ?? configSnapshot.userId ?? 1) else { throw AppError.unauthorized }
            }
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
        storedConfig = newConfig
        cachedRadarr = nil
        cachedSonarr = nil
        connectionRevision = UUID()
        discoveryStatusCoordinator.replaceClient(with: SeerClient(config: newConfig, http: http))
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

    public func discover(
        _ feed: DiscoverFeed, page: Int = 1, language: String = "en"
    ) async throws -> DiscoverPage {
        guard Self.hasUsableEndpoint(config) else { throw AppError.unauthorized }
        guard (1...500).contains(page) else { throw AppError.invalidResponse }
        let revision = connectionRevision
        let activeClient = client
        try Task.checkCancellation()
        let result = try await activeClient.discover(feed, page: page, language: language)
        try Task.checkCancellation()
        guard revision == connectionRevision else { throw CancellationError() }
        guard result.page == page, result.totalPages >= 0, result.totalResults >= 0,
              result.results.isEmpty || result.totalPages >= page else {
            throw AppError.invalidResponse
        }
        var seen = Set<String>()
        let items = result.results.filter { $0.adult != true }.compactMap(SeerMapper.mediaItem).filter {
            (feed.kind == nil || $0.kind == feed.kind) && seen.insert($0.id).inserted
        }
        return DiscoverPage(
            items: items,
            nextPage: !result.results.isEmpty && page < min(result.totalPages, 500) ? page + 1 : nil
        )
    }

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
        if let session = activeConfig.session {
            return [SeerUser(id: session.userID, name: session.name, serverIdentity: serverIdentity)]
        }
        var adminConfig = activeConfig
        adminConfig.userId = nil
        return try await users(config: adminConfig, revision: activeRevision)
    }

    private func users(config activeConfig: SeerConfig, revision activeRevision: UUID) async throws -> [SeerUser] {
        let activeClient = SeerClient(config: activeConfig, http: http)
        let activeServerIdentity = activeConfig.baseURL.flatMap(SeerServerIdentity.init(baseURL:))
        var collected: [SeerUserDTO] = []
        var skip = 0
        let take = 100
        while true {
            let page = try await activeClient.users(take: take, skip: skip)
            synchronizeProfile()
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
        synchronizeProfile()
        let requestProfileID = activeProfileID
        let selectionGeneration = connectionAttemptGeneration
        var selected = profileConnections.selected
        if profileSource != nil, profileConnections.offersChoice {
            guard destinationContinuation == nil else { return .failure(.unknown("Choose a Seerr connection first.")) }
            let selectionID = UUID()
            let choice: UUID? = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume(returning: nil); return }
                    destinationContinuation = continuation
                    pendingDestination = selectionID
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard self?.pendingDestination == selectionID else { return }
                    self?.chooseDestination(nil)
                }
            }
            synchronizeProfile()
            guard !Task.isCancelled, requestProfileID == activeProfileID,
                  selectionGeneration == connectionAttemptGeneration,
                  let choice else { return .failure(.cancelled) }
            selected = profileConnections.connections.first { $0.id == choice }
        }
        let activeConfig = profileSource == nil ? config : selected?.config ?? .init()
        if selected?.requiresRelink == true { return .failure(.mappingNeedsRelink) }
        let isOtherDestination = selected?.id != profileConnections.selected?.id
        let activeRevision = connectionRevision
        let identity: SeerRequestIdentity = profileSource == nil ? identity
            : activeConfig.userId.map { .user(id: $0, server: activeConfig.baseURL.flatMap(SeerServerIdentity.init(baseURL:))) } ?? .admin
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
        if refusesAdminRequests(),
           activeConfig.session.map({ $0.permissions & 2 != 0 }) ?? (identity == .admin) {
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
            && activeConfig.session == nil
            ? (isTV ? await defaultSonarr(using: activeClient, revision: activeRevision, useCache: !isOtherDestination)
                    : await defaultRadarr(using: activeClient, revision: activeRevision, useCache: !isOtherDestination))
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
            var verifiedPermissions: Int?
            if profileSource != nil, let baseURL = activeConfig.baseURL {
                let me = try await activeClient.currentUser()
                verifiedPermissions = me.permissions
                guard me.id == (activeConfig.session?.userID ?? activeConfig.userId ?? 1) else {
                    return .failure(.signInRequired)
                }
                if refusesAdminRequests(), me.permissions.map({ $0 & 2 != 0 }) ?? true {
                    return .failure(.noPermission)
                }
                if isOtherDestination {
                    let availability = SeerMapper.requestAvailability(
                        from: try await activeClient.mediaDetails(mediaType: mediaType, tmdbID: tmdbID)
                    )
                    synchronizeProfile()
                    guard requestProfileID == activeProfileID, connectionRevision == activeRevision,
                          !Task.isCancelled else { return .failure(.cancelled) }
                    if availability.status == .available {
                        return .successElsewhere("Already available on \(selected?.label ?? baseURL.host ?? "Seerr").")
                    }
                }
            }
            synchronizeProfile()
            guard !Task.isCancelled, profileSource == nil
                    || (requestProfileID == activeProfileID && activeRevision == connectionRevision)
            else { return .failure(.cancelled) }
            if refusesAdminRequests(),
               profileSource != nil ? (verifiedPermissions.map { $0 & 2 != 0 } ?? true) : identity == .admin {
                return .failure(.noPermission)
            }
            let result = try await activeClient.createRequest(body, actingUserID: actingUserID)
            synchronizeProfile()
            if profileSource != nil,
               requestProfileID != activeProfileID || connectionRevision != activeRevision {
                return .failure(.cancelled)
            }
            switch result {
            case let .created(response, status, rawBody):
                let outcome = interpretCreate(response: response, status: status, rawBody: rawBody)
                if case .success = outcome, let selected, let requestProfileID, requestProfileID == profileSource?().id {
                    var state = profileConnections
                    state.lastSuccessfulID = selected.id
                    do {
                        try accountConnectionStore.save(state, profileID: requestProfileID)
                        profileConnections = state
                        if state.rememberLastUsed, isOtherDestination { replaceConfig(with: selected.config) }
                    }
                    catch { PlozzLog.sync.error("Seerr request succeeded but its destination could not be remembered") }
                    if isOtherDestination { return .successElsewhere("Request sent as \(selected.label).") }
                }
                return outcome
            case let .failed(status, message):
                // A 409 means Overseerr already has a request for this title. If
                // that existing request is FAILED or DECLINED it's a dead artifact
                // that blocks re-requesting — clear it and recreate a fresh one so
                // the user's tap actually results in a live request.
                if status == 409, profileSource == nil, activeConfig.session == nil {
                    return await recoverFromConflict(
                        mediaType: mediaType,
                        tmdbID: tmdbID,
                        body: body,
                        client: activeClient,
                        actingUserID: actingUserID
                    )
                }
                if status == 401, activeConfig.session != nil { return .failure(.signInRequired) }
                if status == 409, isOtherDestination {
                    return .successElsewhere("Already requested on \(selected?.label ?? "Seerr").")
                }
                return .failure(.classify(status: status, message: message, actingUserSent: actingUserID != nil))
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch AppError.unauthorized {
            return .failure(.signInRequired)
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

    private func defaultRadarr(using client: SeerClient, revision: UUID, useCache: Bool = true) async -> SeerServiceServer? {
        if useCache, let cachedRadarr, cachedRadarr.revision == revision {
            return cachedRadarr.server
        }
        // Only cache a *successful* fetch. A transient failure (timeout, 401,
        // network blip) must stay uncached so the next request retries — caching
        // it would masquerade as "no servers" and permanently drop the default
        // serverId/profileId/rootFolder for the rest of the session.
        guard let resolved = try? await client.radarrServers() else { return nil }
        let chosen = Self.pickDefault(resolved)
        if useCache, connectionRevision == revision {
            cachedRadarr = ServerCache(revision: revision, server: chosen)
        }
        return chosen
    }

    private func defaultSonarr(using client: SeerClient, revision: UUID, useCache: Bool = true) async -> SeerServiceServer? {
        if useCache, let cachedSonarr, cachedSonarr.revision == revision {
            return cachedSonarr.server
        }
        guard let resolved = try? await client.sonarrServers() else { return nil }
        let chosen = Self.pickDefault(resolved)
        if useCache, connectionRevision == revision {
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
        http: HTTPClient = SeerAuthentication.makeHTTPClient(),
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
