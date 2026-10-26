import Foundation
import Observation
import CoreModels
import CoreNetworking

/// Connection phase for Simkl (mirrors Trakt's pattern).
public enum SimklConnectionPhase: Equatable, Sendable {
    case unknown
    case unavailable
    case disconnected
    case connecting(userCode: String, verificationURL: String, expiresAt: Date)
    case connected(username: String)
    case error(LocalizedStringResource)
}

/// App-level façade for the Simkl integration.
@MainActor
@Observable
public final class SimklService: TrackerHistorySyncReading {
    public private(set) var phase: SimklConnectionPhase
    public let historySyncTrackerID = "simkl"
    public private(set) var historySyncNamespace: String?
    public var historySyncCategories: Set<TrackerHistorySyncCategory> { [.watched] }
    @ObservationIgnored public var onHistorySyncDisconnect: (@MainActor () throws -> Void)?
    @ObservationIgnored public var makeHistoryExport: (@MainActor () throws -> TrackerHistoryExportSession<SimklHistoryExportTarget>)?
    public private(set) var codeLifetime: TimeInterval = 900

    @ObservationIgnored public let scrobbler: any SimklScrobbling

    @ObservationIgnored private let config: SimklConfig
    @ObservationIgnored private let client: SimklClient
    @ObservationIgnored private let auth: SimklAuthService
    @ObservationIgnored private let tokenStore: SimklTokenStoring
    @ObservationIgnored private(set) var connectTask: Task<Void, Never>?
    @ObservationIgnored private var profileGeneration: UInt64 = 0
    @ObservationIgnored private let historyReader: SimklHistoryReader

    /// The universal watchlist's Simkl destination, or `nil` when Simkl is not
    /// configured in this build. Mirrors `TraktService.watchlistDestination`.
    @ObservationIgnored public let watchlistDestination:
        SimklWatchlistDestination?

    public init(
        config: SimklConfig, http: HTTPClient = URLSessionHTTPClient(),
        tokenStore: SimklTokenStoring, namespace: String? = nil
    ) {
        historySyncNamespace = namespace
        self.config = config
        self.client = SimklClient(config: config, http: http)
        self.auth = SimklAuthService(config: config, http: http)
        self.tokenStore = tokenStore
        self.historyReader = SimklHistoryReader(client: client)
        if config.isConfigured {
            self.scrobbler = SimklScrobbler(config: config, http: http, tokenStore: tokenStore)
            self.watchlistDestination = SimklWatchlistDestination(
                config: config,
                http: http,
                tokenStore: tokenStore
            )
            self.phase = .unknown
        } else {
            self.scrobbler = DisabledSimklScrobbler()
            self.watchlistDestination = nil
            self.phase = .unavailable
        }
    }

    public var isConfigured: Bool { config.isConfigured }

    public var historyConnectionID: String? {
        guard case .connected = phase, let tokens = tokenStore.load(), !tokens.accessToken.isEmpty else { return nil }
        return "\(profileGeneration):\(tokens.stableAccountIdentity)"
    }

    public var historySyncIdentity: TrackerHistorySyncIdentity? {
        guard case .connected = phase, let tokens = tokenStore.load(), !tokens.accessToken.isEmpty else { return nil }
        return .init(
            trackerID: historySyncTrackerID, connectionID: tokens.stableAccountIdentity, allowsForegroundChecks: false
        )
    }

    public func historySnapshot(expectedConnectionID: String) async throws -> TrackerHistorySnapshot {
        let validate: @MainActor () throws -> Void = { [weak self] in
            guard self?.historyConnectionID == expectedConnectionID else { throw TrackerHistoryError.scopeChanged }
        }
        try validate()
        guard let token = tokenStore.load()?.accessToken else { throw TrackerHistoryError.scopeChanged }
        return try await historyReader.snapshot(
            accessToken: token, connectionID: expectedConnectionID, validateScope: validate
        )
    }

    public func makeHistoryExportSession(
        source: TrackerServerHistorySource, store: DurableLocalStateStore
    ) throws -> TrackerHistoryExportSession<SimklHistoryExportTarget> {
        guard let connection = historyConnectionID, let identity = historySyncIdentity,
              source.scope.profileID == (historySyncNamespace ?? ProfileStore.defaultProfileID) else {
            throw TrackerHistoryError.scopeChanged
        }
        let current: @MainActor @Sendable () throws -> Void = { [weak self] in
            try Task.checkCancellation()
            try source.requireCurrent()
            guard self?.historyConnectionID == connection else { throw TrackerHistoryError.scopeChanged }
        }
        let access: @MainActor @Sendable () throws -> String = { [weak self] in
            try current()
            guard let token = self?.tokenStore.load()?.accessToken else { throw TrackerHistoryError.scopeChanged }
            return token
        }
        let adapter = SimklHistoryExportAdapter(client: client, connectionID: connection)
        return .init(
            trackerID: historySyncTrackerID, trackerName: "Simkl",
            connectionID: identity.connectionID, snapshotConnectionID: connection,
            source: source, store: store, preservesWatchDates: true,
            isConnected: { [weak self] in self?.historyConnectionID == connection },
            supports: { SimklHistoryExportAdapter.supports($0) },
            readAll: { try await adapter.snapshot(token: access(), validate: current) },
            resolve: { try await adapter.resolve($0, token: access(), validate: current) },
            readTarget: { try await adapter.state($0, token: access(), validate: current) },
            write: { [client] target, date, _, authorize in
                try await client.exportHistory(
                    target, date: date, token: access(),
                    authorize: { try await current(); try await authorize() },
                    validate: { try await current() }
                )
            }
        )
    }

    public func setActiveProfile(namespace: String?) async {
        historySyncNamespace = namespace
        profileGeneration &+= 1
        let generation = profileGeneration
        connectTask?.cancel()
        connectTask = nil
        tokenStore.setNamespace(namespace)
        phase = config.isConfigured ? .unknown : .unavailable
        await refreshStatus(generation: generation)
    }

    public func refreshStatus() async {
        await refreshStatus(generation: profileGeneration)
    }

    private func refreshStatus(generation: UInt64) async {
        guard config.isConfigured else { phase = .unavailable; return }
        guard let tokens = tokenStore.load() else { phase = .disconnected; return }
        do {
            let settings = try await auth.userSettings(accessToken: tokens.accessToken)
            guard generation == profileGeneration, tokenStore.load() == tokens else { return }
            phase = .connected(username: settings.displayName)
        } catch {
            guard generation == profileGeneration, tokenStore.load() == tokens else { return }
            // A network blip is not evidence the token is bad; only the
            // server rejecting it is. Discarding it here made a momentary
            // failure a permanent sign-out.
            guard CredentialRejection.discardsStoredCredential(error) else {
                phase = .unknown
                return
            }
            clearConnection()
        }
    }

    public func connect() {
        guard config.isConfigured else { phase = .unavailable; return }
        connectTask?.cancel()
        profileGeneration &+= 1
        let generation = profileGeneration
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    try Task.checkCancellation()
                    let code = try await self.auth.beginDeviceCode()
                    try Task.checkCancellation()
                    guard generation == self.profileGeneration else { return }
                    self.codeLifetime = code.expiresIn
                    self.phase = .connecting(
                        userCode: code.userCode,
                        verificationURL: code.verificationURL,
                        expiresAt: Date().addingTimeInterval(code.expiresIn)
                    )
                    do {
                        var tokens = try await self.auth.awaitToken(for: code)
                        try Task.checkCancellation()
                        guard generation == self.profileGeneration else { return }
                        tokens.accountIdentity = UUID().uuidString
                        do {
                            try self.onHistorySyncDisconnect?()
                            try self.tokenStore.save(tokens)
                        } catch {
                            PlozzLog.app.error("Simkl connection persistence failed")
                            self.phase = (error as? TrackerHistorySyncError) == .revocationFailed
                                ? .error("Sync is paused. Retry before closing the app.")
                                : .error("Could not save the connection. Try again.")
                            return
                        }
                        let settings = try? await self.auth.userSettings(accessToken: tokens.accessToken)
                        guard generation == self.profileGeneration, self.tokenStore.load() == tokens else { return }
                        self.phase = .connected(username: settings?.displayName ?? "Simkl")
                        return
                    } catch let error as AppError where error == .quickConnectExpired {
                        continue
                    }
                }
            } catch is CancellationError {
                // Cancelled by user.
            } catch let error as AppError {
                if error == .cancelled { return }
                guard generation == self.profileGeneration else { return }
                self.phase = .error(error.userMessage)
            } catch {
                guard generation == self.profileGeneration else { return }
                self.phase = .error(AppError.unknown("").userMessage)
            }
        }
    }

    public func cancelConnect() {
        profileGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        phase = config.isConfigured ? .disconnected : .unavailable
    }

    public func disconnect() async {
        profileGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        clearConnection()
    }

    private func clearConnection() {
        do {
            try onHistorySyncDisconnect?()
            try tokenStore.clear()
            phase = config.isConfigured ? .disconnected : .unavailable
        } catch {
            PlozzLog.app.error("Simkl connection removal failed")
            phase = .error("Could not disconnect. Retry before closing the app.")
        }
    }
}

/// Factory for building SimklService.
public enum SimklServiceFactory {
    @MainActor
    public static func make(
        config: SimklConfig = .resolved(),
        http: HTTPClient = URLSessionHTTPClient(),
        tokenStore: SimklTokenStoring? = nil,
        namespace: String? = nil
    ) -> SimklService {
        let store = tokenStore ?? defaultTokenStore()
        store.setNamespace(namespace)
        return SimklService(config: config, http: http, tokenStore: store, namespace: namespace)
    }

    public static func defaultTokenStore() -> SimklTokenStoring {
        #if canImport(Security)
        return KeychainSimklTokenStore()
        #else
        return InMemorySimklTokenStore()
        #endif
    }
}
