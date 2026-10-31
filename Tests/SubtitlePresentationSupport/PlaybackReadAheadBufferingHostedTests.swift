import AVFoundation
import CoreModels
import EnginePlozzigen
import FeaturePlayback
import UIKit
import XCTest

@MainActor
final class PlaybackReadAheadBufferingHostedTests: XCTestCase {
    func testLargerReadAheadCarriesPlaybackThroughASourceOutageThatExhaustsAutomatic() async throws {
        let url = try await makeVideo()
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(size, 80 * 1_024 * 1_024, "Do not let a transport window cache the whole fixture.")
        let automatic = try await exercise(url: url, size: size, preference: .automatic)
        let larger = try await exercise(url: url, size: size, preference: .fiveMinutes)
        XCTAssertGreaterThan(automatic.longestFreeze, 8, "The baseline must actually exhaust its buffer.")
        XCTAssertLessThan(larger.longestFreeze, 3, "The larger buffer must cover the same source outage.")
        XCTAssertGreaterThan(larger.changedFrames, automatic.changedFrames + 80)
        // tvOS software buffering keeps its independent 96 MiB forward cap.
        // Require enough source data for the 90 media-second outage (half this
        // uniform fixture), not an extra 80 MiB beyond the automatic buffer.
        XCTAssertGreaterThan(larger.sourceBytes, size / 2)
        XCTAssertGreaterThan(larger.sourceBytes, automatic.sourceBytes)
        XCTAssertLessThan(larger.startupSeconds, 15, "A larger target must not become a startup fill requirement.")
    }

    private struct Result {
        let sourceBytes: Int
        let startupSeconds: Double
        let changedFrames: Int
        let longestFreeze: Double
    }

    private func exercise(url: URL, size: Int, preference: PlaybackReadAhead) async throws -> Result {
        let gate = SourceGate()
        let server = try IPTVTestHTTPServer(beforeBodyChunk: { try await gate.wait() }) { request in
            Self.response(for: request, file: url, size: size)
        }
        addTeardownBlock { await server.stop() }
        let origin = try await server.start()
        let sceneDeadline = ContinuousClock.now + .seconds(10)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < sceneDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let engine = try PlozzigenVideoEngine(readAheadPreference: { preference })
        let video = engine.makeVideoOutputView()
        video.frame = window.bounds
        controller.view.addSubview(video)
        window.makeKeyAndVisible()
        defer {
            engine.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        engine.configureLiveOutput(.init(isAudible: false, suppressesDisplayMatching: true))
        let start = ContinuousClock.now
        await engine.load(
            request: PlaybackRequest(
                item: MediaItem(id: "read-ahead", title: "Buffer fixture", kind: .movie, runtime: 180),
                streamURL: origin.appendingPathComponent("source.mp4")
            ), startPosition: 0
        )
        let startupDeadline = start + .seconds(30)
        while !engine.liveSnapshot.firstFrameReady, ContinuousClock.now < startupDeadline {
            try check(engine)
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(engine.liveSnapshot.firstFrameReady)
        guard engine.liveSnapshot.firstFrameReady else { throw FixtureError.startup }
        let startup = seconds(start.duration(to: .now))
        let frames = try FrameProbe(view: video)
        defer { frames.close() }
        // Both runs get the same opportunity to fill while playback continues.
        try await Task.sleep(for: .seconds(10))
        switch engine.liveSnapshot.route {
        case .localHLS:
            let cache = try XCTUnwrap(engine.liveTelemetry?.sessionCache)
            XCTAssertGreaterThan(cache.residentBytes, 0)
            XCTAssertGreaterThan(cache.effectiveBudgetBytes, 0)
        case .software:
            let cache = try XCTUnwrap(engine.liveTelemetry?.sessionCache)
            XCTAssertGreaterThan(cache.residentBytes, 0)
            XCTAssertEqual(cache.effectiveBudgetBytes, 96 * 1_024 * 1_024)
            XCTAssertEqual(cache.targetSeconds, preference == .automatic ? 40 : 300)
        default:
            XCTFail("This fixture must exercise an engine-owned buffer.")
        }
        let headroom = engine.bufferedPosition - engine.currentTime
        await gate.pause()
        try await Task.sleep(for: .milliseconds(250))
        let bytesBeforeOutage = await server.bodyBytesSent
        let before = engine.currentTime
        engine.setPlaybackSpeed(2)
        var fingerprint = frames.fingerprint()
        var lastFrame = ContinuousClock.now
        var longestFreeze = 0.0
        var changedFrames = 0
        let outageDeadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < outageDeadline {
            try check(engine)
            if let next = frames.fingerprint(), next != fingerprint {
                changedFrames += 1
                fingerprint = next
                lastFrame = .now
            }
            longestFreeze = max(longestFreeze, seconds(lastFrame.duration(to: .now)))
            try await Task.sleep(for: .milliseconds(100))
        }
        let progress = engine.currentTime - before
        let bytesAfterOutage = await server.bodyBytesSent
        XCTAssertEqual(bytesAfterOutage, bytesBeforeOutage, "No source bytes may arrive during the outage.")
        await gate.resume()
        let frozenFrame = fingerprint
        let recoveryDeadline = ContinuousClock.now + .seconds(15)
        var recovered = false
        while !recovered, ContinuousClock.now < recoveryDeadline {
            try check(engine)
            if let next = frames.fingerprint(), next != frozenFrame { recovered = true }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(recovered, "Require a new decoded frame after supply resumes, not just a running clock.")
        await gate.pause()
        engine.stop()
        await engine.drainTransport()
        XCTAssertNil(engine.liveTelemetry?.sessionCache, "Stopped sessions must not retain active cache usage.")
        let stopDeadline = ContinuousClock.now + .seconds(5)
        while await server.activeRequestCount > 0, ContinuousClock.now < stopDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let activeRequests = await server.activeRequestCount
        XCTAssertEqual(activeRequests, 0, "The player must cancel reads before the fixture server stops.")
        let finalBytes = await server.bodyBytesSent
        await gate.resume()
        try await Task.sleep(for: .milliseconds(250))
        let stoppedBytes = await server.bodyBytesSent
        XCTAssertEqual(stoppedBytes, finalBytes, "Stopping must cancel outstanding reads.")
        await server.stop()
        print("READ_AHEAD preset=\(preference.rawValue) size=\(size) startup=\(startup)"
            + " headroom=\(headroom) outage_progress=\(progress) source_bytes=\(bytesBeforeOutage)"
            + " changed_frames=\(changedFrames) longest_freeze=\(longestFreeze)")
        return Result(
            sourceBytes: bytesBeforeOutage, startupSeconds: startup,
            changedFrames: changedFrames, longestFreeze: longestFreeze
        )
    }

    private func check(_ engine: PlozzigenVideoEngine) throws {
        if case .failed(let error) = engine.status { throw error }
    }

    private nonisolated static func response(
        for request: String, file: URL, size: Int
    ) -> IPTVTestHTTPServer.Response {
        let header = request.components(separatedBy: "\r\n").first {
            $0.lowercased().hasPrefix("range: bytes=")
        }
        guard let header else {
            return .init(file: file, headers: ["Content-Type": "video/mp4", "Accept-Ranges": "bytes"])
        }
        let bounds = header.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let first = Int(bounds[0]), first >= 0, first < size else { return .init(status: 416) }
        let last = min(Int(bounds[1]) ?? (size - 1), size - 1)
        guard last >= first else { return .init(status: 416) }
        return .init(
            file: file, status: 206,
            headers: ["Content-Type": "video/mp4", "Accept-Ranges": "bytes",
                      "Content-Range": "bytes \(first)-\(last)/\(size)"],
            range: first..<(last + 1)
        )
    }

    private func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("read-ahead-\(UUID()).mp4")
        let clip = url.deletingPathExtension().appendingPathExtension("clip.mp4")
        let writer = try AVAssetWriter(outputURL: clip, fileType: .mp4)
        var finished = false
        defer {
            if !finished {
                writer.cancelWriting()
            }
            for path in [clip] + (finished ? [] : [url]) where FileManager.default.fileExists(atPath: path.path) {
                do { try FileManager.default.removeItem(at: path) }
                catch { XCTFail("Could not remove read-ahead fixture: \(error)") }
            }
        }
        let width = 640, height = 360, fps = 15
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoExpectedSourceFrameRateKey: fps
            ]
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adapter.pixelBufferPool)
        let deadline = ContinuousClock.now + .seconds(120)
        for frame in 0..<(12 * fps) {
            while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard input.isReadyForMoreMediaData, ContinuousClock.now < deadline else {
                throw writer.error ?? FixtureError.encoding
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else {
                throw FixtureError.encoding
            }
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
            let words = address.bindMemory(to: UInt32.self, capacity: CVPixelBufferGetBytesPerRow(pixel) * height / 4)
            var noise = UInt32(frame + 1)
            for index in 0..<(CVPixelBufferGetBytesPerRow(pixel) * height / 4) {
                noise ^= noise << 13
                noise ^= noise >> 17
                noise ^= noise << 5
                words[index] = noise | 0xff00_0000
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adapter.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else {
                throw writer.error ?? FixtureError.encoding
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 12, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw try XCTUnwrap(writer.error) }
        let audioURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "embedded", withExtension: "mp4", subdirectory: "Fixtures"
        ))
        let videoAsset = AVURLAsset(url: clip)
        let audioAsset = AVURLAsset(url: audioURL)
        defer { withExtendedLifetime((videoAsset, audioAsset)) {} }
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let composition = AVMutableComposition()
        let video = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let audio = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let duration = CMTime(seconds: 12, preferredTimescale: 600)
        for index in 0..<15 {
            let at = CMTime(seconds: Double(index * 12), preferredTimescale: 600)
            try video.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: at)
            try audio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: at)
        }
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await exporter.export(to: url, as: .mp4)
        finished = true
        return url
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    @MainActor
    private final class FrameProbe {
        private let sampleLayer: AVSampleBufferDisplayLayer?
        private let player: AVPlayer?
        private let output: AVPlayerItemVideoOutput?

        init(view: UIView) throws {
            let layers = Self.layers(in: view.layer)
            sampleLayer = layers.compactMap { $0 as? AVSampleBufferDisplayLayer }.first
            player = layers.compactMap { ($0 as? AVPlayerLayer)?.player }.first
            if let player {
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                try XCTUnwrap(player.currentItem).add(output)
                self.output = output
            } else {
                output = nil
                _ = try XCTUnwrap(sampleLayer, "Require a real render surface.")
            }
        }

        func close() {
            if let output { player?.currentItem?.remove(output) }
        }

        func fingerprint() -> UInt64? {
            let pixel: CVPixelBuffer?
            if let player, let output {
                pixel = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil)
            } else {
                pixel = sampleLayer?.sampleBufferRenderer.displayedPixelBuffer()
            }
            guard let pixel else { return nil }
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            let planar = CVPixelBufferIsPlanar(pixel)
            let address = planar ? CVPixelBufferGetBaseAddressOfPlane(pixel, 0) : CVPixelBufferGetBaseAddress(pixel)
            let length = planar
                ? CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) * CVPixelBufferGetHeightOfPlane(pixel, 0)
                : CVPixelBufferGetBytesPerRow(pixel) * CVPixelBufferGetHeight(pixel)
            guard let address, length > 0 else { return nil }
            let bytes = address.assumingMemoryBound(to: UInt8.self)
            return stride(from: 0, to: length, by: max(1, length / 256)).reduce(UInt64(0)) {
                ($0 &* 31) &+ UInt64(bytes[$1])
            }
        }

        private static func layers(in root: CALayer) -> [CALayer] {
            [root] + (root.sublayers ?? []).flatMap { layers(in: $0) }
        }
    }

    private enum FixtureError: Error { case encoding, startup }
}

private actor SourceGate {
    private var paused = false
    func pause() { paused = true }
    func resume() { paused = false }
    func wait() async throws {
        while paused {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
