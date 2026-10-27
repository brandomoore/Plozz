import CoreModels
import Foundation
import XCTest
@testable import CoreNetworking

final class PlaybackPreparationDiagnosticsTests: XCTestCase {
    func testFailureReachesRecentActivityWithoutPrivateErrorDetails() async throws {
        let before = Set(PlozzLog.recentEntries(limit: 500).map(\.id))
        do {
            let _: Int = try await PlaybackPreparationDiagnostics.capture(provider: .jellyfin, operation: .versions) {
                HTTPResponseDiagnostics.recordRequest(.init(
                    route: .playbackInventory, method: "GET", elapsedMilliseconds: 10_005,
                    httpStatus: nil, urlErrorCode: -1001, bytes: 0, format: .unknown,
                    requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 12_000
                ))
                HTTPResponseDiagnostics.recordTransportFailure(URLError(.timedOut, userInfo: [
                    NSURLErrorFailingURLStringErrorKey: "https://private.invalid/secret-token"
                ]))
                throw AppError.unknown("private server title secret-token")
            }
            XCTFail("Diagnostics must not turn a failure into success.")
        } catch {
            XCTAssertEqual(error as? AppError, .unknown("private server title secret-token"))
        }
        let entries = PlozzLog.recentEntries(limit: 500).filter {
            !before.contains($0.id) && $0.message.hasPrefix("format=plozz-preparation-1")
        }
        let text = try XCTUnwrap(entries.first?.message)
        XCTAssertEqual(entries.count, 1)
        for field in [
            "provider=jellyfin", "operation=versions", "error=unknown",
            "request_0.route=playbackInventory", "request_0.elapsed_ms=10005",
            "request_0.url_error_code=-1001", "request_0.request_timeout_ms=10000",
            "request_0.resource_timeout_ms=12000"
        ] { XCTAssertTrue(text.contains(field), field) }
        for privateValue in ["private", "secret-token", "https://"] { XCTAssertFalse(text.contains(privateValue)) }
        XCTAssertTrue(PlozzLog.recentLogText(limit: 500).contains(text),
                      "The detailed developer text stays available locally.")
        let exported = PlaybackPreparationDiagnostics.export(scope: DiagnosticExportScope())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(exported)) as? [String: Any])
        let facts = try XCTUnwrap((body["entries"] as? [[String: Any]])?.last?["facts"] as? [String: Any])
        let request = try XCTUnwrap((facts["requests"] as? [[String: Any]])?.first)
        XCTAssertEqual(request["route"] as? String, "playbackInventory")
        XCTAssertEqual(request["elapsedMilliseconds"] as? Int, 10_005)
        XCTAssertEqual(request["urlErrorCode"] as? Int, -1001)
        XCTAssertEqual(request["requestTimeoutMilliseconds"] as? Int, 10_000)
        let exportedText = String(decoding: try JSONEncoder().encode(exported), as: UTF8.self)
        for value in ["private", "secret-token", "https"] { XCTAssertFalse(exportedText.contains(value), value) }
    }

    func testSuccessAndCancellationDoNotPublishFailureDiagnostics() async throws {
        let before = Set(PlozzLog.recentEntries(limit: 500).map(\.id))
        let scope = DiagnosticExportScope()
        let beforeAttempts = try exportedAttempts(scope: scope)
        let value = try await PlaybackPreparationDiagnostics.capture(provider: .plex, operation: .versions) { 7 }
        XCTAssertEqual(value, 7)
        for error: any Error in [AppError.cancelled, CancellationError()] {
            do {
                let _: Int = try await PlaybackPreparationDiagnostics.capture(provider: .emby, operation: .detailVersions) {
                    throw error
                }
                XCTFail("Cancellation must still throw.")
            } catch {
                XCTAssertTrue(error is CancellationError || error as? AppError == .cancelled)
            }
        }
        XCTAssertFalse(PlozzLog.recentEntries(limit: 500).contains {
            !before.contains($0.id) && $0.message.hasPrefix("format=plozz-preparation-1")
        })
        XCTAssertEqual(try exportedAttempts(scope: scope), beforeAttempts)
    }

    func testIdentityFailureNamesTheRejectedCheckNotTheIdentity() throws {
        for (id, kind, account, reason) in [
            ("private-other", MediaItemKind.movie, "private-account", "itemIDMismatch"),
            ("private-item", .episode, "private-account", "itemKindMismatch"),
            ("private-item", .movie, "private-other", "accountMismatch")
        ] {
            let before = Set(PlozzLog.recentEntries(limit: 500).map(\.id))
            PlaybackPreparationDiagnostics.identityFailure(
                provider: .jellyfin, operation: .versions, expectedID: "private-item",
                expectedKind: .movie, expectedAccountID: "private-account",
                resolved: MediaItem(id: id, title: "private-title", kind: kind, sourceAccountID: account)
            )
            let entry = try XCTUnwrap(PlozzLog.recentEntries(limit: 500).first { !before.contains($0.id) })
            XCTAssertTrue(entry.message.contains("validation=\(reason)"))
            XCTAssertFalse(entry.message.contains("private"))
        }
    }

    private func exportedAttempts(scope: DiagnosticExportScope) throws -> [String] {
        let data = try JSONEncoder().encode(PlaybackPreparationDiagnostics.export(scope: scope))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(body["entries"] as? [[String: Any]]).compactMap { $0["attempt"] as? String }
    }
}
