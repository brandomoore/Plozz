import unittest

from tvos_bdj import validate_menu


def menu_fixture(selected):
    pixels = bytearray(b"\x10\x14\x1c" * (1280 * 720))

    def rectangle(x, y, width, height, color):
        for row in range(y, y + height):
            start = (row * 1280 + x) * 3
            pixels[start:start + width * 3] = color * width

    for episode, left in ((1, 80), (2, 660)):
        rectangle(left, 250, 520, 220,
                  b"\xff\xff\x00" if selected == episode else b"\x80\x80\x80")
        rectangle(left + 40, 320, 30, 10, b"\x00\x00\x00")
    rectangle(80, 80, 100, 10, b"\xff\xff\xff")
    return b"P6\n1280 720\n255\n" + pixels


class BDJMenuTests(unittest.TestCase):
    def test_requires_matching_selection_and_rendered_text(self):
        for selected in (1, 2):
            with self.subTest(selected=selected):
                validate_menu(menu_fixture(selected), selected)
                with self.assertRaisesRegex(ValueError, "incorrect card"):
                    validate_menu(menu_fixture(3 - selected), selected)

    def test_blank_or_missing_text_is_not_a_menu_pass(self):
        header = b"P6\n1280 720\n255\n"
        with self.assertRaises(ValueError):
            validate_menu(header + b"\x00" * (1280 * 720 * 3), 1)
        data = bytearray(menu_fixture(1))
        for y in range(70, 115):
            start = len(header) + (y * 1280 + 80) * 3
            data[start:start + 570 * 3] = b"\x10\x14\x1c" * 570
        with self.assertRaisesRegex(ValueError, "title text"):
            validate_menu(bytes(data), 1)

    def test_rejects_malformed_dimensions_truncation_and_choice(self):
        for data in (b"", b"P6\n1 1\n255\n\0\0\0", menu_fixture(1)[:-1]):
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                validate_menu(data, 1)
        with self.assertRaises(ValueError):
            validate_menu(menu_fixture(1), 3)


if __name__ == "__main__":
    unittest.main()
