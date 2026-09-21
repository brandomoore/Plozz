#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import Foundation
import XCTest
@testable import FeaturePlayback

private struct RefusingPlaybackResolver: AuthenticatedHTTPResourceResolving {
    func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        throw AppError.unauthorized
    }
}

final class NativePlaybackFailureTests: XCTestCase {
    @MainActor
    func testAuthenticationFailureIsPreservedBeforeAnAVPlayerItemExists() async throws {
        let locator = try AuthenticatedHTTPPlaybackLocator(
            provider: .emby, accountID: "fixture", credentialRevision: CredentialRevision(),
            itemID: "item", deliveryMode: .directFile, purpose: .mediaStream,
            resource: try AuthenticatedHTTPResource(pathBase: .configuredBaseURL, path: "Videos/item/stream")
        )
        let engine = NativeVideoEngine(authenticatedHTTPResolver: RefusingPlaybackResolver())
        var reported: AppError?
        engine.onFailure = { reported = $0 }
        await engine.load(request: .init(
            item: .init(id: "item", title: "Fixture", kind: .movie),
            playbackSource: .authenticatedHTTP(locator)
        ), startPosition: 0)
        XCTAssertEqual(reported, .unauthorized)
        XCTAssertEqual(engine.status, .failed(.unauthorized))
        engine.stop()
    }

    func testCoreMediaNumericCodesRemainAvailableWithoutRawDescriptions() {
        let failure = NativePlaybackFailure.classify(NSError(domain: "CoreMediaErrorDomain", code: -12642))
        XCTAssertEqual(failure.diagnosticCode, "CoreMedia -12642")
        XCTAssertEqual(failure.kind, .unknown)
    }

    func testUnderlyingNetworkFailureIsNotBlamedOnCodec() {
        let nested = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "https://private.example/secret?api_key=private"
        ])
        let outer = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [NSUnderlyingErrorKey: nested])
        let result = NativePlaybackFailure.classify(outer)
        XCTAssertEqual(result.kind, .timedOut)
        XCTAssertEqual(result.diagnosticCode, "URL -1001")
        XCTAssertFalse(result.allowsCodecFallback)
        XCTAssertFalse(String(localized: result.userMessage).contains("private"))
    }

    func testHTTPAndDecoderFailuresRemainDistinct() {
        for (status, kind) in [
            (401, StreamingPlaybackFailure.Kind.accessDenied), (403, .accessDenied),
            (404, .unavailable), (500, .server), (503, .server), (504, .timedOut)
        ] {
            let result = NativePlaybackFailure.classify(nil, httpStatus: status)
            XCTAssertEqual(result.kind, kind)
            XCTAssertEqual(result.diagnosticCode, "HTTP \(status)")
            XCTAssertFalse(result.allowsCodecFallback)
        }
        let error = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue)
        let result = NativePlaybackFailure.classify(error)
        XCTAssertEqual(result.kind, .unsupportedFormat)
        XCTAssertTrue(result.allowsCodecFallback)
    }

    func testUnknownDomainsAndMessagesCannotLeakIntoDiagnostics() {
        let result = NativePlaybackFailure.classify(NSError(
            domain: "https://secret.example/token", code: 500,
            userInfo: [NSLocalizedDescriptionKey: "Private media file"]
        ), httpStatus: -12642)
        XCTAssertEqual(result.kind, .unknown)
        XCTAssertNil(result.diagnosticCode)
        XCTAssertFalse(String(localized: result.userMessage).contains("HEVC"))
    }
}
#endif
