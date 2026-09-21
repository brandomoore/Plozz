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

    def test_outer_quality_button_only_appears_for_failed_playback(self):
        source = (ROOT / "Sources/AppShelliOS/PlozziOSPlayerView.swift").read_text()
        controls = swift_block(source, "private var closeButton:")
        self.assertIn("case .failed = viewModel.phase, viewModel.streamingQualityAvailable", controls)
        self.assertIn('accessibilityIdentifier("player-failed-streaming-quality")', controls)


if __name__ == "__main__":
    unittest.main()
