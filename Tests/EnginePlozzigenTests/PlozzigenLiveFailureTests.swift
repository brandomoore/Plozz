import Foundation
import XCTest
import AetherEngine
import AVFoundation
import CoreModels
@testable import FeaturePlayback
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
        XCTAssertEqual(diagnostic.domain, .osstatus)
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
            (451, .accessRestricted),
            (503, .rateLimited(retryAfter: nil)), (500, .invalidResponse)
        ]
        for (code, expected) in cases {
            let info = PlaybackErrorInfo(kind: .sourceRefused, message: "localized failure", underlyingCode: code)
            XCTAssertEqual(PlozzigenLiveFailure.appError(info), expected)
        }
    }

    func testRelayRefusalSurvivesGenericNativePlaybackFailure() {
        let generic = PlaybackErrorInfo(kind: .liveSourceUnavailable, message: "unavailable")
        XCTAssertEqual(
            PlozzigenLiveFailure.appError(generic, deliveryFailure: .accessRestricted), .accessRestricted
        )
        XCTAssertEqual(
            PlozzigenLiveFailure.appError(generic, deliveryFailure: .rateLimited(retryAfter: 30)),
            .rateLimited(retryAfter: 30)
        )
        XCTAssertFalse(AppError.accessRestricted.requiresSignIn)
        XCTAssertFalse(CredentialRejection.discardsStoredCredential(AppError.accessRestricted))
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

    @MainActor
    func testNativeCapturePreservesUnderlyingErrorsAndIsExplicitWhenNoItemExists() async {
        let error = NSError(domain: "CoreMediaErrorDomain", code: -12939)
        let capture = NativePlaybackFailureCapture()
        let absent = await capture.capture(item: nil, fallbackError: error)
        XCTAssertEqual(absent.nativeCapture, .noItem)
        XCTAssertEqual(absent.nativeErrors.map(\.code), [-12939])
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/fixture"))
        let result = await capture.capture(item: item, fallbackError: nil, timeout: 0.5) { _ in
            XCTAssertFalse(Thread.isMainThread)
            return .init(nativeCapture: .captured, nativeErrors: PlaybackFailureEvidence.ErrorCode.chain(error),
                  nativeLogErrors: [.init(domain: "CoreMediaErrorDomain", code: -12312)])
        }
        XCTAssertEqual(result.nativeCapture, .captured)
        XCTAssertEqual(result.nativeErrors.map(\.code), [-12939])
        XCTAssertEqual(result.nativeLogErrors.map(\.code), [-12312])
    }

    @MainActor
    func testNativeCaptureTimesOutAndDoesNotAdmitUnlimitedBlockedReaders() async {
        let capture = NativePlaybackFailureCapture()
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/fixture"))
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let reader: @Sendable (AVPlayerItem) -> PlaybackFailureEvidence = { _ in
            _ = release.wait(timeout: .now() + 5)
            return .init(nativeCapture: .captured)
        }
        async let first = capture.capture(item: item, fallbackError: nil, timeout: 0.02, read: reader)
        async let second = capture.capture(item: item, fallbackError: nil, timeout: 0.02, read: reader)
        let results = await [first, second]
        XCTAssertTrue(results.allSatisfy { $0.nativeCapture == .timedOut })
        let third = await capture.capture(item: item, fallbackError: nil, timeout: 0.02, read: reader)
        XCTAssertEqual(third.nativeCapture, .busy)
    }

    func testCombinedFailureKeepsEngineCauseAndTerminalProviderEvidence() throws {
        let diagnostics = PlaybackFailureDiagnostics()
        let attempt = try XCTUnwrap(diagnostics.begin(
            layer: .liveEngine, content: .live, captureForPresentation: true
        ))
        let delivery = try XCTUnwrap(diagnostics.begin(
            layer: .iptvProxy, content: .live, captureForPresentation: true
        ))
        delivery.fail(stage: .response, reason: .authentication, httpStatus: 403)
        var root = PlaybackDeliveryEvidence.Request(
            sequence: 1, resource: .root, method: .get, startedMilliseconds: 0
        )
        root.format = .hls
        let evidence = PlaybackFailureEvidence(route: .nativeHLS, delivery: .init(root: root))
        PlozzigenLiveFailure.record(
            .init(kind: .nativeItemFailed, message: "private", underlyingDomain: "AVFoundationErrorDomain",
                  underlyingCode: -11850),
            attempt: attempt, stage: .playback, evidence: evidence, deliveryDiagnostic: delivery.diagnostic
        )
        XCTAssertEqual(attempt.diagnostic?.code, -11850)
        XCTAssertEqual(attempt.diagnostic?.httpStatus, 403)
        XCTAssertEqual(attempt.diagnostic?.format, .hls)
        XCTAssertEqual(attempt.diagnostic?.evidence?.route, .nativeHLS)
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

    func testNonVideoRefreshKeepsItsBodyClassificationAfterASuccessfulManifest() throws {
        let diagnostics = PlaybackFailureDiagnostics()
        let attempt = try XCTUnwrap(diagnostics.begin(
            layer: .liveEngine, content: .live, captureForPresentation: true
        ))
        let delivery = try XCTUnwrap(diagnostics.begin(
            layer: .iptvProxy, content: .live, captureForPresentation: true
        ))
        delivery.fail(stage: .body, reason: .invalidResponse, httpStatus: 200, format: .html)
        var root = PlaybackDeliveryEvidence.Request(
            sequence: 1, resource: .root, method: .get, startedMilliseconds: 0
        )
        root.format = .hls
        root.outcome = .complete
        PlozzigenLiveFailure.record(
            .init(kind: .nativeItemFailed, message: "private"),
            attempt: attempt, stage: .playback,
            evidence: .init(delivery: .init(root: root)), deliveryDiagnostic: delivery.diagnostic
        )
        XCTAssertEqual(attempt.diagnostic?.format, .html)
        XCTAssertEqual(attempt.diagnostic?.httpStatus, 200)
        XCTAssertEqual(attempt.diagnostic?.evidence?.delivery?.root?.format, .hls)
        let report = LiveChannelFailureReport(failure: .engine(.invalidResponse), diagnostic: attempt.diagnostic)
        XCTAssertEqual(report.message, PlaybackFailureDiagnostic.Format.html.nonVideoMessage)
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
