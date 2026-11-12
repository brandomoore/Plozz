import AVFoundation
import CoreModels
import CoreUI
import FeatureMusic
import MediaPlayer
import XCTest

@MainActor
final class MusicTransportTransitionTests: XCTestCase {
    func testSelectionRetiresOldAudioAndProgressBeforeResolution() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.start()
        let oldPlayer = try XCTUnwrap(fixture.publisher.player)
        await oldPlayer.seek(to: CMTime(seconds: 8, preferredTimescale: 600))
        try await waitUntil { fixture.controller.currentTime > 7 }
        let outgoingPosition = fixture.controller.currentTime
        fixture.holdResolution = true
        fixture.controller.play(at: 2)
        XCTAssertEqual(oldPlayer.rate, 0, "A selection must stop the old song synchronously")
        XCTAssertEqual(fixture.controller.currentTime, 0)
        XCTAssertEqual(fixture.controller.duration, 30)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(fixture.controller.currentTime, 0, "Old item callbacks cannot repopulate the scrubber")
        XCTAssertEqual(oldPlayer.rate, 0)
        XCTAssertTrue(fixture.controller.isBuffering)
        try await waitUntil { fixture.stops.count == 1 }
        XCTAssertEqual(fixture.stops.first ?? -1, outgoingPosition, accuracy: 0.3)
        fixture.controller.previous()
        XCTAssertEqual(fixture.controller.index, 1, "Previous must use the new selection, not the outgoing clock")
        fixture.controller.pause()
        fixture.release()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(fixture.controller.isPlaying)
        XCTAssertEqual(oldPlayer.rate, 0, "Cancelled resolution must not restart audio")
        fixture.controller.resume()
        try await waitUntil {
            fixture.controller.index == 1 && fixture.controller.isPlaying && !fixture.controller.isBuffering
                && fixture.controller.currentTime > 0.2
        }
    }

    func testNewQueueAndFailedResolutionNeverLeaveOldProgressOrAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.start()
        let player = try XCTUnwrap(fixture.publisher.player)
        fixture.controller.play(
            tracks: [MusicTrack(id: "unavailable", title: "Unavailable", duration: 123)], startIndex: 0,
            resolveStreamURL: { _ in nil }
        )
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(fixture.controller.currentTime, 0)
        XCTAssertEqual(fixture.controller.duration, 123)
        try await waitUntil { fixture.controller.playbackFailed }
        XCTAssertFalse(fixture.controller.isPlaying)
        XCTAssertEqual(fixture.controller.currentTime, 0)
        XCTAssertEqual(fixture.stops.count, 1)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard predicate() else {
            XCTFail("Music transport did not reach its expected state")
            throw URLError(.timedOut)
        }
    }

    @MainActor private final class Fixture {
        let publisher = Publisher()
        let controller: AudioPlaybackController
        let file: URL
        var holdResolution = false
        var pending: [CheckedContinuation<Void, Never>] = []
        var stops: [Double] = []

        init() throws {
            controller = AudioPlaybackController(nowPlayingPublisher: publisher)
            file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_323_000))
            buffer.frameLength = buffer.frameCapacity
            try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0, count: Int(buffer.frameLength))
            let audio = try AVAudioFile(forWriting: file, settings: format.settings)
            try audio.write(from: buffer)
        }

        func start() async throws {
            controller.play(
                tracks: (0..<3).map { MusicTrack(id: "track-\($0)", title: "Track", duration: 30) },
                startIndex: 0,
                resolveStreamURL: { [weak self] _ in
                    guard let self else { return nil }
                    if self.holdResolution {
                        await withCheckedContinuation { self.pending.append($0) }
                    }
                    guard !Task.isCancelled else { return nil }
                    return .init(url: self.file)
                },
                reportPlayback: { [weak self] _, event, position, _ in
                    if event == .stop { self?.stops.append(position) }
                }
            )
            let deadline = ContinuousClock.now + .seconds(10)
            while (controller.currentTime < 0.3 || controller.isBuffering), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertGreaterThan(controller.currentTime, 0.2)
            XCTAssertFalse(controller.isBuffering)
        }

        func release() {
            holdResolution = false
            let waiters = pending
            pending = []
            waiters.forEach { $0.resume() }
        }

        func close() {
            controller.stop()
            release()
            do { try FileManager.default.removeItem(at: file) }
            catch { XCTFail("Could not remove owned audio fixture") }
        }
    }

    @MainActor private final class Publisher: NowPlayingPublishing {
        weak var player: AVPlayer?
        var isActive = false
        func bind(player: AVPlayer?) { self.player = player; player?.isMuted = true }
        func activate(onCommand: @escaping @MainActor (NowPlayingCommand) -> Void,
                      onResigned: @escaping @MainActor () -> Void) { isActive = true }
        func publish(_ info: [String: Any], state: MPNowPlayingPlaybackState,
                     transport: NowPlayingTransport) {}
        func invalidate() { isActive = false }
    }
}
