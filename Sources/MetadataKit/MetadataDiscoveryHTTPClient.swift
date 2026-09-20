import CoreModels
import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MetadataDiscoveryHTTPError: Error, Equatable, Sendable {
    case status(Int, retryAfter: TimeInterval?)
    case invalidResponse
    case responseTooLarge
}

/// Bounded transport for public discovery APIs, independent of playback traffic.
public struct MetadataDiscoveryHTTPClient: Sendable {
    public typealias Sending = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let send: Sending
    private static let limiter = ConcurrencyLimiter(limit: 4)
    private static let maximumResponseBytes = 4 * 1_024 * 1_024

    public init(send: Sending? = nil) {
        self.send = send ?? { try await MetadataHTTP.session.data(for: $0) }
    }

    public func data(for request: URLRequest) async throws -> Data {
        let send = send
        return try await Self.limiter.runUnlessCancelled {
            var request = request
            request.timeoutInterval = 12
            if request.value(forHTTPHeaderField: "Accept") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Accept")
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development"
            request.setValue(
                "Plozz/\(version) (+https://github.com/brandomoore/Plozz)",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await send(request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw MetadataDiscoveryHTTPError.invalidResponse
            }
            guard (200...299).contains(response.statusCode) else {
                throw MetadataDiscoveryHTTPError.status(
                    response.statusCode,
                    retryAfter: MetadataHTTP.retryAfterSeconds(response)
                )
            }
            guard data.count <= Self.maximumResponseBytes else {
                throw MetadataDiscoveryHTTPError.responseTooLarge
            }
            return data
        }
    }

    public func decode<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from request: URLRequest,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> Value {
        let data = try await data(for: request)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw MetadataDiscoveryHTTPError.invalidResponse
        }
    }

    public static func configurationFingerprint(_ value: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(value.utf8)) {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
