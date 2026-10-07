import Foundation
import XCTest
import AetherEngine
import CoreModels
@testable import EnginePlozzigen

final class PlozzigenLiveFailureTests: XCTestCase {
    func testThrownFailureRetainsNumericEvidenceWithoutEngineErrorInfo() throws {
        let diagnostics = PlaybackFailureDiagnostics()
        let buffer = LiveFailureBuffer()
        diagnostics.start { buffer.append($0) }
        let attempt = try XCTUnwrap(diagnostics.begin(layer: .liveEngine, content: .live))
        PlozzigenLiveFailure.record(nil, attempt: attempt, stage: .load, fallbackError: URLError(.cancelled))
        XCTAssertNil(buffer.last)
        PlozzigenLiveFailure.record(
            nil, attempt: attempt, stage: .audioSession,
            fallbackError: NSError(domain: NSOSStatusErrorDomain, code: -50, userInfo: [
                NSLocalizedDescriptionKey: "private source details"
            ])
        )
        let diagnostic = try XCTUnwrap(buffer.last)
        XCTAssertEqual(diagnostic.code, -50)
        XCTAssertEqual(diagnostic.domain, .other)
        XCTAssertEqual(diagnostic.engineFailure, .audioSessionFailed)
        XCTAssertNil(diagnostic.httpStatus)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self).contains("private"))
    }

    func testEngineReportsTypedFailureWithoutItsMessageAndSuppressesCancellation() throws {
        let diagnostics = PlaybackFailureDiagnostics()
        let buffer = LiveFailureBuffer()
        diagnostics.start { buffer.append($0) }
        let attempt = try XCTUnwrap(diagnostics.begin(layer: .liveEngine, content: .live))
        PlozzigenLiveFailure.record(
            .init(kind: .sourceOpenFailed, message: "private", underlyingDomain: NSURLErrorDomain,
                  underlyingCode: NSURLErrorCancelled), attempt: attempt, stage: .load
        )
        XCTAssertNil(buffer.last)
        PlozzigenLiveFailure.record(
            .init(kind: .nativeItemFailed, message: "https://private.test/token",
                  underlyingDomain: "AVFoundationErrorDomain", underlyingCode: -11850),
            attempt: attempt, stage: .playback
        )
        let diagnostic = try XCTUnwrap(buffer.last)
        XCTAssertEqual(diagnostic.engineFailure, .nativeItemFailed)
        XCTAssertEqual(diagnostic.domain, .avfoundation)
        XCTAssertEqual(diagnostic.code, -11850)
        XCTAssertNil(diagnostic.httpStatus)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self).contains("private"))
    }

    func testHTTPRefusalsAreTypedWithoutInspectingLocalizedText() {
        let cases: [(Int, AppError)] = [
            (401, .unauthorized), (403, .unauthorized), (404, .notFound),
            (410, .notFound), (429, .rateLimited(retryAfter: nil)),
            (503, .rateLimited(retryAfter: nil)), (500, .invalidResponse)
        ]
        for (code, expected) in cases {
            let info = PlaybackErrorInfo(kind: .sourceRefused, message: "localized failure", underlyingCode: code)
            XCTAssertEqual(PlozzigenLiveFailure.appError(info), expected)
        }
    }

    private final class LiveFailureBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PlaybackFailureDiagnostic?
        var last: PlaybackFailureDiagnostic? { lock.withLock { value } }
        func append(_ value: PlaybackFailureDiagnostic) { lock.withLock { self.value = value } }
    }

    func testNativeItemFailureDoesNotInventAnHTTPStatus() {
        let info = PlaybackErrorInfo(
            kind: .nativeItemFailed, message: "404 appears only in this untrusted message",
            underlyingDomain: "AVFoundationErrorDomain", underlyingCode: -11850
        )
        XCTAssertEqual(PlozzigenLiveFailure.appError(info), .invalidResponse)
        XCTAssertEqual(
            PlozzigenLiveFailure.diagnostic(info),
            "kind=nativeItemFailed domain=avfoundation code=-11850"
        )
    }

    func testNetworkRateLimitAndDecodeFailuresStayDistinct() {
        XCTAssertEqual(PlozzigenLiveFailure.appError(PlaybackErrorInfo(
            kind: .sourceOpenFailed, message: "", underlyingDomain: NSURLErrorDomain,
            underlyingCode: NSURLErrorNotConnectedToInternet
        )), .serverUnreachable)
        XCTAssertEqual(PlozzigenLiveFailure.appError(PlaybackErrorInfo(
            kind: .sourceRateLimited, message: ""
        )), .rateLimited(retryAfter: nil))
        XCTAssertEqual(PlozzigenLiveFailure.appError(PlaybackErrorInfo(
            kind: .softwarePipelineFailed, message: ""
        )), .decoding)
    }

    func testUnknownKindsAndDomainsCannotLeakLocatorsIntoDiagnosticFields() {
        let secret = "https://example.invalid/live?token=fixture-secret"
        let info = PlaybackErrorInfo(
            kind: PlaybackErrorKind(rawValue: secret), message: secret,
            underlyingDomain: secret, underlyingCode: 404
        )
        XCTAssertEqual(PlozzigenLiveFailure.diagnostic(info), "kind=unknown domain=other code=404")
        XCTAssertEqual(PlozzigenLiveFailure.appError(info), .unknown("live playback failed"))
        XCTAssertEqual(PlozzigenLiveFailure.appError(nil), .unknown("live playback failed"))
    }
}
