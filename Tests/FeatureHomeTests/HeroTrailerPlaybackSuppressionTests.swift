#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import CoreVideo
import CoreModels
import FeatureHomeCore
import UIKit
import XCTest

@MainActor
final class HeroTrailerPlaybackSuppressionTests: XCTestCase {
    func testPlayingTrailerStillProducesHandoffFrame() async throws {
        let url = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        controller.play(itemID: "hero", resolvedURL: url, muted: true)
        try await wait { controller.isPlaying && controller.player.currentTime().seconds > 0.1 }
        await controller.captureHandoffFrame()
        let frame = try XCTUnwrap(controller.handoffImage?.cgImage)
        XCTAssertEqual(frame.width, 160)
        XCTAssertEqual(frame.height, 96)
        XCTAssertEqual(controller.currentItemID, "hero")
        controller.stop()
        XCTAssertNil(controller.handoffImage)
    }

    func testFeaturedCoordinatorPlaysResolvedTrailerAndWithdrawsOnScrollAway() async throws {
        let url = try await makeVideo()
        let controller = HeroTrailerController()
        let coordinator = FeaturedTrailerCoordinator(settleDelay: .zero)
        defer { coordinator.stop() }
        let row = UUID()
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie).taggingSource("account")
        coordinator.update(
            rowID: row, item: item, scope: ObjectIdentifier(controller), priority: 0,
            muted: false, controller: controller, resolve: { selected in
                XCTAssertEqual(selected.sourceAccountID, "account")
                XCTAssertEqual(selected.id, "movie")
                return HeroTrailerSource(ownerItemID: selected.id, trailerItemID: "clip", url: url, duration: 30)
            }
        )
        try await wait { controller.isPlaying && controller.player.currentTime().seconds > 0.1 }
        XCTAssertTrue(controller.isClaimed(by: .featured, itemID: try XCTUnwrap(coordinator.playerItemID)))
        XCTAssertFalse(controller.isMuted)
        coordinator.withdraw(rowID: row)
        XCTAssertNil(controller.player.currentItem)
        XCTAssertFalse(controller.isFeaturedReserved)
    }

    func testFeaturedReservationRejectsHiddenHeroCommandsAndRestoresRecedePause() async throws {
        let url = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        controller.setPaused(true)
        let owner = UUID()
        XCTAssertTrue(controller.reserveFeaturedSurface(owner: owner))
        controller.play(itemID: "featured", resolvedURL: url, muted: true, featuredOwner: owner)
        try await wait { controller.isPlaying }
        let current = controller.player.currentItem
        controller.stopHero()
        controller.setPaused(true)
        controller.setMuted(false)
        controller.prepare(itemID: "late-hero", resolvedURL: url, muted: false)
        controller.play(itemID: "late-hero", resolvedURL: url, muted: false)
        controller.claimSurface(.home, itemID: "featured")
        XCTAssertTrue(controller.player.currentItem === current)
        XCTAssertTrue(controller.isMuted)
        XCTAssertFalse(controller.isPaused)
        controller.releaseFeaturedSurface(owner: UUID())
        XCTAssertEqual(controller.currentItemID, "featured")
        controller.releaseFeaturedSurface(owner: owner)
        XCTAssertNil(controller.player.currentItem)
        XCTAssertTrue(controller.isPaused, "The receded hero must not resume offscreen.")
        XCTAssertFalse(controller.isFeaturedReserved)
    }

    func testFeaturedCannotOverrideFullPlaybackOrRestartAfterGlobalStop() async throws {
        let url = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        let owner = UUID()
        XCTAssertTrue(controller.reserveFeaturedSurface(owner: owner))
        controller.prepare(itemID: "featured", resolvedURL: url, muted: true, featuredOwner: owner)
        let fullPlayer = UUID()
        controller.suspendForPlayback(owner: fullPlayer)
        XCTAssertFalse(controller.reserveFeaturedSurface(owner: UUID()))
        controller.startPrepared(featuredOwner: owner)
        XCTAssertEqual(controller.player.rate, 0)
        controller.stop()
        controller.resumeAfterPlayback(owner: fullPlayer)
        controller.play(itemID: "late", resolvedURL: url, muted: false, featuredOwner: owner)
        XCTAssertNil(controller.currentItemID)
        XCTAssertNil(controller.player.currentItem)
    }

    func testDepartingDetailCannotStopTheSameTitlesNewerTrailerOwner() async throws {
        let url = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        controller.prepare(itemID: "movie", resolvedURL: url, muted: true)
        controller.setEndHandler(ownerID: "new-page") {}
        let current = controller.player.currentItem
        controller.stop(ifShowing: "movie", ownedBy: "old-page")
        controller.clearEndHandler(ownerID: "old-page")
        XCTAssertEqual(controller.currentItemID, "movie")
        XCTAssertTrue(controller.player.currentItem === current)
        controller.stop(ifShowing: "movie", ownedBy: "new-page")
        XCTAssertNil(controller.currentItemID)
        XCTAssertNil(controller.player.currentItem)
    }

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
