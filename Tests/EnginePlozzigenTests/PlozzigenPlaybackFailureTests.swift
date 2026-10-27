import AetherEngine
import CoreModels
import Foundation
import XCTest
@testable import EnginePlozzigen

final class PlozzigenPlaybackFailureTests: XCTestCase {
    func testHTTPRefusalRetainsStatusAndNeverBecomesACodecFailure() throws {
        for (status, kind) in [
            (401, StreamingPlaybackFailure.Kind.accessDenied), (403, .accessDenied),
            (404, .unavailable), (410, .unavailable), (429, .rateLimited),
            (451, .accessRestricted), (500, .server), (504, .timedOut)
        ] {
            let info = PlaybackErrorInfo(
                kind: .sourceRefused, message: "https://private.test?token=secret", underlyingCode: status
            )
            let failure = try XCTUnwrap(PlozzigenPlaybackFailure.classify(info))
            XCTAssertEqual(failure.kind, kind)
            XCTAssertEqual(failure.diagnosticCode, "HTTP \(status)")
            XCTAssertEqual(failure.engineFailure, .sourceRefused)
            XCTAssertFalse(failure.allowsCodecFallback)
            XCTAssertFalse(String(localized: failure.userMessage).contains("secret"))
        }
    }

    func testRateLimitingStorageAndAudioFailuresHaveSpecificRecovery() throws {
        for (engineKind, kind) in [
            (PlaybackErrorKind.sourceRateLimited, StreamingPlaybackFailure.Kind.rateLimited),
            (.storageExhausted, .storageExhausted), (.audioSessionFailed, .audioOutputFailed)
        ] {
            let failure = try XCTUnwrap(PlozzigenPlaybackFailure.classify(
                .init(kind: engineKind, message: "private failure")
            ))
            XCTAssertEqual(failure.kind, kind)
            XCTAssertFalse(failure.allowsCodecFallback)
        }
    }

    func testDecoderFailureStillAllowsCompatibilityFallback() {
        let failure = PlozzigenPlaybackFailure.classify(.init(kind: .softwarePipelineFailed, message: "private"))
        XCTAssertEqual(failure?.kind, .processingFailed)
        XCTAssertEqual(failure?.engineFailure, .softwarePipelineFailed)
        XCTAssertEqual(failure?.allowsCodecFallback, true)
    }

    func testNativeResourceErrorAllowsRecoveryButTypedRefusalDoesNot() throws {
        for (kind, allowsRecovery) in [
            (PlaybackErrorKind.nativeItemFailed, true), (.sourceRefused, false),
            (.sourceRateLimited, false), (.sourceCertificateRejected, false)
        ] {
            let failure = try XCTUnwrap(PlozzigenPlaybackFailure.classify(.init(
                kind: kind, message: "private",
                underlyingDomain: NSURLErrorDomain, underlyingCode: URLError.resourceUnavailable.rawValue
            )))
            XCTAssertEqual(failure.diagnosticCode, "URL -1008")
            XCTAssertEqual(failure.allowsCodecFallback, allowsRecovery)
        }
    }

    func testCertificateFailureUsesTypedEvidenceNotMessage() {
        let failure = PlozzigenPlaybackFailure.classify(.init(
            kind: .sourceCertificateRejected, message: "localized failure",
            underlyingDomain: NSURLErrorDomain, underlyingCode: URLError.serverCertificateUntrusted.rawValue
        ))
        XCTAssertEqual(failure?.kind, .network)
        XCTAssertEqual(failure?.diagnosticCode, "URL -1202")
        XCTAssertEqual(failure?.allowsCodecFallback, false)
    }

    func testUnknownTextAndDomainCannotInventHTTPOrLeakSecrets() {
        let failure = PlozzigenPlaybackFailure.classify(.init(
            kind: .sourceOpenFailed, message: "HTTP 410 https://private.test?token=secret",
            underlyingDomain: "private-domain", underlyingCode: 410
        ))
        XCTAssertEqual(failure?.kind, .unknown)
        XCTAssertNil(failure?.httpStatus)
        XCTAssertNil(failure?.diagnosticCode)
        XCTAssertEqual(failure?.underlyingErrors, [.init(domain: "private-domain", code: 410)])
        XCTAssertEqual(failure?.underlyingErrors.first?.domain, .other)
    }

    func testReadinessTimeoutIsNotReportedAsANetworkTimeout() throws {
        for kind in [PlaybackErrorKind.noPlayableTrackWithinBudget, .liveReloadNeverReady] {
            let failure = try XCTUnwrap(PlozzigenPlaybackFailure.classify(.init(kind: kind, message: "private")))
            XCTAssertEqual(failure.kind, .readinessTimedOut)
            XCTAssertEqual(failure.engineFailure?.rawValue, kind.rawValue)
            XCTAssertFalse(failure.allowsCodecFallback)
            XCTAssertFalse(String(localized: failure.userMessage).contains("request"))
        }
    }

    func testUnrecognizedEngineKindCannotEnterTheReport() throws {
        let failure = try XCTUnwrap(PlozzigenPlaybackFailure.classify(.init(
            kind: .init(rawValue: "https://private.test?token=secret"), message: "private"
        )))
        XCTAssertEqual(failure.engineFailure, .unknown)
    }
}
