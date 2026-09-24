import CoreModels
import XCTest
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif

@testable import FeaturePlayback

/// tvOS delivers the Siri Remote's Play/Pause as a Now Playing command while video
/// plays and as a press while paused. Both are the viewer's input, and one press
/// must never be acted on twice.
@MainActor
final class RemotePlayPauseInputTests: XCTestCase {

    // MARK: Echo arbitration

    func testSystemCommandEchoingARecentPressIsNotActedOn() {
        let clock = ManualUptime()
        let input = RemotePlayPauseInput(now: { clock.now })
        XCTAssertTrue(input.admit(.press))
        clock.now += 0.1
        XCTAssertFalse(input.admit(.systemCommand),
                       "The same press arriving through Now Playing would toggle straight back")
    }

    func testPressEchoingARecentSystemCommandIsNotActedOn() {
        let clock = ManualUptime()
        let input = RemotePlayPauseInput(now: { clock.now })
        XCTAssertTrue(input.admit(.systemCommand))
        clock.now += 0.1
        XCTAssertFalse(input.admit(.press))
    }

    func testRepeatedInputOnOnePathIsNeverAnEcho() {
        let clock = ManualUptime()
        let input = RemotePlayPauseInput(now: { clock.now })
        XCTAssertTrue(input.admit(.systemCommand))
        clock.now += 0.05
        XCTAssertTrue(input.admit(.systemCommand))
        clock.now += 0.05
        XCTAssertTrue(input.admit(.systemCommand))
    }

    func testOtherPathAfterTheEchoWindowIsAFreshPress() {
        // On device a pause arrives by command and the resume by press about a
        // second later; that follow-up is the viewer's, not an echo.
        let clock = ManualUptime()
        let input = RemotePlayPauseInput(now: { clock.now })
        XCTAssertTrue(input.admit(.systemCommand))
        clock.now += 0.9
        XCTAssertTrue(input.admit(.press))
        clock.now += RemotePlayPauseInput.echoWindow + 0.01
        XCTAssertTrue(input.admit(.systemCommand))
    }

    func testOnePressDropsAtMostOneEcho() {
        let clock = ManualUptime()
        let input = RemotePlayPauseInput(now: { clock.now })
        XCTAssertTrue(input.admit(.press))
        clock.now += 0.05
        XCTAssertFalse(input.admit(.systemCommand))
        clock.now += 0.05
        XCTAssertTrue(input.admit(.press), "A second press is new input even inside the window")
    }

    // MARK: Input controller

    #if canImport(UIKit)
    func testSystemPlayPauseRevealsTheHiddenTransport() {
        let (controller, model, toggles) = makeInput()
        defer { controller.viewDidDisappear(false) }
        XCTAssertFalse(model.controlsVisible)
        model.isPaused = true
        model.remotePlayPause.onSystemCommand?()
        XCTAssertTrue(model.controlsVisible, "Pausing from the remote shows the controls")
        XCTAssertEqual(toggles.count, 0, "The view model already applied the command")
    }

    func testContainerWithoutSharedTransportLeavesSystemPlayPauseToItsOverlay() {
        // iOS mounts the container without the shared transport and draws its
        // own overlay, which follows the paused intent directly.
        let model = PlayerControlsModel()
        let controller = PlayerInputViewController(
            engine: RemoteInputSpyEngine(), model: model, actions: PlayerActions()
        )
        controller.loadViewIfNeeded()
        XCTAssertNil(model.remotePlayPause.onSystemCommand)
    }

    func testRemotePressTogglesAndRevealsTheTransport() {
        let (controller, model, toggles) = makeInput()
        defer { controller.viewDidDisappear(false) }
        controller.handlePlayPause()
        XCTAssertEqual(toggles.count, 1)
        XCTAssertTrue(model.controlsVisible)
    }

    func testRemotePressEchoingASystemCommandRevealsWithoutTogglingAgain() {
        let (controller, model, toggles) = makeInput()
        defer { controller.viewDidDisappear(false) }
        XCTAssertTrue(model.remotePlayPause.admit(.systemCommand))
        controller.handlePlayPause()
        XCTAssertEqual(toggles.count, 0, "One press must not pause and then resume")
        XCTAssertTrue(model.controlsVisible)
    }

    private func makeInput() -> (PlayerInputViewController, PlayerControlsModel, ToggleCounter) {
        let model = PlayerControlsModel()
        model.duration = 7200
        let toggles = ToggleCounter()
        let controller = PlayerInputViewController(
            engine: RemoteInputSpyEngine(), model: model,
            actions: PlayerActions(togglePlayPause: {
                toggles.count += 1
                model.isPaused.toggle()
            })
        )
        controller.loadViewIfNeeded()
        controller.attachControls(themePalette: ThemePaletteBox(
            makeControls: { _, _, _ in AnyView(EmptyView()) },
            makeSkipButton: { _, _, _, _ in AnyView(EmptyView()) },
            makeUpNextCard: { _, _, _, _ in AnyView(EmptyView()) }
        ))
        return (controller, model, toggles)
    }
    #endif
}

private final class ManualUptime {
    var now: TimeInterval = 1_000
}

#if canImport(UIKit)
@MainActor
private final class ToggleCounter {
    var count = 0
}

@MainActor
private final class RemoteInputSpyEngine: VideoEngine {
    var status: VideoEngineStatus = .ready
    var isPaused = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 7200
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
    func play() { isPaused = false }
    func pause() { isPaused = true }
    func seek(to seconds: TimeInterval) async { currentTime = seconds }
    func stop() { status = .idle }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView { UIView() }
}
#endif
