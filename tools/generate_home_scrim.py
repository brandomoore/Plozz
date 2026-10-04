#!/usr/bin/env python3
"""Bake the shared Home/detail legibility alpha field; never bake artwork or theme color."""

import argparse
from pathlib import Path

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Sources/CoreUI/Resources/HeroAssets.xcassets"
SIDE_STOPS = [(0, 0), (0.34, 0.35), (0.62, 1)]
BOTTOM_STOPS = [
    (0, 0), (0.538, 0), (0.5968, 0.0055), (0.6556, 0.022),
    (0.7228, 0.066), (0.8068, 0.154), (0.8908, 0.286),
    (0.958, 0.418), (1, 0.55),
]


def interpolate(stops, position):
    if position <= stops[0][0]:
        return stops[0][1]
    for (left, a), (right, b) in zip(stops, stops[1:]):
        if position <= right:
            return a + (b - a) * (position - left) / (right - left)
    return stops[-1][1]


def alpha_at(x, y, pinned=False):
    """Match HeroLegibilityScrim: side start 0 when pinned, otherwise .34."""
    side = max(0, 0.55 * (1 - x / 0.42))
    side *= 1 if pinned else interpolate(SIDE_STOPS, y)
    bottom = interpolate(BOTTOM_STOPS, y)
    return 1 - (1 - 0.06) * (1 - side) * (1 - bottom)


def render(width, height, pinned=False):
    pixels = bytearray(width * height * 4)
    sides = [max(0, 0.55 * (1 - (x + 0.5) / width / 0.42)) for x in range(width)]
    for y in range(height):
        position = (y + 0.5) / height
        mask = 1 if pinned else interpolate(SIDE_STOPS, position)
        transmission = 0.94 * (1 - interpolate(BOTTOM_STOPS, position))
        row = bytearray(b"\xff\xff\xff\x00" * width)
        row[3::4] = bytes(
            round((1 - transmission * (1 - side * mask)) * 255)
            for side in sides
        )
        pixels[y * width * 4:(y + 1) * width * 4] = row
    return Image.frombytes("RGBA", (width, height), bytes(pixels))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify asset pixels without writing")
    args = parser.parse_args()
    for pinned in (False, True):
        name = "HomeHeroLegibilityPinned" if pinned else "HomeHeroLegibility"
        output = ASSETS / f"{name}.imageset"
        for scale in (1, 2):
            image = render(1920 * scale, 1080 * scale, pinned=pinned)
            destination = output / f"home-legibility@{scale}x.png"
            if args.check:
                with Image.open(destination) as existing:
                    if existing.size != image.size or ImageChops.difference(
                        existing.convert("RGBA").getchannel("A"), image.getchannel("A")
                    ).getbbox():
                        raise SystemExit(f"Stale scrim asset: {destination}")
                print(f"Verified {name}/{destination.name}")
            else:
                output.mkdir(parents=True, exist_ok=True)
                image.save(destination, optimize=True)
                print(f"Wrote {name}/{destination.name}: {destination.stat().st_size} bytes")


if __name__ == "__main__":
    main()
