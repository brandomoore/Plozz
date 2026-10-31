import AVFoundation
import CoreModels
import FeaturePlayback
import EnginePlozzigen
import Foundation
import XCTest

@MainActor
final class StreamingBufferingHostedTests: XCTestCase {
    func testOrdinaryServerHLSStartupTimeoutRecoversToDecodedVideo() async throws {
        let initialization = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "iptv-init", withExtension: "mp4", subdirectory: "Fixtures"
        ))
        let segment = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "iptv-segment-0", withExtension: "m4s", subdirectory: "Fixtures"
        ))
        let server = try IPTVTestHTTPServer { request in
            if request.contains(".m3u8") {
                let media = request.contains("/initial.m3u8") ? "unresponsive.m4s" : "ready.m4s"
                return .init(data: Data("""
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:12
                #EXT-X-PLAYLIST-TYPE:VOD
                #EXT-X-MAP:URI="init.mp4"
                #EXTINF:12,
                \(media)
                #EXT-X-ENDLIST

                """.utf8), headers: ["Content-Type": "application/vnd.apple.mpegurl"])
            }
            if request.contains("/init.mp4") {
                return .init(file: initialization, headers: ["Content-Type": "video/mp4"])
            }
            if request.contains(".m4s") {
                return .init(
                    file: segment, headers: ["Content-Type": "video/mp4"],
                    headerDelay: request.contains("/unresponsive.m4s") ? .seconds(45) : .zero
                )
            }
            return .init(status: 404)
        }
        addTeardownBlock { await server.stop() }
        let origin = try await server.start()
        let provider = StartupRecoveryProvider(origin: origin)
        let aether = try PlozzigenVideoEngine()
        let model = PlayerViewModel(
            provider: provider, itemID: "movie", mediaSourceID: "version",
            engineFactory: .init(
                makeNative: { NativeVideoEngine(style: $0, startsMuted: true) },
                makePlozzigen: { aether }
            )
        )
        addTeardownBlock { @MainActor in await model.stop() }
        let started = ContinuousClock.now
        await model.load()
        XCTAssertNil(model.streamingOptions, "Reproduce the ordinary Apple TV path, not mobile quality selection.")
        XCTAssertEqual(model.videoEngine.diagnosticRoute, .nativeHLS)
        var observedItem: AVPlayerItem?
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        defer { observedItem?.remove(output) }
        var decodedFrames = 0
        let deadline = started + .seconds(44)
        while ContinuousClock.now < deadline {
            if case .failed = model.phase { break }
            if let player = model.diagnosticsPlayer, let item = player.currentItem {
                player.isMuted = true
                if observedItem !== item {
                    observedItem?.remove(output)
                    observedItem = item
                    item.add(output)
                }
                if output.hasNewPixelBuffer(forItemTime: player.currentTime()),
                   output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil {
                    decodedFrames += 1
                    if decodedFrames >= 10 { break }
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let retries = await provider.retries
        print("SERVER_HLS_RECOVERY elapsed=\(started.duration(to: .now)) frames=\(decodedFrames) retries=\(retries.count)")
        XCTAssertGreaterThanOrEqual(decodedFrames, 10, "Require decoded replacement frames before the original segment can respond.")
        XCTAssertEqual(retries.count, 1)
        XCTAssertEqual(retries.first?.source, "version")
        XCTAssertEqual(retries.first?.options.quality, .original)
        XCTAssertEqual(retries.first?.options.codec, .preferH264)
        XCTAssertEqual(retries.first?.forceTranscode, true)
        XCTAssertEqual(retries.first?.previousSessionStopped, true)
        XCTAssertNil(model.streamingQualityError)
        await model.stop()
    }

    func testServerHLSRecoversFromAnEncoderSegmentGap() async throws {
        try await exercise(pauseBeforeStarting: false, rate: 1)
    }

    private actor StartupRecoveryProvider: StreamingQualityProviding {
        struct Retry: Sendable {
            let source: String?
            let options: StreamingPlaybackOptions
            let forceTranscode: Bool
            let previousSessionStopped: Bool
        }
        nonisolated let kind: ProviderKind = .jellyfin
        nonisolated let session: UserSession
        private let origin: URL
        private(set) var retries: [Retry] = []
        private var stoppedSessions: [String] = []

        init(origin: URL) {
            self.origin = origin
            session = .init(
                server: .init(id: "fixture", name: "Fixture", baseURL: origin, provider: .jellyfin),
                userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: "fixture"
            )
        }

        func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
            request(path: "initial.m3u8")
        }

        func playbackInfo(
            for itemID: String, mediaSourceID: String?, forceTranscode: Bool,
            streaming: StreamingPlaybackOptions
        ) async throws -> PlaybackRequest {
            retries.append(.init(
                source: mediaSourceID, options: streaming, forceTranscode: forceTranscode,
                previousSessionStopped: stoppedSessions.contains("initial.m3u8")
            ))
            var result = request(path: "replacement.m3u8")
            result.streamingOptions = streaming
            result.streamingSessionID = "replacement"
            result.negotiatedStreamingVideoCodec = .h264
            return result
        }

        private func request(path: String) -> PlaybackRequest {
            .init(
                item: .init(id: "movie", title: "Synthetic startup recovery", kind: .movie, runtime: 12),
                streamURL: origin.appendingPathComponent(path), playSessionID: path,
                isTranscoding: true, sourceProvider: .jellyfin
            )
        }

        func releaseStreamingSession(_ request: PlaybackRequest) async {}
        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { request(path: "initial.m3u8").item }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
            .init(items: [], startIndex: 0, totalCount: 0)
        }
        func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
            if event == .stop, let session = progress.playSessionID { stoppedSessions.append(session) }
        }
        nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }

    func testServerHLSResumePreservesSpeedAcrossAnEncoderSegmentGap() async throws {
        try await exercise(pauseBeforeStarting: true, rate: 1.25)
    }

    func testAetherServerHLSRecoversFromAnEncoderSegmentGap() async throws {
        try await exercise(pauseBeforeStarting: false, rate: 1, useAether: true)
    }

    func testAetherServerHLSPreservesPauseAndSpeedAcrossAnEncoderSegmentGap() async throws {
        try await exercise(pauseBeforeStarting: true, rate: 1.25, useAether: true)
    }

    private func exercise(pauseBeforeStarting: Bool, rate: Double, useAether: Bool = false) async throws {
        let initialization = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "iptv-init", withExtension: "mp4", subdirectory: "Fixtures"
        ))
        let segment = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "iptv-segment-0", withExtension: "m4s", subdirectory: "Fixtures"
        ))
        let server = try IPTVTestHTTPServer { request in
            if request.contains("/media.m3u8") {
                return .init(data: Data("""
                #EXTM3U
                #EXT-X-VERSION:7
                #EXT-X-TARGETDURATION:12
                #EXT-X-PLAYLIST-TYPE:VOD
                #EXT-X-MAP:URI="init.mp4"
                #EXTINF:12,
                first.m4s
                #EXT-X-DISCONTINUITY
                #EXTINF:12,
                delayed.m4s
                #EXT-X-DISCONTINUITY
                #EXTINF:12,
                last.m4s
                #EXT-X-ENDLIST

                """.utf8), headers: ["Content-Type": "application/vnd.apple.mpegurl"])
            }
            if request.contains("/init.mp4") {
                return .init(file: initialization, headers: ["Content-Type": "video/mp4"])
            }
            if request.contains(".m4s") {
                return .init(
                    file: segment, headers: ["Content-Type": "video/mp4"],
                    headerDelay: request.contains("/delayed.m4s") ? .seconds(20) : .zero
                )
            }
            return .init(status: 404)
        }
        addTeardownBlock { await server.stop() }
        let origin = try await server.start()
        let engine: any VideoEngine = useAether ? try PlozzigenVideoEngine() : NativeVideoEngine(startsMuted: true)
        defer { engine.stop() }
        var request = PlaybackRequest(
            item: .init(id: "paced-transcode", title: "Paced transcode", kind: .movie, runtime: 36),
            streamURL: origin.appendingPathComponent("media.m3u8"),
            playSessionID: "paced-fixture", isTranscoding: true, sourceProvider: .jellyfin
        )
        request.streamingOptions = .init(quality: .low)
        let started = ContinuousClock.now
        await engine.load(request: request, startPosition: 0)
        let player = try XCTUnwrap(engine.nowPlayingPlayer)
        player.isMuted = true
        if pauseBeforeStarting {
            engine.pause()
            engine.setPlaybackSpeed(rate)
            XCTAssertTrue(engine.isPaused)
            XCTAssertEqual(player.rate, 0)
            engine.play()
        }
        if !useAether { XCTAssertTrue(player.automaticallyWaitsToMinimizeStalling) }
        let item = try XCTUnwrap(player.currentItem)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        defer { item.remove(output) }
        var decodedFrames = 0
        let startupDeadline = started + .seconds(45)
        while ContinuousClock.now < startupDeadline, item.status != .failed {
            if player.currentTime().seconds > 0.2,
               output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil {
                decodedFrames += 1
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(decodedFrames, 0, "Require a decoded frame, not readiness or HTTP success.")
        guard decodedFrames > 0 else { return }
        XCTAssertEqual(player.rate, Float(rate))
        let firstFrame = ContinuousClock.now
        let initialPosition = player.currentTime().seconds
        let observationDeadline = firstFrame + .seconds(20)
        while ContinuousClock.now < observationDeadline, item.status != .failed {
            if output.hasNewPixelBuffer(forItemTime: player.currentTime()),
               output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil {
                decodedFrames += 1
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let advancedDuringGap = player.currentTime().seconds - initialPosition
        // Automatic buffering cannot predict an arbitrary server production gap.
        // Once all segments are available, the same player must recover unaided.
        try await Task.sleep(for: .seconds(3))
        let recoveryPosition = player.currentTime().seconds
        let recoveryDeadline = ContinuousClock.now + .seconds(5)
        var recoveryFrames = 0
        while ContinuousClock.now < recoveryDeadline, item.status != .failed {
            if output.hasNewPixelBuffer(forItemTime: player.currentTime()),
               output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil {
                recoveryFrames += 1
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let recoveredProgress = player.currentTime().seconds - recoveryPosition
        print("TRANSCODE_BUFFERING startup=\(started.duration(to: firstFrame))"
            + " gap_progress=\(advancedDuringGap) recovery_progress=\(recoveredProgress)"
            + " frames=\(decodedFrames) recovery_frames=\(recoveryFrames)")
        XCTAssertNotEqual(item.status, .failed)
        XCTAssertGreaterThan(decodedFrames, 30)
        XCTAssertGreaterThan(recoveryFrames, 20)
        XCTAssertGreaterThan(player.currentTime().seconds, 18)
        XCTAssertGreaterThan(
            recoveredProgress, 4.5 * rate,
            "Playback must recover at the selected speed after the server supplies the remaining segments."
        )
    }
}
