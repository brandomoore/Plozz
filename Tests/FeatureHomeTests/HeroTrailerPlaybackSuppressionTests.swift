#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import CoreVideo
import FeatureHomeCore
import UIKit
import XCTest

@MainActor
final class HeroTrailerPlaybackSuppressionTests: XCTestCase {
    func testMainPlaybackPausesExistingTrailerAndRejectsLateStarts() async throws {
        let url = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        controller.play(itemID: "hero", resolvedURL: url, muted: false)
        try await wait { controller.isPlaying && controller.player.currentTime().seconds > 0.1 }
        let item = try XCTUnwrap(controller.player.currentItem)
        let owner = UUID()
        controller.suspendForPlayback(owner: owner)
        let position = controller.player.currentTime().seconds
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(controller.player.rate, 0)

        controller.setPaused(false)
        controller.startPrepared()
        controller.prepare(itemID: "late-result", resolvedURL: url, muted: true)
        controller.play(itemID: "late-result", resolvedURL: url, muted: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(controller.player.currentItem === item)
        XCTAssertEqual(controller.currentItemID, "hero")
        XCTAssertFalse(controller.isMuted, "Suppression must preserve the live mute choice")
        XCTAssertEqual(controller.player.rate, 0)
        XCTAssertEqual(controller.player.currentTime().seconds, position, accuracy: 0.05)

        controller.resumeAfterPlayback(owner: owner)
        try await wait { controller.player.currentTime().seconds > position + 0.1 }
        XCTAssertFalse(controller.isPaused)
        XCTAssertTrue(controller.player.currentItem === item)
    }

    func testReadinessArrivingUnderMainPlaybackCannotAutoplay() async throws {
        let url = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        let owner = UUID()
        controller.play(itemID: "pending", resolvedURL: url, muted: false)
        controller.suspendForPlayback(owner: owner)
        try await wait { controller.isReady }
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.player.rate, 0)
        controller.setPaused(false)
        controller.startPrepared()
        XCTAssertEqual(controller.player.rate, 0)
        controller.resumeAfterPlayback(owner: owner)
        controller.startPrepared()
        try await wait { controller.isPlaying }
    }

    func testOnlyTheLastOwnerCanReleasePlaybackAndSurfacePauseStillWins() {
        let controller = HeroTrailerController()
        let first = UUID()
        let second = UUID()
        controller.suspendForPlayback(owner: first)
        controller.suspendForPlayback(owner: first)
        controller.suspendForPlayback(owner: second)
        controller.setPaused(false)
        controller.resumeAfterPlayback(owner: first)
        controller.resumeAfterPlayback(owner: first)
        controller.resumeAfterPlayback(owner: UUID())
        XCTAssertTrue(controller.isPlaybackSuppressed)
        XCTAssertTrue(controller.isPaused)
        controller.setPaused(true)
        controller.resumeAfterPlayback(owner: second)
        XCTAssertFalse(controller.isPlaybackSuppressed)
        XCTAssertTrue(controller.isPaused)
        controller.setPaused(false)
        XCTAssertFalse(controller.isPaused)
    }

    func testStoppingOldTrailerDoesNotClearTheMainPlayerHold() async throws {
        let url = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        controller.prepare(itemID: "old", resolvedURL: url, muted: true)
        let owner = UUID()
        controller.suspendForPlayback(owner: owner)
        controller.stop()
        controller.setPaused(false)
        controller.play(itemID: "late", resolvedURL: url, muted: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.player.currentItem)
        XCTAssertNil(controller.currentItemID)
        XCTAssertFalse(controller.isReady, "A stale item's status must not publish readiness after teardown")
        XCTAssertTrue(controller.isPlaybackSuppressed)
        XCTAssertTrue(controller.isPaused)
        controller.resumeAfterPlayback(owner: owner)
        controller.play(itemID: "new", resolvedURL: url, muted: false)
        try await wait { controller.isPlaying }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Trailer did not reach the expected state")
        throw FixtureError.timedOut
    }

    private func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hero-hold-\(UUID()).mov")
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 96
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 96
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.encodingFailed }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 96, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw FixtureError.encodingFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) {
            memset(address, 0x80, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<30 {
            try await wait { input.isReadyForMoreMediaData || writer.status == .failed }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)) else {
                throw writer.error ?? FixtureError.encodingFailed
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureError.encodingFailed }
        return url
    }

    private enum FixtureError: Error { case encodingFailed, timedOut }
}
#endif
