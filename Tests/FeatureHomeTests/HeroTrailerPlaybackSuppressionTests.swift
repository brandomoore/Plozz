#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import CoreVideo
import CoreModels
@testable import FeatureHomeCore
import UIKit
import XCTest

@MainActor
final class HeroTrailerPlaybackSuppressionTests: XCTestCase {
    func testScopedSourceSurvivesHandoffAndFullscreenReplayButNotAmbientEnd() async throws {
        let controller = HeroTrailerController()
        defer { controller.stop() }
        let released = expectation(description: "release after player detaches")
        let source = try await makeVideo(session: HeroTrailerSession { @MainActor [weak controller] in
            XCTAssertNil(controller?.player.currentItem)
            released.fulfill()
        })
        controller.play(itemID: "movie", source: source, muted: true)
        controller.claimSurface(.home, itemID: "movie")
        try await wait { controller.isPlaying }
        let item = try XCTUnwrap(controller.player.currentItem)
        controller.handoffToDetail(itemID: "movie")
        controller.stopHero()
        let fullscreen = try XCTUnwrap(controller.beginFullScreen(itemID: "movie", from: .detail))
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        XCTAssertTrue(controller.player.currentItem === item, "Fullscreen still owns replay and seeking")
        controller.endFullScreen(id: fullscreen)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        XCTAssertNil(controller.player.currentItem)
        XCTAssertFalse(controller.prepare(itemID: "movie", source: source, muted: true), "Cannot replay a released grant")
        await fulfillment(of: [released], timeout: 2)
    }

    func testDuplicateReplacementAndStopConsumeOnlyTheirOwnGrants() async throws {
        let controller = HeroTrailerController()
        let releases = ["original", "duplicate", "replacement", "rejected"].map { expectation(description: $0) }
        func source(_ index: Int) -> HeroTrailerSource {
            HeroTrailerSource(ownerItemID: "movie", trailerItemID: "clip",
                              url: URL(fileURLWithPath: "/unused-trailer.mov"), duration: 30,
                              session: HeroTrailerSession { releases[index].fulfill() })
        }
        let sources = releases.indices.map(source)
        controller.prepare(itemID: "movie", source: sources[0], muted: true)
        let original = try XCTUnwrap(controller.player.currentItem)
        controller.prepare(itemID: "movie", source: sources[1], muted: true)
        XCTAssertTrue(controller.player.currentItem === original)
        controller.prepare(itemID: "next", source: sources[2], muted: true)
        XCTAssertFalse(controller.player.currentItem === original)
        let owner = UUID()
        controller.suspendForPlayback(owner: owner)
        XCTAssertFalse(controller.prepare(itemID: "late", source: sources[3], muted: true))
        controller.stop()
        controller.stop()
        await fulfillment(of: releases, timeout: 2)
        controller.resumeAfterPlayback(owner: owner)
        for source in sources {
            XCTAssertFalse(controller.prepare(itemID: "movie", source: source, muted: true))
        }
    }

    func testPlayingTrailerStillProducesHandoffFrame() async throws {
        let source = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        controller.play(itemID: "hero", source: source, muted: true)
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
        let source = try await makeVideo()
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
                return source
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
        let source = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        controller.setPaused(true)
        let owner = UUID()
        XCTAssertTrue(controller.reserveFeaturedSurface(owner: owner))
        controller.play(itemID: "featured", source: source, muted: true, featuredOwner: owner)
        try await wait { controller.isPlaying }
        let current = controller.player.currentItem
        controller.stopHero()
        controller.setPaused(true)
        controller.setMuted(false)
        controller.prepare(itemID: "late-hero", source: source, muted: false)
        controller.play(itemID: "late-hero", source: source, muted: false)
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
        let source = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        let owner = UUID()
        XCTAssertTrue(controller.reserveFeaturedSurface(owner: owner))
        controller.prepare(itemID: "featured", source: source, muted: true, featuredOwner: owner)
        let fullPlayer = UUID()
        controller.suspendForPlayback(owner: fullPlayer)
        XCTAssertFalse(controller.reserveFeaturedSurface(owner: UUID()))
        controller.startPrepared(featuredOwner: owner)
        XCTAssertEqual(controller.player.rate, 0)
        controller.stop()
        controller.resumeAfterPlayback(owner: fullPlayer)
        controller.play(itemID: "late", source: source, muted: false, featuredOwner: owner)
        XCTAssertNil(controller.currentItemID)
        XCTAssertNil(controller.player.currentItem)
    }

    func testDepartingDetailCannotStopTheSameTitlesNewerTrailerOwner() async throws {
        let source = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        controller.prepare(itemID: "movie", source: source, muted: true)
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
        let source = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        controller.play(itemID: "hero", source: source, muted: false)
        try await wait { controller.isPlaying && controller.player.currentTime().seconds > 0.1 }
        let item = try XCTUnwrap(controller.player.currentItem)
        let owner = UUID()
        controller.suspendForPlayback(owner: owner)
        let position = controller.player.currentTime().seconds
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(controller.player.rate, 0)

        controller.setPaused(false)
        controller.startPrepared()
        controller.prepare(itemID: "late-result", source: source, muted: true)
        controller.play(itemID: "late-result", source: source, muted: true)
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
        let source = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        let owner = UUID()
        controller.play(itemID: "pending", source: source, muted: false)
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
        let source = try await makeVideo()
        let controller = HeroTrailerController()
        defer { controller.stop() }
        controller.prepare(itemID: "old", source: source, muted: true)
        let owner = UUID()
        controller.suspendForPlayback(owner: owner)
        controller.stop()
        controller.setPaused(false)
        controller.play(itemID: "late", source: source, muted: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.player.currentItem)
        XCTAssertNil(controller.currentItemID)
        XCTAssertFalse(controller.isReady, "A stale item's status must not publish readiness after teardown")
        XCTAssertTrue(controller.isPlaybackSuppressed)
        XCTAssertTrue(controller.isPaused)
        controller.resumeAfterPlayback(owner: owner)
        controller.play(itemID: "new", source: source, muted: false)
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

    private func makeVideo(session: HeroTrailerSession? = nil) async throws -> HeroTrailerSource {
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
        return HeroTrailerSource(ownerItemID: "movie", trailerItemID: "clip", url: url, duration: 30, session: session)
    }

    private enum FixtureError: Error { case encodingFailed, timedOut }
}
#endif
