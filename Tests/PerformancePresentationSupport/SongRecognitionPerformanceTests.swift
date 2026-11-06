import AVFoundation
import CoreModels
@testable import EnginePlozzigen
@testable import FeaturePlayback
import ShazamKit
import UIKit
import XCTest

@MainActor
final class SongRecognitionPerformanceTests: XCTestCase {
    func testPerformanceRecognitionEnabled() async throws {
        try await measureRecognition(enabled: true)
    }

    func testPerformanceRecognitionDisabled() async throws {
        try await measureRecognition(enabled: false)
    }

    private func measureRecognition(enabled: Bool) async throws {
        try PerformanceProbe.requireEnabled()
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        let audio = try AVAudioFile(forReading: folder.appendingPathComponent("song-performance.m4a"))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)
        ))
        try audio.read(into: buffer)
        let generator = SHSignatureGenerator()
        try generator.append(buffer, at: nil)
        let catalog = SHCustomCatalog()
        try catalog.addReferenceSignature(generator.signature(), representing: [
            SHMediaItem(properties: [.title: "Performance cue", .artist: "Synthetic fixture", .genres: ["Music"]])
        ])
        let catalogData = catalog.dataRepresentation
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let engine = try PlozzigenVideoEngine()
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        let surface = engine.makeVideoOutputView()
        surface.frame = window.bounds
        host.view.addSubview(surface)
        defer {
            engine.removeSongTap()
            engine.stop()
            surface.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        await engine.load(request: PlaybackRequest(
            item: MediaItem(id: "song-performance", title: "Synthetic performance video", kind: .movie, runtime: 35),
            streamURL: folder.appendingPathComponent("song-performance.mkv")
        ), startPosition: 0)
        let deadline = ContinuousClock.now + .seconds(30)
        while !engine.hasPresentedVideoFrame, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(engine.hasPresentedVideoFrame)
        let stats = SongPerformanceCounters()
        var watcher: Task<Void, Never>?
        if enabled {
            let stream = try XCTUnwrap(engine.installSongTap(), "Must exercise a supported audio tap, not an unavailable-route fallback.")
            watcher = Task {
                await SongRecognizer.watch(stream, makeSession: {
                    // This exact catalog was validated above; a fresh session owns each copy.
                    SHSession(catalog: try! SHCustomCatalog(dataRepresentation: catalogData))
                }, didFeed: { stats.add(frames: $0) }, didMatch: { stats.match() }) { _ in }
            }
        }
        defer { watcher?.cancel() }
        engine.play()
        try await Task.sleep(for: .seconds(2))
        try await PerformanceProbe.measure(self, scenario: "song-recognition-\(enabled ? "enabled" : "disabled")") {
            let start = engine.currentTime
            let before = stats.snapshot
            try await Task.sleep(for: .seconds(3))
            let after = stats.snapshot
            XCTAssertGreaterThan(engine.currentTime - start, 2.3, "Recognition must not stall video playback.")
            if enabled {
                XCTAssertGreaterThan(after.frames - before.frames, 48_000, "Must process fresh audio, not an idle matcher.")
            } else {
                XCTAssertEqual(after.frames, 0)
            }
            return [
                "audioFrames": after.frames - before.frames,
                "matches": after.matches - before.matches,
                "windowMilliseconds": 3000,
                "playbackMilliseconds": Int((engine.currentTime - start) * 1000)
            ]
        }
        if enabled {
            XCTAssertGreaterThan(stats.snapshot.matches, 0, "The local catalog must actually recognize the synthetic cue.")
        }
        watcher?.cancel()
        await watcher?.value
    }
}

private final class SongPerformanceCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var matches = 0
    var snapshot: (frames: Int, matches: Int) { lock.withLock { (frames, matches) } }
    func add(frames count: Int) { lock.withLock { frames += count } }
    func match() { lock.withLock { matches += 1 } }
}
