import Foundation
import XCTest
@testable import MetadataKit

final class MetadataDiscoveryHTTPClientTests: XCTestCase {
    func testIdentifiesAppPreservesAuthenticationAndAppliesTimeout() async throws {
        let client = MetadataDiscoveryHTTPClient { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Plozz/") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            XCTAssertEqual(request.timeoutInterval, 12)
            return (Data(#"{"value":7}"#.utf8), Self.response(status: 200))
        }
        var request = URLRequest(url: Self.url)
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        let value = try await client.decode(Value.self, from: request)
        XCTAssertEqual(value.value, 7)
    }

    func testStatusFailureRetainsRetryAfterWithoutDecodingSuccess() async {
        let client = MetadataDiscoveryHTTPClient { _ in
            (Data("not json".utf8), Self.response(status: 429, headers: ["Retry-After": "30"]))
        }
        do {
            _ = try await client.decode(Value.self, from: URLRequest(url: Self.url))
            XCTFail("Expected throttling failure")
        } catch let error as MetadataDiscoveryHTTPError {
            XCTAssertEqual(error, .status(429, retryAfter: 30))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMalformedSuccessIsAnExplicitFailure() async {
        let client = MetadataDiscoveryHTTPClient { _ in
            (Data("not json".utf8), Self.response(status: 200))
        }
        do {
            _ = try await client.decode(Value.self, from: URLRequest(url: Self.url))
            XCTFail("Expected decoding failure")
        } catch let error as MetadataDiscoveryHTTPError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOversizedPayloadIsRejectedBeforeDecoding() async {
        let client = MetadataDiscoveryHTTPClient { _ in
            (Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1), Self.response(status: 200))
        }
        do {
            _ = try await client.data(for: URLRequest(url: Self.url))
            XCTFail("Expected response limit")
        } catch let error as MetadataDiscoveryHTTPError {
            XCTAssertEqual(error, .responseTooLarge)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationPropagates() async {
        let client = MetadataDiscoveryHTTPClient { _ in throw CancellationError() }
        do {
            _ = try await client.data(for: URLRequest(url: Self.url))
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCredentialFingerprintIsOpaqueAndConfigurationSpecific() {
        let first = MetadataDiscoveryHTTPClient.configurationFingerprint("first-private-key")
        XCTAssertEqual(first.count, 64)
        XCTAssertFalse(first.contains("private"))
        XCTAssertEqual(first, MetadataDiscoveryHTTPClient.configurationFingerprint("first-private-key"))
        XCTAssertNotEqual(first, MetadataDiscoveryHTTPClient.configurationFingerprint("second-private-key"))
    }

    private struct Value: Decodable, Sendable { let value: Int }
    private static let url = URL(string: "https://discovery.example.test/feed")!
    private static func response(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
}
