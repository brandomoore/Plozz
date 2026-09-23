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

final class NativeStartupResumeTests: XCTestCase {
    @MainActor
    func testRejectedDirectPlayResumeFailsBeforePlayingFromZero() async {
        let resume = NativeStartupResume(
            itemStatus: { .readyToPlay }, isCurrent: { true },
            beginSeek: { completion in
                completion(NativeStartupResume.didLand(
                    finished: false, position: 0, target: 425.7, tolerance: 1
                ))
            },
            cancelSeek: { XCTFail("A completed rejection has no pending seek to cancel.") }
        )
        let result = await resume.run()
        XCTAssertEqual(result, .failed)
        XCTAssertFalse(NativeStartupResume.didLand(
            finished: true, position: 0, target: 425.7, tolerance: 1
        ), "A callback alone must not accept playback at the wrong position.")
        XCTAssertTrue(NativeStartupResume.didLand(
            finished: true, position: 425.73, target: 425.7, tolerance: 1
        ))
        XCTAssertFalse(NativeStartupResume.didLand(
            finished: true, position: .nan, target: 425.7, tolerance: 1
        ))
    }

    @MainActor
    func testCancellingAUserWaiterDoesNotCancelStartupOrAnotherWaiter() async {
        let seeking = expectation(description: "startup seek pending")
        let waiterReturned = expectation(description: "cancelled user waiter returned")
        let loadReturned = expectation(description: "startup load completed")
        let otherReturned = expectation(description: "other waiter completed")
        var callback: (@Sendable (Bool) -> Void)?
        var cancellationCount = 0
        let resume = NativeStartupResume(
            itemStatus: { .readyToPlay }, isCurrent: { true },
            beginSeek: { callback = $0; seeking.fulfill() },
            cancelSeek: { cancellationCount += 1 }
        )
        let load = Task {
            let result = await resume.run()
            XCTAssertEqual(result, .ready)
            loadReturned.fulfill()
        }
        await fulfillment(of: [seeking], timeout: 1)
        let waiter = Task {
            let result = await resume.waitForCompletion()
            XCTAssertEqual(result, .cancelled)
            waiterReturned.fulfill()
        }
        defer { load.cancel(); waiter.cancel(); resume.cancel() }
        await Task.yield()
        waiter.cancel()
        await fulfillment(of: [waiterReturned], timeout: 1)
        XCTAssertEqual(cancellationCount, 0)
        let other = Task {
            let result = await resume.waitForCompletion()
            XCTAssertEqual(result, .ready)
            otherReturned.fulfill()
        }
        defer { other.cancel() }
        callback?(true)
        await fulfillment(of: [loadReturned, otherReturned], timeout: 1)
    }

    @MainActor
    func testUnknownPastFiveSecondsNeverSeeksUntilActuallyReady() async {
        var status = AVPlayerItem.Status.unknown
        var seeks = 0
        let earlySeek = expectation(description: "no seek while unknown for 5.2 seconds")
        earlySeek.isInverted = true
        let returned = expectation(description: "ready seek completed")
        let resume = NativeStartupResume(
            itemStatus: { status }, isCurrent: { true },
            beginSeek: { completion in
                if status != .readyToPlay { earlySeek.fulfill() }
                XCTAssertEqual(status, .readyToPlay)
                seeks += 1
                completion(true)
            },
            cancelSeek: { XCTFail("Healthy startup must not cancel the item") }
        )
        let task = Task {
            let result = await resume.run()
            XCTAssertEqual(result, .ready)
            returned.fulfill()
        }
        defer { task.cancel(); resume.cancel() }
        await fulfillment(of: [earlySeek], timeout: 5.2)
        XCTAssertEqual(seeks, 0)
        status = .readyToPlay
        await fulfillment(of: [returned], timeout: 1)
        XCTAssertEqual(seeks, 1)
    }

    @MainActor
    func testSameItemUserSeekReplacesPendingResumeWithoutCancellingLoad() async {
        let initialSeek = expectation(description: "initial resume seek")
        let replacementSeek = expectation(description: "user replacement seek")
        let loadReturned = expectation(description: "load readied")
        let userReturned = expectation(description: "user seek completed")
        var initialCallback: (@Sendable (Bool) -> Void)?
        var replacementCallback: (@Sendable (Bool) -> Void)?
        var cancellations = 0
        var ready = false
        let resume = NativeStartupResume(
            itemStatus: { .readyToPlay }, isCurrent: { true },
            beginSeek: { initialCallback = $0; initialSeek.fulfill() },
            cancelSeek: { cancellations += 1 }
        )
        let load = Task {
            let result = await resume.run()
            XCTAssertEqual(result, .ready)
            ready = true
            loadReturned.fulfill()
        }
        await fulfillment(of: [initialSeek], timeout: 1)
        XCTAssertTrue(resume.replaceSeek {
            replacementCallback = $0
            replacementSeek.fulfill()
        })
        let userSeek = Task {
            let result = await resume.waitForCompletion()
            XCTAssertEqual(result, .ready)
            userReturned.fulfill()
        }
        defer { load.cancel(); userSeek.cancel(); resume.cancel() }
        await fulfillment(of: [replacementSeek], timeout: 1)
        XCTAssertEqual(cancellations, 1)
        initialCallback?(false)
        initialCallback?(true)
        await Task.yield()
        XCTAssertFalse(ready, "Late startup completions cannot finish the replacement seek")
        XCTAssertEqual(cancellations, 1, "The new same-item seek must not be cancelled")
        replacementCallback?(true)
        await fulfillment(of: [loadReturned, userReturned], timeout: 1)
        resume.cancel()
        XCTAssertEqual(cancellations, 1)
    }

    @MainActor
    func testSameItemUserTargetWhileUnknownStillWaitsForReadiness() async {
        var status = AVPlayerItem.Status.unknown
        var seeks = 0
        let waiting = expectation(description: "readiness checked")
        let returned = expectation(description: "latest target completed")
        var announcedWaiting = false
        let resume = NativeStartupResume(
            itemStatus: {
                if !announcedWaiting { announcedWaiting = true; waiting.fulfill() }
                return status
            },
            isCurrent: { true },
            beginSeek: { _ in XCTFail("Superseded initial target must never seek") },
            cancelSeek: { XCTFail("No seek exists before readiness") }
        )
        let load = Task {
            let result = await resume.run()
            XCTAssertEqual(result, .ready)
            returned.fulfill()
        }
        defer { load.cancel(); resume.cancel() }
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertTrue(resume.replaceSeek { completion in
            XCTAssertEqual(status, .readyToPlay)
            seeks += 1
            completion(true)
        })
        XCTAssertEqual(seeks, 0)
        status = .readyToPlay
        await fulfillment(of: [returned], timeout: 1)
        XCTAssertEqual(seeks, 1)
    }

    @MainActor
    func testCancellationDuringReadinessReturnsWithoutSeeking() async {
        let waiting = expectation(description: "waiting for readiness")
        let returned = expectation(description: "cancelled startup returned")
        var seeks = 0
        let resume = NativeStartupResume(
            itemStatus: { .unknown }, isCurrent: { true },
            beginSeek: { _ in seeks += 1 },
            cancelSeek: { XCTFail("No seek exists while waiting for readiness") },
            pause: {
                waiting.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )
        let task = Task {
            let result = await resume.run()
            XCTAssertEqual(result, .cancelled)
            returned.fulfill()
        }
        defer { task.cancel(); resume.cancel() }
        await fulfillment(of: [waiting], timeout: 1)
        task.cancel()
        await fulfillment(of: [returned], timeout: 1)
        XCTAssertEqual(seeks, 0)
    }

    @MainActor
    func testCancellationDuringPendingSeekDoesNotWaitForAVFoundationCallback() async {
        let seeking = expectation(description: "seek started")
        let returned = expectation(description: "cancelled seek returned")
        var callback: (@Sendable (Bool) -> Void)?
        var cancellations = 0
        let resume = NativeStartupResume(
            itemStatus: { .readyToPlay }, isCurrent: { true },
            beginSeek: { completion in callback = completion; seeking.fulfill() },
            cancelSeek: { cancellations += 1 }
        )
        let task = Task {
            let result = await resume.run()
            XCTAssertEqual(result, .cancelled)
            returned.fulfill()
        }
        defer { task.cancel(); resume.cancel() }
        await fulfillment(of: [seeking], timeout: 1)
        task.cancel()
        await fulfillment(of: [returned], timeout: 1)
        XCTAssertEqual(cancellations, 1)
        callback?(true)
        await Task.yield()
        XCTAssertEqual(cancellations, 1, "A late completion must not finish/cancel another operation")
    }

    @MainActor
    func testFailedItemNeverSeeksOrPublishesReady() async {
        let failed = NativeStartupResume(
            itemStatus: { .failed }, isCurrent: { true },
            beginSeek: { _ in XCTFail("Failed items cannot seek") },
            cancelSeek: {}
        )
        let initialResult = await failed.run()
        XCTAssertEqual(initialResult, .failed)

        var status = AVPlayerItem.Status.readyToPlay
        let failsDuringSeek = NativeStartupResume(
            itemStatus: { status }, isCurrent: { true },
            beginSeek: { completion in status = .failed; completion(true) },
            cancelSeek: {}
        )
        let seekResult = await failsDuringSeek.run()
        XCTAssertEqual(seekResult, .failed)
    }

    @MainActor
    func testCancellingOldLoadCannotCancelNewerPendingSeek() async {
        let oldSeeking = expectation(description: "old seek")
        let newSeeking = expectation(description: "new seek")
        let oldReturned = expectation(description: "old returned")
        let newReturned = expectation(description: "new returned")
        var oldCallback: (@Sendable (Bool) -> Void)?
        var newCallback: (@Sendable (Bool) -> Void)?
        var oldCancellations = 0
        var newCancellations = 0
        var newFinished = false
        let old = NativeStartupResume(
            itemStatus: { .readyToPlay }, isCurrent: { true },
            beginSeek: { oldCallback = $0; oldSeeking.fulfill() },
            cancelSeek: { oldCancellations += 1 }
        )
        let newer = NativeStartupResume(
            itemStatus: { .readyToPlay }, isCurrent: { true },
            beginSeek: { newCallback = $0; newSeeking.fulfill() },
            cancelSeek: { newCancellations += 1 }
        )
        let oldTask = Task {
            let result = await old.run()
            XCTAssertEqual(result, .cancelled)
            oldReturned.fulfill()
        }
        await fulfillment(of: [oldSeeking], timeout: 1)
        old.cancel() // The old item's teardown precedes installing the new item.
        let newTask = Task {
            let result = await newer.run()
            XCTAssertEqual(result, .ready)
            newFinished = true
            newReturned.fulfill()
        }
        defer { oldTask.cancel(); newTask.cancel(); old.cancel(); newer.cancel() }
        await fulfillment(of: [newSeeking, oldReturned], timeout: 1)
        oldTask.cancel()
        oldCallback?(true)
        await Task.yield()
        XCTAssertEqual(oldCancellations, 1)
        XCTAssertEqual(newCancellations, 0)
        XCTAssertFalse(newFinished)
        newCallback?(true)
        await fulfillment(of: [newReturned], timeout: 1)
        old.cancel()
        XCTAssertEqual(newCancellations, 0)
    }
}

final class NativePlaybackFailureTests: XCTestCase {
    @MainActor
    func testSilentTestEngineMutesPlayerBeforeStartingPlayback() async {
        let engine = NativeVideoEngine(startsMuted: true)
        defer { engine.stop() }
        await engine.load(request: .init(
            item: .init(id: "fixture", title: "Silent fixture", kind: .movie),
            streamURL: URL(fileURLWithPath: "/dev/null")
        ), startPosition: 0)
        XCTAssertEqual(engine.underlyingPlayer?.isMuted, true)
    }

    func testErrorChainKeepsUnderlyingNumericCauseWithoutDescriptionsOrUnknownDomains() {
        let media = NSError(domain: "CoreMediaErrorDomain", code: -12642, userInfo: [
            NSLocalizedDescriptionKey: "https://private.example/?api_key=secret"
        ])
        let privateWrapper = NSError(domain: "https://private.example/token", code: 123, userInfo: [
            NSUnderlyingErrorKey: media
        ])
        let error = NSError(domain: AVFoundationErrorDomain, code: -11829, userInfo: [
            NSUnderlyingErrorKey: privateWrapper
        ])
        XCTAssertEqual(NativePlaybackLifecycleDiagnostics.errorChain(error), "AV:-11829>CoreMedia:-12642")
        XCTAssertEqual(NativePlaybackLifecycleDiagnostics.errorChain(nil), "none")
    }

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
