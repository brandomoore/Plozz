import Foundation
import Observation
import CoreModels
import CoreNetworking

/// Connection phase for MAL.
public enum MALConnectionPhase: Equatable, Sendable {
    case unknown
    case unavailable
    case disconnected
    case awaitingAuthorizationCode(authorizationURL: String)
    case connected(username: String)
    case error(LocalizedStringResource)
}

/// App-level façade for the MyAnimeList integration.
@MainActor
@Observable
public final class MALService: TrackerHistorySyncReading {
    public private(set) var phase: MALConnectionPhase
    public let historySyncTrackerID = "myanimelist"
    public private(set) var historySyncNamespace: String?
    public var historySyncCategories: Set<TrackerHistorySyncCategory> { [.watched] }
    @ObservationIgnored public var onHistorySyncDisconnect: (@MainActor () throws -> Void)?

    @ObservationIgnored public let scrobbler: any MALScrobbling

    @ObservationIgnored private let config: MALConfig
    @ObservationIgnored private let auth: MALAuthService
    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let tokenStore: MALTokenStoring
    @ObservationIgnored private(set) var connectTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSession: String?
    @ObservationIgnored private let profileGeneration: MALProfileGeneration

    /// The universal watchlist's MyAnimeList destination — anime series only,
    /// and `nil` when MAL is not configured in this build.
    @ObservationIgnored public let watchlistDestination:
        MALWatchlistDestination?

    public init(
        config: MALConfig, http: HTTPClient = URLSessionHTTPClient(),
        tokenStore: MALTokenStoring, namespace: String? = nil
    ) {
        historySyncNamespace = namespace
        self.config = config
        self.auth = MALAuthService(config: config, http: http)
        self.http = http
        self.tokenStore = tokenStore
        let profileGeneration = MALProfileGeneration()
        self.profileGeneration = profileGeneration
        if config.isConfigured {
            self.scrobbler = MALScrobbler(
                config: config,
                http: http,
                tokenStore: tokenStore,
                profileGeneration: profileGeneration
            )
            self.watchlistDestination = MALWatchlistDestination(
                config: config,
                http: http,
                tokenStore: tokenStore,
                profileGeneration: profileGeneration
            )
            self.phase = .unknown
        } else {
            self.scrobbler = DisabledMALScrobbler()
            self.watchlistDestination = nil
            self.phase = .unavailable
        }
    }

    public var isConfigured: Bool { config.isConfigured }

    public var historyConnectionID: String? {
        guard case .connected = phase, let tokens = tokenStore.load() else { return nil }
        return "\(profileGeneration.current)#\(tokens.stableAccountIdentity)"
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
        let generation = profileGeneration.current
        guard let tokens = tokenStore.load() else { throw AppError.unauthorized }
        let access = try await validAccessToken(tokens, generation: generation)
        try current()
        return try await MALClient(config: config, http: http).historySnapshot(
            accessToken: access, connectionID: expectedConnectionID, validateScope: { try await current() }
        )
    }

    public func setActiveProfile(namespace: String?) async {
        historySyncNamespace = namespace
        let generation = profileGeneration.advance {
            tokenStore.setNamespace(namespace)
        }
        connectTask?.cancel()
        connectTask = nil
        phase = config.isConfigured ? .unknown : .unavailable
        await refreshStatus(generation: generation)
    }

    public func refreshStatus() async {
        await refreshStatus(generation: profileGeneration.current)
    }

    private func refreshStatus(generation: UInt64) async {
        guard config.isConfigured else { phase = .unavailable; return }
        guard let tokens = tokenStore.load() else { phase = .disconnected; return }
        var checkedTokens = tokens
        do {
            let access = try await validAccessToken(
                tokens,
                generation: generation
            )
            guard let current = tokenStore.load(), current.accessToken == access,
                  current.stableAccountIdentity == tokens.stableAccountIdentity else { return }
            checkedTokens = current
            let user = try await auth.userInfo(accessToken: access)
            guard generation == profileGeneration.current, tokenStore.load() == checkedTokens else { return }
            phase = .connected(username: user.name)
        } catch {
            guard generation == profileGeneration.current, tokenStore.load() == checkedTokens else { return }
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
        profileGeneration.advance()
        connectTask?.cancel()
        connectTask = nil
        // Mint a 32-char TV session so the short redeem code is bound to this TV.
        let session = Self.randomSession()
        pendingSession = session
        // Show the relay auth URL — relay handles PKCE and exchange
        phase = .awaitingAuthorizationCode(authorizationURL: "\(config.relayBaseURL)/myanimelist?s=\(session)")
    }

    /// Redeems a short code from the auth relay to get the access token.
    public func submitAuthorizationCode(_ input: String) {
        guard config.isConfigured else { phase = .unavailable; return }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .error("Code cannot be empty")
            return
        }

        connectTask?.cancel()
        let generation = profileGeneration.advance()
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let relayURL = URL(string: self.config.relayBaseURL) else { throw AppError.invalidResponse }
                var query = [URLQueryItem(name: "code", value: trimmed)]
                if let session = self.pendingSession {
                    query.append(.init(name: "session", value: session))
                }
                var endpoint = Endpoint(path: "/api/redeem", queryItems: query, redirectPolicy: .sameOrigin)
                endpoint.redactsURLForLogging = true
                let (data, _) = try await self.http.send(endpoint, baseURL: relayURL)
                guard generation == self.profileGeneration.current else { return }
                let result = try JSONDecoder().decode(RelayRedeemResponse.self, from: data)

                let tokens = MALTokens(
                    accessToken: result.accessToken,
                    refreshToken: result.refreshToken ?? "",
                    expiresAt: Date().addingTimeInterval(Double(result.expiresIn ?? 3600)),
                    accountIdentity: UUID().uuidString
                )
                try Task.checkCancellation()
                do {
                    try self.onHistorySyncDisconnect?()
                    guard try self.profileGeneration.performIfCurrent(
                        generation, operation: { try self.tokenStore.save(tokens) }
                    ) else { return }
                } catch {
                    PlozzLog.app.error("MyAnimeList connection persistence failed")
                    self.connectTask = nil
                    self.phase = (error as? TrackerHistorySyncError) == .revocationFailed
                        ? .error("Sync is paused. Retry before closing the app.")
                        : .error("Could not save the connection. Try again.")
                    return
                }
                let user = try? await self.auth.userInfo(accessToken: tokens.accessToken)
                guard generation == self.profileGeneration.current, self.tokenStore.load() == tokens else { return }
                self.connectTask = nil
                self.pendingSession = nil
                self.phase = .connected(username: user?.name ?? "MyAnimeList")
            } catch is CancellationError {
                guard generation == self.profileGeneration.current else { return }
                self.connectTask = nil
            } catch {
                guard generation == self.profileGeneration.current else { return }
                self.connectTask = nil
                self.phase = .error("Invalid or expired code — please try again")
            }
        }
    }

    public func cancelConnect() {
        profileGeneration.advance()
        connectTask?.cancel()
        connectTask = nil
        phase = config.isConfigured ? .disconnected : .unavailable
    }

    public func disconnect() async {
        profileGeneration.advance()
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
            PlozzLog.app.error("MyAnimeList connection removal failed")
            phase = .error("Could not disconnect. Retry before closing the app.")
        }
    }

    private func validAccessToken(
        _ tokens: MALTokens,
        generation: UInt64
    ) async throws -> String {
        try Task.checkCancellation()
        guard generation == profileGeneration.current, tokenStore.load() == tokens else {
            throw TrackerHistoryError.scopeChanged
        }
        guard tokens.isExpired else { return tokens.accessToken }
        let refreshed = try await auth.refresh(tokens.refreshToken)
            .inheritingAccountIdentity(from: tokens)
        try Task.checkCancellation()
        guard try profileGeneration.performIfCurrent(
            generation,
            operation: {
                guard tokenStore.load() == tokens else { throw TrackerHistoryError.scopeChanged }
                try tokenStore.save(refreshed)
            }
        ) else {
            throw CancellationError()
        }
        return refreshed.accessToken
    }

    /// 32-char URL-safe session id binding a redeem code to this TV.
    private static func randomSession() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<32).map { _ in chars.randomElement()! })
    }
}

/// Response from the auth relay's /api/redeem endpoint.
private struct RelayRedeemResponse: Decodable {
    let service: String
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case service
        case accessToken
        case refreshToken
        case expiresIn
    }
}

/// Factory for building MALService.
public enum MALServiceFactory {
    @MainActor
    public static func make(
        config: MALConfig = .resolved(),
        http: HTTPClient = URLSessionHTTPClient(),
        tokenStore: MALTokenStoring? = nil,
        namespace: String? = nil
    ) -> MALService {
        let store = tokenStore ?? defaultTokenStore()
        store.setNamespace(namespace)
        return MALService(config: config, http: http, tokenStore: store, namespace: namespace)
    }

    public static func defaultTokenStore() -> MALTokenStoring {
        #if canImport(Security)
        return KeychainMALTokenStore()
        #else
        return InMemoryMALTokenStore()
        #endif
    }
}
