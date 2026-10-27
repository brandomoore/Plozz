import CoreModels
import CoreNetworking
import Foundation
import XCTest
@testable import ProviderJellyfin

final class JellyfinInventoryDiagnosticsTests: XCTestCase {
    func testEveryInventoryValidationFailureKeepsItsReasonAndOriginalError() async throws {
        for kind in [ProviderKind.jellyfin, .emby] {
            for (json, reason, count) in [
                (#"{"MediaSources":[]}"#, ResponseValidationDiagnostic.Reason.emptySources, 0),
                (#"{"MediaSources":[{}]}"#, .missingSourceID, 1),
                (#"{"MediaSources":[{"Id":" "}]}"#, .blankSourceID, 1),
                (#"{"MediaSources":[{"Id":"same"},{"Id":"same"}]}"#, .duplicateSourceID, 2),
                (#"{"MediaSources":[{"Id":"item","IsRemote":true,"Name":"No streams · Unavailable"}]}"#,
                 .unavailablePlaceholder, 1),
                (#"{"MediaSources":[],"ErrorCode":"NoCompatibleStream"}"#, .serverRejected, 0)
            ] {
                let http = StubHTTPClient()
                http.stub(pathSuffix: "/Users/viewer/Items/item", json:
                    #"{"Id":"item","Name":"private-title","Type":"Movie"}"#)
                http.stub(pathSuffix: "/PlaybackInfo", json: json)
                let provider = provider(kind, http: http)
                let captured = await HTTPResponseDiagnostics.capture {
                    try await provider.playbackItem(id: "item")
                }
                guard case .failure(let error) = captured.result else { return XCTFail("Expected inventory failure") }
                switch reason {
                case .unavailablePlaceholder: XCTAssertEqual(error as? StreamingQualityError, .noStreams)
                case .serverRejected: XCTAssertEqual(error as? StreamingQualityError, .noCompatibleStream)
                default: XCTAssertEqual(error as? AppError, .invalidResponse)
                }
                XCTAssertEqual(captured.validation, [.init(route: .playbackInventory, reason: reason, sourceCount: count)])
            }
        }
    }

    func testItemAndInventoryDecodeFailuresIdentifyDifferentRoutesAndFields() async throws {
        for inventoryFailure in [false, true] {
            let http = StubHTTPClient()
            http.stub(pathSuffix: "/Users/viewer/Items/item", json: inventoryFailure
                ? #"{"Id":"item","Name":"private-title","Type":"Movie"}"# : #"{"Id":false}"#)
            http.stub(pathSuffix: "/PlaybackInfo", json: #"{"MediaSources":[{"Id":false}]}"#)
            let provider = provider(.jellyfin, http: http)
            let captured = await HTTPResponseDiagnostics.capture {
                try await provider.playbackItem(id: "item")
            }
            guard case .failure(let error) = captured.result else { return XCTFail("Expected decode failure") }
            XCTAssertEqual(error as? AppError, .decoding)
            let decode = try XCTUnwrap(captured.responses.first)
            XCTAssertEqual(decode.route, inventoryFailure ? .playbackInventory : .itemDetail)
            XCTAssertEqual(decode.path, inventoryFailure ? "MediaSources.[0].Id" : "Id")
            XCTAssertEqual(decode.reason, .wrongType)
            XCTAssertEqual(decode.expected, .string)
        }
    }

    private func provider(_ kind: ProviderKind, http: any HTTPClient) -> JellyfinProvider {
        JellyfinProvider(session: UserSession(
            server: MediaServer(id: "server", name: "private-server", baseURL: URL(string: "https://fixture.invalid")!,
                                provider: kind),
            userID: "viewer", userName: "private-user", deviceID: "device", accessToken: "private-token"
        ), http: http, playbackRequests: .init())
    }
}
