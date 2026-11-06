import AVFoundation
@testable import FeaturePlayback
import ShazamKit
import XCTest

@MainActor
final class SongRecognitionLifecycleTests: XCTestCase {
    func testPauseResumePreservesRemainingExpiryWithoutNeedingAMatchResult() async throws {
        let sleeps = ExpirySleeps()
        defer { Task { await sleeps.finishAll() } }
        var now = 100.0
        let model = SongRecognitionModel(now: { now }, sleep: { await sleeps.wait($0) })
        let song = SongMatch(title: "Current", artist: nil, artworkURL: nil, appleMusicURL: nil)
        model.heard(song)
        await sleeps.waitForCount(1)
        now = 110
        model.pauseExpiry()
        now = 1010
        XCTAssertEqual(model.state, .found(song))
        model.resumeExpiry()
        await sleeps.waitForCount(2)
        let durations = await sleeps.durations
        XCTAssertEqual(durations, [.seconds(25), .seconds(15)])
        await sleeps.finishFirst()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.state, .found(song), "The cancelled pre-pause timer cannot erase the resumed card.")
        await sleeps.finishFirst()
        try await waitUntil { model.state == .idle }
    }

    func testRepeatedHearingRenewsExpiryAndOldTimerCannotClearIt() async throws {
        let sleeps = ExpirySleeps()
        defer { Task { await sleeps.finishAll() } }
        var now = 100.0
        let model = SongRecognitionModel(now: { now }, sleep: { await sleeps.wait($0) })
        let song = SongMatch(title: "Current", artist: nil, artworkURL: nil, appleMusicURL: nil)
        model.heard(song)
        await sleeps.waitForCount(1)
        now += 20
        model.heard(song)
        await sleeps.waitForCount(2)
        let durations = await sleeps.durations
        XCTAssertEqual(durations, [.seconds(25), .seconds(25)])
        await sleeps.finishFirst()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.state, .found(song))
        model.heard(nil)
        await sleeps.finishFirst()
        XCTAssertEqual(model.state, .idle)
    }

    func testAudioPacerWaitsForSourcePlayheadNotElapsedWallTime() async throws {
        var playhead = 0.0
        var finished = false
        let task = Task {
            var pacer = SongAudioPacer()
            let result = try await pacer.wait(until: 10, playbackTime: { playhead })
            finished = true
            return result
        }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(finished, "A stationary clock must not admit decoded-ahead audio.")
        playhead = 9.8
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(finished)
        playhead = 10
        let result = try await task.value
        XCTAssertTrue(result, "Any playback rate is governed by actual source progress, not a guessed delay.")
    }

    func testAudioPacerCancellationDoesNotWaitForPlayback() async throws {
        let task = Task {
            var pacer = SongAudioPacer()
            return try await pacer.wait(until: 100, playbackTime: { 0 })
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Pacing must propagate cancellation.")
        } catch is CancellationError {}
    }

    func testAudioPacerRejectsInvalidClock() async throws {
        var pacer = SongAudioPacer()
        let result = try await pacer.wait(until: 1, playbackTime: { .nan })
        XCTAssertFalse(result)
    }

    func testStopReleasesTapBeforeCancelledWorkerFinishes() async throws {
        let probe = TapProbe()
        let gate = WatchGate()
        let controller = SongRecognitionController(
            install: { probe.install() }, remove: { probe.remove() },
            report: { probe.values.append($0) },
            watch: { _, report in await gate.wait(report: report) }
        )
        controller.start()
        try await waitUntil { probe.installs == 1 }
        await gate.waitForCount(1)
        controller.stop()
        XCTAssertFalse(probe.active)
        controller.start()
        try await waitUntil { probe.installs == 2 }
        await gate.waitForCount(2)
        let removals = probe.removals
        await gate.finishFirst(with: SongMatch(title: "Stale", artist: nil, artworkURL: nil, appleMusicURL: nil))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(probe.active, "Old cancellation must not remove the replacement tap.")
        XCTAssertEqual(probe.removals, removals)
        XCTAssertTrue(probe.values.isEmpty, "Late old-session matches must not enter the new playback.")
        controller.stop()
        await gate.finishFirst(with: nil)
    }

    private actor ExpirySleeps {
        var durations: [Duration] = []
        private var continuations: [CheckedContinuation<Void, Never>] = []
        func wait(_ duration: Duration) async {
            durations.append(duration)
            await withCheckedContinuation { continuations.append($0) }
        }
        func waitForCount(_ count: Int) async {
            let deadline = ContinuousClock.now + .seconds(2)
            while durations.count < count, ContinuousClock.now < deadline { await Task.yield() }
        }
        func finishFirst() {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume()
        }
        func finishAll() {
            while !continuations.isEmpty { finishFirst() }
        }
    }

    func testErrorCooldownRemovesTapAndCanBeCancelled() async throws {
        let probe = TapProbe()
        let sleep = SleepProbe()
        let controller = SongRecognitionController(
            install: { probe.install() }, remove: { probe.remove() }, report: { probe.values.append($0) },
            watch: { _, _ in .failed },
            sleep: { duration in try await sleep.wait(duration) }
        )
        controller.start()
        try await waitUntil { probe.removals == 1 }
        let deadline = ContinuousClock.now + .seconds(2)
        while await sleep.durations.isEmpty, ContinuousClock.now < deadline {
            await Task.yield()
        }
        let durations = await sleep.durations
        XCTAssertEqual(durations, [.seconds(30)])
        XCTAssertFalse(probe.active, "Cooldown must stop decode, not merely discard its output.")
        controller.stop()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(probe.installs, 1)
    }

    func testUnavailableTapRetriesAreBounded() async throws {
        let probe = TapProbe()
        let controller = SongRecognitionController(
            install: { probe.installs += 1; return nil }, remove: { probe.remove() },
            report: { _ in }, sleep: { _ in }
        )
        controller.start()
        try await waitUntil { probe.installs == 3 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(probe.installs, 3)
        controller.stop()
    }

    func testDiscontinuityStopsRatherThanStitchingUnrelatedAudio() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 4800)
        let stream = AsyncStream<SongTapChunk> {
            $0.yield(.init(buffer: buffer, sourceTime: 0, discontinuity: true))
            $0.yield(.init(buffer: buffer, sourceTime: 10, discontinuity: true))
            $0.finish()
        }
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
        let audio = try AVAudioFile(forReading: folder.appendingPathComponent("song-performance.m4a"))
        let reference = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)
        ))
        try audio.read(into: reference)
        let generator = SHSignatureGenerator()
        try generator.append(reference, at: nil)
        let catalog = SHCustomCatalog()
        try catalog.addReferenceSignature(generator.signature(), representing: [
            SHMediaItem(properties: [.title: "Synthetic fixture", .genres: ["Music"]])
        ])
        let data = catalog.dataRepresentation
        let reason = await SongRecognizer.watch(stream, makeSession: {
            SHSession(catalog: try! SHCustomCatalog(dataRepresentation: data))
        }) { _ in }
        XCTAssertEqual(reason, .discontinuity)
    }

    func testReleasingOwnerCancelsAndRemovesTap() async throws {
        let probe = TapProbe()
        var controller: SongRecognitionController? = SongRecognitionController(
            install: { probe.install() }, remove: { probe.remove() }, report: { _ in },
            watch: { stream, _ in
                for await _ in stream {}
                return .ended
            }
        )
        weak var owner = controller
        controller?.start()
        try await waitUntil { probe.active }
        controller = nil
        XCTAssertNil(owner)
        try await waitUntil { !probe.active }
    }

    func testRepeatedStartDoesNotDuplicateAudioWorkers() async throws {
        let probe = TapProbe()
        let controller = SongRecognitionController(
            install: { probe.install() }, remove: { probe.remove() }, report: { _ in },
            watch: { stream, _ in
                for await _ in stream {}
                return .ended
            }
        )
        controller.start()
        controller.start()
        try await waitUntil { probe.installs == 1 }
        XCTAssertEqual(probe.installs, 1)
        controller.stop()
        XCTAssertFalse(probe.active)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate())
    }
}

@MainActor
private final class TapProbe {
    var installs = 0
    var removals = 0
    var active = false
    var values: [SongMatch?] = []
    private var continuation: AsyncStream<SongTapChunk>.Continuation?
    func install() -> AsyncStream<SongTapChunk> {
        installs += 1
        active = true
        return AsyncStream { continuation = $0 }
    }
    func remove() {
        removals += 1
        active = false
        continuation?.finish()
        continuation = nil
    }
}

private actor SleepProbe {
    var durations: [Duration] = []
    func wait(_ duration: Duration) async throws {
        durations.append(duration)
        try await Task.sleep(for: .seconds(60))
    }
}

private actor WatchGate {
    private var continuations: [(SongRecognitionController.Report, CheckedContinuation<SongRecognizer.StopReason, Never>)] = []
    func wait(report: @escaping SongRecognitionController.Report) async -> SongRecognizer.StopReason {
        await withCheckedContinuation { continuations.append((report, $0)) }
    }
    func waitForCount(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while continuations.count < count, ContinuousClock.now < deadline { await Task.yield() }
    }
    func finishFirst(with song: SongMatch?) async {
        guard !continuations.isEmpty else { return }
        let (report, continuation) = continuations.removeFirst()
        await report(song)
        continuation.resume(returning: .ended)
    }
}
