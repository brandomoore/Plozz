import Foundation
import CoreModels
import CoreNetworking
import ProviderJellyfin

/// Signs a user in with a Jellyfin/Emby username + password and builds a
/// `UserSession`.
///
/// This is intentionally the *lower-priority* alternative to Quick Connect: it
/// exists for people who'd rather type credentials, and for servers that have
/// Quick Connect turned off entirely. The resulting `UserSession` is identical
/// to the one Quick Connect produces, so everything downstream is unchanged.
public struct PasswordSignInService: Sendable {
    private let server: MediaServer
    private let deviceID: String
    private let http: HTTPClient
    private let diagnostics: ServerConnectionDiagnostics

    public init(
        server: MediaServer,
        deviceID: String,
        http: HTTPClient = URLSessionHTTPClient(),
        diagnostics: ServerConnectionDiagnostics = .shared
    ) {
        self.server = server
        self.deviceID = deviceID
        self.http = http
        self.diagnostics = diagnostics
    }

    private var client: JellyfinClient {
        JellyfinClient(
            baseURL: server.baseURL,
            deviceProfile: JellyfinDeviceProfile(deviceID: deviceID),
            providerKind: server.provider,
            http: http
        )
    }

    /// Authenticates against the server. Throws `.invalidCredentials` when the
    /// username/password is rejected, or any transport error otherwise.
    public func signIn(username: String, password: String) async throws -> UserSession {
        try await diagnostics.capture(provider: server.provider, stage: .passwordSignIn, baseURL: server.baseURL) {
            try await authenticate(username: username, password: password)
        }
    }

    private func authenticate(username: String, password: String) async throws -> UserSession {
        let client = self.client
        let auth = try await client.authenticate(username: username, password: password)
        // Fetch the server's real identity/name (no auth required) — otherwise the
        // account keeps the placeholder provider name ("Jellyfin") from the add screen
        // instead of the server's actual name / host.
        let info: MediaServer?
        do {
            info = try await client.publicSystemInfo()
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? AppError) == .cancelled { throw error }
            PlozzLog.auth.info("Public server metadata unavailable after password sign-in")
            info = nil
        }
        try Task.checkCancellation()
        if let info, info.baseURL != server.baseURL,
           let authenticatedServerID = auth.serverID, info.id != authenticatedServerID {
            PlozzLog.auth.error("Redirected public metadata did not match the authenticated server")
            throw AppError.invalidResponse
        }
        let resolvedServer = MediaServer(
            id: auth.serverID ?? info?.id ?? server.id,
            name: info?.name ?? server.name,
            baseURL: info?.baseURL ?? server.baseURL,
            provider: server.provider,
            version: info?.version ?? server.version
        )
        let resolvedClient = JellyfinClient(
            baseURL: resolvedServer.baseURL,
            deviceProfile: JellyfinDeviceProfile(deviceID: deviceID),
            providerKind: server.provider,
            http: http
        )
        return UserSession(
            server: resolvedServer,
            userID: auth.userID,
            userName: auth.userName,
            avatarURL: resolvedClient.userAvatarURL(userID: auth.userID, maxWidth: 120, token: auth.token),
            deviceID: deviceID,
            accessToken: auth.token
        )
    }
}
