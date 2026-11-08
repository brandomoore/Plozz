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

    func testPerformanceRecognitionTapPaced() async throws {
        try await measureRecognition(mode: "tap-paced")
    }

    func testPerformanceRecognitionLifecycle() async throws {
        try await measureRecognition(mode: "lifecycle")
    }

    func testPerformanceRecognitionSoakDisabled() async throws {
        try await measureRecognition(mode: "disabled", soak: true)
    }

    func testPerformanceRecognitionSoakTapOnly() async throws {
        try await measureRecognition(mode: "tap-only", soak: true)
    }

    func testPerformanceRecognitionSoakEnabled() async throws {
        try await measureRecognition(mode: "enabled", soak: true)
    }

    private func measureRecognition(mode: String, soak: Bool = false) async throws {
        try PerformanceProbe.requireEnabled()
        let stats = SongPerformanceCounters()
        let before = try PerformanceProbe.usage().residentBytes
        var memorySnapshots: [String: [String: Int64]] = [:]
        if soak { memorySnapshots["beforePlayback"] = try PerformanceProbe.memoryUsage() }
        try await runRecognition(mode: mode, soak: soak, stats: stats) { stage in
            if soak { memorySnapshots[stage] = try PerformanceProbe.memoryUsage() }
        }
        guard soak else { return }
        let stopped = try PerformanceProbe.usage().residentBytes
        memorySnapshots["afterStop"] = try PerformanceProbe.memoryUsage()
        try await Task.sleep(for: .seconds(30))
        memorySnapshots["afterThirtySeconds"] = try PerformanceProbe.memoryUsage()
        let afterThirtySeconds = try PerformanceProbe.usage().residentBytes
        XCTAssertEqual(stats.liveSessions, 0)
        XCTAssertEqual(stats.liveEngines, 0, "Leaving playback must release the adapter, not only its tap.")
        let releasedUnusedHeapBytes = PerformanceProbe.releaseUnusedHeapForDiagnosis()
        memorySnapshots["afterHeapPressureRelief"] = try PerformanceProbe.memoryUsage()
        let data = try JSONSerialization.data(withJSONObject: [
            "mode": mode,
            "processID": Int(ProcessInfo.processInfo.processIdentifier),
            "beforePlaybackResidentBytes": before,
            "afterStopResidentBytes": stopped,
            "afterThirtySecondsResidentBytes": afterThirtySeconds,
            "liveSessions": stats.liveSessions,
            "liveWorkers": stats.liveWorkers,
            "liveEngines": stats.liveEngines,
            "memorySnapshots": memorySnapshots,
            "releasedUnusedHeapBytes": releasedUnusedHeapBytes,
        ], options: [.sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "plozz-song-memory-\(mode).json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func runRecognition(
        mode: String, soak: Bool, stats: SongPerformanceCounters,
        recordMemory: (String) throws -> Void
    ) async throws {
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
        stats.track(engine)
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
        let display = SongDisplayProbe()
        display.start()
        defer { display.stop() }
        let presentation = SongRecognitionModel()
        let lifecycle = mode == "lifecycle" || soak
        let cycles = soak ? 4 : 1
        let recognizes = mode == "enabled" || mode == "lifecycle"
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
                defer { stats.finishStream() }
                if mode == "tap-only" || mode == "tap-paced" {
                    var pacer = SongAudioPacer()
                    for await chunk in stream {
                        if Task.isCancelled { break }
                        if mode == "tap-paced" {
                            let end = chunk.sourceTime + Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
                            do {
                                guard try await pacer.wait(until: end, playbackTime: { engine.audioTapPresentationTime })
                                else { return .failed }
                            } catch is CancellationError { return .ended }
                            catch {
                                XCTFail("Paced control failed: \(error)")
                                return .failed
                            }
                        }
                        stats.feed(chunk, playhead: mode == "tap-paced" ? pacer.playhead : nil)
                    }
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
        try recordMemory("afterPlaybackWarmup")
        let scenario = "song-recognition-\(soak ? "soak-" : "")\(mode)"
        var memoryWindow = 0
        try await PerformanceProbe.measure(self, scenario: scenario) {
            let before = stats.snapshot
            var playbackMilliseconds = 0
            var droppedFrames = 0
            var hasDropTelemetry = true
            var displayCallbacks = 0
            var maxDisplayGap = 0
            for _ in 0..<cycles {
                if lifecycle {
                    controller.stop()
                    try await waitForSessionRelease(stats)
                    await engine.seek(to: 0)
                    if mode != "disabled" { controller.start() }
                    engine.play()
                }
                let start = engine.currentTime
                let cycleBefore = stats.snapshot
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
                    if mode != "disabled" { controller.start() }
                    engine.play()
                    try await Task.sleep(for: .seconds(12))
                } else {
                    try await Task.sleep(for: .seconds(3))
                }
                let after = stats.snapshot
                if let first = dropsBefore, let last = engine.liveTelemetry?.droppedFrameCount {
                    droppedFrames += Int(max(0, last - first))
                } else {
                    hasDropTelemetry = false
                }
                let progress = engine.currentTime - start
                XCTAssertGreaterThan(progress, lifecycle ? 22 : 2.3, "Recognition must not stall video playback.")
                playbackMilliseconds += Int(progress * 1000)
                displayCallbacks += display.callbacks
                maxDisplayGap = max(maxDisplayGap, display.maxGapMilliseconds)
                if mode != "disabled" {
                    XCTAssertGreaterThan(after.frames - cycleBefore.frames, lifecycle ? 600_000 : 120_000, "Must process substantially continuous audio, not sparse samples.")
                    XCTAssertLessThanOrEqual(after.maxGapMilliseconds, 250, "No unaccounted source-timeline holes.")
                    if recognizes || mode == "tap-paced" {
                        XCTAssertLessThanOrEqual(after.maxLeadMilliseconds, 51, "Never feed decoded-ahead audio.")
                    }
                } else {
                    XCTAssertEqual(after.frames, 0)
                    XCTAssertEqual(stats.installs, 0)
                }
                if lifecycle {
                    if recognizes {
                        XCTAssertGreaterThan(after.confirmed, cycleBefore.confirmed, "Every cycle must confirm a displayable song.")
                    }
                    controller.stop()
                    try await waitForSessionRelease(stats)
                }
            }
            let after = stats.snapshot
            try recordMemory("window\(memoryWindow)")
            memoryWindow += 1
            return [
                "audioFrames": after.frames - before.frames,
                "matches": after.matches - before.matches,
                "confirmedSongs": after.confirmed,
                "maxSourceGapMilliseconds": after.maxGapMilliseconds,
                "maxFeedLeadMilliseconds": after.maxLeadMilliseconds,
                "liveSessions": stats.liveSessions,
                "displayCallbacks": displayCallbacks,
                "maxDisplayGapMilliseconds": maxDisplayGap,
                "hasDropTelemetry": hasDropTelemetry ? 1 : 0,
                "droppedFrames": droppedFrames,
                "windowMilliseconds": lifecycle ? 25_000 * cycles : 3000,
                "playbackMilliseconds": playbackMilliseconds
            ]
        }
        if recognizes {
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
        while stats.liveSessions > 0 || stats.liveWorkers > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(stats.liveSessions, 0, "Stopped recognition must release its SHSession.")
        XCTAssertEqual(stats.liveWorkers, 0, "Cancellation must settle before measuring paused work.")
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
    private var workers = 0
    var liveWorkers: Int { lock.withLock { workers } }
    private var confirmationTime: Double?
    private weak var engine: PlozzigenVideoEngine?
    var liveEngines: Int { lock.withLock { engine == nil ? 0 : 1 } }
    func track(_ engine: PlozzigenVideoEngine) { lock.withLock { self.engine = engine } }
    var installs: Int { lock.withLock { installationCount } }
    var firstConfirmation: Double? { lock.withLock { confirmationTime } }
    var liveSessions: Int { lock.withLock { sessions.filter { $0.value != nil }.count } }
    var snapshot: (frames: Int, matches: Int, confirmed: Int, maxGapMilliseconds: Int, maxLeadMilliseconds: Int) {
        lock.withLock { (frames, matches, confirmed, maxGapMilliseconds, maxLeadMilliseconds) }
    }
    func install() { lock.withLock { installationCount += 1 } }
    func beginStream() { lock.withLock { end = nil; workers += 1 } }
    func finishStream() { lock.withLock { workers -= 1 } }
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
