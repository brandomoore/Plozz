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

private final class LifecycleDiagnosticLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

private final class LifecycleDiagnosticItem: AVPlayerItem {
    private var diagnosticStatus: AVPlayerItem.Status = .unknown
    override var status: AVPlayerItem.Status { diagnosticStatus }

    func transition(to status: AVPlayerItem.Status) {
        willChangeValue(forKey: "status")
        diagnosticStatus = status
        didChangeValue(forKey: "status")
    }
}

final class NativePlaybackFailureTests: XCTestCase {
    @MainActor
    func testLifetimeEvidenceContinuesAfterReadyAndRemovesObserversOnTeardown() throws {
        let item = LifecycleDiagnosticItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: item)
        let lines = LifecycleDiagnosticLines()
        var diagnostics: NativePlaybackLifecycleDiagnostics? = NativePlaybackLifecycleDiagnostics(
            player: player,
            request: .init(
                item: .init(id: "private-item", title: "Private title", kind: .movie),
                streamURL: URL(fileURLWithPath: "/dev/null"),
                playSessionID: "private-session"
            ),
            emit: { lines.append($0) }
        )
        XCTAssertNotNil(diagnostics)
        item.transition(to: .readyToPlay)
        let afterReady = lines.snapshot.count
        item.transition(to: .failed)
        XCTAssertTrue(lines.snapshot.dropFirst(afterReady).contains {
            $0.contains("event=ITEM_STATUS") && $0.contains("status=2")
        })
        let failure = NSError(domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue, userInfo: [
            NSLocalizedDescriptionKey: "https://private.example/?api_key=secret"
        ])
        NotificationCenter.default.post(
            name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: failure]
        )
        XCTAssertTrue(lines.snapshot.contains {
            $0.contains("event=FAILED_TO_END") && $0.contains("code=URL -1005")
        })
        NotificationCenter.default.post(name: AVPlayerItem.playbackStalledNotification, object: item)
        XCTAssertTrue(lines.snapshot.contains { $0.contains("event=STALLED") })
        XCTAssertFalse(lines.snapshot.joined().contains("private"))
        XCTAssertFalse(lines.snapshot.joined().contains("secret"))

        diagnostics = nil
        let afterTeardown = lines.snapshot.count
        item.transition(to: .unknown)
        NotificationCenter.default.post(name: AVPlayerItem.playbackStalledNotification, object: item)
        NotificationCenter.default.post(name: AVPlayerItem.newErrorLogEntryNotification, object: item)
        XCTAssertEqual(lines.snapshot.count, afterTeardown)
    }

    @MainActor
    func testLifetimeEvidenceIgnoresOtherPlayerItems() {
        let item = AVPlayerItem(asset: AVMutableComposition())
        let other = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: item)
        let lines = LifecycleDiagnosticLines()
        let diagnostics = NativePlaybackLifecycleDiagnostics(
            player: player, request: .init(
                item: .init(id: "item", title: "Fixture", kind: .movie),
                streamURL: URL(fileURLWithPath: "/dev/null")
            ),
            emit: { lines.append($0) }
        )
        withExtendedLifetime(diagnostics) {
            NotificationCenter.default.post(name: AVPlayerItem.playbackStalledNotification, object: other)
            NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: other)
            XCTAssertFalse(lines.snapshot.contains { $0.contains("event=STALLED") || $0.contains("event=FAILED_TO_END") })
        }
    }

    func testObservedCodecComesFromTheReturnedFormatDescription() throws {
        XCTAssertEqual(try format(codec: kCMVideoCodecType_H264, transfer: nil).videoCodec, .h264)
        XCTAssertEqual(try format(codec: kCMVideoCodecType_HEVC, transfer: nil).videoCodec, .hevc)
    }

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

    func testHDRContextGivesConditionalAdviceWhenDecoderFailsBeforeFormatArrives() throws {
        let failure = NativePlaybackFailure.classify(
            NSError(domain: "CoreMediaErrorDomain", code: -12927),
            provider: .emby, convertingHDRSource: true
        )
        XCTAssertEqual(failure.kind, .hdrConversionUnconfirmed)
        XCTAssertTrue(failure.allowsCodecFallback)
        var message = failure.userMessage
        message.locale = Locale(identifier: "en_US")
        let text = String(localized: message)
        XCTAssertTrue(text.contains("may be needed"))
        XCTAssertFalse(text.contains("disabled"))
        XCTAssertEqual(NativePlaybackFailure.classify(
            NSError(domain: "CoreMediaErrorDomain", code: -12927), provider: .emby
        ).kind, .unknown)
        let sdr = try format(codec: kCMVideoCodecType_H264, transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2)
        XCTAssertEqual(NativePlaybackFailure.classify(
            NSError(domain: "CoreMediaErrorDomain", code: -12927),
            convertedFormat: sdr, provider: .emby, convertingHDRSource: true
        ).kind, .unknown)
        XCTAssertEqual(NativePlaybackFailure.classify(
            NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue),
            provider: .emby, convertingHDRSource: true
        ).kind, .timedOut)
    }

    @MainActor
    func testProbeWaitsForColorMetadataRatherThanAssumingTheFirstTrackIsSDR() async throws {
        let incomplete = try format(codec: kCMVideoCodecType_H264, transfer: nil)
        let sdr = try format(codec: kCMVideoCodecType_H264, transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2)
        var reads = 0
        let actual = try await NativePlaybackFailure.probeConvertedFormat(
            read: { reads += 1; return reads < 3 ? incomplete : sdr },
            isCurrent: { true }, pause: {}
        )
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(actual?.dynamicRange, .sdr)
        XCTAssertNil(incomplete.dynamicRange)
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
