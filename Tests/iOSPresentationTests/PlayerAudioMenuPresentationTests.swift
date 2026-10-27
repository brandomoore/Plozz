#if os(iOS)
import AVFoundation
import CoreModels
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeaturePlayback

@MainActor
final class PlayerAudioMenuPresentationTests: XCTestCase {
    func testNativeTracksSubmenuKeepsRichTitlesIDsAndCurrentSelection() throws {
        let options = TrackMenuBuilder.audioOptions(
            tracks: [
                .init(id: 17, kind: .audio, displayTitle: "English", language: "en", codec: "opus", channels: 6),
                .init(id: 42, kind: .audio, displayTitle: "French", language: "fr", codec: "aac", channels: 2)
            ], selectedID: 42, preferred: [], locale: .init(identifier: "en")
        )
        var picked: Int?
        let menu = PlayerAudioMenu.make(options: options, locale: .init(identifier: "en"), onSelect: { picked = $0 })
        XCTAssertEqual(menu.title, "Audio")
        XCTAssertEqual(menu.children.count, 1, "Unavailable enhancement must not produce a nonfunctional submenu.")
        let tracks = try XCTUnwrap(menu.children.first as? UIMenu)
        XCTAssertTrue(tracks.title.isEmpty, "The Audio menu already labels these tracks.")
        XCTAssertTrue(tracks.options.contains(.displayInline), "Audio tracks should not need another submenu tap.")
        XCTAssertTrue(tracks.options.contains(.singleSelection))
        let choices = tracks.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(choices.map(\.title), ["English (Opus 5.1)", "French (AAC Stereo)"])
        XCTAssertEqual(choices.map(\.state), [.off, .on], "The container's default is not the active selection.")
        perform(choices[0])
        XCTAssertEqual(picked, 17)
        perform(choices[1])
        XCTAssertEqual(picked, 42)
    }

    func testSoleTrackIsVisibleDisabledMetadata() throws {
        let menu = PlayerAudioMenu.make(options: [
            .init(id: 7, title: Text(verbatim: "English (Opus Stereo)"), isSelected: true, nativeTitle: "English (Opus Stereo)")
        ], onSelect: { _ in XCTFail("A sole track must not initiate a switch.") })
        let tracks = try XCTUnwrap(menu.children.first as? UIMenu)
        XCTAssertTrue(tracks.title.isEmpty)
        let track = try XCTUnwrap(tracks.children.first as? UIAction)
        XCTAssertEqual(track.title, "English (Opus Stereo)")
        XCTAssertEqual(track.state, .on)
        XCTAssertTrue(track.attributes.contains(.disabled))
    }

    func testSupportedEngineEnhancementUsesRealBinaryChoicesInItsOwnSubmenu() throws {
        var enabled: Bool?
        let menu = PlayerAudioMenu.make(
            options: [], dialogueEnhancement: true, locale: .init(identifier: "en"),
            onSelect: { _ in XCTFail("There are no tracks.") },
            onSetDialogueEnhancement: { enabled = $0 }
        )
        let enhancement = try XCTUnwrap(menu.children.first as? UIMenu)
        XCTAssertEqual(enhancement.title, "Enhance Dialogue")
        let choices = enhancement.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(choices.map(\.title), ["Off", "On"])
        XCTAssertEqual(choices.map(\.state), [.off, .on])
        perform(choices[0])
        XCTAssertEqual(enabled, false)
        perform(choices[1])
        XCTAssertEqual(enabled, true)
        XCTAssertEqual(menu.children.count, 1)
    }

    func testNoTracksAndNoWorkingEnhancementProducesNoOptions() {
        XCTAssertTrue(PlayerAudioMenu.make(options: [], onSelect: { _ in }).children.isEmpty)
    }

    func testAudioButtonUsesNativeMenuAndKeepsSnapshotAcrossClockUpdates() async throws {
        let state = MenuState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: MenuFixture(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.button(in: host.view) != nil }
        let button = try XCTUnwrap(button(in: host.view))
        XCTAssertEqual(button.accessibilityIdentifier, "player-audio")
        XCTAssertEqual(button.accessibilityLabel, "Audio")
        XCTAssertEqual(PlayerOptionsMenuButton.Kind.audio.symbol, "waveform")
        XCTAssertEqual(PlayerOptionsMenuButton.Kind.audio.symbol, LiveChannelTrackMenuKind.audio.icon)
        let audioImage = try XCTUnwrap(button.image(for: .normal))
        let waveformImage = try XCTUnwrap(UIImage(
            systemName: "waveform", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)
        ))
        XCTAssertTrue(audioImage.isEqual(waveformImage))
        XCTAssertTrue(button.showsMenuAsPrimaryAction)
        let interaction = try XCTUnwrap(button.contextMenuInteraction)
        defer { interaction.dismissMenu() }
        button.performPrimaryAction()
        try await waitUntil { button.presentedMenu != nil }
        let original = try XCTUnwrap(button.presentedMenu)
        XCTAssertEqual(original.title, "Audio")
        let tracks = try XCTUnwrap(original.children.first as? UIMenu)
        XCTAssertTrue(tracks.title.isEmpty, "The native popup must not repeat Audio as a section heading.")
        XCTAssertEqual(tracks.children.compactMap { ($0 as? UIAction)?.state }, [.on, .off])
        for tick in 1...10 {
            state.seconds = tick
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(button.presentedMenu === original)
        }
        XCTAssertEqual(state.presentations, [true])
        interaction.dismissMenu()
        try await waitUntil { button.presentedMenu == nil }
        state.selectedID = 42
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        button.performPrimaryAction()
        try await waitUntil { button.presentedMenu != nil }
        let reopened = try XCTUnwrap(button.presentedMenu?.children.first as? UIMenu)
        XCTAssertEqual(reopened.children.compactMap { ($0 as? UIAction)?.state }, [.off, .on])
        interaction.dismissMenu()
        try await waitUntil { button.presentedMenu == nil }
        XCTAssertEqual(state.presentations, [true, false, true, false])
    }

    func testLiveProgrammeRolloverReleasesNativeAudioMenuPinWithoutChangingChannel() async throws {
        let engine = AudioMenuLiveEngine()
        let input = LiveChannelInput.stream(url: URL(string: "https://fixture.invalid/live.m3u8")!, httpHeaders: [:])
        let tracks = LiveChannelPlayerModel(engine: engine, channelID: "channel", input: input)
        defer { tracks.stop() }
        await tracks.start()
        try await waitUntil { !tracks.audioTracks.isEmpty }
        let state = MenuState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: LiveMenuFixture(tracks: tracks, input: input, state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.button(in: host.view) != nil }
        let button = try XCTUnwrap(button(in: host.view))
        XCTAssertEqual(button.accessibilityIdentifier, "live-channel-playback-options")
        button.performPrimaryAction()
        try await waitUntil { button.presentedMenu != nil && state.presentations.last == true }
        let audio = try XCTUnwrap(button.presentedMenu?.children.first as? UIMenu)
        XCTAssertEqual(audio.title, "Audio")
        let audioTracks = try XCTUnwrap(audio.children.first as? UIMenu)
        XCTAssertTrue(audioTracks.title.isEmpty, "Live TV must use the same unlabelled track group as VOD.")
        engine.audioTracks = []
        engine.liveSnapshot = .init(phase: .loading)
        engine.onProgrammeChanged?()
        try await waitUntil { self.button(in: host.view) == nil && state.presentations.last == false }
        XCTAssertTrue(tracks.matchesSource(channelID: "channel", input: input), "A programme boundary is not a retune.")
        XCTAssertTrue(tracks.audioTracks.isEmpty)
    }

    private func perform(_ action: UIAction) {
        let button = UIButton(type: .system)
        button.addAction(action, for: .primaryActionTriggered)
        button.sendActions(for: .primaryActionTriggered)
    }

    private func button(in view: UIView) -> PlayerOptionsMenuControl? {
        if let button = view as? PlayerOptionsMenuControl { return button }
        return view.subviews.lazy.compactMap { self.button(in: $0) }.first
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }

    @MainActor @Observable
    final class MenuState {
        var seconds = 0
        var selectedID = 17
        var presentations: [Bool] = []

        var options: [PlayerTrackOption] {
            [
                .init(id: 17, title: Text(verbatim: "English (Opus 5.1)"),
                      isSelected: selectedID == 17, nativeTitle: "English (Opus 5.1)"),
                .init(id: 42, title: Text(verbatim: "French (AAC Stereo)"),
                      isSelected: selectedID == 42, nativeTitle: "French (AAC Stereo)")
            ]
        }
    }

    private struct MenuFixture: View {
        let state: MenuState

        var body: some View {
            VStack {
                Text(verbatim: "\(state.seconds)")
                PlayerAudioMenuButton(
                    options: state.options, onSelect: { state.selectedID = $0 },
                    onPresentationChange: { state.presentations.append($0) }
                )
            }
            .environment(\.locale, .init(identifier: "en"))
        }
    }

    private struct LiveMenuFixture: View {
        let tracks: LiveChannelPlayerModel
        let input: LiveChannelInput
        let state: MenuState
        @FocusState private var focus: LiveChannelControl?

        var body: some View {
            LiveChannelOverlay(
                title: "Channel", logoURL: nil, plozzChannelID: "scheduled", channelID: "channel", input: input,
                program: nil, earlierPrograms: [], libraryItem: nil, openLibraryItem: nil, phase: tracks.phase,
                isAtLiveEdge: true, behindLiveSeconds: 0, canPause: true, canGoLive: false,
                seekWindowSeconds: nil, onSeekBy: { _ in }, onSeekBehindLive: { _ in },
                focus: $focus, onClose: {}, onPrevious: {}, onPlayPause: {}, onGoLive: {}, onNext: {},
                onMultiview: nil, guideContent: nil, pendingGuideOpen: false, consumeGuideOpen: {},
                onGuideCardChange: { _ in }, loadOnNow: { [] }, onTuneChannel: nil, tracks: tracks,
                diagnosticsEnabled: false, toggleDiagnostics: {},
                onTracksPresentationChange: { state.presentations.append($0) },
                onControlActivity: {}, onDismissControls: {}
            )
            .environment(\.scenePhase, .active)
        }
    }

    @MainActor
    private final class AudioMenuLiveEngine: LiveChannelEngine {
        var status = VideoEngineStatus.ready
        var isPaused = false
        var currentTime: TimeInterval = 10
        var duration: TimeInterval = 0
        var furthestObservedPosition: TimeInterval = 0
        var audioTracks: [MediaTrack] = [
            .init(id: 1, kind: .audio, displayTitle: "English", language: "en", codec: "opus", isDefault: true, channels: 2),
            .init(id: 2, kind: .audio, displayTitle: "French", language: "fr", codec: "aac", channels: 2)
        ]
        var subtitleTracks: [MediaTrack] = []
        var onProgress: (@MainActor () -> Void)?
        var onFailure: (@MainActor (AppError) -> Void)?
        var onEnded: (@MainActor () -> Void)?
        var onTracksChanged: (@MainActor () -> Void)?
        var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
        var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
        var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
        var onLiveSourceReset: (@MainActor () -> Void)?
        var onProgrammeChanged: (@MainActor () -> Void)?
        var liveSnapshot = LiveChannelEngineSnapshot(phase: .playing, firstFrameReady: true, position: 10, route: .nativeHLS)
        func loadLive(url: URL, httpHeaders: [String: String]) async {}
        func seekToLiveEdge() async {}
        func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
        func play() {}
        func pause() {}
        func stop() {}
        func seek(to seconds: TimeInterval) async {}
        func selectAudioTrack(_ track: MediaTrack?) {}
        func selectSubtitleTrack(_ track: MediaTrack?) {}
        func makeVideoOutputView() -> UIView { UIView() }
    }
}
#endif
