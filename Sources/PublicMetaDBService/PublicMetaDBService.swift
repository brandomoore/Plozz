import CoreModels
import CoreNetworking
import CoreSecureStore
import Foundation
import Observation

public struct PublicMetaDBCredentials: Codable, Sendable, CustomStringConvertible {
    public let connectionID: UUID
    let key: String
    public var description: String { "PublicMetaDBCredentials(<private>)" }

    init(key: String, connectionID: UUID = UUID()) {
        self.key = key
        self.connectionID = connectionID
    }
}

public protocol PublicMetaDBCredentialStoring: Sendable {
    func load(namespace: String?) -> PublicMetaDBCredentials?
    func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws
    func clear(namespace: String?) throws
}

public struct PublicMetaDBKeychainStore: PublicMetaDBCredentialStoring {
    public init() {}

    private func box(_ namespace: String?) -> SyncedTokenBox<PublicMetaDBCredentials> {
        SyncedTokenBox(account: "publicmetadb.key", namespace: namespace)
    }
    public func load(namespace: String?) -> PublicMetaDBCredentials? { box(namespace).load() }
    public func save(_ credentials: PublicMetaDBCredentials, namespace: String?) throws {
        try box(namespace).save(credentials)
    }
    public func clear(namespace: String?) throws { try box(namespace).clear() }
}

@MainActor
@Observable
public final class PublicMetaDBService: TrackerHistorySyncReading {
    public let historySyncTrackerID = "publicmetadb"
    public var historySyncNamespace: String? { namespace }
    @ObservationIgnored public var onHistorySyncDisconnect: (@MainActor () throws -> Void)?
    public enum Phase: Equatable, Sendable {
        case disconnected, connecting, connected
        case failed(AppError)
        case pairingFailed(PublicMetaDBPairingFailure)
        case credentialChangeFailed
    }

    public private(set) var phase: Phase = .disconnected
    public private(set) var connectionID: UUID?
    private(set) var trackingClient: PublicMetaDBClient?
    @ObservationIgnored private(set) var historyPages: PublicMetaDBHistoryPages?
    /// The account tools can browse and mutate arbitrary records. A tracking
    /// connection must not hand their client to a presenter or restore their grants.
    public var client: PublicMetaDBClient? { accountToolsEnabled ? trackingClient : nil }
    private let accountToolsEnabled: Bool
    public private(set) var hasSavedKey = false
    public var profileNamespace: String? { namespace }
    public let browserPairing: PublicMetaDBBrowserPairing
    public private(set) var watchlistSelection: PublicMetaDBWatchlistSelection?
    public private(set) var playbackConsent: PublicMetaDBPlaybackConsent?
    public private(set) var communityRatingsEnabled = false
    public private(set) var presentedItem: MediaItem?
    public private(set) var catalogNavigation: CatalogNavigation?
    private var deliveredCatalogNavigationID: UUID?
    public var hasPendingCatalogNavigation: Bool {
        catalogNavigation != nil && catalogNavigation?.id != deliveredCatalogNavigationID
    }
    @ObservationIgnored public var resolveCatalogItem: (@MainActor (PublicMetaDB.Content) async throws -> MediaItem)?
    @ObservationIgnored public var resolveEpisodeIdentity: (@MainActor @Sendable (PublicMetaDB.Content) async throws -> MediaItem?)?
    @ObservationIgnored public var resolveLibraryEpisode: (@MainActor @Sendable (MediaItem) async throws -> MediaItem?)?

    public struct CatalogNavigation: Identifiable {
        public let id = UUID()
        public let item: MediaItem
        public let connectionID: UUID
    }
    public var playbackConnectionID: String? {
        phase == .connected ? playbackConsent?.deliveryScope : nil
    }
    public var trackerEnabled: Bool { playbackConnectionID != nil }
    public var historyActivationID: String? { playbackConnectionID }

    public func setTrackerEnabled(_ enabled: Bool) throws {
        guard phase == .connected, let connectionID else { throw PublicMetaDB.Failure.disconnected }
        guard enabled != trackerEnabled else { return }
        if enabled {
            try enablePlayback(expectedConnectionID: connectionID)
        } else {
            disablePlayback()
        }
    }
    public let watchlistDestination: PublicMetaDBWatchlistDestination
    @ObservationIgnored public var onConnectionChanged: (@MainActor () -> Void)?
    @ObservationIgnored private var watchlistRequestID = UUID()
    private var namespace: String?
    @ObservationIgnored private var epoch = PublicMetaDBConnectionEpoch()
    @ObservationIgnored private var playbackEpoch = PublicMetaDBConnectionEpoch()
    @ObservationIgnored private var playbackReporter: PublicMetaDBPlaybackReporter?
    @ObservationIgnored private var ratingsEpoch = PublicMetaDBConnectionEpoch()
    @ObservationIgnored var communityRatingsCache: [PublicMetaDB.Content: PublicMetaDBRatingCacheEntry] = [:]
    @ObservationIgnored var activeAnimeMutations: Set<String> = []
    private let credentials: any PublicMetaDBCredentialStoring
    private let http: (any HTTPClient)?
    private let defaults: UserDefaults
    private let receiptStore: DurableLocalStateStore?
    public var makeHistoryExportSource: (@MainActor () throws -> TrackerServerHistorySource)?

    public func makeHistoryExportSession() throws -> PublicMetaDBHistoryExportSession {
        guard let connectionID else { throw PublicMetaDB.Failure.disconnected }
        let client = try confirmedClient(connectionID)
        guard let makeHistoryExportSource else { throw PublicMetaDB.Failure.rejected }
        let captured = epoch
        return try PublicMetaDBHistoryExportSession(
            source: makeHistoryExportSource(), client: client, connectionID: connectionID,
            store: receiptStore ?? DurableLocalStateStoreFactory.userIndependent(),
            isConnected: { [weak self] in
                captured.isCurrent && self?.phase == .connected && self?.connectionID == connectionID
            },
            resolveEpisodeIdentity: { [weak self] content in
                guard captured.isCurrent, let self else { throw PublicMetaDB.Failure.connectionChanged }
                _ = try self.confirmedClient(connectionID)
                let item = try await self.resolveEpisodeIdentity?(content)
                try Task.checkCancellation()
                _ = try self.confirmedClient(connectionID)
                guard captured.isCurrent else { throw PublicMetaDB.Failure.connectionChanged }
                return item
            }
        )
    }
    private var watchlistStore: PublicMetaDBWatchlistStore { .init(defaults: defaults, namespace: namespace) }
    private var playbackStore: PublicMetaDBPlaybackConsentStore { .init(defaults: defaults, namespace: namespace) }
    private var ratingsPreferenceKey: String { SettingsKey.scoped("publicmetadb.communityRatings", namespace: namespace) }

    public convenience init(
        credentials: any PublicMetaDBCredentialStoring = PublicMetaDBKeychainStore(),
        http: (any HTTPClient)? = nil,
        namespace: String? = nil,
        defaults: UserDefaults = .standard,
        watchlistReceiptStore: DurableLocalStateStore? = nil
    ) {
        self.init(accountToolsEnabled: false, credentials: credentials, http: http, namespace: namespace,
                  defaults: defaults, watchlistReceiptStore: watchlistReceiptStore)
    }

    // The deferred account-tool contracts remain independently testable, but
    // app modules can only create tracking connections.
    init(
        accountToolsEnabled: Bool, credentials: any PublicMetaDBCredentialStoring,
        http: (any HTTPClient)? = nil, namespace: String? = nil,
        defaults: UserDefaults = .standard, watchlistReceiptStore: DurableLocalStateStore? = nil
    ) {
        self.accountToolsEnabled = accountToolsEnabled
        self.credentials = credentials
        self.http = http
        browserPairing = PublicMetaDBBrowserPairing(http: http)
        self.namespace = namespace
        self.defaults = defaults
        self.receiptStore = watchlistReceiptStore
        watchlistDestination = PublicMetaDBWatchlistDestination(receiptStore: watchlistReceiptStore)
        hasSavedKey = credentials.load(namespace: namespace) != nil
        communityRatingsEnabled = accountToolsEnabled && defaults.bool(forKey: ratingsPreferenceKey)
    }

    public func selectProfile(namespace: String?) {
        invalidate()
        self.namespace = namespace
        communityRatingsEnabled = accountToolsEnabled && defaults.bool(forKey: ratingsPreferenceKey)
        hasSavedKey = credentials.load(namespace: namespace) != nil
        phase = .disconnected
    }

    public func setActiveProfile(namespace: String?) async {
        selectProfile(namespace: namespace)
        await refreshStatus()
    }

    public func refreshStatus() async {
        invalidate()
        guard let saved = credentials.load(namespace: namespace) else {
            hasSavedKey = false
            phase = .disconnected
            return
        }
        hasSavedKey = true
        await verify(saved, saving: false)
    }

    public func connect(key: String) async {
        invalidate()
        await verify(.init(key: key.trimmingCharacters(in: .whitespacesAndNewlines)), saving: true)
    }

    public func switchToManualKeyEntry() {
        invalidate()
        phase = .disconnected
    }

    public func connectUsingBrowser() async {
        invalidate()
        phase = .disconnected
        let captured = epoch
        do {
            let key = try await browserPairing.receiveKey()
            try Task.checkCancellation()
            guard captured.isCurrent else { return }
            await verify(.init(key: key), saving: true)
        } catch {
            guard captured.isCurrent else { return }
            if error is CancellationError || (error as? AppError) == .cancelled {
                // The cancelled task cannot verify a saved connection itself.
                let restoration = Task {
                    guard captured.isCurrent else { return }
                    await refreshStatus()
                }
                await restoration.value
                return
            }
            if let appError = error as? AppError, case .rateLimited = appError {
                phase = .failed(appError)
            } else {
                phase = .pairingFailed((error as? PublicMetaDBPairingFailure) ?? .unavailable)
            }
            PlozzLog.networking.error("PublicMetaDB browser pairing failed")
        }
    }

    public func disconnect() throws {
        let pages = historyPages ?? credentials.load(namespace: namespace).map { self.pages(for: $0.connectionID) }
        invalidate()
        do {
            try onHistorySyncDisconnect?()
            try credentials.clear(namespace: namespace)
            if let pages { Task { await pages.discard() } }
            watchlistStore.clear()
            playbackStore.clear()
            hasSavedKey = false
            phase = .disconnected
        } catch {
            phase = .credentialChangeFailed
            PlozzLog.networking.error("PublicMetaDB credential removal failed")
            throw error
        }
    }

    private func invalidate() {
        browserPairing.cancel()
        presentedItem = nil
        catalogNavigation = nil
        deliveredCatalogNavigationID = nil
        epoch.invalidate()
        epoch = PublicMetaDBConnectionEpoch()
        trackingClient = nil
        historyPages = nil
        connectionID = nil
        watchlistRequestID = UUID()
        watchlistDestination.disable()
        watchlistSelection = nil
        playbackEpoch.invalidate()
        playbackEpoch = PublicMetaDBConnectionEpoch()
        playbackReporter = nil
        playbackConsent = nil
        invalidateCommunityRatings()
        onConnectionChanged?()
    }

    public func setCommunityRatingsEnabled(_ enabled: Bool) {
        guard accountToolsEnabled else { return }
        invalidateCommunityRatings()
        communityRatingsEnabled = enabled
        defaults.set(enabled, forKey: ratingsPreferenceKey)
    }

    func invalidateCommunityRatings(expectedConnectionID: UUID? = nil) {
        if let expectedConnectionID, connectionID != expectedConnectionID { return }
        ratingsEpoch.invalidate()
        ratingsEpoch = PublicMetaDBConnectionEpoch()
        communityRatingsCache.removeAll()
    }

    public func presentContent(for item: MediaItem) throws {
        guard accountToolsEnabled else { throw PublicMetaDB.Failure.rejected }
        guard phase == .connected else { throw PublicMetaDB.Failure.disconnected }
        presentedItem = item
    }

    public func dismissContent() { presentedItem = nil }

    public func catalogItem(for content: PublicMetaDB.Content, expectedConnectionID: UUID) async throws -> MediaItem {
        _ = try confirmedClient(expectedConnectionID)
        let connection = epoch
        guard let resolveCatalogItem else { throw PublicMetaDB.Failure.rejected }
        let item = try await resolveCatalogItem(content)
        _ = try confirmedClient(expectedConnectionID)
        guard connection.isCurrent else { throw PublicMetaDB.Failure.connectionChanged }
        guard item.kind == (content.mediaType == .movie ? .movie : .series),
              PublicMetaDB.Content.resolvedTMDBID(item.providerIDs, namespace: .tmdb) == content.tmdbID else {
            throw PublicMetaDB.Failure.incompleteResponse
        }
        return item
    }

    public func openCatalogItem(for content: PublicMetaDB.Content, expectedConnectionID: UUID) async throws {
        let item = try await catalogItem(for: content, expectedConnectionID: expectedConnectionID)
        catalogNavigation = CatalogNavigation(item: item, connectionID: expectedConnectionID)
        dismissContent()
    }

    public func consumeCatalogNavigation() -> MediaItem? {
        guard hasPendingCatalogNavigation, let catalogNavigation,
              catalogNavigation.connectionID == connectionID, phase == .connected else { return nil }
        // Keep the request visible until its presenters observe the dismissal.
        deliveredCatalogNavigationID = catalogNavigation.id
        return catalogNavigation.item
    }

    func communityRatingsClient() throws -> (PublicMetaDBClient, PublicMetaDBConnectionEpoch) {
        guard communityRatingsEnabled, phase == .connected,
              let saved = credentials.load(namespace: namespace),
              saved.connectionID == connectionID else { throw PublicMetaDB.Failure.connectionChanged }
        let connection = epoch
        let ratings = ratingsEpoch
        return (
            try PublicMetaDBClient(key: saved.key, http: http, isCurrent: { connection.isCurrent && ratings.isCurrent }),
            ratings
        )
    }

    public func enablePlayback(expectedConnectionID: UUID) throws {
        guard phase == .connected, connectionID == expectedConnectionID,
              let saved = credentials.load(namespace: namespace),
              saved.connectionID == expectedConnectionID else { throw PublicMetaDB.Failure.connectionChanged }
        let consent = PublicMetaDBPlaybackConsent(connectionID: expectedConnectionID)
        try configurePlayback(saved, consent: consent)
        do { try playbackStore.save(consent) }
        catch {
            playbackEpoch.invalidate()
            playbackReporter = nil
            playbackConsent = nil
            PlozzLog.networking.error("PublicMetaDB playback consent could not be saved")
            throw error
        }
    }

    public func disablePlayback() {
        playbackEpoch.invalidate()
        playbackReporter = nil
        playbackConsent = nil
        playbackStore.clear()
    }

    public func reportPlayback(_ delivery: TrackerPlaybackDelivery) async throws {
        guard delivery.trackerID == "publicmetadb", delivery.connectionID == playbackConnectionID,
              let reporter = playbackReporter else { throw TrackerPlaybackDeliveryError.connectionChanged }
        do { try await reporter.report(delivery) }
        catch {
            if playbackConnectionID == delivery.connectionID, var consent = playbackConsent {
                consent.lastFailure = (error as? TrackerPlaybackDeliveryError) ?? .retryAfter(nil)
                do { try playbackStore.save(consent) }
                catch { PlozzLog.networking.error("PublicMetaDB playback failure could not be persisted") }
                playbackConsent = consent
            }
            let reason: String
            switch error {
            case let failure as PublicMetaDB.Failure:
                reason = String(describing: failure)
            case let failure as TrackerPlaybackDeliveryError:
                reason = String(describing: failure)
            case let failure as AppError:
                if case .unknown = failure { reason = "unknown" }
                else { reason = String(describing: failure) }
            default:
                reason = String(reflecting: type(of: error))
            }
            PlozzLog.networking.error("PublicMetaDB playback delivery was not confirmed reason=\(reason)")
            throw error
        }
    }

    private func configurePlayback(_ saved: PublicMetaDBCredentials, consent: PublicMetaDBPlaybackConsent) throws {
        playbackEpoch.invalidate()
        playbackEpoch = PublicMetaDBConnectionEpoch()
        let captured = epoch
        let playback = playbackEpoch
        let client = try PublicMetaDBClient(
            key: saved.key, http: http, isCurrent: { captured.isCurrent && playback.isCurrent }
        )
        playbackReporter = try PublicMetaDBPlaybackReporter(
            client: client, store: receiptStore ?? DurableLocalStateStoreFactory.userIndependent(),
            resolveEpisodeIdentity: { [weak self] content in
                guard captured.isCurrent, playback.isCurrent, let self else {
                    throw TrackerPlaybackDeliveryError.connectionChanged
                }
                let item = try await self.resolveEpisodeIdentity?(content)
                try Task.checkCancellation()
                guard captured.isCurrent, playback.isCurrent else {
                    throw TrackerPlaybackDeliveryError.connectionChanged
                }
                return item
            }
        )
        playbackConsent = consent
    }

    public func enableWatchlist(_ list: PublicMetaDB.List, expectedConnectionID: UUID) async throws {
        guard accountToolsEnabled else { throw PublicMetaDB.Failure.rejected }
        guard expectedConnectionID == connectionID, let client,
              let saved = credentials.load(namespace: namespace),
              saved.connectionID == expectedConnectionID else { throw PublicMetaDB.Failure.connectionChanged }
        let captured = epoch
        let requestID = UUID()
        watchlistRequestID = requestID
        do {
            let owned = try await client.completePages(maximumPages: 100) {
                try await client.lists(page: $0, perPage: 500)
            }
            try Task.checkCancellation()
            guard captured.isCurrent, watchlistRequestID == requestID,
                  connectionID == expectedConnectionID else { throw PublicMetaDB.Failure.connectionChanged }
            guard let current = owned.first(where: { $0.id == list.id }),
                  current.name == list.name, current.isPublic == list.isPublic else {
                throw PublicMetaDB.Failure.incompleteResponse
            }
            let selection = PublicMetaDBWatchlistSelection(list: current, connectionID: expectedConnectionID)
            try watchlistStore.save(selection)
            try watchlistDestination.configure(
                credentials: saved, selection: selection, http: http,
                connectionIsCurrent: { captured.isCurrent }
            )
            watchlistSelection = selection
            onConnectionChanged?()
        } catch {
            PlozzLog.networking.error("PublicMetaDB watchlist selection could not be enabled")
            throw error
        }
    }

    public func disableWatchlist() {
        watchlistRequestID = UUID()
        watchlistDestination.disable()
        watchlistStore.clear()
        watchlistSelection = nil
        onConnectionChanged?()
    }

    func confirmedClient(_ expected: UUID) throws -> PublicMetaDBClient {
        guard accountToolsEnabled else { throw PublicMetaDB.Failure.rejected }
        return try confirmedTrackingClient(expected)
    }

    func confirmedTrackingClient(_ expected: UUID) throws -> PublicMetaDBClient {
        try Task.checkCancellation()
        guard connectionID == expected, phase == .connected, let trackingClient else {
            throw PublicMetaDB.Failure.connectionChanged
        }
        return trackingClient
    }

    private func pages(for id: UUID) -> PublicMetaDBHistoryPages {
        .init(connection: id, namespace: namespace, root: http == nil ? PublicMetaDBHistoryPages.appRoot : nil)
    }

    private func verify(_ saved: PublicMetaDBCredentials, saving: Bool) async {
        let captured = epoch
        phase = .connecting
        do {
            let candidate = try PublicMetaDBClient(key: saved.key, http: http, isCurrent: { captured.isCurrent })
            _ = try await candidate.lists(page: 1, perPage: 1)
            try Task.checkCancellation()
            guard captured.isCurrent else { return }
            if saving {
                do {
                    try onHistorySyncDisconnect?()
                    let previous = credentials.load(namespace: namespace)
                    try credentials.save(saved, namespace: namespace)
                    if let previous, previous.connectionID != saved.connectionID {
                        let retired = pages(for: previous.connectionID)
                        Task { await retired.discard() }
                    }
                } catch {
                    invalidate()
                    phase = .credentialChangeFailed
                    PlozzLog.networking.error("PublicMetaDB credential change persistence failed")
                    return
                }
                hasSavedKey = true
            }
            if accountToolsEnabled, let selection = try watchlistStore.load(), selection.connectionID == saved.connectionID {
                try watchlistDestination.configure(
                    credentials: saved, selection: selection, http: http,
                    connectionIsCurrent: { captured.isCurrent }
                )
                watchlistSelection = selection
            }
            if saving && !accountToolsEnabled {
                // A new tracking connection starts enabled. Refreshing an existing
                // key must never turn reporting back on or reuse an old delivery scope.
                let consent = PublicMetaDBPlaybackConsent(connectionID: saved.connectionID)
                try configurePlayback(saved, consent: consent)
                try playbackStore.save(consent)
            } else if let consent = try playbackStore.load(), consent.connectionID == saved.connectionID {
                try configurePlayback(saved, consent: consent)
            }
            connectionID = saved.connectionID
            historyPages = pages(for: saved.connectionID)
            trackingClient = candidate
            phase = .connected
            onConnectionChanged?()
        } catch {
            guard captured.isCurrent else { return }
            let failure = (error as? PublicMetaDB.Failure)?.appError
                ?? (error as? AppError)
                ?? (error is CancellationError ? .cancelled : .unknown("Could not connect to PublicMetaDB or save its key."))
            invalidate()
            phase = .failed(failure)
            PlozzLog.networking.error("PublicMetaDB connection verification failed")
        }
    }
}

final class PublicMetaDBConnectionEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var isCurrent: Bool { lock.withLock { current } }
    func invalidate() { lock.withLock { current = false } }
}
