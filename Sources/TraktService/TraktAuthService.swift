import Foundation
import CoreModels
import CoreNetworking

enum TraktDeviceAuthorizationError: Error {
    case pending
}

/// Orchestrates the Trakt OAuth **device-code** flow plus token maintenance.
///
/// Device-code is the right grant for a TV: the app shows a short code, the user
/// enters it at `trakt.tv/activate` on a phone/computer, and the app polls until
/// it's approved. Polling honours a deadline (the code's `expires_in`) and Swift
/// task cancellation so the UI can offer Cancel cleanly — mirroring the existing
/// Jellyfin Quick Connect service.
public struct TraktAuthService: Sendable {
    private let client: TraktClient
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        config: TraktConfig,
        http: HTTPClient = URLSessionHTTPClient(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.client = TraktClient(config: config, http: http)
        self.sleep = sleep
    }

    init(client: TraktClient, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.client = client
        self.sleep = sleep
    }

    /// Begins the flow, returning the code to display + polling parameters.
    public func beginDeviceCode() async throws -> TraktDeviceCode {
        try await client.requestDeviceCode()
    }

    /// Polls for approval of `code`, returning tokens once the user authorizes.
    ///
    /// Only HTTP 400 means pending. Rejection, invalid codes and transport
    /// failures terminate the attempt; throttling lengthens subsequent intervals.
    public func awaitToken(for code: TraktDeviceCode) async throws -> TraktTokens {
        guard code.expiresIn.isFinite, code.interval.isFinite else {
            throw AppError.invalidResponse
        }
        let deadline = Date().addingTimeInterval(code.expiresIn)
        var pollInterval = max(code.interval, 1)
        while Date() < deadline {
            try Task.checkCancellation()
            try await sleep(min(pollInterval, max(0, deadline.timeIntervalSinceNow)))
            try Task.checkCancellation()
            guard Date() < deadline else { break }
            do {
                let response = try await client.requestToken(deviceCode: code.deviceCode)
                return response.tokens
            } catch TraktDeviceAuthorizationError.pending {
                continue
            } catch AppError.rateLimited(let retryAfter) {
                pollInterval = max(pollInterval + 5, retryAfter ?? 0)
            }
        }
        throw AppError.quickConnectExpired
    }

    /// Exchanges a refresh token for a fresh access token.
    public func refresh(_ refreshToken: String) async throws -> TraktTokens {
        try await client.refreshToken(refreshToken).tokens
    }

    func exchangeCode(_ code: String, verifier: String) async throws -> TraktTokens {
        try await client.exchangeCode(code, verifier: verifier).tokens
    }

    /// Best-effort server-side revoke on disconnect.
    public func revoke(accessToken: String) async throws {
        try await client.revoke(accessToken: accessToken)
    }

    /// The connected user's profile, for display in Settings.
    public func userSettings(accessToken: String) async throws -> TraktUserSettings {
        try await client.userSettings(accessToken: accessToken)
    }
}
