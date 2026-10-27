import AppRuntime
import CoreModels
import CoreNetworking
import Foundation
import ProviderPlex
import XCTest
@testable import TestSupportNetworking

@MainActor
final class PreparationHTTPDiagnosticsTests: XCTestCase {
    func testRealInventoryHTTPFailureCapturesTimingAndStatusWithoutChangingRequests() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            let (provider, server) = try await fixture(kind, inventory: .init(
                status: 503, headers: ["Content-Type": "text/html"],
                body: Data("<html>private-server-response</html>".utf8), delay: .milliseconds(200)
            ))
            let before = Set(PlozzLog.recentEntries(limit: 500).map(\.id))
            do {
                _ = try await PlaybackPreparationDiagnostics.capture(provider: kind, operation: .versions) {
                    try await provider.playbackItem(id: "private-item")
                }
                XCTFail("The HTTP failure must reach the caller.")
            } catch {
                XCTAssertEqual(error as? AppError, .invalidResponse)
            }
            let text = try XCTUnwrap(PlozzLog.recentEntries(limit: 500).first {
                !before.contains($0.id) && $0.message.hasPrefix("format=plozz-preparation-1")
            }?.message)
            for field in [
                "provider=\(kind.rawValue)", "request_0.route=itemDetail", "request_0.http_status=200",
                "request_1.route=playbackInventory", "request_1.http_status=503",
                "request_1.format=html", "request_1.request_timeout_ms=10000",
                "request_1.resource_timeout_ms=12000"
            ] { XCTAssertTrue(text.contains(field), text) }
            let durationField = try XCTUnwrap(text.split(separator: " ").first { $0.hasPrefix("request_1.elapsed_ms=") })
            let milliseconds = try XCTUnwrap(Int(durationField.split(separator: "=").last ?? ""))
            XCTAssertGreaterThanOrEqual(milliseconds, 150)
            for value in ["private", "127.0.0.1", "<html>", "Authorization", "http://"] {
                XCTAssertFalse(text.contains(value))
            }
            let requests = await server.requests
            XCTAssertEqual(requests.filter { $0.target.contains("/PlaybackInfo") }.count, 1)
            XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && $0.body.isEmpty })
        }
    }

    func testSuccessfulHTTPResponseStillCapturesDecodeAndSourceValidationFailures() async throws {
        for (json, field, expected) in [
            (#"{"MediaSources":[{"Id":false}]}"#, "decode_0.path=MediaSources.[0].Id", AppError.decoding),
            (#"{"MediaSources":[{"Id":"private-source"},{"Id":"private-source"}]}"#,
             "validation_0.reason=duplicateSourceID", .invalidResponse)
        ] {
            let (provider, server) = try await fixture(.jellyfin, inventory: .json(json))
            let before = Set(PlozzLog.recentEntries(limit: 500).map(\.id))
            do {
                _ = try await PlaybackPreparationDiagnostics.capture(provider: .jellyfin, operation: .detailVersions) {
                    try await provider.playbackItem(id: "private-item")
                }
                XCTFail("The validation failure must reach the caller.")
            } catch {
                XCTAssertEqual(error as? AppError, expected)
            }
            let text = try XCTUnwrap(PlozzLog.recentEntries(limit: 500).first {
                !before.contains($0.id) && $0.message.hasPrefix("format=plozz-preparation-1")
            }?.message)
            XCTAssertTrue(text.contains(field), text)
            XCTAssertTrue(text.contains("request_1.http_status=200"), text)
            XCTAssertTrue(text.contains("operation=detailVersions"), text)
            XCTAssertFalse(text.contains("private"))
            let requests = await server.requests
            XCTAssertEqual(requests.filter { $0.target.contains("/PlaybackInfo") }.count, 1)
        }
    }

    func testPlexMetadataDecodeFailureUsesTheSameSecretSafeReport() async throws {
        let server = try LoopbackHTTPServer { request in
            if request.target.hasPrefix("/library/metadata/1") {
                return .json(#"{"MediaContainer":{"Metadata":[{"ratingKey":false}]}}"#)
            }
            return .json("{}", status: 404)
        }
        addTeardownBlock { await server.stop() }
        let url = try await server.start()
        let provider = PlexProvider(session: UserSession(
            server: MediaServer(id: UUID().uuidString, name: "private-server", baseURL: url, provider: .plex),
            userID: "private-user", userName: "private-user", deviceID: "device", accessToken: "private-token"
        ), interactiveHTTP: URLSessionHTTPClient(session: .plozzInteractive))
        let before = Set(PlozzLog.recentEntries(limit: 500).map(\.id))
        do {
            _ = try await PlaybackPreparationDiagnostics.capture(provider: .plex, operation: .versions) {
                try await provider.playbackItem(id: "1")
            }
            XCTFail("The Plex decode failure must still reach the caller.")
        } catch {
            XCTAssertEqual(error as? AppError, .decoding)
        }
        let text = try XCTUnwrap(PlozzLog.recentEntries(limit: 500).first {
            !before.contains($0.id) && $0.message.hasPrefix("format=plozz-preparation-1")
        }?.message)
        XCTAssertTrue(text.contains("provider=plex"))
        XCTAssertTrue(text.contains("decode_0.route=itemDetail"))
        XCTAssertTrue(text.contains("decode_0.path=MediaContainer.Metadata.[0].ratingKey"))
        XCTAssertFalse(text.contains("private"))
    }

    private func fixture(
        _ kind: ProviderKind, inventory: LoopbackHTTPServer.Response
    ) async throws -> (any MediaProvider, LoopbackHTTPServer) {
        // Separate fixtures must not inherit the shared coordinator's per-server backoff.
        let serverID = UUID().uuidString
        let server = try LoopbackHTTPServer { request in
            switch request.target.split(separator: "?").first {
            case "/System/Info/Public": return .json(#"{"Id":"\#(serverID)"}"#)
            case "/Users/private-user/Items/private-item":
                return .json(#"{"Id":"private-item","Name":"private-title","Type":"Movie"}"#)
            case "/Items/private-item/PlaybackInfo": return inventory
            default: return .json("{}", status: 404)
            }
        }
        addTeardownBlock { await server.stop() }
        let url = try await server.start()
        let session = UserSession(
            server: MediaServer(id: serverID, name: "private-server", baseURL: url, provider: kind),
            userID: "private-user", userName: "private-user", deviceID: "device", accessToken: "private-token"
        )
        let registry = ManagedProviderRegistry.make()
        return (try registry.provider(for: .init(
            session: session, accountID: "private-account", credentialRevision: CredentialRevision()
        )), server)
    }
}
