import CoreModels
import CoreNetworking
import CoreTrackerAuth
import Foundation
import Observation

public enum WetrakrConnectionPhase: Equatable, Sendable {
    case unknown, unavailable, disconnected, authorizing, savingConnection
    case connecting(userCode: String, verificationURL: String, expiresAt: Date)
    case connected(username: String)
    case error(LocalizedStringResource)
    case syncError(message: LocalizedStringResource, canReconnect: Bool)
}

@MainActor
@Observable
public final class WetrakrService: TrackerHistorySyncReading {
    public let historySyncTrackerID = "wetrakr"
    public private(set) var historySyncNamespace: String?
    @ObservationIgnored public var onHistorySyncDisconnect: (@MainActor () throws -> Void)?
    public private(set) var phase: WetrakrConnectionPhase
    public private(set) var codeLifetime: TimeInterval = 600
    @ObservationIgnored public let watchlistDestination: WetrakrWatchlistDestination?
    @ObservationIgnored public var onConnectionChanged: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored public var makeHistoryExport: (@MainActor () throws -> TrackerHistoryExportSession<WetrakrHistoryExportTarget>)?
    @ObservationIgnored private let config: WetrakrConfig
    @ObservationIgnored private let client: WetrakrClient
    @ObservationIgnored private let auth: WetrakrAuthService
    @ObservationIgnored private let tokenStore: any TrackerTokenStoring
    @ObservationIgnored private let coordinator: TrackerTokenCoordinator
    @ObservationIgnored private let generation = TrackerProfileGeneration()
    @ObservationIgnored private let historyReader = WetrakrHistoryReader()
    @ObservationIgnored var connectTask: Task<Void, Never>?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var activeNamespace: String??
    @ObservationIgnored private var statusTask: (id: UUID, scope: StatusScope, task: Task<Void, Never>)?
    @ObservationIgnored private var lastStatusCheck: (scope: StatusScope, date: Date)?
    @ObservationIgnored private var publishedScope: StatusScope?

    private struct StatusScope: Equatable {
        let store: String
        let identity: String?
        let credentialVersion: String?
        init(_ store: any TrackerTokenStoring) {
            let tokens = store.load()
            self.store = store.coordinationID
            self.identity = tokens?.stableAccountIdentity
            self.credentialVersion = tokens.map {
                WatchlistReconciliationIdentity.credential($0.accessToken)
            }
        }
    }

    public convenience init(
        config: WetrakrConfig, http: any HTTPClient = URLSessionHTTPClient(),
        tokenStore: any TrackerTokenStoring, namespace: String? = nil
    ) {
        self.init(config: config, http: http, tokenStore: tokenStore, coordinator: .shared, namespace: namespace)
    }

    init(
        config: WetrakrConfig, http: any HTTPClient,
        tokenStore: any TrackerTokenStoring, coordinator: TrackerTokenCoordinator,
        namespace: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        historySyncNamespace = namespace
        self.config = config
        self.client = WetrakrClient(config: config, http: http)
        self.auth = WetrakrAuthService(client: client)
        self.tokenStore = tokenStore
        self.coordinator = coordinator
        self.now = now
        phase = config.isConfigured ? .unknown : .unavailable
        watchlistDestination = config.isConfigured ? WetrakrWatchlistDestination(
            client: client, tokenStore: tokenStore, coordinator: coordinator, generation: generation
        ) : nil
    }

    public var isConfigured: Bool { config.isConfigured }

    public var accountIdentity: String? {
        config.isConfigured ? tokenStore.load()?.stableAccountIdentity : nil
    }

    public var historyConnectionID: String? {
        guard case .connected = phase, let tokens = tokenStore.load() else { return nil }
        return "\(tokenStore.coordinationID)#\(generation.current)#\(tokens.stableAccountIdentity)"
    }

    public var historySyncIdentity: TrackerHistorySyncIdentity? {
        guard case .connected = phase, let tokens = tokenStore.load() else { return nil }
        return .init(trackerID: historySyncTrackerID, connectionID: tokens.stableAccountIdentity)
    }

    public func historySnapshot(expectedConnectionID: String) async throws -> TrackerHistorySnapshot {
        let current: @MainActor @Sendable () throws -> Void = { [weak self] in
            try Task.checkCancellation()
            guard self?.historyConnectionID == expectedConnectionID else { throw TrackerHistoryError.scopeChanged }
        }
        try current()
        let store = tokenStore.snapshot()
        guard let access = try await coordinator.accessToken(store: store, auth: auth) else { throw AppError.unauthorized }
        try current()
        return try await historyReader.snapshot(
            client: client, accessToken: access, connectionID: expectedConnectionID,
            validateScope: { try await current() }
        )
    }

    public func playbackScrobbler() -> WetrakrScrobbler {
        WetrakrScrobbler(client: client, tokenStore: tokenStore.snapshot(), coordinator: coordinator)
    }

    public func makeHistoryExportSession(
        source: TrackerServerHistorySource, store: DurableLocalStateStore
    ) throws -> TrackerHistoryExportSession<WetrakrHistoryExportTarget> {
        guard let connection = historyConnectionID, let identity = historySyncIdentity,
              source.scope.profileID == (historySyncNamespace ?? ProfileStore.defaultProfileID) else {
            throw TrackerHistoryError.scopeChanged
        }
        let current: @MainActor @Sendable () throws -> Void = { [weak self] in
            try Task.checkCancellation()
            try source.requireCurrent()
            guard self?.historyConnectionID == connection else { throw TrackerHistoryError.scopeChanged }
        }
        let access: @MainActor @Sendable () async throws -> String = { [weak self] in
            try current()
            guard let self, let token = try await self.coordinator.accessToken(
                store: self.tokenStore.snapshot(), auth: self.auth
            ) else { throw AppError.unauthorized }
            try current()
            return token
        }
        let validate: @Sendable () async throws -> Void = { try await current() }
        let adapter = WetrakrHistoryExportAdapter(client: client)
        return .init(
            trackerID: historySyncTrackerID, trackerName: "WeTrakr",
            connectionID: identity.connectionID, snapshotConnectionID: connection,
            source: source, store: store, preservesWatchDates: true,
            isConnected: { [weak self] in self?.historyConnectionID == connection },
            supports: { WetrakrHistoryExportAdapter.supports($0) },
            readAll: {
                try await adapter.snapshot(accessToken: access(), connectionID: connection, validateScope: validate)
            },
            resolve: {
                try await adapter.resolve($0, accessToken: access(), validateScope: validate)
            },
            readTarget: {
                try await adapter.state($0, accessToken: access(), validateScope: validate)
            },
            write: { [client] target, date, key, authorize in
                try await client.exportHistory(
                    target, date: date, idempotencyKey: key, accessToken: access(),
                    authorize: {
                        try await validate()
                        try await authorize()
                    }, validateScope: validate
                )
            }
        )
    }

    public func setActiveProfile(namespace: String?) async {
        historySyncNamespace = namespace
        if let activeNamespace, activeNamespace == namespace {
            await refreshStatus()
            return
        }
        activeNamespace = .some(namespace)
        let version = generation.advance { tokenStore.setNamespace(namespace) }
        invalidateStatus()
        connectTask?.cancel()
        connectTask = nil
        await watchlistDestination?.clearCache()
        guard version == generation.current else { return }
        phase = config.isConfigured ? .unknown : .unavailable
        await refreshStatus()
    }

    public func refreshStatus() async {
        guard config.isConfigured else { phase = .unavailable; return }
        switch phase {
        case .authorizing, .connecting, .savingConnection: return
        default: break
        }
        let scope = StatusScope(tokenStore)
        if case .connected = phase, let lastStatusCheck,
           lastStatusCheck.scope == scope, now().timeIntervalSince(lastStatusCheck.date) < 300 {
            return
        }
        if let statusTask, statusTask.scope == scope {
            await statusTask.task.value
            return
        }
        statusTask?.task.cancel()
        let id = UUID()
        let task = Task { await self.performStatusRefresh() }
        statusTask = (id, scope, task)
        await task.value
        if statusTask?.id == id { statusTask = nil }
    }

    private func invalidateStatus() {
        statusTask?.task.cancel()
        statusTask = nil
        lastStatusCheck = nil
        publishedScope = nil
    }

    private func publishConnection() {
        let scope = StatusScope(tokenStore)
        guard publishedScope != scope else { return }
        publishedScope = scope
        onConnectionChanged?()
    }

    private func performStatusRefresh() async {
        let version = generation.current
        let store = tokenStore.snapshot()
        var scope = StatusScope(store)
        do {
            guard let token = try await coordinator.accessToken(store: store, auth: auth) else {
                guard !Task.isCancelled, version == generation.current,
                      StatusScope(store) == StatusScope(tokenStore) else { return }
                phase = .disconnected
                await watchlistDestination?.clearCache()
                guard !Task.isCancelled, version == generation.current,
                      StatusScope(store) == StatusScope(tokenStore) else { return }
                publishConnection()
                return
            }
            scope = StatusScope(store)
            try Task.checkCancellation()
            guard version == generation.current, scope == StatusScope(tokenStore) else { return }
            let user = try await auth.user(accessToken: token)
            guard !Task.isCancelled, version == generation.current, scope == StatusScope(tokenStore) else { return }
            phase = .connected(username: user.info.username)
            lastStatusCheck = (scope, now())
            publishConnection()
        } catch {
            guard !Task.isCancelled, version == generation.current, scope == StatusScope(tokenStore) else { return }
            if error is CancellationError || (error as? AppError) == .cancelled { return }
            show(error)
        }
    }

    public func connect() {
        startConnection { [auth] update in
            let code = try await auth.beginDeviceCode()
            await update(code)
            return try await auth.awaitToken(for: code)
        }
    }

    public func connect(
        authorize: @escaping @MainActor @Sendable (URL, URL) async throws -> URL
    ) {
        startConnection { [config, auth] _ in
            let request = try TrackerPKCE(
                clientID: config.clientID,
                authorizationEndpoint: config.apiBaseURL.appendingPathComponent("oauth/authorize"),
                redirectURI: config.redirectURI
            )
            let callback: URL
            do {
                callback = try await authorize(request.authorizationURL, request.redirectURI)
            } catch AppError.invalidResponse {
                throw WetrakrError.browserAuthorizationFailed
            }
            try Task.checkCancellation()
            let code = try request.authorizationCode(from: callback)
            return try await auth.exchange(code: code, verifier: request.verifier)
        }
    }

    private func startConnection(
        authorize: @escaping @MainActor @Sendable (
            @escaping @MainActor @Sendable (WetrakrDeviceCode) -> Void
        ) async throws -> TrackerTokens
    ) {
        guard config.isConfigured else { phase = .unavailable; return }
        invalidateStatus()
        connectTask?.cancel()
        let version = generation.advance()
        let store = tokenStore.snapshot()
        phase = .authorizing
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try await coordinator.prepareConnection(store: store)
                try Task.checkCancellation()
                guard version == generation.current else { return }
                var tokens = try await authorize { [weak self] code in
                    guard let self, version == generation.current else { return }
                    codeLifetime = code.expiresIn
                    phase = .connecting(
                        userCode: code.userCode, verificationURL: code.verificationURL,
                        expiresAt: Date().addingTimeInterval(code.expiresIn)
                    )
                }
                try Task.checkCancellation()
                guard version == generation.current else { return }
                tokens.accountIdentity = UUID().uuidString
                phase = .savingConnection
                try onHistorySyncDisconnect?()
                try await coordinator.save(tokens, store: store, context: context)
                guard version == generation.current else { return }
                await watchlistDestination?.clearCache()
                guard version == generation.current else { return }
                phase = .connected(username: "WeTrakr")
                publishConnection()
                do {
                    let user = try await auth.user(accessToken: tokens.accessToken)
                    guard version == generation.current else { return }
                    phase = .connected(username: user.info.username)
                    lastStatusCheck = (StatusScope(store), now())
                } catch {
                    PlozzLog.app.debug("WeTrakr connected; display information unavailable")
                }
            } catch {
                guard version == generation.current else { return }
                if error is CancellationError || (error as? AppError) == .cancelled {
                    cancelConnect()
                    return
                }
                show(error)
            }
        }
    }

    public func cancelConnect() {
        switch phase {
        case .connecting, .authorizing: break
        default: return
        }
        let version = generation.advance()
        connectTask?.cancel()
        connectTask = nil
        phase = config.isConfigured ? (tokenStore.load() == nil ? .disconnected : .unknown) : .unavailable
        if phase == .unknown {
            Task { [weak self] in
                guard let self, version == generation.current else { return }
                await refreshStatus()
            }
        }
    }

    public func disconnect() async {
        let version = generation.advance()
        invalidateStatus()
        connectTask?.cancel()
        connectTask = nil
        let store = tokenStore.snapshot()
        do {
            try onHistorySyncDisconnect?()
            let tokens = try await coordinator.disconnect(store: store)
            guard version == generation.current else { return }
            await watchlistDestination?.clearCache()
            guard version == generation.current else { return }
            phase = config.isConfigured ? .disconnected : .unavailable
            publishConnection()
            if let tokens {
                do { try await auth.revoke(tokens) }
                catch {
                    guard version == generation.current else { return }
                    PlozzLog.app.error("WeTrakr disconnected locally; server revocation failed")
                    phase = .error("Disconnected from Plozz. WeTrakr could not revoke the session; remove Plozz from your connected apps on WeTrakr.")
                }
            }
        } catch {
            guard version == generation.current else { return }
            await watchlistDestination?.clearCache()
            guard version == generation.current else { return }
            publishConnection()
            show(error)
        }
    }

    private func show(_ error: Error) {
        publishedScope = nil
        if (error as? TrackerHistorySyncError) == .revocationFailed {
            PlozzLog.app.error("WeTrakr history permission revocation failed")
            phase = .error("Sync is paused. Retry before closing the app.")
            return
        }
        if error is CancellationError || (error as? AppError) == .cancelled {
            phase = tokenStore.load() == nil ? .disconnected : .unknown
            return
        }
        PlozzLog.app.error("WeTrakr connection needs attention")
        if let error = error as? TrackerSharedRefreshError {
            phase = .syncError(
                message: "Plozz couldn't synchronize this WeTrakr connection. Open Plozz on your other devices and retry. If it cannot recover, reconnect this profile.",
                canReconnect: error == .outcomeUnknown || error == .refreshInProgress
                    || error == .superseded || error == .invalidRecord
            )
        } else if let error = error as? TrackerPKCE.CallbackError {
            PlozzLog.app.error("WeTrakr sign-in callback rejected: \(error.rawValue)")
            switch error {
            case .unexpectedEndpoint:
                phase = .error("WeTrakr returned to an unexpected sign-in address. Please try again.")
            case .unexpectedScheme:
                phase = .error("WeTrakr changed the sign-in address's URL scheme. Please try again.")
            case .unexpectedHost:
                phase = .error("WeTrakr returned to a different sign-in website. Please try again.")
            case .unexpectedPort:
                phase = .error("WeTrakr changed the sign-in address's port. Please try again.")
            case .unexpectedPath:
                phase = .error("WeTrakr returned to a different sign-in callback path. Please try again.")
            case .unexpectedUserInfo:
                phase = .error("WeTrakr added user information to the sign-in address. Please try again.")
            case .unexpectedFragment:
                phase = .error("WeTrakr added a fragment to the sign-in address. Please try again.")
            case .invalidState:
                phase = .error("WeTrakr returned a missing or mismatched sign-in security token. Please try again.")
            case .invalidCode:
                phase = .error("WeTrakr returned no valid sign-in code. Please try again.")
            }
        } else if (error as? WetrakrError) == .browserAuthorizationFailed {
            phase = .error("The sign-in browser couldn't return to Plozz. Please try again.")
        } else if (error as? WetrakrError) == .authorizationCodeRejected {
            phase = .error("WeTrakr rejected the sign-in code. Please start sign-in again.")
        } else if (error as? WetrakrError) == .invalidTokenResponse {
            phase = .error("WeTrakr couldn't complete the sign-in exchange. Please try again.")
        } else if (error as? WetrakrError) == .clientRejected {
            phase = .error("WeTrakr rejected this app's API credentials.")
        } else if (error as? WetrakrError) == .requestBlocked {
            phase = .error("WeTrakr blocked this request. Try again later or contact WeTrakr support.")
        } else if (error as? WetrakrError) == .accessDenied {
            phase = .error("WeTrakr sign-in was declined.")
        } else if let error = error as? AppError {
            phase = .error(error.userMessage)
        } else {
            phase = .error("Plozz couldn't save the WeTrakr connection. Try again.")
        }
    }
}

public enum WetrakrServiceFactory {
    @MainActor
    public static func make(
        config: WetrakrConfig = .resolved(), http: any HTTPClient = URLSessionHTTPClient(),
        tokenStore: (any TrackerTokenStoring)? = nil, namespace: String? = nil
    ) -> WetrakrService {
        let store = tokenStore ?? KeychainTrackerTokenStore(account: "wetrakr.oauth")
        store.setNamespace(namespace)
        return WetrakrService(config: config, http: http, tokenStore: store, namespace: namespace)
    }
}
