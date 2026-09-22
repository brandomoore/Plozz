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
        self.assertIn('action("Now Playing"', menu)
        self.assertNotIn('"Playback Diagnostics"', menu)
        self.assertNotIn('"Subtitles"', menu)
        self.assertIn('UIImage(systemName: "speaker.wave.2")', menu)
        self.assertIn("PlayerOptionsMenuButton(", menu)
        info = swift_block(source, "private struct PlozziOSPlaybackInfoSheet:")
        self.assertIn('Button("Playback Diagnostics"', info)
        callback = swift_block(source, "onShowQuality:")
        self.assertIn("presentedSheet = .quality", callback)
        self.assertIn("cancelAutoHide()", callback)
        self.assertIn("case .quality:\n                PlozziOSStreamingQualitySheet(viewModel: viewModel)", source)

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
