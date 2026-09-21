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
    def test_quality_is_wired_into_the_rendered_transport_not_only_the_unused_menu(self):
        source = (ROOT / "Sources/AppShelliOS/PlozziOSPlayerControlsOverlay.swift").read_text()
        transport = swift_block(source, "private struct PlozziOSPlayerTransport:")
        body = swift_block(transport, "var body: some View")
        self.assertIn("trackControls", body)
        controls = swift_block(transport, "private var trackControls:")
        quality = swift_block(controls, "if viewModel.streamingQualityAvailable")
        self.assertIn("Button(action: onShowQuality)", quality)
        self.assertIn("PlayerGlassCircleButtonStyle(diameter: 44)", quality)
        self.assertIn('accessibilityLabel("Quality")', quality)
        self.assertIn('accessibilityIdentifier("player-streaming-quality")', quality)
        callback = swift_block(source, "onShowQuality:")
        self.assertIn("presentedSheet = .quality", callback)
        self.assertIn("cancelAutoHide()", callback)
        self.assertIn("case .quality:\n                PlozziOSStreamingQualitySheet(viewModel: viewModel)", source)

    def test_failure_recovery_is_central_not_in_the_close_button(self):
        source = (ROOT / "Sources/AppShelliOS/PlozziOSPlayerView.swift").read_text()
        controls = swift_block(source, "private var closeButton:")
        self.assertNotIn("Quality", controls)
        self.assertIn("onChangeQuality: { presentsStreamingQuality = true }", source)
        feedback = (ROOT / "Sources/FeaturePlayback/StreamingPlaybackFeedback.swift").read_text()
        self.assertIn('Button("Change quality"', feedback)
        self.assertIn('accessibilityIdentifier("player-failed-streaming-quality")', feedback)
        self.assertIn("viewModel.phase == .ready, !viewModel.showBringUpSpinner", source)


if __name__ == "__main__":
    unittest.main()
