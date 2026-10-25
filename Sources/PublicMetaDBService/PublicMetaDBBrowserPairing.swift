import CoreModels
import CoreNetworking
import CryptoKit
import Foundation
import Observation

public struct PublicMetaDBPairingChallenge: Equatable, Sendable {
    public static let entryURL = URL(string: "https://plozz.app/publicmetadb")!
    public let code: String
    public let expiresAt: Date
    public let url: URL
    public var displayCode: String { "\(code.prefix(4)) \(code.suffix(4))" }
}

public enum PublicMetaDBPairingFailure: Error, Equatable, Sendable {
    case expired, unavailable, invalidResponse

    public var userMessage: LocalizedStringResource {
        switch self {
        case .expired: "Code expired or used."
        case .unavailable: "QR code unavailable."
        case .invalidResponse: "Could not verify key."
        }
    }
}

struct PublicMetaDBPairingEnvelope: Codable, Sendable {
    let version: Int
    let publicKey: String
    let sealed: String
}

struct PublicMetaDBPairingKeys: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let context = "plozz-publicmetadb-pairing-v1"
    private let key: P256.KeyAgreement.PrivateKey
    let secret: String
    var publicKey: String { Self.encode(key.publicKey.x963Representation) }
    var description: String { "PublicMetaDBPairingKeys(<private>)" }
    var debugDescription: String { description }

    init() {
        key = P256.KeyAgreement.PrivateKey()
        secret = Self.encode(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    init(privateKey: Data, secret: String) throws {
        key = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        self.secret = secret
    }

    func open(_ envelope: PublicMetaDBPairingEnvelope, code: String) throws -> String {
        guard envelope.version == 1,
              let publicBytes = Self.decode(envelope.publicKey), publicBytes.count == 65,
              let combined = Self.decode(envelope.sealed), combined.count == 91 else {
            throw PublicMetaDBPairingFailure.invalidResponse
        }
        do {
            let sender = try P256.KeyAgreement.PublicKey(x963Representation: publicBytes)
            let shared = try key.sharedSecretFromKeyAgreement(with: sender)
            let aes = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: Data(code.utf8),
                sharedInfo: Data(Self.context.utf8), outputByteCount: 32
            )
            let plaintext = try AES.GCM.open(
                .init(combined: combined), using: aes,
                authenticating: Data("\(Self.context):\(code)".utf8)
            )
            guard let candidate = String(data: plaintext, encoding: .utf8),
                  candidate.range(of: "^pm-[A-Za-z0-9]{60}$", options: .regularExpression) != nil else {
                throw PublicMetaDBPairingFailure.invalidResponse
            }
            return candidate
        } catch {
            throw PublicMetaDBPairingFailure.invalidResponse
        }
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) -> Data? {
        guard !value.isEmpty, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), encode(data) == value else { return nil }
        return data
    }
}

@MainActor
@Observable
public final class PublicMetaDBBrowserPairing {
    public private(set) var challenge: PublicMetaDBPairingChallenge?
    public private(set) var isStarting = false
    public var isActive: Bool { isStarting || challenge != nil }
    @ObservationIgnored private var requestID = UUID()
    private let http: any HTTPClient
    private let now: @Sendable () -> Date
    private let sleep: @Sendable () async throws -> Void
    private static let baseURL = URL(string: "https://plozz.app")!
    private static let path = "/api/publicmetadb/pairing"

    public init(http: (any HTTPClient)? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        self.http = http ?? URLSessionHTTPClient(session: URLSession(configuration: configuration))
        now = { Date() }
        sleep = { try await Task.sleep(for: .seconds(3)) }
    }

    init(
        http: any HTTPClient, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable () async throws -> Void
    ) {
        self.http = http
        self.now = now
        self.sleep = sleep
    }

    public func cancel() {
        requestID = UUID()
        challenge = nil
        isStarting = false
    }

    func receiveKey() async throws -> String {
        cancel()
        let request = requestID
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        let keys = PublicMetaDBPairingKeys()
        var activeCode: String?
        isStarting = true
        defer {
            if requestID == request {
                challenge = nil
                isStarting = false
            }
        }
        do {
            struct Start: Encodable { let publicKey: String }
            struct Started: Decodable { let code: String; let expiresAt: Double }
            let (data, status) = try await send(
                .post, path: Self.path, keys: keys,
                body: JSONEncoder().encode(Start(publicKey: keys.publicKey))
            )
            guard status == 201 else { throw PublicMetaDBPairingFailure.invalidResponse }
            let started = try JSONDecoder().decode(Started.self, from: data)
            guard started.code.range(of: "^[A-HJ-NP-Z2-9]{8}$", options: .regularExpression) != nil else {
                throw PublicMetaDBPairingFailure.invalidResponse
            }
            activeCode = started.code
            let expiresAt = Date(timeIntervalSince1970: started.expiresAt / 1000)
            guard started.expiresAt.isFinite, expiresAt > now(), expiresAt.timeIntervalSince(now()) <= 610 else {
                throw PublicMetaDBPairingFailure.expired
            }
            try check(request)
            var url = URLComponents(url: PublicMetaDBPairingChallenge.entryURL, resolvingAgainstBaseURL: false)!
            url.fragment = "code=\(started.code)&key=\(keys.publicKey)"
            challenge = .init(code: started.code, expiresAt: expiresAt, url: url.url!)
            isStarting = false
            for _ in 0..<200 {
                try check(request)
                guard now() < expiresAt, ContinuousClock.now < deadline else { throw PublicMetaDBPairingFailure.expired }
                let (envelope, status) = try await send(
                    .post, path: "\(Self.path)/\(started.code)/redeem", keys: keys
                )
                try check(request)
                guard now() < expiresAt, ContinuousClock.now < deadline else { throw PublicMetaDBPairingFailure.expired }
                if status == 200 {
                    let value = try JSONDecoder().decode(PublicMetaDBPairingEnvelope.self, from: envelope)
                    return try keys.open(value, code: started.code)
                }
                guard status == 202 else { throw PublicMetaDBPairingFailure.invalidResponse }
                try await sleep()
            }
            throw PublicMetaDBPairingFailure.expired
        } catch {
            if let activeCode {
                // Cancellation must not cancel its own best-effort remote revocation.
                // The awaited cleanup has the transport's strict timeout; expiry is the fallback.
                let cleanup = Task {
                    try await send(.delete, path: "\(Self.path)/\(activeCode)", keys: keys)
                }
                do { _ = try await cleanup.value }
                catch { PlozzLog.networking.error("PublicMetaDB pairing cancellation could not reach the relay") }
            }
            if error is DecodingError { throw PublicMetaDBPairingFailure.invalidResponse }
            throw error
        }
    }

    private func check(_ request: UUID) throws {
        try Task.checkCancellation()
        guard requestID == request else { throw CancellationError() }
    }

    private func send(
        _ method: HTTPMethod, path: String, keys: PublicMetaDBPairingKeys, body: Data? = nil
    ) async throws -> (Data, Int) {
        try Task.checkCancellation()
        var endpoint = Endpoint(
            method: method, path: path,
            headers: ["Authorization": "Bearer \(keys.secret)", "Accept": "application/json"],
            body: body, redirectPolicy: .sameOrigin
        )
        if body != nil { endpoint.headers["Content-Type"] = "application/json" }
        endpoint.redactsURLForLogging = true
        endpoint.maximumResponseBytes = 4096
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.sendRaw(endpoint, baseURL: Self.baseURL)
        } catch let error as AppError where error == .invalidResponse {
            // An HTML error page can hit the transport's byte cap before status mapping.
            throw PublicMetaDBPairingFailure.unavailable
        }
        guard data.count <= 4096 else { throw PublicMetaDBPairingFailure.invalidResponse }
        switch response.statusCode {
        case 200, 201, 202, 204: return (data, response.statusCode)
        case 410 where method == .delete: return (data, response.statusCode)
        case 410: throw PublicMetaDBPairingFailure.expired
        case 404, 503: throw PublicMetaDBPairingFailure.unavailable
        case 429: throw AppError.rateLimited(retryAfter: nil)
        default: throw PublicMetaDBPairingFailure.invalidResponse
        }
    }
}
