import importlib.util
import math
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "generate-subtitle-hdr-preview.py"
SPEC = importlib.util.spec_from_file_location("subtitle_hdr_preview", SCRIPT)
PREVIEW = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREVIEW)


class SubtitleHDRPreviewGeneratorTests(unittest.TestCase):
    def test_scene_loops_without_a_position_or_luminance_jump(self):
        for x in (0, 0.25, 0.5, 0.75, 1):
            for y in (0, 0.25, 0.5, 0.75, 1):
                first = PREVIEW.scene_nits(x, y, 0)
                last = PREVIEW.scene_nits(x, y, PREVIEW.DURATION)
                for a, b in zip(first, last):
                    self.assertAlmostEqual(a, b, places=8)

    def test_all_authored_values_are_finite_and_within_mastering_range(self):
        for time in range(PREVIEW.DURATION):
            for x in range(17):
                for y in range(10):
                    for value in PREVIEW.scene_nits(x / 16, y / 9, time):
                        self.assertTrue(math.isfinite(value))
                        self.assertGreaterEqual(value, 0)
                        self.assertLessEqual(value, 1000)

    def test_hdr_glare_does_not_turn_into_a_full_white_frame(self):
        averages = [PREVIEW.authored_average(time) for time in range(PREVIEW.DURATION)]
        self.assertGreater(max(averages), 30)
        self.assertLess(max(averages), 150)
        self.assertEqual(PREVIEW.PEAK_LUMINANCE, 1000)


if __name__ == "__main__":
    unittest.main()
