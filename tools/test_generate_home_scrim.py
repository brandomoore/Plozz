import unittest

from generate_home_scrim import alpha_at, render


class HomeScrimGeneratorTests(unittest.TestCase):
    def test_clear_center_keeps_only_the_wash(self):
        self.assertAlmostEqual(alpha_at(0.5, 0.2), 0.06)

    def test_bottom_corner_combines_all_three_layers(self):
        self.assertAlmostEqual(alpha_at(0, 1), 1 - 0.94 * 0.45 * 0.45)

    def test_far_bottom_edge_has_no_side_darkening(self):
        self.assertAlmostEqual(alpha_at(1, 1), 1 - 0.94 * 0.45)

    def test_side_ramp_preserves_its_middle_stop(self):
        self.assertAlmostEqual(alpha_at(0, 0.34), 1 - 0.94 * (1 - 0.55 * 0.35))

    def test_renderer_samples_the_continuous_field_at_pixel_centers(self):
        for pinned in (False, True):
            image = render(16, 9, pinned=pinned)
            for y in range(9):
                for x in range(16):
                    red, green, blue, alpha = image.getpixel((x, y))
                    self.assertEqual((red, green, blue), (255, 255, 255))
                    expected = alpha_at((x + 0.5) / 16, (y + 0.5) / 9, pinned=pinned)
                    self.assertEqual(alpha, round(expected * 255))

    def test_pinned_leading_fade_reaches_the_top_without_stacking_shading(self):
        for y in (0, 0.1, 0.34, 0.5):
            self.assertAlmostEqual(alpha_at(0, y, pinned=True), 1 - 0.94 * 0.45)
            self.assertGreater(alpha_at(0, y, pinned=True), alpha_at(0, y))

    def test_pinned_preserves_the_lower_field_and_artwork_beyond_the_leading_fade(self):
        for x in (0, 0.05, 0.2, 0.42, 0.7, 1):
            for y in (0.62, 0.7, 0.9, 1):
                self.assertEqual(alpha_at(x, y, pinned=True), alpha_at(x, y))
        for x in (0.42, 0.5, 0.75, 1):
            for y in (0, 0.2, 0.34, 0.5, 0.8, 1):
                self.assertEqual(alpha_at(x, y, pinned=True), alpha_at(x, y))

    def test_pinned_fade_has_no_horizontal_or_vertical_seam(self):
        for x, y in ((0.42, 0.2), (0.05, 0.538), (0.05, 0.62)):
            for dx, dy in ((0.0001, 0), (0, 0.0001)):
                self.assertLess(abs(alpha_at(x - dx, y - dy, pinned=True)
                                    - alpha_at(x + dx, y + dy, pinned=True)), 0.001)

    def test_pinned_rail_has_icon_contrast_over_white_artwork_without_a_shadow(self):
        # The compact rail occupies the leading 8% of a 1920pt screen.
        for x in (0.02, 0.05, 0.08):
            background = 1 - alpha_at(x, 0, pinned=True)
            luminance = ((background + 0.055) / 1.055) ** 2.4
            self.assertGreaterEqual(1.05 / (luminance + 0.05), 3)


if __name__ == "__main__":
    unittest.main()
