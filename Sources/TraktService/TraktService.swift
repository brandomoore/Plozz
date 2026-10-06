import Foundation
import Observation
import CoreModels
import CoreNetworking

/// The state of the device's Trakt connection, rendered by Settings.
public enum TraktConnectionPhase: Equatable, Sendable {
    /// Status not yet determined (initial).
    case unknown
    /// No Trakt client credentials are configured in this build.
    case unavailable
    /// Configured but the user hasn't connected an account.
    case disconnected
    /// Device-code issued; waiting for the user to approve it on the web.
    case connecting(userCode: String, verificationURL: String, expiresAt: Date)
    /// Browser sign-in is in progress; the PKCE verifier never leaves memory.
    case authorizing
    /// Authorization completed; committing the credential is no longer cancellable.
    case savingConnection
    /// Connected to `username`'s Trakt account.
    case connected(username: String)
    /// A connection attempt failed.
    case error(LocalizedStringResource)
    /// A saved shared grant needs cloud recovery, not a new device sign-in.
    case syncError(message: LocalizedStringResource, canReconnect: Bool)
}

/// App-level façade for the Trakt integration.
///
/// Owns the connection lifecycle (device-code OAuth, status, disconnect) for the
/// Settings UI and exposes the `scrobbler` the player uses to sync watches. The
/// connection model and the scrobbler share one `TraktTokenStoring`, so a
/// connection made in Settings is immediately usable by playback and vice-versa.
@MainActor
@Observable
public final class TraktService {
    public private(set) var phase: TraktConnectionPhase

    /// Lifetime (seconds) of the most recently issued device code, so the UI can
    /// render a countdown ring against the current `connecting` `expiresAt`.
    public private(set) var codeLifetime: TimeInterval = 600

    /// The scrobbler injected into playback. A no-op when Trakt is unconfigured.
    @ObservationIgnored public let scrobbler: any TraktScrobbling
    @ObservationIgnored public let watchlistDestination:
        TraktWatchlistDestination?
    @ObservationIgnored public var onConnectionAvailable:
        (@MainActor @Sendable () -> Void)?

    @ObservationIgnored private let config: TraktConfig
    @ObservationIgnored private let auth: TraktAuthService
    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let tokenStore: TraktTokenStoring
    @ObservationIgnored private let coordinator: TraktTokenCoordinator
    @ObservationIgnored private(set) var connectTask: Task<Void, Never>?
    @ObservationIgnored private let profileGeneration:
        TraktProfileGeneration

    public convenience init(config: TraktConfig, http: HTTPClient = URLSessionHTTPClient(), tokenStore: TraktTokenStoring) {
        self.init(config: config, http: http, tokenStore: tokenStore, coordinator: .shared)
    }

    init(config: TraktConfig, http: HTTPClient, tokenStore: TraktTokenStoring, coordinator: TraktTokenCoordinator) {
        self.config = config
        self.auth = TraktAuthService(config: config, http: http)
        self.http = http
        self.tokenStore = tokenStore
        self.coordinator = coordinator
        let profileGeneration = TraktProfileGeneration()
        self.profileGeneration = profileGeneration
        if config.isConfigured {
            self.scrobbler = TraktScrobbler(
                config: config,
                http: http,
                tokenStore: tokenStore,
                profileGeneration: profileGeneration
            )
            self.watchlistDestination = TraktWatchlistDestination(
                config: config,
                http: http,
                tokenStore: tokenStore,
                profileGeneration: profileGeneration
            )
            self.phase = .unknown
        } else {
            self.scrobbler = DisabledTraktScrobbler()
            self.watchlistDestination = nil
            self.phase = .unavailable
        }
    }

    /// Whether the feature is offered at all (client credentials present).
    public var isConfigured: Bool { config.isConfigured }

    public func playbackScrobbler() -> any TraktScrobbling {
        guard config.isConfigured else { return DisabledTraktScrobbler() }
        return TraktScrobbler(config: config, http: http, tokenStore: tokenStore.snapshot())
    }

    /// Switches the service (and its shared scrobbler) to a household profile's
    /// own Trakt connection. Each profile connects/disconnects independently;
    /// the default profile uses `nil` (legacy un-namespaced storage). Cancels any
    /// in-flight connect, repoints the shared token store, then re-resolves status.
    public func setActiveProfile(namespace: String?) async {
        let generation = profileGeneration.advance {
            tokenStore.setNamespace(namespace)
        }
        connectTask?.cancel()
        connectTask = nil
        phase = config.isConfigured ? .unknown : .unavailable
        await refreshStatus(generation: generation)
    }

    /// Resolves the current connection status: verifies any stored token (and
    /// refreshes it if expired), then loads the username for display. Safe to
    /// call repeatedly (e.g. when Settings appears).
    public func refreshStatus() async {
        switch phase {
        case .connecting, .authorizing, .savingConnection: return
        default: break
        }
        await refreshStatus(generation: profileGeneration.current)
    }

    private func refreshStatus(generation: UInt64) async {
        guard config.isConfigured else { phase = .unavailable; return }
        let store = tokenStore.snapshot()
        do {
            guard let access = try await coordinator.accessToken(store: store, auth: auth) else {
                guard generation == profileGeneration.current else { return }
                phase = .disconnected
                return
            }
            let settings = try await auth.userSettings(accessToken: access)
            guard generation == profileGeneration.current else { return }
            phase = .connected(username: settings.displayName)
            onConnectionAvailable?()
        } catch {
            guard generation == profileGeneration.current else { return }
            if error is CancellationError || (error as? AppError) == .cancelled { return }
            // An invalid_grant needs a fresh authorization. Do not delete the
            // synced credential: another device's rotation may still arrive.
            show(error)
        }
    }

    /// Starts (or restarts) the device-code flow: shows a code, then polls until
    /// the user approves it at `trakt.tv/activate`. Keeps a live code on screen
    /// indefinitely — as soon as one lapses unapproved it transparently issues a
    /// fresh one (like Jellyfin Quick Connect), so the user never hits "retry".
    public func connect() {
        guard config.isConfigured else { phase = .unavailable; return }
        connectTask?.cancel()
        let generation = profileGeneration.advance()
        let store = tokenStore.snapshot()
        phase = .authorizing
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try await coordinator.prepareConnection(store: store)
                try Task.checkCancellation()
                guard generation == profileGeneration.current else { return }
                while true {
                    try Task.checkCancellation()
                    let code: TraktDeviceCode
                    do {
                        code = try await self.auth.beginDeviceCode()
                    } catch let error as AppError where error == .unauthorized {
                        // A 401 HERE cannot be about the viewer: no account is
                        // involved until a code has been issued and approved. It
                        // means Trakt rejected this build's client credentials —
                        // the application was removed, or API access for it has
                        // lapsed. Retrying cannot change that, and saying "your
                        // session has expired" sends someone to re-authenticate an
                        // account that was never the problem.
                        guard generation == self.profileGeneration.current else { return }
                        self.phase = .error(LocalizedStringResource(
                            "trakt.error.clientRejected",
                            defaultValue: "Trakt rejected this app's API credentials. The application may have been removed, or its API access may no longer be active.",
                            comment: "Shown when Trakt refuses the app's own client credentials, so no sign-in can succeed until they are replaced."
                        ))
                        return
                    }
                    try Task.checkCancellation()
                    guard generation == self.profileGeneration.current else {
                        return
                    }
                    self.codeLifetime = code.expiresIn
                    self.phase = .connecting(
                        userCode: code.userCode,
                        verificationURL: code.verificationURL,
                        expiresAt: Date().addingTimeInterval(code.expiresIn)
                    )
                    do {
                        let tokens = try await self.auth.awaitToken(for: code)
                        try Task.checkCancellation()
                        try await self.finishConnection(tokens, store: store, generation: generation, context: context)
                        return
                    } catch let error as AppError where error == .quickConnectExpired {
                        continue // Code lapsed unapproved — issue a fresh one.
                    }
                }
            } catch is CancellationError {
                // Cancelled by the user; `cancelConnect()` set the phase.
            } catch let error as AppError {
                guard generation == self.profileGeneration.current else {
                    return
                }
                self.show(error)
            } catch {
                guard generation == self.profileGeneration.current else {
                    return
                }
                self.show(error)
            }
        }
    }

    public func connect(
        authorize: @escaping @MainActor @Sendable (_ url: URL, _ callback: URL) async throws -> URL
    ) {
        guard config.isConfigured else { phase = .unavailable; return }
        connectTask?.cancel()
        let generation = profileGeneration.advance()
        let store = tokenStore.snapshot()
        phase = .authorizing
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try await coordinator.prepareConnection(store: store)
                try Task.checkCancellation()
                guard generation == profileGeneration.current else { return }
                let request = try TraktPKCE(config: config)
                let callback = try await authorize(request.authorizationURL, request.redirectURI)
                try Task.checkCancellation()
                guard generation == profileGeneration.current else { return }
                let code = try request.authorizationCode(from: callback)
                let tokens = try await auth.exchangeCode(code, verifier: request.verifier)
                try Task.checkCancellation()
                try await finishConnection(tokens, store: store, generation: generation, context: context)
            } catch {
                guard generation == profileGeneration.current else { return }
                show(error)
            }
        }
    }

    /// Aborts an in-flight connection attempt.
    public func cancelConnect() {
        switch phase {
        case .connecting, .authorizing: break
        default: return
        }
        _ = profileGeneration.advance()
        connectTask?.cancel()
        connectTask = nil
        phase = config.isConfigured ? .disconnected : .unavailable
    }

    /// Disconnects: revokes the token server-side (best-effort) and clears it.
    public func disconnect() async {
        let generation = profileGeneration.advance()
        connectTask?.cancel()
        connectTask = nil
        let store = tokenStore.snapshot()
        do {
            let tokens = try await coordinator.disconnect(store: store)
            guard generation == profileGeneration.current else { return }
            phase = config.isConfigured ? .disconnected : .unavailable
            if let tokens {
                do { try await auth.revoke(accessToken: tokens.accessToken) }
                catch { PlozzLog.app.error("Trakt disconnected locally; server revocation failed") }
            }
        } catch {
            guard generation == profileGeneration.current else { return }
            show(error)
        }
    }

    private func finishConnection(
        _ tokens: TraktTokens,
        store: any TraktTokenStoring,
        generation: UInt64,
        context: TraktTokenCoordinator.ConnectionContext
    ) async throws {
        try Task.checkCancellation()
        guard generation == profileGeneration.current else { throw CancellationError() }
        phase = .savingConnection
        try await coordinator.save(tokens, store: store, context: context)
        guard generation == profileGeneration.current else { return }
        phase = .connected(username: "Trakt")
        onConnectionAvailable?()
        do {
            let settings = try await auth.userSettings(accessToken: tokens.accessToken)
            guard generation == profileGeneration.current else { return }
            phase = .connected(username: settings.displayName)
        } catch {
            // Display metadata is not the connection commit. Do not undo a
            // persisted grant or offer Cancel after it is already usable.
            PlozzLog.app.debug("Trakt connected; account display information unavailable")
        }
    }

    private func show(_ error: Error) {
        if let error = error as? TraktSharedRefreshError {
            PlozzLog.app.error("Trakt shared connection needs recovery")
            phase = .syncError(
                message: error.userMessage,
                canReconnect: error == .outcomeUnknown || error == .refreshInProgress
            )
        } else if error is CancellationError || (error as? AppError) == .cancelled {
            phase = .disconnected
        } else {
            PlozzLog.app.error("Trakt connection operation failed")
            phase = .error((error as? AppError ?? .unknown("")).userMessage)
        }
    }
}

/// Builds the app's `TraktService` from configuration, choosing a Keychain-backed
/// token store on Apple platforms and an in-memory one elsewhere.
public enum TraktServiceFactory {
    @MainActor
    public static func make(
        config: TraktConfig = .resolved(),
        http: HTTPClient = URLSessionHTTPClient(),
        tokenStore: TraktTokenStoring? = nil,
        namespace: String? = nil
    ) -> TraktService {
        let store = tokenStore ?? defaultTokenStore()
        store.setNamespace(namespace)
        return TraktService(config: config, http: http, tokenStore: store)
    }

    public static func defaultTokenStore() -> TraktTokenStoring {
        #if canImport(Security)
        return KeychainTraktTokenStore()
        #else
        return InMemoryTraktTokenStore()
        #endif
    }
}
