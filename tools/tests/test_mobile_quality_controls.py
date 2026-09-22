import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def swift_block(source, declaration):
    start = source.index("{", source.index(declaration))
    depth = 1
    for index in range(start + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start + 1:index]
    raise AssertionError(f"Unclosed Swift block: {declaration}")


class MobileQualityControlsTests(unittest.TestCase):
    def test_network_cost_does_not_replace_wifi_with_the_cellular_preset(self):
        source = (ROOT / "Sources/AppShelliOS/PlozziOSStreamingQuality.swift").read_text()
        monitor = swift_block(source, "enum PlozziOSStreamingNetwork")
        self.assertIn("StreamingNetwork.classify(", monitor)
        self.assertIn("usesCellular: path.usesInterfaceType(.cellular),", monitor)
        self.assertIn("usesWiFi: path.usesInterfaceType(.wifi),", monitor)
        self.assertNotIn("|| path.isExpensive", monitor)

    def test_maximum_uses_the_original_loading_indicator(self):
        source = (ROOT / "Sources/FeaturePlayback/PlayerView.swift").read_text()
        overlay = swift_block(source, "private var bringUpSpinnerOverlay:")
        self.assertIn("options.quality != .original", overlay)
        self.assertIn("StreamingPlaybackLoadingView(", overlay)
        self.assertIn("LoadingMessagesView(spinnerTint: .white", overlay)

    def test_main_playback_holds_hero_until_media_io_stops(self):
        source = (ROOT / "Sources/AppShelliOS/PlozziOSPlayerView.swift").read_text()
        self.assertIn("suspendHeroPlayback()", swift_block(source, ".onAppear"))
        self.assertIn("trailerController.suspendForPlayback(owner: owner)", source)
        teardown = swift_block(source, ".onDisappear")
        self.assertLess(teardown.index("await outgoing.stop()"),
                        teardown.index("heroController.resumeAfterPlayback"))
        self.assertIn("heroPlaybackOwner = nil", teardown)
        hero = (ROOT / "Sources/AppShelliOS/PlozziOSHeroViews.swift").read_text()
        self.assertIn("isActive: isActive && !trailerController.isPlaybackSuppressed", hero)
        self.assertIn("guard !trailerController.isPlaybackSuppressed",
                      swift_block(hero, "private func updateTrailerPlayback()"))

    def test_loading_has_only_a_spinner_status_and_quality(self):
        source = (ROOT / "Sources/FeaturePlayback/StreamingPlaybackFeedback.swift").read_text()
        loading = swift_block(source, "struct StreamingPlaybackLoadingView:")
        self.assertIn("ProgressView()", loading)
        self.assertEqual(loading.count("Text("), 2)
        self.assertNotIn(".footnote", loading)

    def test_secondary_controls_are_in_the_rendered_menu_not_an_unused_menu(self):
        source = (ROOT / "Sources/AppShelliOS/PlozziOSPlayerControlsOverlay.swift").read_text()
        transport = swift_block(source, "private struct PlozziOSPlayerTransport:")
        body = swift_block(transport, "var body: some View")
        self.assertIn("trackControls", body)
        controls = swift_block(transport, "private var trackControls:")
        self.assertIn("playbackOptions", controls)
        self.assertEqual(controls.count("Button("), 1, "Only captions remain a separate button")
        menu = swift_block(source, "private struct PlozziOSPlaybackOptionsMenu:")
        self.assertIn('action("Quality"', menu)
        self.assertIn('action("Version"', menu)
        self.assertNotIn('"Now Playing"', source)
        self.assertNotIn("PlozziOSPlaybackInfoSheet", source)
        self.assertNotIn("onShowInfo", source)
        self.assertNotIn('"Playback Diagnostics"', menu)
        self.assertNotIn('"Subtitles"', menu)
        self.assertIn('UIImage(systemName: "speaker.wave.2")', menu)
        self.assertIn("PlayerOptionsMenuButton(", menu)
        self.assertIn("if hasAudioControls", menu)
        self.assertIn("hasAudioControls: viewModel.controls.hasAudioControls", transport)
        self.assertIn("viewModel.controls.hasSelectableAudio ? viewModel.controls.audioOptions : []", transport)
        info = (ROOT / "Sources/FeaturePlayback/InfoPanelView.swift").read_text()
        self.assertIn('title: "Playback Info"', info)
        self.assertIn("model.diagnosticsEnabled.toggle()", info)
        callback = swift_block(source, "onShowQuality:")
        self.assertIn("presentedSheet = .quality", callback)
        self.assertIn("cancelAutoHide()", callback)
        self.assertIn("case .quality:\n                PlozziOSStreamingQualitySheet(viewModel: viewModel)", source)

    def test_tv_audio_uses_same_availability_and_info_labels_source_tracks(self):
        source = (ROOT / "Sources/FeaturePlayback/PlayerControls.swift").read_text()
        self.assertIn("if hasAudioControls", swift_block(source, "var trackControlCategories:"))
        self.assertIn("where model.hasSelectableAudio", swift_block(source, "private var audioRows:"))
        info = (ROOT / "Sources/FeaturePlayback/InfoPanelView.swift").read_text()
        self.assertIn("audioDetails", swift_block(info, "private func compactStack"))
        self.assertIn("audioDetails", swift_block(info, "private func regularBody"))
        self.assertIn('Text("Source audio: \\(option.title)")', info)
        vm = (ROOT / "Sources/FeaturePlayback/PlayerViewModel.swift").read_text()
        self.assertIn("controls.infoCard.audioIsSourceTrack = request.isTranscoding", vm)

    def test_auto_hide_waits_for_native_menu_and_all_player_sheets(self):
        source = (ROOT / "Sources/AppShelliOS/PlozziOSPlayerControlsOverlay.swift").read_text()
        timer = swift_block(source, "private func scheduleAutoHide()")
        for guard in ("!optionsMenuPresented", "!versionsPresented",
                      "!viewModel.controls.diagnosticsEnabled", "presentedSheet == nil"):
            self.assertIn(guard, timer)
        callback = swift_block(source, "onOptionsMenuPresentationChange:")
        self.assertIn("optionsMenuPresented = presented", callback)
        self.assertIn("cancelAutoHide()", callback)
        self.assertIn("scheduleAutoHide()", callback)
        self.assertIn("guard !optionsMenuPresented", swift_block(source, "private func toggleControls()"))

    def test_failure_recovery_is_central_not_in_the_close_button(self):
        source = (ROOT / "Sources/AppShelliOS/PlozziOSPlayerView.swift").read_text()
        controls = swift_block(source, "private var closeButton:")
        self.assertNotIn("Quality", controls)
        self.assertIn("onChangeQuality: { presentsStreamingQuality = true }", source)
        feedback = (ROOT / "Sources/FeaturePlayback/StreamingPlaybackFeedback.swift").read_text()
        self.assertIn('Button("Change quality"', feedback)
        self.assertIn('accessibilityIdentifier("player-failed-streaming-quality")', feedback)
        self.assertIn("viewModel.phase == .ready, !viewModel.showBringUpSpinner", source)

    def test_sdr_is_offered_not_automatically_selected_and_original_needs_confirmation(self):
        source = (ROOT / "Sources/AppShelliOS/PlozziOSPlayerView.swift").read_text()
        self.assertIn("onPlaySDRVersion:", source)
        self.assertIn("showVersions(onlySDR: true)", source)
        notice = swift_block(source, "private func presentSDRNoticeIfReady()")
        self.assertIn("viewModel.phase == .ready", notice)
        self.assertIn("!viewModel.showBringUpSpinner", notice)
        self.assertIn("announcedSDRPlayer != playerIdentity", notice)
        self.assertIn('text: "Playing in SDR"', notice)
        self.assertIn("TransientStatusView(presenter: playbackStatus)", source)
        self.assertNotIn("switchVersion", notice)
        feedback = (ROOT / "Sources/FeaturePlayback/StreamingPlaybackFeedback.swift").read_text()
        self.assertIn('Button("Play original quality") { confirmsOriginal = true }', feedback)
        self.assertIn('.confirmationDialog("Play original quality?"', feedback)
        self.assertIn("substantially more data", feedback)


if __name__ == "__main__":
    unittest.main()
