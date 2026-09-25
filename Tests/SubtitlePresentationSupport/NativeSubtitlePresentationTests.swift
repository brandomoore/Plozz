import AVFoundation
import CoreModels
import EnginePlozzigen
import Network
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class NativeSubtitlePresentationTests: XCTestCase {
    func testEngineMetricsAreJournaledWithoutOpeningPlaybackInfo() async throws {
        let tracing = HandoffDiagnostics.isEnabled
        HandoffDiagnostics.setEnabled(true)
        defer { HandoffDiagnostics.setEnabled(tracing) }
        let previous = Set(HandoffDiagnostics.persistentPlaybackLogText().components(separatedBy: .newlines))
        let engine = try PlozzigenVideoEngine()
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        let model = LiveSubtitleModel()
        let window = try await mount(engine, subtitles: model)
        defer { engine.stop(); window.isHidden = true; window.rootViewController = nil }
        await engine.load(request: request(try fixtureURL("embedded.mp4"), tracks: []), startPosition: 0)
        let route = engine.liveSnapshot.route == .software ? "software" : "loopback"
        var line: String?
        try await waitUntil(timeout: 30) {
            line = HandoffDiagnostics.persistentPlaybackLogText().components(separatedBy: .newlines).last {
                !previous.contains($0) && $0.contains("playback PIPELINE") && $0.contains("route=\(route)")
            }
            return line != nil
        }
        let captured = try XCTUnwrap(line)
        XCTAssertTrue(captured.contains("sourceBytes="))
        XCTAssertTrue(captured.contains("muxBytes="))
        XCTAssertTrue(captured.contains("servedBytes="))
        XCTAssertTrue(captured.contains("audioID="))
        XCTAssertTrue(captured.contains("audioCodec=aac"))
    }

    func testPlozzigenVODReloadPreservesPauseAndDiagnosticsFollowTheNewItem() async throws {
        let server = try SubtitleFixtureServer(directory: fixtureDirectory())
        let port = try await server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/master.m3u8"))
        let engine = try PlozzigenVideoEngine()
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        let model = LiveSubtitleModel()
        let window = try await mount(engine, subtitles: model)
        let sampler = PlaybackDiagnosticsSampler()
        defer { sampler.stop(); engine.stop(); window.isHidden = true; window.rootViewController = nil }
        await engine.load(request: request(url, tracks: []), startPosition: 0)
        try await waitUntil(timeout: 30) { engine.isPlaybackPositionReady }
        engine.pause()
        await engine.seek(to: 2.5)
        let previous = try XCTUnwrap(engine.nowPlayingPlayer?.currentItem)
        sampler.start(
            player: nil, playerProvider: { [weak engine] in engine?.nowPlayingPlayer },
            mode: .plozzigen, engineTelemetry: { [weak engine] in engine?.liveTelemetry },
            includesSystemMetrics: false
        )
        sampler.sampleTick()
        XCTAssertNotNil(sampler.latest?.bufferedSecondsAhead)
        XCTAssertNotNil(sampler.latest?.playbackState)
        XCTAssertNil(sampler.latest?.observedBitrate, "A loopback access log is not server-network throughput")
        try await engine.reloadAfterForeground()
        try await waitUntil(timeout: 30) { engine.isPlaybackPositionReady }
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(engine.currentTime, 2.5, accuracy: 0.15)
        XCTAssertFalse(engine.nowPlayingPlayer?.currentItem === previous)
        sampler.sampleTick()
        XCTAssertEqual(try XCTUnwrap(sampler.latest?.positionSeconds), engine.nowPlayingPlayer?.currentTime().seconds ?? -1,
                       accuracy: 0.05)
        XCTAssertNotNil(sampler.latest?.bufferedSecondsAhead)
    }

    func testEmbeddedMP4CaptionsUseTheOwnedOverlayAcrossPauseAndBackwardSeek() async throws {
        let url = try fixtureURL("embedded.mp4")
        let engine = NativeVideoEngine(startsMuted: true)
        let model = LiveSubtitleModel()
        model.beginLiveFeed(permitsTimingOffsets: false)
        var cues: [SubtitleCue] = []
        engine.onSubtitleCues = { cues = $0; model.updateLiveCues($0) }
        let window = try await mount(engine, subtitles: model)
        defer { engine.stop(); window.isHidden = true }
        let track = MediaTrack(id: 2, kind: .subtitle, displayTitle: "English", language: "en", codec: "mov_text")
        await engine.load(request: request(url, tracks: [track]), startPosition: 0)
        try await waitUntil(timeout: 30) { engine.underlyingPlayer?.currentItem?.status == .readyToPlay }
        engine.selectSubtitleTrack(track)
        try await waitUntil { cues.contains { $0.text == "Repeated" && $0.start == 9 } }
        engine.pause()
        XCTAssertEqual(cues.active(at: 1.5).compactMap(\.text), ["Alpha"])
        XCTAssertEqual(cues.active(at: 2.5).compactMap(\.text), ["Bravo"])
        XCTAssertTrue(cues.active(at: 4).isEmpty)
        try assertOnlySuppressedOutput(engine)

        await engine.seek(to: 6.5)
        try await waitUntil {
            return model.primary.map(\.text) == ["Repeated"]
        }
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(engine.underlyingPlayer?.rate, 0)
        XCTAssertEqual(engine.currentTime, 6.5, accuracy: 1.0 / 24)
        await engine.seek(to: 0)
        try await waitUntil {
            return model.primary.isEmpty
        }
        engine.play()
        try await waitUntil {
            return model.primary.map(\.text) == ["Alpha"]
        }
        XCTAssertLessThanOrEqual(engine.subtitlePresentationTime, 1 + 1.0 / 24 + 0.02)
        engine.selectSubtitleTrack(nil)
        try await waitUntil { cues.isEmpty }
    }

    func testNativeHLSOverlapsSameLanguageSwitchingPresentationStatesAndClearing() async throws {
        let server = try SubtitleFixtureServer(directory: fixtureDirectory())
        let port = try await server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/master.m3u8"))
        let engine = NativeVideoEngine(startsMuted: true)
        let model = LiveSubtitleModel()
        model.beginLiveFeed(permitsTimingOffsets: false)
        var cues: [SubtitleCue] = []
        engine.onSubtitleCues = { cues = $0; model.updateLiveCues($0) }
        let window = try await mount(engine, subtitles: model, liveClock: true)
        defer { engine.stop(); window.isHidden = true }
        let full = MediaTrack(id: 2, kind: .subtitle, displayTitle: "Full", language: "en", codec: "webvtt")
        let alternate = MediaTrack(id: 3, kind: .subtitle, displayTitle: "Alternate", language: "en", codec: "webvtt")
        var playback = request(url, tracks: [full, alternate])
        playback.isTranscoding = true
        playback.streamingOptions = .init(quality: .hd720)
        await engine.load(request: playback, startPosition: 0)
        engine.selectSubtitleTrack(full)
        try await waitUntil { cues.contains { $0.text == "Repeated" && $0.start > 8 } }
        engine.pause()
        // This fixture's fMP4 edit/timestamp mapping puts VTT 1s at item 11/12s.
        // The bridge must preserve AVFoundation's mapped timestamp, not use 1s.
        let start = try XCTUnwrap(cues.first { $0.text == "Alpha" }?.start)
        XCTAssertEqual(start, 11.0 / 12, accuracy: 1.0 / 24)
        XCTAssertEqual(cues.active(at: start + 1.5).compactMap(\.text), ["Alpha", "Bravo"])
        XCTAssertEqual(cues.active(at: start + 2.5).compactMap(\.text), ["Bravo"])
        XCTAssertTrue(cues.active(at: start + 3).isEmpty)
        for offset in [-0.5, 0.0, 0.5, 10] {
            XCTAssertEqual(cues.active(at: start + 0.5 + offset, offset: offset).compactMap(\.text), ["Alpha"])
            XCTAssertTrue(cues.active(at: start + 3 + offset + 1.0 / 600, offset: offset).isEmpty)
        }
        try assertOnlySuppressedOutput(engine)

        await engine.seek(to: 2.5)
        engine.selectSubtitleTrack(alternate)
        try await waitUntil {
            return model.primary.map(\.text) == ["Alternate"]
        }
        XCTAssertTrue(engine.isPaused)
        XCTAssertFalse(cues.contains { $0.text == "Alpha" || $0.text == "Bravo" })
        engine.selectSubtitleTrack(full)
        try await waitUntil {
            return model.primary.compactMap(\.text) == ["Alpha", "Bravo"]
        }
        await engine.seek(to: 7.5)
        try await waitUntil {
            return model.primary.isEmpty
        }
        await engine.seek(to: 0)
        engine.play()
        try await waitUntil { model.primary.compactMap(\.text) == ["Alpha"] }
        XCTAssertLessThanOrEqual(engine.subtitlePresentationTime, start + 1.0 / 24 + 0.02,
                                 "Live captions must not wait for the 250ms status monitor")
        engine.selectSubtitleTrack(nil)
        try await waitUntil { cues.isEmpty }
    }

    func testPlozzigenRemoteHLSUsesTheSameOverlayAndPreservesSystemPresentationHandoff() async throws {
        let server = try SubtitleFixtureServer(directory: fixtureDirectory())
        let port = try await server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/master.m3u8"))
        let engine = try PlozzigenVideoEngine()
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        let model = LiveSubtitleModel()
        model.beginLiveFeed(permitsTimingOffsets: false)
        var cues: [SubtitleCue] = []
        engine.onSubtitleCues = { cues = $0; model.updateLiveCues($0) }
        let window = try await mount(engine, subtitles: model, liveClock: true)
        defer { engine.stop(); window.isHidden = true }
        await engine.loadLive(url: url, httpHeaders: [:])
        try await waitUntil { engine.subtitleTracks.count == 2 }
        let full = try XCTUnwrap(engine.subtitleTracks.first)
        engine.selectSubtitleTrack(full)
        try await waitUntil { cues.contains { $0.text == "Alpha" } }
        engine.pause()
        XCTAssertFalse(engine.capabilities.contains(.dualSubtitleDecode),
                       "One native legible selection cannot promise dual embedded decoding")
        await engine.seek(to: 2.5)
        try await waitUntil {
            return model.primary.compactMap(\.text) == ["Alpha", "Bravo"]
        }
        let player = try XCTUnwrap(engine.nowPlayingPlayer)
        let item = try XCTUnwrap(player.currentItem)
        let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loadedGroup)
        let selected = try XCTUnwrap(item.currentMediaSelection.selectedMediaOption(in: group))
        engine.setNativeSubtitlesActive(true)
        try await waitUntil {
            item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.allSatisfy { !$0.suppressesPlayerRendering }
                && item.currentMediaSelection.selectedMediaOption(in: group) == selected
        }
        XCTAssertTrue(cues.isEmpty, "System presentation must not double-draw the in-app overlay")
        engine.setNativeSubtitlesActive(false)
        try await waitUntil {
            return model.primary.compactMap(\.text) == ["Alpha", "Bravo"]
                && item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.contains { $0.suppressesPlayerRendering }
        }
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: group), selected)
    }

    private func assertOnlySuppressedOutput(_ engine: NativeVideoEngine) throws {
        let item = try XCTUnwrap(engine.underlyingPlayer?.currentItem)
        let outputs = item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.suppressesPlayerRendering, true)
        XCTAssertNil(item.textStyleRules, "Owned captions must not bake Apple's final styling into the source cues")
    }

    private func request(_ url: URL, tracks: [MediaTrack]) -> PlaybackRequest {
        PlaybackRequest(
            item: MediaItem(id: "fixture", title: "Synthetic captions", kind: .movie, runtime: 12),
            streamURL: url, subtitleTracks: tracks
        )
    }

    private func fixtureDirectory() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let url = try fixtureDirectory().appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    private func mount(_ engine: any VideoEngine, subtitles: LiveSubtitleModel, liveClock: Bool = false) async throws -> UIWindow {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        let controller: UIViewController
        subtitles.style.fontFamily = .system
        if liveClock {
            controller = UIViewController()
            controller.loadViewIfNeeded()
            let surface = engine.makeVideoOutputView()
            surface.frame = controller.view.bounds
            surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.view.addSubview(surface)
            let overlay = UIHostingController(rootView:
                LiveSubtitleOverlay(model: subtitles, controls: PlayerControlsModel())
                    .background(SubtitleDisplayClock(engine: engine, subtitles: subtitles))
            )
            overlay.safeAreaRegions = []
            overlay.view.backgroundColor = .clear
            overlay.view.frame = controller.view.bounds
            overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            controller.addChild(overlay)
            controller.view.addSubview(overlay.view)
            overlay.didMove(toParent: controller)
        } else {
            let player = PlayerInputViewController(engine: engine, model: PlayerControlsModel(), actions: PlayerActions())
            player.loadViewIfNeeded()
            player.attachVideoSurface()
            player.attachSubtitleOverlay(subtitles)
            controller = player
        }
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func waitUntil(
        timeout: Double = 12, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Native subtitle presentation did not settle", file: file, line: line)
    }
}

private final class SubtitleFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let files: [String: Data]
    private let queue = DispatchQueue(label: "SubtitleFixtureServer")
    private var connections: [NWConnection] = []

    init(directory: URL) throws {
        files = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connections.append(connection)
                connection.start(queue: queue)
                receive(connection, request: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, request: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, let data, error == nil else { connection.cancel(); return }
            let request = request + data
            guard let header = String(data: request, encoding: .utf8), header.contains("\r\n\r\n") else {
                if complete || request.count > 16_384 { connection.cancel() }
                else { receive(connection, request: request) }
                return
            }
            let path = header.split(separator: " ").dropFirst().first ?? ""
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            let body = files[name] ?? Data()
            let status = files[name] == nil ? "404 Not Found" : "200 OK"
            let type = name.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl" : name.hasSuffix(".vtt") ? "text/vtt" : "video/mp4"
            let response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
