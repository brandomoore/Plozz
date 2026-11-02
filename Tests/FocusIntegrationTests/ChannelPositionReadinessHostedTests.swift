import AVFoundation
import CoreModels
import EnginePlozzigen
import FeaturePlayback
import UIKit
import XCTest

@MainActor
final class ChannelPositionReadinessHostedTests: XCTestCase {
    func testSDRPreviewFullscreenRoundTripsKeepTheDecoderPositionAndPauseState() async throws {
        try await verifySDRPresentationRoundTrips(isLive: false)
    }

    func testNativeHLSSDRPreviewFullscreenRoundTripsKeepThePlayingItemAndPauseState() async throws {
        try await verifySDRPresentationRoundTrips(isLive: true)
    }

    private func verifySDRPresentationRoundTrips(isLive: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let url: URL
        var server: SubtitleFixtureServer?
        var temporaryVideo: URL?
        defer {
            server?.stop()
            if let temporaryVideo { try? FileManager.default.removeItem(at: temporaryVideo) }
        }
        if isLive {
            let directory = try XCTUnwrap(Bundle(for: Self.self).url(
                forResource: "Fixtures", withExtension: nil
            )).appendingPathComponent("active-picture-hls")
            let fixtureServer = try SubtitleFixtureServer(directory: directory)
            server = fixtureServer
            let port = try await fixtureServer.start()
            url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/active-picture.m3u8"))
        } else {
            url = try await makeVideo()
            temporaryVideo = url
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let controller = UIViewController()
        window.rootViewController = controller
        let engine = try PlozzigenVideoEngine()
        var failures: [AppError] = []
        var endings = 0
        var sourcePublications = 0
        engine.onFailure = { failures.append($0) }
        engine.onEnded = { endings += 1 }
        engine.onProbedSourceFactsChanged = { _ in sourcePublications += 1 }
        let video = engine.makeVideoOutputView()
        video.frame = window.bounds
        controller.view.addSubview(video)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            engine.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        engine.configureLiveOutput(.init(suppressesDisplayMatching: true))
        XCTAssertFalse(engine.isPlaybackPositionReady)
        if isLive {
            await engine.loadLive(url: url, httpHeaders: [:])
        } else {
            await engine.load(
                request: PlaybackRequest(
                    item: MediaItem(id: "readiness", title: "Readiness fixture", kind: .movie, runtime: 120),
                    streamURL: url
                ),
                startPosition: 20
            )
        }
        try await waitForPosition(engine)
        XCTAssertTrue(engine.liveSnapshot.firstFrameReady)
        if !isLive { XCTAssertGreaterThanOrEqual(engine.currentTime, 19) }
        let probeDeadline = ContinuousClock.now + .seconds(5)
        while engine.probedSourceFacts == nil, ContinuousClock.now < probeDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(engine.probedSourceFacts?.range, .sdr)
        let publications = sourcePublications
        XCTAssertGreaterThan(publications, 0)
        let player = engine.nowPlayingPlayer
        let item = player?.currentItem
        if isLive {
            XCTAssertNotNil(player, "The HLS fixture must exercise the native AVPlayer route.")
            XCTAssertNotNil(item)
        }
        for suppressed in [false, true] {
            let position = engine.currentTime
            engine.configureLiveOutput(.init(suppressesDisplayMatching: suppressed))
            XCTAssertTrue(engine.isPlaybackPositionReady, "An SDR transition must not rebuild the decoder.")
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(engine.isPlaybackPositionReady)
            XCTAssertGreaterThanOrEqual(engine.currentTime, position - 1)
            XCTAssertTrue(engine.liveSnapshot.firstFrameReady)
            XCTAssertFalse(engine.isPaused)
        }
        engine.pause()
        let position = engine.currentTime
        let selectedAudio = engine.currentAudioTrackID
        for suppressed in [false, true, false, true] {
            engine.configureLiveOutput(.init(suppressesDisplayMatching: suppressed))
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(engine.isPlaybackPositionReady)
            XCTAssertTrue(engine.isPaused)
            XCTAssertEqual(engine.currentTime, position, accuracy: 0.1)
            XCTAssertEqual(engine.currentAudioTrackID, selectedAudio)
            XCTAssertTrue(engine.nowPlayingPlayer === player)
            XCTAssertTrue(engine.nowPlayingPlayer?.currentItem === item)
        }
        XCTAssertEqual(sourcePublications, publications, "An SDR transition must retain its probed source.")
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(endings, 0, "A presentation transition is not the end of playback.")
    }

    private func waitForPosition(_ engine: PlozzigenVideoEngine) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !engine.isPlaybackPositionReady, ContinuousClock.now < deadline {
            if case .failed(let error) = engine.status { throw error }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(engine.isPlaybackPositionReady, "The real decoder did not settle its playback position.")
        guard engine.isPlaybackPositionReady else { throw NSError(domain: "ChannelPositionFixture", code: 2) }
    }

    private func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var finished = false
        defer {
            if !finished {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: url)
            }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 90,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: 30, AVVideoExpectedSourceFrameRateKey: 30
            ]
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: nil
        )
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA, nil, &buffer),
            kCVReturnSuccess
        )
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
        bytes.initializeMemory(as: UInt8.self, repeating: 255, count: CVPixelBufferGetBytesPerRow(pixel) * 90)
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let deadline = ContinuousClock.now + .seconds(30)
        for frame in 0..<3_600 {
            while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard input.isReadyForMoreMediaData,
                  adapter.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                writer.cancelWriting()
                throw writer.error ?? NSError(domain: "ChannelPositionFixture", code: 1)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw try XCTUnwrap(writer.error) }
        finished = true
        return url
    }
}
