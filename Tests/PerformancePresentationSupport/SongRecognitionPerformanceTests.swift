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
        try await measureRecognition(mode: "enabled")
    }

    func testPerformanceRecognitionDisabled() async throws {
        try await measureRecognition(mode: "disabled")
    }

    func testPerformanceRecognitionTapOnly() async throws {
        try await measureRecognition(mode: "tap-only")
    }

    func testPerformanceRecognitionLifecycle() async throws {
        try await measureRecognition(mode: "lifecycle")
    }

    private func measureRecognition(mode: String) async throws {
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
        let display = SongDisplayProbe()
        display.start()
        defer { display.stop() }
        let presentation = SongRecognitionModel()
        let lifecycle = mode == "lifecycle"
        let controller = SongRecognitionController(
            install: {
                stats.install()
                let stream = engine.installSongTap()
                XCTAssertNotNil(stream, "Must exercise a supported tap, not an unavailable-route fallback.")
                return stream
            },
            remove: { engine.removeSongTap() },
            report: { song in
                presentation.heard(song)
                if song != nil { stats.confirm(at: engine.audioTapPresentationTime) }
            },
            watch: { stream, report in
                stats.beginStream()
                if mode == "tap-only" {
                    for await chunk in stream { stats.feed(chunk, playhead: nil) }
                    return .ended
                }
                return await SongRecognizer.watch(stream, makeSession: {
                    // This exact catalog was validated above; a fresh session owns each copy.
                    let session = SHSession(catalog: try! SHCustomCatalog(dataRepresentation: catalogData))
                    stats.track(session)
                    return session
                }, playbackTime: { engine.audioTapPresentationTime },
                didFeed: { stats.feed($0, playhead: $1) }, didMatch: { stats.match() }, report: report)
            }
        )
        defer { controller.stop(); presentation.heard(nil) }
        if mode != "disabled" { controller.start() }
        engine.play()
        let warmupDeadline = ContinuousClock.now + .seconds(15)
        while engine.currentTime < 8, ContinuousClock.now < warmupDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(engine.currentTime, 8)
        try await PerformanceProbe.measure(self, scenario: "song-recognition-\(mode)") {
            if lifecycle {
                controller.stop()
                try await waitForSessionRelease(stats)
                await engine.seek(to: 0)
                controller.start()
                engine.play()
            }
            let start = engine.currentTime
            let before = stats.snapshot
            let dropsBefore = engine.liveTelemetry?.droppedFrameCount
            display.reset()
            if lifecycle {
                try await Task.sleep(for: .seconds(12))
                engine.pause()
                controller.stop()
                presentation.pauseExpiry()
                try await waitForSessionRelease(stats)
                let pausedFrames = stats.snapshot.frames
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(stats.snapshot.frames, pausedFrames, "Pause must do no further recognition work.")
                presentation.resumeExpiry()
                controller.start()
                engine.play()
                try await Task.sleep(for: .seconds(12))
            } else {
                try await Task.sleep(for: .seconds(3))
            }
            let after = stats.snapshot
            let dropsAfter = engine.liveTelemetry?.droppedFrameCount
            let drops = dropsBefore.flatMap { before in dropsAfter.map { max(0, $0 - before) } }
            XCTAssertGreaterThan(engine.currentTime - start, lifecycle ? 22 : 2.3, "Recognition must not stall video playback.")
            if mode != "disabled" {
                XCTAssertGreaterThan(after.frames - before.frames, lifecycle ? 600_000 : 120_000, "Must process substantially continuous audio, not sparse samples.")
                XCTAssertLessThanOrEqual(after.maxGapMilliseconds, 250, "No unaccounted source-timeline holes.")
                if mode != "tap-only" {
                    XCTAssertLessThanOrEqual(after.maxLeadMilliseconds, 51, "Never feed decoded-ahead audio.")
                }
            } else {
                XCTAssertEqual(after.frames, 0)
            }
            if lifecycle {
                XCTAssertGreaterThan(after.confirmed, before.confirmed, "Every cycle must confirm a displayable song.")
                controller.stop()
                try await waitForSessionRelease(stats)
            }
            return [
                "audioFrames": after.frames - before.frames,
                "matches": after.matches - before.matches,
                "confirmedSongs": after.confirmed,
                "maxSourceGapMilliseconds": after.maxGapMilliseconds,
                "maxFeedLeadMilliseconds": after.maxLeadMilliseconds,
                "liveSessions": stats.liveSessions,
                "displayCallbacks": display.callbacks,
                "maxDisplayGapMilliseconds": display.maxGapMilliseconds,
                "hasDropTelemetry": drops == nil ? 0 : 1,
                "droppedFrames": drops.map { Int($0) } ?? 0,
                "windowMilliseconds": lifecycle ? 25_000 : 3000,
                "playbackMilliseconds": Int((engine.currentTime - start) * 1000)
            ]
        }
        if mode == "enabled" || lifecycle {
            XCTAssertGreaterThan(stats.snapshot.matches, 0, "The local catalog must actually recognize the synthetic cue.")
            XCTAssertGreaterThan(stats.snapshot.confirmed, 0, "A raw match must also pass production confirmation.")
            XCTAssertLessThan(stats.firstConfirmation ?? .infinity, 20, "Local recognition must produce a bounded-latency result.")
        }
        if !lifecycle { XCTAssertEqual(stats.installs, mode == "disabled" ? 0 : 1) }
        controller.stop()
        try await waitForSessionRelease(stats)
    }

    @MainActor
    private final class SongDisplayProbe: NSObject {
        private var link: CADisplayLink?
        private var previous: CFTimeInterval?
        private(set) var callbacks = 0
        private(set) var maxGapMilliseconds = 0
        func start() {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        func stop() { link?.invalidate(); link = nil }
        func reset() { previous = nil; callbacks = 0; maxGapMilliseconds = 0 }
        @objc private func tick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            if let previous { maxGapMilliseconds = max(maxGapMilliseconds, Int((now - previous) * 1000)) }
            previous = now
            callbacks += 1
        }
    }

    private func waitForSessionRelease(_ stats: SongPerformanceCounters) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while stats.liveSessions > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(stats.liveSessions, 0, "Stopped recognition must release its SHSession.")
    }
}

private final class SongPerformanceCounters: @unchecked Sendable {
    private final class SessionReference {
        weak var value: SHSession?
        init(_ value: SHSession) { self.value = value }
    }
    private let lock = NSLock()
    private var frames = 0
    private var matches = 0
    private var confirmed = 0
    private var end: Double?
    private var maxGapMilliseconds = 0
    private var maxLeadMilliseconds = 0
    private var sessions: [SessionReference] = []
    private var installationCount = 0
    private var confirmationTime: Double?
    var installs: Int { lock.withLock { installationCount } }
    var firstConfirmation: Double? { lock.withLock { confirmationTime } }
    var liveSessions: Int { lock.withLock { sessions.filter { $0.value != nil }.count } }
    var snapshot: (frames: Int, matches: Int, confirmed: Int, maxGapMilliseconds: Int, maxLeadMilliseconds: Int) {
        lock.withLock { (frames, matches, confirmed, maxGapMilliseconds, maxLeadMilliseconds) }
    }
    func install() { lock.withLock { installationCount += 1 } }
    func beginStream() { lock.withLock { end = nil } }
    func track(_ session: SHSession) {
        lock.withLock {
            sessions.removeAll { $0.value == nil }
            sessions.append(SessionReference(session))
        }
    }
    func feed(_ chunk: SongTapChunk, playhead: Double?) {
        lock.withLock {
            frames += Int(chunk.buffer.frameLength)
            if let end { maxGapMilliseconds = max(maxGapMilliseconds, Int(abs(chunk.sourceTime - end) * 1000)) }
            end = chunk.sourceTime + Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
            if let playhead, let end { maxLeadMilliseconds = max(maxLeadMilliseconds, Int((end - playhead) * 1000)) }
        }
    }
    func match() { lock.withLock { matches += 1 } }
    func confirm(at time: Double) {
        lock.withLock {
            confirmed += 1
            if confirmationTime == nil { confirmationTime = time }
        }
    }
}
