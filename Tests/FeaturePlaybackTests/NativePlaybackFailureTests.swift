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
    private func format(codec: CMVideoCodecType, transfer: CFString?) throws -> NativePlaybackFailure.VideoFormat {
        var description: CMVideoFormatDescription?
        var extensions: [CFString: Any] = [:]
        if let transfer { extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer }
        XCTAssertEqual(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: codec, width: 1280, height: 720,
            extensions: extensions as CFDictionary, formatDescriptionOut: &description
        ), noErr)
        return NativePlaybackFailure.VideoFormat(try XCTUnwrap(description))
    }

    func testHDRH264FailureGivesSpecificAdviceWithoutClaimingToReadServerSettings() throws {
        for transfer in [
            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        ] {
            let observed = try format(codec: kCMVideoCodecType_H264, transfer: transfer)
            let error = NSError(domain: "CoreMediaErrorDomain", code: -12927)
            let result = NativePlaybackFailure.classify(error, convertedFormat: observed, provider: .emby)
            XCTAssertEqual(result.kind, .hdrConversion)
            XCTAssertEqual(result.diagnosticCode, "CoreMedia -12927")
            XCTAssertFalse(result.allowsCodecFallback, "Retrying H.264 cannot fix HDR H.264")
            var message = result.userMessage
            message.locale = Locale(identifier: "en_US")
            let text = String(localized: message)
            XCTAssertTrue(text.contains("requires Emby Premiere"))
            XCTAssertTrue(text.contains("SDR version"))
            XCTAssertFalse(text.contains("disabled"))
        }
    }

    func testErrorCodeOrOriginalHDRHintsAloneNeverClaimMissingToneMapping() throws {
        let error = NSError(domain: "CoreMediaErrorDomain", code: -12927)
        XCTAssertEqual(NativePlaybackFailure.classify(error, provider: .emby).kind, .unknown)
        let cases: [(CMVideoCodecType, CFString?)] = [
            (kCMVideoCodecType_H264, kCMFormatDescriptionTransferFunction_ITU_R_709_2),
            (kCMVideoCodecType_HEVC, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ),
            (kCMVideoCodecType_H264, nil)
        ]
        for (codec, transfer) in cases {
            let observed = try format(codec: codec, transfer: transfer)
            XCTAssertNotEqual(NativePlaybackFailure.classify(error, convertedFormat: observed).kind, .hdrConversion)
        }
    }

    func testTransportErrorsTakePriorityOverFormatRemediation() throws {
        let observed = try format(codec: kCMVideoCodecType_H264, transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
        XCTAssertEqual(NativePlaybackFailure.classify(
            NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue),
            convertedFormat: observed, provider: .emby
        ).kind, .timedOut)
        XCTAssertEqual(NativePlaybackFailure.classify(
            nil, httpStatus: 403, convertedFormat: observed, provider: .emby
        ).kind, .accessDenied)
        XCTAssertEqual(NativePlaybackFailure.classify(
            NSError(domain: "CoreMediaErrorDomain", code: -12889), convertedFormat: observed
        ).kind, .unknown)
    }

    func testOtherServersDoNotGetEmbyLicensingAdvice() throws {
        let observed = try format(codec: kCMVideoCodecType_H264, transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
        for provider in [ProviderKind.jellyfin, .plex] {
            let result = NativePlaybackFailure.classify(
                NSError(domain: "CoreMediaErrorDomain", code: -12927),
                convertedFormat: observed, provider: provider
            )
            XCTAssertEqual(result.kind, .hdrConversion)
            var message = result.userMessage
            message.locale = Locale(identifier: "en_US")
            XCTAssertFalse(String(localized: message).contains("Premiere"))
        }
    }

    @MainActor
    func testHLSTrackProbeWaitsForTheInitializationSegment() async throws {
        let expected = try format(codec: kCMVideoCodecType_H264, transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
        var reads = 0
        let observed = try await NativePlaybackFailure.probeConvertedFormat(
            read: { reads += 1; return reads < 3 ? nil : expected },
            isCurrent: { true }, pause: {}
        )
        XCTAssertEqual(reads, 3)
        XCTAssertTrue(observed?.isHDRH264 == true)
    }

    @MainActor
    func testLateFormatFromReplacedStreamIsDiscarded() async throws {
        let expected = try format(codec: kCMVideoCodecType_H264, transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
        var current = true
        let observed = try await NativePlaybackFailure.probeConvertedFormat(
            read: { current = false; return expected }, isCurrent: { current }, pause: {}
        )
        XCTAssertNil(observed)
    }

    @MainActor
    func testMissingHLSMetadataHasABoundedGenericFallback() async throws {
        var reads = 0
        let observed = try await NativePlaybackFailure.probeConvertedFormat(
            read: { reads += 1; return nil }, isCurrent: { true }, pause: {}
        )
        XCTAssertNil(observed)
        XCTAssertEqual(reads, 50)
    }

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
            XCTAssertEqual(result.allowsCodecFallback, kind == .unavailable)
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
