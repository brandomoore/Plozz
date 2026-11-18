import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

SPEC = importlib.util.spec_from_file_location(
    "multiview_symbols", Path(__file__).resolve().parents[1] / "generate-multiview-symbols.py")
symbols = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(symbols)


class MultiviewSymbolsTests(unittest.TestCase):
    def test_every_master_contains_exactly_the_displayed_picture_count(self):
        names = set()
        namespace = {"svg": "http://www.w3.org/2000/svg"}
        for name, rectangles, filled in symbols.layouts():
            self.assertNotIn(name, names)
            names.add(name)
            count = int(name.split(".")[2])
            self.assertEqual(len(rectangles), count)
            root = ET.fromstring(symbols.symbol_svg(name, rectangles, filled))
            for weight, _ in symbols.WEIGHTS:
                paths = root.findall(f".//svg:g[@id='{weight}-S']/svg:path", namespace)
                self.assertEqual(len(paths), count)
            for x, y, width, height in rectangles:
                self.assertGreater(width, 0)
                self.assertGreater(height, 0)
                self.assertGreaterEqual(x, 0)
                self.assertGreaterEqual(y, 0)
                self.assertLessEqual(x + width, symbols.WIDTH)
                self.assertLessEqual(y + height, symbols.HEIGHT)
        self.assertEqual(len(names), 40)

    def test_corner_pictures_stay_clear_of_every_outline_weight(self):
        for count in range(2, 5):
            for corner in ("topLeading", "topTrailing", "bottomLeading", "bottomTrailing"):
                for _, fraction in symbols.INSET_SIZES:
                    for _, thickness in symbols.WEIGHTS:
                        _, *insets = symbols.corner_rectangles(count, corner, fraction, margin=thickness + 4)
                        for x, y, width, height in insets:
                            self.assertGreater(width, 0)
                            self.assertGreater(height, 0)
                            self.assertGreaterEqual(x, thickness + 3.99)
                            self.assertGreaterEqual(y, thickness + 3.99)
                            self.assertLessEqual(x + width, symbols.WIDTH - thickness - 3.99)
                            self.assertLessEqual(y + height, symbols.HEIGHT - thickness - 3.99)
                        for first, second in zip(insets, insets[1:]):
                            self.assertAlmostEqual(second[1] - first[1] - first[3], 5)

    def test_corner_and_stack_symbols_preserve_actual_arrangement(self):
        for name, rectangles, _ in symbols.layouts():
            if ".main-and-stack." in name:
                main, *stack = rectangles
                self.assertTrue(all(rect[0] > main[0] + main[2] for rect in stack))
                self.assertTrue(all(rect[2] < main[2] for rect in stack))
            elif ".corner." in name:
                _, *stack = rectangles
                corner = name.split(".")[3]
                for x, _, width, _ in stack:
                    if corner.endswith("Leading"):
                        self.assertLess(x + width / 2, symbols.WIDTH / 2)
                    else:
                        self.assertGreater(x + width / 2, symbols.WIDTH / 2)
                if corner.startswith("top"):
                    self.assertEqual(stack[0][1], 8)
                else:
                    self.assertAlmostEqual(stack[-1][1] + stack[-1][3], symbols.HEIGHT - 8)
            else:
                continue
            for first, second in zip(stack, stack[1:]):
                self.assertLess(first[1] + first[3], second[1])


if __name__ == "__main__":
    unittest.main()
