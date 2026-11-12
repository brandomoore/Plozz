import CryptoKit
import Foundation
import CoreModels
import CoreNetworking

/// Bootstrap authority only. Profile PIN proofs are deliberately not transferable.
public struct SiloSyncCredential: Codable, Sendable, Equatable {
    public let accountID: String
    public let profileID: String
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(_ credential: SiloCredential) {
        accountID = credential.accountID
        profileID = credential.profileID
        accessToken = credential.accessToken
        refreshToken = credential.refreshToken
        expiresAt = credential.expiresAt
    }
}

public enum SiloDeviceEnrollmentError: Error {
    case profilePINRequired
    case identityMismatch
}

extension SiloAuthentication {
    /// Use a synced login only to approve a new, independently revocable session.
    /// Never installs or refreshes the source device's saved credential.
    public func enrollDevice(
        using credential: SiloSyncCredential, serverID: String,
        serverName: String, deviceID: String, platform: String
    ) async throws -> UserSession {
        struct Capability: Decodable {
            let state: String
            let protocol_versions: [Int]
            let allowed: Bool?
            let session_binding: Bool?
        }
        let capability: Capability = try await request("/auth/device/capability")
        guard capability.state == "available", capability.allowed != false,
              capability.protocol_versions.contains(2), capability.session_binding == true else {
            throw SiloAuthenticationError.pairingUnavailable
        }
        var accessToken = credential.accessToken
        if credential.expiresAt <= Date().addingTimeInterval(60) {
            struct Body: Encodable { let refresh_token: String }
            struct Refreshed: Decodable { let access_token: String }
            // Silo checks session standing; refresh does not consume the old JWT.
            let refreshed: Refreshed = try await request(
                "/auth/refresh", method: .post,
                body: Body(refresh_token: credential.refreshToken))
            guard !refreshed.access_token.isEmpty else { throw AppError.invalidResponse }
            accessToken = refreshed.access_token
        }
        let profiles = try await profiles(token: accessToken)
        guard let profile = profiles.first(where: { $0.id == credential.profileID }) else {
            throw SiloDeviceEnrollmentError.identityMismatch
        }
        guard !profile.has_pin else { throw SiloDeviceEnrollmentError.profilePINRequired }
        try Task.checkCancellation()
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let binding = base64URL(Data(SHA256.hash(data: secret)))
        struct Start: Encodable {
            let device_name = "Plozz"
            let device_platform: String
            let client_purpose = "device_login"
            let temporary = false
            let binding: String
        }
        let challenge: SiloDeviceChallenge = try await request(
            "/auth/device/start", method: .post,
            body: Start(device_platform: platform, binding: binding))
        var received: SiloTokenPair?
        do {
            guard !challenge.device_code.isEmpty, !challenge.user_code.isEmpty,
                  challenge.expires_in > 0 else { throw AppError.invalidResponse }
            struct Lookup: Decodable {
                let binding: String?
                let server_id: String?
                let client_purpose: String
                let temporary: Bool
                let status: String
            }
            let lookup: Lookup = try await request(
                "/auth/device", token: accessToken,
                query: [URLQueryItem(name: "code", value: challenge.user_code)])
            guard lookup.binding == binding, lookup.server_id == serverID,
                  lookup.client_purpose == "device_login", !lookup.temporary,
                  lookup.status == "pending" else {
                throw SiloDeviceEnrollmentError.identityMismatch
            }
            try Task.checkCancellation()
            struct Decision: Encodable { let code: String }
            struct Approved: Decodable { let status: String }
            let approval: Approved = try await request(
                "/auth/device/approve", method: .post,
                body: Decision(code: challenge.user_code), token: accessToken)
            guard approval.status == "approved" else { throw SiloAuthenticationError.pairingDenied }
            struct Poll: Encodable { let device_code: String; let binding_secret: String }
            var endpoint = try SiloAPI.endpoint("/auth/device/poll", method: .post)
                .jsonBody(Poll(device_code: challenge.device_code, binding_secret: base64URL(secret)))
            endpoint.headers["X-Silo-Device-Id"] = deviceID
            endpoint.headers["X-Silo-Device-Name"] = "Plozz"
            endpoint.headers["X-Silo-Device-Platform"] = platform
            let result = try await SiloSetupRequest.decode(
                SiloDevicePoll.self, endpoint: endpoint, baseURL: baseURL, http: http, stage: .poll)
            received = result.tokens
            guard result.status == "approved", !result.temporary, let tokens = received,
                  tokens.user.id == credential.accountID, !tokens.access_token.isEmpty,
                  !tokens.refresh_token.isEmpty, tokens.expires_in > 0 else {
                throw SiloDeviceEnrollmentError.identityMismatch
            }
            try Task.checkCancellation()
            // Re-read the PIN requirement in the new session, not its source proof.
            let currentProfiles = try await self.profiles(token: tokens.access_token)
            guard let current = currentProfiles.first(where: { $0.id == credential.profileID }) else {
                throw SiloDeviceEnrollmentError.identityMismatch
            }
            guard !current.has_pin else { throw SiloDeviceEnrollmentError.profilePINRequired }
            let session = try await makeSession(
                tokens: tokens, profile: current, profileToken: nil,
                deviceID: deviceID, serverName: serverName)
            guard session.server.id == serverID else { throw SiloDeviceEnrollmentError.identityMismatch }
            try Task.checkCancellation()
            return session
        } catch {
            let login = received
            await Task {
                do {
                    if let login {
                        try await endVerificationLogin(accessToken: login.access_token)
                    } else {
                        struct Cancel: Encodable { let device_code: String }
                        struct Canceled: Decodable { let status: String }
                        let _: Canceled = try await request(
                            "/auth/device/cancel", method: .post,
                            body: Cancel(device_code: challenge.device_code))
                    }
                } catch {
                    PlozzLog.auth.error("Silo automatic sign-in cleanup failed")
                }
            }.value
            throw error
        }
    }
}
