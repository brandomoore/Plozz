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
public final class PublicMetaDBService: TrackerHistoryReading {
    public enum Phase: Equatable, Sendable {
        case disconnected, connecting, connected
        case failed(AppError)
        case pairingFailed(PublicMetaDBPairingFailure)
    }

    public private(set) var phase: Phase = .disconnected
    public private(set) var connectionID: UUID?
    public private(set) var client: PublicMetaDBClient?
    public private(set) var hasSavedKey = false
    public var profileNamespace: String? { namespace }
    public let browserPairing: PublicMetaDBBrowserPairing
    public private(set) var watchlistSelection: PublicMetaDBWatchlistSelection?
    public private(set) var playbackConsent: PublicMetaDBPlaybackConsent?
    public private(set) var communityRatingsEnabled = false
    public private(set) var playbackTimestampSource: (any CommunityPlaybackTimestampProviding)?
    public private(set) var presentedItem: MediaItem?
    public private(set) var catalogNavigation: CatalogNavigation?
    private var deliveredCatalogNavigationID: UUID?
    public var hasPendingCatalogNavigation: Bool {
        catalogNavigation != nil && catalogNavigation?.id != deliveredCatalogNavigationID
    }
    @ObservationIgnored public var resolveCatalogItem: (@MainActor (PublicMetaDB.Content) async throws -> MediaItem)?

    public struct CatalogNavigation: Identifiable {
        public let id = UUID()
        public let item: MediaItem
        public let connectionID: UUID
    }
    public var playbackConnectionID: String? {
        phase == .connected ? playbackConsent?.deliveryScope : nil
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
        guard let connectionID, let makeHistoryExportSource else { throw PublicMetaDB.Failure.disconnected }
        let client = try confirmedClient(connectionID)
        let captured = epoch
        return try PublicMetaDBHistoryExportSession(
            source: makeHistoryExportSource(), client: client, connectionID: connectionID,
            store: receiptStore ?? DurableLocalStateStoreFactory.userIndependent(),
            isConnected: { [weak self] in
                captured.isCurrent && self?.phase == .connected && self?.connectionID == connectionID
            }
        )
    }
    private var watchlistStore: PublicMetaDBWatchlistStore { .init(defaults: defaults, namespace: namespace) }
    private var playbackStore: PublicMetaDBPlaybackConsentStore { .init(defaults: defaults, namespace: namespace) }
    private var ratingsPreferenceKey: String { SettingsKey.scoped("publicmetadb.communityRatings", namespace: namespace) }

    public init(
        credentials: any PublicMetaDBCredentialStoring = PublicMetaDBKeychainStore(),
        http: (any HTTPClient)? = nil,
        namespace: String? = nil,
        defaults: UserDefaults = .standard,
        watchlistReceiptStore: DurableLocalStateStore? = nil
    ) {
        self.credentials = credentials
        self.http = http
        browserPairing = PublicMetaDBBrowserPairing(http: http)
        self.namespace = namespace
        self.defaults = defaults
        self.receiptStore = watchlistReceiptStore
        watchlistDestination = PublicMetaDBWatchlistDestination(receiptStore: watchlistReceiptStore)
        hasSavedKey = credentials.load(namespace: namespace) != nil
        communityRatingsEnabled = defaults.bool(forKey: ratingsPreferenceKey)
    }

    public func selectProfile(namespace: String?) {
        invalidate()
        self.namespace = namespace
        communityRatingsEnabled = defaults.bool(forKey: ratingsPreferenceKey)
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
                phase = .disconnected
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
        invalidate()
        do {
            try credentials.clear(namespace: namespace)
            watchlistStore.clear()
            playbackStore.clear()
            hasSavedKey = false
            phase = .disconnected
        } catch {
            phase = .failed(.unknown("Could not remove the saved PublicMetaDB key."))
            PlozzLog.networking.error("PublicMetaDB credential removal failed")
            throw error
        }
    }

    private func invalidate() {
        browserPairing.cancel()
        playbackTimestampSource = nil
        presentedItem = nil
        catalogNavigation = nil
        deliveredCatalogNavigationID = nil
        epoch.invalidate()
        epoch = PublicMetaDBConnectionEpoch()
        client = nil
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
            PlozzLog.networking.error("PublicMetaDB playback delivery was not confirmed")
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
            client: client, store: receiptStore ?? DurableLocalStateStoreFactory.userIndependent()
        )
        playbackConsent = consent
    }

    public func enableWatchlist(_ list: PublicMetaDB.List, expectedConnectionID: UUID) async throws {
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
        try Task.checkCancellation()
        guard connectionID == expected, phase == .connected, let client else {
            throw PublicMetaDB.Failure.connectionChanged
        }
        return client
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
                try credentials.save(saved, namespace: namespace)
                hasSavedKey = true
            }
            if let selection = try watchlistStore.load(), selection.connectionID == saved.connectionID {
                try watchlistDestination.configure(
                    credentials: saved, selection: selection, http: http,
                    connectionIsCurrent: { captured.isCurrent }
                )
                watchlistSelection = selection
            }
            if let consent = try playbackStore.load(), consent.connectionID == saved.connectionID {
                try configurePlayback(saved, consent: consent)
            }
            connectionID = saved.connectionID
            client = candidate
            phase = .connected
            playbackTimestampSource = PublicMetaDBPlaybackTimestampSource(
                service: self, connectionID: saved.connectionID, epoch: captured
            )
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
