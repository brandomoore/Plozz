import AVFoundation
import CoreModels
import EnginePlozzigen
import Network
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback
@testable import CoreUI

@MainActor
final class NativeSubtitlePresentationTests: XCTestCase {
    func testLocalEmbeddedASSKeepsAuthoredGraphicsThroughSeekAndOff() async throws {
        guard let path = ProcessInfo.processInfo.environment["PLOZZ_ASS_MEDIA_REPRO"] else {
            throw XCTSkip("Requires an explicitly supplied local ASS media fixture.")
        }
        let engine = try PlozzigenVideoEngine()
        engine.configureLiveOutput(.init(isAudible: false, sharesAudioSession: true, suppressesDisplayMatching: true))
        let model = LiveSubtitleModel()
        model.beginLiveFeed()
        var latest: [SubtitleCue] = []
        engine.onSubtitleCues = { latest = $0; model.updateLiveCues($0) }
        let window = try await mount(engine, subtitles: model)
        defer { engine.stop(); window.isHidden = true; window.rootViewController = nil }
        let mediaURL = path.hasPrefix("cache:")
            ? try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
                .appendingPathComponent(String(path.dropFirst("cache:".count)))
            : URL(fileURLWithPath: path)
        let mediaHandle = try FileHandle(forReadingFrom: mediaURL)
        try mediaHandle.close()
        if path == "cache:apothecary-repro.mkv" {
            addTeardownBlock { try FileManager.default.removeItem(at: mediaURL) }
        }
        await engine.load(request: request(mediaURL, tracks: []), startPosition: 0)
        try await waitUntil(timeout: 30) { engine.isPlaybackPositionReady }
        let track = try XCTUnwrap(engine.subtitleTracks.first { $0.codec == "ass" })
        engine.selectSubtitleTrack(track)
        try await waitUntil(timeout: 30) { latest.contains(where: \.isImage) && model.primary.contains(where: \.isImage) }
        engine.pause()
        await engine.seek(to: 8)
        try await waitUntil(timeout: 30) {
            abs(engine.subtitlePresentationTime - 8) < 0.1
                && latest.contains(where: \.isImage) && model.primary.contains(where: \.isImage)
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(latest.allSatisfy(\.isImage), "ASS drawings and glyph layers must never reach the plain text overlay.")
        let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "Local ASS artwork at actual player position"
        attachment.lifetime = .keepAlways
        add(attachment)
        let initialID = latest.first?.id
        await engine.seek(to: 3)
        try await waitUntil(timeout: 30) { latest.first?.id != initialID && latest.contains(where: \.isImage) }
        XCTAssertTrue(engine.isPaused)
        engine.selectSubtitleTrack(nil)
        try await waitUntil { latest.isEmpty && model.primary.isEmpty }
        engine.selectSubtitleTrack(track)
        try await waitUntil(timeout: 30) { latest.contains(where: \.isImage) }
        if let alternate = engine.subtitleTracks.first(where: { $0.codec == "ass" && $0.id != track.id }) {
            engine.selectSubtitleTrack(alternate)
            try await waitUntil(timeout: 30) { latest.contains(where: \.isImage) }
        }
        model.style.followsSystemStyle = true
        try await waitUntil {
            !latest.isEmpty && latest.allSatisfy { !$0.isImage }
        }
        XCTAssertFalse(latest.contains { $0.text?.hasPrefix("m ") == true },
                       "Explicit system-style fallback must not expose vector coordinates.")
        model.style.followsSystemStyle = false
        try await waitUntil(timeout: 30) { latest.contains(where: \.isImage) }
    }

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
        let originalStyle = model.style
        let originalCaption = try XCTUnwrap(captionFrames(in: window, relativeTo: window).first)
        model.style.followsSystemStyle = false
        model.style.fontScale = 1.4
        model.style.textColor = .yellow
        model.style.verticalPosition = 0.35
        try await waitUntil {
            window.layoutIfNeeded()
            guard let frame = self.captionFrames(in: window, relativeTo: window).first else { return false }
            return frame.height > originalCaption.height * 1.2
                && abs(frame.maxY - window.bounds.height * 0.65) <= 1
        }
        XCTAssertEqual(engine.currentTime, 6.5, accuracy: 1.0 / 24)
        XCTAssertEqual(model.primary.compactMap(\.text), ["Repeated"])
        try assertOnlySuppressedOutput(engine)
        let styled = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: styled)
        attachment.name = "Native embedded caption restyled while paused"
        attachment.lifetime = .keepAlways
        add(attachment)
        model.style = originalStyle
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

    #if os(tvOS)
    func testDirectMP4SidecarsKeepSelectionStyleOffsetAndEmbeddedCaptionsWithoutWrappingVideo() async throws {
        let server = try SubtitleFixtureServer(directory: fixtureDirectory())
        let port = try await server.start()
        defer { server.stop() }
        let videoURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/embedded.mp4"))
        for (name, codec) in [("full.vtt", "webvtt"), ("sidecar.srt", "srt")] {
            let locator = try AuthenticatedHTTPPlaybackLocator(
                provider: .jellyfin, accountID: "fixture", credentialRevision: CredentialRevision(),
                itemID: "fixture", deliveryMode: .directFile, purpose: .subtitle,
                resource: try AuthenticatedHTTPResource(pathBase: .configuredBaseURL, path: name)
            )
            let resolver = SidecarResolver(
                locator: locator,
                url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(name)"))
            )
            let engine = NativeVideoEngine(authenticatedHTTPResolver: resolver, startsMuted: true)
            let embedded = MediaTrack(id: 2, kind: .subtitle, displayTitle: "Embedded", language: "en", codec: "mov_text")
            let sidecar = MediaTrack(
                id: 9, kind: .subtitle, displayTitle: "Sidecar", language: "en", codec: codec,
                deliverySource: .authenticatedHTTP(locator)
            )
            let playback = request(videoURL, tracks: [embedded, sidecar])
            let host = SidecarTrackHost(engine: engine, request: playback, resolver: resolver)
            engine.onSubtitleCues = { [model = host.subtitles] in model.updateLiveCues($0) }
            let window = try await mount(engine, subtitles: host.subtitles)
            defer {
                host.loader.cancelAll()
                engine.stop()
                window.isHidden = true
                window.rootViewController = nil
            }
            await engine.load(request: playback, startPosition: 0)
            let surface = try XCTUnwrap(engine.makeVideoOutputView() as? PlayerLayerView)
            try await waitUntil(timeout: 30) {
                surface.playerLayer.isReadyForDisplay && engine.currentTime > 0.1
            }
            let item = try XCTUnwrap(
                surface.playerLayer.isReadyForDisplay && engine.currentTime > 0.1
                    ? engine.underlyingPlayer?.currentItem : nil,
                "The direct MP4 fixture must present frames before seeking"
            )
            engine.pause()
            await engine.seek(to: 1.5)
            XCTAssertEqual((item.asset as? AVURLAsset)?.url, videoURL)
            XCTAssertTrue(resolver.resolutions.isEmpty, "Available sidecars must not change or delay the video asset")
            host.controller.loadTrackOptions()
            XCTAssertTrue(host.controls.subtitleOptions.contains { $0.id == sidecar.id })
            host.controller.selectSubtitleOption(id: PlayerTrackOption.offID)
            XCTAssertTrue(resolver.resolutions.isEmpty)
            host.controller.selectSubtitleOption(id: sidecar.id)
            try await waitUntil { host.subtitles.primary.compactMap(\.text) == ["Alpha"] }
            XCTAssertEqual(resolver.resolutions, [locator])
            XCTAssertTrue(engine.supportsSubtitleTimingAdjustments(for: sidecar))
            try assertOnlySuppressedOutput(engine)

            host.subtitles.offset = 1
            try await waitUntil { host.subtitles.primary.isEmpty }
            host.subtitles.offset = 0
            try await waitUntil { host.subtitles.primary.compactMap(\.text) == ["Alpha"] }
            let initialFrame = try XCTUnwrap(captionFrames(in: window, relativeTo: window).first)
            host.subtitles.style.followsSystemStyle = false
            host.subtitles.style.fontScale = 1.4
            host.subtitles.style.textColor = .yellow
            try await waitUntil {
                window.layoutIfNeeded()
                return self.captionFrames(in: window, relativeTo: window).first.map {
                    $0.height > initialFrame.height * 1.2
                } == true
            }
            XCTAssertEqual(engine.currentTime, 1.5, accuracy: 1.0 / 24)

            host.controller.selectSubtitleOption(id: embedded.id)
            await engine.seek(to: 0)
            try await waitUntil { host.subtitles.primary.isEmpty }
            engine.play()
            try await waitUntil { host.subtitles.primary.compactMap(\.text) == ["Alpha"] }
            XCTAssertTrue(host.subtitles.rendersPrimary, "Embedded captions still use native cue extraction")
            host.controller.selectSubtitleOption(id: PlayerTrackOption.offID)
            try await waitUntil { host.subtitles.primary.isEmpty }
            XCTAssertTrue(engine.underlyingPlayer?.currentItem === item)
            XCTAssertEqual((item.asset as? AVURLAsset)?.url, videoURL)
            XCTAssertTrue(item.appliesPerFrameHDRDisplayMetadata)
        }
    }
    #endif

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
        let item = try XCTUnwrap(engine.underlyingPlayer?.currentItem)
        let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loadedGroup)

        await engine.seek(to: 2.5)
        engine.selectSubtitleTrack(alternate)
        try await waitUntil(
            detail: "After selecting Alternate: visible=\(model.primary.compactMap(\.text)), "
                + "decoded=\(cues.compactMap(\.text))"
        ) {
            return model.primary.map(\.text) == ["Alternate"]
        }
        XCTAssertTrue(engine.isPaused)
        XCTAssertFalse(cues.contains { $0.text == "Alpha" || $0.text == "Bravo" })
        engine.selectSubtitleTrack(full)
        try await waitUntil(
            detail: "After reselecting Full: visible=\(model.primary.compactMap(\.text)), "
                + "decoded=\(cues.compactMap(\.text)), "
                + "selected=\(String(describing: item.currentMediaSelection.selectedMediaOption(in: group))), "
                + "suppressed=\(item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.map(\.suppressesPlayerRendering))"
        ) {
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
        // The selected HLS rendition can disappear while AVFoundation changes renderers.
        item.select(nil, in: group)
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
        engine.setNativeSubtitlesActive(false)
        try await waitUntil(
            detail: "After restoring the overlay: visible=\(model.primary.compactMap(\.text)), "
                + "decoded=\(cues.compactMap(\.text)), "
                + "selected=\(String(describing: item.currentMediaSelection.selectedMediaOption(in: group))), "
                + "suppressed=\(item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.map(\.suppressesPlayerRendering))"
        ) {
            return model.primary.compactMap(\.text) == ["Alpha", "Bravo"]
                && item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.contains { $0.suppressesPlayerRendering }
        }
        XCTAssertTrue(engine.isPaused)
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: group), selected)
        engine.selectSubtitleTrack(nil)
        try await waitUntil {
            item.currentMediaSelection.selectedMediaOption(in: group) == nil && cues.isEmpty
        }
        engine.setNativeSubtitlesActive(true)
        try await waitUntil {
            item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.contains { !$0.suppressesPlayerRendering }
                && item.currentMediaSelection.selectedMediaOption(in: group) == nil
        }
        engine.setNativeSubtitlesActive(false)
        try await waitUntil {
            item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.contains { $0.suppressesPlayerRendering }
                && item.currentMediaSelection.selectedMediaOption(in: group) == nil && cues.isEmpty
        }
    }

    private func assertOnlySuppressedOutput(_ engine: NativeVideoEngine) throws {
        let item = try XCTUnwrap(engine.underlyingPlayer?.currentItem)
        let outputs = item.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first?.suppressesPlayerRendering, true)
        XCTAssertNil(item.textStyleRules, "Owned captions must not bake Apple's final styling into the source cues")
    }

    private func captionFrames(in view: UIView, relativeTo window: UIWindow) -> [CGRect] {
        if let line = view as? SubtitleLineView { return [line.convert(line.bounds, to: window)] }
        return view.subviews.flatMap { captionFrames(in: $0, relativeTo: window) }
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
        timeout: Double = 12, detail: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Native subtitle presentation did not settle. \(detail())", file: file, line: line)
    }
}

@MainActor
private final class SidecarResolver: AuthenticatedHTTPResourceResolving {
    let locator: AuthenticatedHTTPPlaybackLocator
    let url: URL
    private(set) var resolutions: [AuthenticatedHTTPPlaybackLocator] = []

    init(locator: AuthenticatedHTTPPlaybackLocator, url: URL) {
        self.locator = locator
        self.url = url
    }

    func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        resolutions.append(locator)
        guard locator == self.locator else { throw AppError.invalidResponse }
        return url
    }
}

@MainActor
private final class SidecarTrackHost: SubtitleTrackControllerHost, SubtitleOverlayLoaderHost {
    let engine: NativeVideoEngine
    let request: PlaybackRequest
    let resolver: SidecarResolver
    let subtitles = LiveSubtitleModel()
    let controls = PlayerControlsModel()
    lazy var controller = SubtitleTrackController(host: self)
    lazy var loader = SubtitleOverlayLoader(host: self)

    init(engine: NativeVideoEngine, request: PlaybackRequest, resolver: SidecarResolver) {
        self.engine = engine
        self.request = request
        self.resolver = resolver
    }

    var trackEngine: any VideoEngine { engine }
    var trackEngineKind: PlaybackEngineKind { .native }
    var trackRequest: PlaybackRequest? { request }
    var trackBehavior: SubtitleBehavior { .default }
    var trackControls: PlayerControlsModel { controls }
    var trackLiveSubtitles: LiveSubtitleModel { subtitles }
    var trackSubtitleOverlay: SubtitleOverlayLoader { loader }
    var trackStyle: SubtitleStyle { subtitles.style }
    var trackPlozzigenAvailable: Bool { false }
    var trackAppLocale: Locale { Locale(identifier: "en_US") }
    var trackAuthenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? { resolver }
    func trackApplySubtitleStyle(_ style: SubtitleStyle) { subtitles.style = style }
    func trackRememberedSubtitle(for item: MediaItem) -> RememberedSubtitleSelection? { .off }
    func trackEffectiveSubtitleRule(for item: MediaItem) -> SubtitlePolicy.Rule { .init() }
    func trackRecordAudioSelection(language: String?) {}
    func trackRecordSubtitleSelection(_ selection: RememberedSubtitleSelection?) {}
    func trackRefreshSubtitleDelayAvailability() {}
    func trackPlayResolvedForImageSubtitleSwap(_ request: PlaybackRequest, startPosition: TimeInterval) async {
        XCTFail("A text sidecar must not switch engines")
    }
    var primarySubtitleSelectionID: Int? { controller.selectedSubtitleTrackID }
    var secondarySubtitleSelectionID: Int? { controller.selectedSecondarySubtitleTrackID }
    func overlayResolveDeliveryURL(_ track: MediaTrack) async throws -> URL? {
        try await controller.resolveSubtitleDeliveryURL(track)
    }
    func overlayApplyPrimaryCues(_ stream: SubtitleCueStream?) { subtitles.loadPrimary(stream) }
    func overlayApplySecondaryCues(_ stream: SubtitleCueStream?) { subtitles.loadSecondary(stream) }
    func overlayDetectedLanguage(for id: Int) -> String? { "en" }
    func overlayRecordDetectedLanguage(_ language: String, for id: Int) {}
    func overlayReloadTrackOptions() {}
    func overlaySetSecondaryStatus(_ status: SecondarySubtitleStatus) { controls.secondarySubtitleStatus = status }
    #if DEBUG
    func overlaySetPrimaryDiagnostic(route: String, cues: Int?) {}
    #endif
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
            var payload = body
            var status = files[name] == nil ? "404 Not Found" : "200 OK"
            var contentRange = ""
            if files[name] != nil,
               let rangeLine = header.components(separatedBy: "\r\n").first(where: {
                   $0.lowercased().hasPrefix("range:")
               }) {
                let value = rangeLine.dropFirst("range:".count).trimmingCharacters(in: .whitespaces)
                if let range = byteRange(value, count: body.count) {
                    payload = body.subdata(in: range)
                    status = "206 Partial Content"
                    contentRange = "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)\r\n"
                } else {
                    payload = Data()
                    status = "416 Range Not Satisfiable"
                    contentRange = "Content-Range: bytes */\(body.count)\r\n"
                }
            }
            let type = name.hasSuffix(".m3u8") ? "application/vnd.apple.mpegurl"
                : name.hasSuffix(".vtt") ? "text/vtt"
                : name.hasSuffix(".srt") ? "application/x-subrip" : "video/mp4"
            let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nAccept-Ranges: bytes\r\n\(contentRange)Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            let response = Data(headers.utf8) + (header.hasPrefix("HEAD ") ? Data() : payload)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func byteRange(_ value: String, count: Int) -> Range<Int>? {
        guard count > 0, value.hasPrefix("bytes=") else { return nil }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = Int(bounds[1]), suffix > 0 else { return nil }
            return max(0, count - min(suffix, count))..<count
        }
        guard let start = Int(bounds[0]), start >= 0, start < count else { return nil }
        let end: Int
        if bounds[1].isEmpty {
            end = count - 1
        } else {
            guard let requestedEnd = Int(bounds[1]), requestedEnd >= start else { return nil }
            end = min(requestedEnd, count - 1)
        }
        return start..<(end + 1)
    }
}
