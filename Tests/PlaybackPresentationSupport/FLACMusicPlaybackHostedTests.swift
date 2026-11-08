import AVFoundation
import CoreModels
import CoreUI
import FeatureMusic
import MediaPlayer
import UIKit
import XCTest

@MainActor
final class FLACMusicPlaybackHostedTests: XCTestCase {
    override func setUp() async throws {
        try await waitUntil("Playback host must be active", timeout: 30) {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
    }

    func testLocalFLACStartsWithRealPlaybackProgress() async throws {
        for name in ["music-flac-16-44100", "music-flac-24-96000"] {
            let url = try fixture(name)
            let audio = try AVAudioFile(forReading: url)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: audio.processingFormat, frameCapacity: 4096
            ))
            try audio.read(into: buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData)
            XCTAssertGreaterThan((0..<Int(buffer.frameLength)).map { abs(samples[0][$0]) }.max() ?? 0, 0.01)

            let publisher = SilentPublisher()
            let controller = AudioPlaybackController(nowPlayingPublisher: publisher)
            defer { controller.stop() }
            controller.play(
                tracks: [MusicTrack(id: name, title: name)], startIndex: 0,
                resolveStreamURL: { _ in .init(url: url) }
            )
            try await waitUntil("Local FLAC must advance: \(name)") {
                self.hasStarted(publisher, trackID: name)
            }
            try await assertFLAC(publisher, sampleRate: audio.fileFormat.sampleRate)
            try await waitUntil("Local FLAC duration must load") { controller.duration > 0 }
            XCTAssertEqual(controller.duration, 8, accuracy: 0.1)
        }
    }

    func testHTTPFLACPlaysSeeksPausesAndAdvances() async throws {
        let standard = try Data(contentsOf: fixture("music-flac-16-44100"))
        let highResolution = try Data(contentsOf: fixture("music-flac-24-96000"))
        let server = try IPTVTestHTTPServer { request in
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let data = target.contains("24-96000") ? highResolution : standard
            let headers = ["Content-Type": "audio/flac", "Accept-Ranges": "bytes"]
            guard let header = request.components(separatedBy: "\r\n").first(where: {
                $0.lowercased().hasPrefix("range: bytes=")
            }) else { return .init(data: data, headers: headers) }
            let bounds = header.dropFirst("range: bytes=".count)
                .split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let first = Int(bounds[0]), first >= 0, first < data.count else {
                return .init(status: 416)
            }
            let last = min(Int(bounds[1]) ?? data.count - 1, data.count - 1)
            guard last >= first else { return .init(status: 416) }
            return .init(
                data: data, status: 206,
                headers: headers.merging(["Content-Range": "bytes \(first)-\(last)/\(data.count)"]) { _, new in new },
                range: first..<(last + 1)
            )
        }
        let base = try await server.start()
        addTeardownBlock { await server.stop() }
        var probe = URLRequest(url: base.appendingPathComponent("16-44100.flac"))
        probe.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        probe.timeoutInterval = 5
        let (signature, response) = try await URLSession.shared.data(for: probe)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(signature, Data("fLaC".utf8))
        for extensionless in [false, true] {
            let publisher = SilentPublisher()
            let controller = AudioPlaybackController(nowPlayingPublisher: publisher)
            defer { controller.stop() }
            let tracks = [
                MusicTrack(id: "16-44100", title: "Standard FLAC"),
                MusicTrack(id: "24-96000", title: "High-resolution FLAC")
            ]
            controller.play(tracks: tracks, startIndex: 0, resolveStreamURL: { track in
                let path = extensionless ? "Audio/\(track.id)/universal" : "\(track.id).flac"
                return .init(url: base.appendingPathComponent(path))
            })
            try await waitUntil("HTTP FLAC must advance; extensionless=\(extensionless)") {
                self.hasStarted(publisher, trackID: tracks[0].id)
            }
            try await assertFLAC(publisher, sampleRate: 44_100)
            try await waitUntil("HTTP FLAC duration must load") { controller.duration > 0 }
            XCTAssertEqual(controller.duration, 8, accuracy: 0.1)
            let player = try XCTUnwrap(publisher.player)
            controller.pause()
            try await Task.sleep(for: .milliseconds(300))
            let paused = player.currentTime().seconds
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(player.currentTime().seconds, paused, accuracy: 0.1)
            XCTAssertEqual(player.timeControlStatus, .paused)
            controller.resume()
            try await waitUntil("FLAC must resume") { player.currentTime().seconds > paused + 0.3 }
            await controller.seek(to: 4)
            try await waitUntil("FLAC must seek") { player.currentTime().seconds > 3.5 }
            controller.next()
            try await waitUntil("Queued high-resolution FLAC must advance") {
                controller.index == 1 && self.hasStarted(publisher, trackID: tracks[1].id)
            }
            try await assertFLAC(publisher, sampleRate: 96_000)
            try await waitUntil("Queued FLAC duration must load") { controller.duration > 0 }
            XCTAssertEqual(controller.duration, 8, accuracy: 0.1)
            controller.play(at: 0)
            try await waitUntil("FLAC must restart after a queue jump") {
                controller.index == 0 && self.hasStarted(publisher, trackID: tracks[0].id)
            }
            try await assertFLAC(publisher, sampleRate: 44_100)
            await controller.seek(to: 6.5)
            try await waitUntil("FLAC must advance naturally at the end of a track") {
                controller.index == 1 && self.hasStarted(publisher, trackID: tracks[1].id)
            }
            try await assertFLAC(publisher, sampleRate: 96_000)
        }
        let bytes = await server.bodyBytesSent
        XCTAssertGreaterThan(bytes, standard.count + highResolution.count)
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: "flac", subdirectory: "Fixtures"
        ))
    }

    private func assertFLAC(_ publisher: SilentPublisher, sampleRate: Double) async throws {
        let player = try XCTUnwrap(publisher.player)
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertEqual(item.status, .readyToPlay)
        XCTAssertGreaterThan(player.currentTime().seconds, 0.4)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(description), kAudioFormatFLAC)
        let format = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description))
        XCTAssertEqual(format.pointee.mSampleRate, sampleRate)
        XCTAssertEqual(format.pointee.mChannelsPerFrame, 2)
    }

    private func hasStarted(_ publisher: SilentPublisher, trackID: String) -> Bool {
        guard let player = publisher.player, let item = player.currentItem,
              let asset = item.asset as? AVURLAsset else { return false }
        return asset.url.path.contains(trackID) && item.status == .readyToPlay
            && player.timeControlStatus == .playing && player.currentTime().seconds > 0.5
    }

    private func waitUntil(
        _ message: String, timeout: TimeInterval = 15, predicate: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard predicate() else {
            for entry in AudioDiagnostics.shared.entries.suffix(12) {
                print("FLAC_FAILURE \(entry.time) \(entry.category) \(entry.message)")
            }
            XCTFail(message)
            throw URLError(.timedOut)
        }
    }

    private final class SilentPublisher: NowPlayingPublishing {
        private let session = NowPlayingSession()
        weak var player: AVPlayer?
        var isActive: Bool { session.isActive }

        func bind(player: AVPlayer?) {
            self.player = player
            player?.isMuted = true
            session.bind(player: player)
        }

        func activate(
            onCommand: @escaping @MainActor (NowPlayingCommand) -> Void,
            onResigned: @escaping @MainActor () -> Void
        ) {
            session.activate(onCommand: onCommand, onResigned: onResigned)
        }

        func publish(
            _ info: [String: Any], state: MPNowPlayingPlaybackState, transport: NowPlayingTransport
        ) {
            session.publish(info, state: state, transport: transport)
        }

        func invalidate() { session.invalidate() }
    }
}
