#if canImport(UIKit)
import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerVideoZoomTests: XCTestCase {
    private let television = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testFitKeepsTheOriginalFrameAndFillCropsProportionally() throws {
        let fit = PlayerVideoZoom()
        XCTAssertEqual(fit.surfaceFrame(in: television, aspectRatio: 4 / 3), television)
        XCTAssertEqual(fit.videoRect(in: television, aspectRatio: 4 / 3),
                       CGRect(x: 240, y: 0, width: 1440, height: 1080))
        let fill = PlayerVideoZoom(mode: .fill)
        let frame = try XCTUnwrap(fill.videoRect(in: television, aspectRatio: 4 / 3))
        XCTAssertEqual(frame, CGRect(x: 0, y: -180, width: 1920, height: 1440))
        XCTAssertEqual(frame.width / frame.height, 4 / 3, accuracy: 0.0001)
        XCTAssertEqual(1 - television.height / frame.height, 0.25, accuracy: 0.0001)
        let cinema = try XCTUnwrap(fill.videoRect(in: television, aspectRatio: 2.4))
        XCTAssertEqual(cinema.height, television.height, accuracy: 0.001)
        XCTAssertEqual(cinema.width / cinema.height, 2.4, accuracy: 0.001)
        XCTAssertLessThan(cinema.minX, 0)
    }

    func testManualZoomCanRemoveEncodedBarsThatBasicFillLeaves() throws {
        let viewport = CGRect(x: 0, y: 0, width: 2622, height: 1206)
        // The issue's 16:9 raster contains a 2144 x 901 active picture.
        let activeFraction = CGRect(x: 0, y: 153.0 / 1206.0, width: 1, height: 901.0 / 1206.0)
        func picture(_ zoom: PlayerVideoZoom) throws -> CGRect {
            let raster = try XCTUnwrap(zoom.videoRect(in: viewport, aspectRatio: 16 / 9))
            return CGRect(x: raster.minX, y: raster.minY + activeFraction.minY * raster.height,
                          width: raster.width, height: raster.height * activeFraction.height)
        }
        let fill = try picture(PlayerVideoZoom(mode: .fill))
        XCTAssertGreaterThan(fill.minY, 50)
        XCTAssertLessThan(fill.maxY, viewport.maxY - 50)
        let custom = try picture(PlayerVideoZoom(mode: .custom, customPercent: 134))
        XCTAssertTrue(custom.contains(viewport))
    }

    func testZoomUsesTheCurrentViewportAndDisplayAspectAcrossRotation() throws {
        let zoom = PlayerVideoZoom(mode: .fill)
        let portrait = CGRect(x: 0, y: 0, width: 390, height: 844)
        let portraitVideo = try XCTUnwrap(zoom.videoRect(in: portrait, aspectRatio: 16 / 9))
        XCTAssertEqual(portraitVideo.height, 844, accuracy: 0.001)
        XCTAssertEqual(portraitVideo.midX, portrait.midX, accuracy: 0.001)
        let landscape = CGRect(x: 0, y: 0, width: 844, height: 390)
        let landscapeVideo = try XCTUnwrap(zoom.videoRect(in: landscape, aspectRatio: 16 / 9))
        XCTAssertEqual(landscapeVideo.width, 844, accuracy: 0.001)
        XCTAssertEqual(landscapeVideo.midY, landscape.midY, accuracy: 0.001)
        for ratio: Double? in [nil, 0, -.infinity, .nan] {
            XCTAssertNil(zoom.videoRect(in: landscape, aspectRatio: ratio))
            XCTAssertEqual(zoom.surfaceFrame(in: landscape, aspectRatio: ratio), landscape)
        }
        XCTAssertNil(zoom.videoRect(in: .zero, aspectRatio: 16 / 9))
    }

    func testModeCyclingCustomBoundsAndIndependentSessions() {
        let first = PlayerVideoZoomModel()
        let second = PlayerVideoZoomModel()
        first.cycleMode(forward: true)
        XCTAssertEqual(first.settings.mode, .fill)
        first.cycleMode(forward: true)
        XCTAssertEqual(first.settings.mode, .custom)
        first.setCustomPercent(134)
        first.cycleMode(forward: true)
        XCTAssertEqual(first.settings.mode, .fit)
        first.cycleMode(forward: false)
        XCTAssertEqual(first.settings, PlayerVideoZoom(mode: .custom, customPercent: 134))
        first.setCustomPercent(999)
        XCTAssertEqual(first.settings.customPercent, 200)
        first.setCustomPercent(-1)
        XCTAssertEqual(first.settings.customPercent, 100)
        XCTAssertEqual(second.settings, PlayerVideoZoom())
    }

    func testInlineChoiceAndSpeedSubmenuUseTheSharedSubtitleRowKinds() throws {
        let model = PlayerControlsModel()
        model.engineCapabilities = [.videoZoom, .playbackSpeed]
        model.playbackSpeed = 1.5
        var speedOpens = 0
        let rows = PlaybackOptionsPane.rows(model: model, zoom: model.videoZoom) { speedOpens += 1 }
        XCTAssertEqual(rows.map(\.slot), [PlaybackOptionsPane.zoomSlot, PlaybackOptionsPane.speedSlot])
        guard case let .choice(_, previous, next) = rows[0].kind else {
            return XCTFail("Zoom must adjust inline, not open a submenu.")
        }
        next()
        XCTAssertEqual(model.videoZoom.settings.mode, .fill)
        previous()
        XCTAssertEqual(model.videoZoom.settings.mode, .fit)
        guard case let .submenu(_, open) = rows[1].kind else {
            return XCTFail("Speed must open the existing fine-control/presets screen.")
        }
        open()
        XCTAssertEqual(speedOpens, 1)
        model.videoZoom.settings.mode = .custom
        let custom = PlaybackOptionsPane.rows(model: model, zoom: model.videoZoom, openSpeed: {})
        XCTAssertEqual(custom.map(\.slot), [0, 1, 2])
        guard case let .number(_, step) = custom[1].kind else {
            return XCTFail("Custom zoom must reuse the inline numeric adjustment.")
        }
        step(34)
        XCTAssertEqual(model.videoZoom.settings.customPercent, 134)
        let live = PlaybackOptionsPane.rows(
            model: model, zoom: model.videoZoom, offersPlaybackSpeed: false, openSpeed: {}
        )
        XCTAssertEqual(live.map(\.slot), [0, 1])
    }

    func testCapabilityGatesAndSelectedSpeedFocus() {
        let model = PlayerControlsModel()
        model.engineCapabilities = [.videoZoom]
        XCTAssertEqual(model.trackControlCategories, [.playback])
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(
            for: .playback, subtitleScreen: .tracks, model: model
        ), .row(PlaybackOptionsPane.zoomSlot))
        model.engineCapabilities = [.playbackSpeed]
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(
            for: .playback, subtitleScreen: .tracks, model: model
        ), .row(PlaybackOptionsPane.speedSlot))
        model.playbackSpeed = 1.75
        XCTAssertEqual(PlayerOptionsPanel.preferredFocus(
            for: .playback, subtitleScreen: .tracks, model: model, playbackScreen: .speed
        ), .row(3))
        model.engineCapabilities = []
        XCTAssertTrue(model.trackControlCategories.isEmpty)
        XCTAssertTrue(PlaybackOptionsPane.rows(model: model, zoom: model.videoZoom, openSpeed: {}).isEmpty)
    }

    func testVideoSurfaceChangesWithoutResizingOverlaysOrRestartingTheEngine() throws {
        let engine = ZoomVideoEngine()
        let parent = UIView(frame: television)
        let host = VideoPresentationView(frame: television)
        let overlay = UIView(frame: television)
        parent.addSubview(host)
        parent.addSubview(overlay)
        host.attach(engine)
        host.update(zoom: PlayerVideoZoom())
        host.layoutIfNeeded()
        let original = engine.output.layer
        host.update(zoom: PlayerVideoZoom(mode: .fill))
        XCTAssertEqual(host.frame, television)
        XCTAssertEqual(overlay.frame, television)
        XCTAssertEqual(engine.output.frame, CGRect(x: -320, y: -180, width: 2560, height: 1440))
        XCTAssertEqual(host.videoRect, CGRect(x: 0, y: -180, width: 1920, height: 1440))
        XCTAssertTrue(host.clipsToBounds)
        XCTAssertTrue(engine.output.layer === original)
        XCTAssertEqual(engine.surfaceRequests, 1)
        XCTAssertTrue(engine.transportCalls.isEmpty)
        engine.videoAspectRatio = 16 / 9
        host.update(zoom: PlayerVideoZoom(mode: .fill))
        XCTAssertEqual(engine.output.frame, television)
        host.update(zoom: PlayerVideoZoom(mode: .custom, customPercent: 150))
        XCTAssertEqual(engine.output.frame.size, CGSize(width: 2880, height: 1620))
        host.update(zoom: PlayerVideoZoom())
        XCTAssertEqual(engine.output.frame, television)
        XCTAssertTrue(engine.transportCalls.isEmpty)
    }

    func testRetiredVideoHostDoesNotResizeASurfaceAdoptedByAnotherHost() {
        let engine = ZoomVideoEngine()
        let retired = VideoPresentationView(frame: television)
        retired.attach(engine)
        let current = VideoPresentationView(frame: CGRect(x: 0, y: 0, width: 844, height: 390))
        current.attach(engine)
        current.layoutIfNeeded()
        let frame = engine.output.frame
        retired.update(zoom: PlayerVideoZoom(mode: .custom, customPercent: 200))
        retired.layoutIfNeeded()
        XCTAssertTrue(engine.output.superview === current)
        XCTAssertEqual(engine.output.frame, frame)
    }
}

@MainActor
private final class ZoomVideoEngine: VideoEngine {
    let output = UIView()
    var videoAspectRatio: Double? = 4 / 3
    var surfaceRequests = 0
    var transportCalls: [String] = []
    var status: VideoEngineStatus = .ready
    var isPaused = true
    var currentTime: TimeInterval = 10
    var duration: TimeInterval = 100
    var furthestObservedPosition: TimeInterval = 10
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    func load(request: PlaybackRequest, startPosition: TimeInterval) async { transportCalls.append("load") }
    func play() { transportCalls.append("play") }
    func pause() { transportCalls.append("pause") }
    func stop() { transportCalls.append("stop") }
    func seek(to seconds: TimeInterval) async { transportCalls.append("seek") }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView { surfaceRequests += 1; return output }
}
#endif
