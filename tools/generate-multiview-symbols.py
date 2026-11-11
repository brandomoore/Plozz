#!/usr/bin/env python3
"""Generate original, count-aware SF Symbol assets for Multiview layouts."""

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Sources/CoreUI/Resources/MultiviewSymbols.xcassets"
WIDTH, HEIGHT = 110.0, 78.0
# Calibrated against rendered rectangle.split.2x1 outlines at matching size/scale.
WEIGHTS = (("Ultralight", 2.55), ("Regular", 8.1), ("Black", 15.8))
INSET_SIZES = (("small", 0.25), ("medium", 0.32), ("large", 0.40))


def rounded_rect(x, y, width, height, radius, reverse=False):
    """Closed paths with matching control points across interpolation masters."""
    right, bottom = x + width, y + height
    r = min(radius, width / 2, height / 2)
    if reverse:
        commands = (
            f"M{x+r},{y} Q{x},{y} {x},{y+r} L{x},{bottom-r} "
            f"Q{x},{bottom} {x+r},{bottom} L{right-r},{bottom} "
            f"Q{right},{bottom} {right},{bottom-r} L{right},{y+r} "
            f"Q{right},{y} {right-r},{y} Z"
        )
    else:
        commands = (
            f"M{x+r},{y} L{right-r},{y} Q{right},{y} {right},{y+r} "
            f"L{right},{bottom-r} Q{right},{bottom} {right-r},{bottom} "
            f"L{x+r},{bottom} Q{x},{bottom} {x},{bottom-r} "
            f"L{x},{y+r} Q{x},{y} {x+r},{y} Z"
        )
    return commands


def picture_path(rect, thickness, filled=False):
    x, y, width, height = rect
    radius = min(9, width / 5, height / 5)
    outer = rounded_rect(x, y, width, height, radius)
    if filled:
        return outer
    inset = min(thickness, min(width, height) / 2 - 1)
    inner = rounded_rect(
        x + inset, y + inset, width - 2 * inset, height - 2 * inset,
        max(1, radius - inset), reverse=True,
    )
    return outer + " " + inner


def corner_rectangles(count, corner, fraction, margin):
    side_count = count - 1
    width = min(WIDTH * fraction, (HEIGHT - 2 * margin - 5 * (side_count - 1)) / side_count * 1.4)
    height = width / 1.4
    x = margin if corner.endswith("Leading") else WIDTH - margin - width
    top = margin if corner.startswith("top") else HEIGHT - margin - side_count * height - 5 * (side_count - 1)
    return [(0, 0, WIDTH, HEIGHT)] + [
        (x, top + i * (height + 5), width, height) for i in range(side_count)
    ]


def layouts():
    yield "multiview.grid.3", [(0, 0, 51, 35), (59, 0, 51, 35), (29.5, 43, 51, 35)], False
    for count in range(2, 5):
        side_count = count - 1
        side_height = (HEIGHT - 8 * (max(2, side_count) - 1)) / max(2, side_count)
        top = (HEIGHT - side_count * side_height - (side_count - 1) * 8) / 2
        rectangles = [(0, 0, 72, HEIGHT)]
        rectangles += [(80, top + i * (side_height + 8), 30, side_height) for i in range(side_count)]
        yield f"multiview.main-and-stack.{count}", rectangles, False
        for corner in ("topLeading", "topTrailing", "bottomLeading", "bottomTrailing"):
            for size, fraction in INSET_SIZES:
                rectangles = corner_rectangles(count, corner, fraction, margin=8)
                yield f"multiview.corner.{count}.{corner}.{size}", rectangles, True


def symbol_svg(name, rectangles, filled_insets):
    # SF Symbols interpolates other weights/scales from these compatible masters.
    guides, symbols = [], []
    for index, (weight, thickness) in enumerate(WEIGHTS):
        weight_rectangles = rectangles
        if filled_insets:
            _, _, count, corner, size = name.split(".")
            weight_rectangles = corner_rectangles(int(count), corner, dict(INSET_SIZES)[size], margin=thickness + 4)
        x, baseline = 400 + index * 400, 500
        variant = f"{weight}-S"
        guides += [
            f'<line id="left-margin-{variant}" x1="{x-5}" x2="{x-5}" y1="350" y2="550"/>',
            f'<line id="right-margin-{variant}" x1="{x+WIDTH+5}" x2="{x+WIDTH+5}" y1="350" y2="550"/>',
        ]
        paths = "\n".join(
            f'      <path d="{picture_path(rect, thickness, filled_insets and i > 0)}"/>'
            for i, rect in enumerate(weight_rectangles)
        )
        symbols.append(f'    <g id="{variant}" transform="translate({x} {baseline-HEIGHT})">\n{paths}\n    </g>')
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" width="1800" height="1600" viewBox="0 0 1800 1600">\n'
        '  <g id="Notes"><text id="template-version">3.0</text></g>\n'
        '  <g id="Guides" fill="none" stroke="#00AEEF" stroke-width="0.5">\n'
        '    <line id="Baseline-S" x1="0" x2="1800" y1="500" y2="500"/>\n'
        '    <line id="Capline-S" x1="0" x2="1800" y1="420" y2="420"/>\n'
        '    <line id="Baseline-M" x1="0" x2="1800" y1="1000" y2="1000"/>\n'
        '    <line id="Capline-M" x1="0" x2="1800" y1="920" y2="920"/>\n'
        '    <line id="Baseline-L" x1="0" x2="1800" y1="1500" y2="1500"/>\n'
        '    <line id="Capline-L" x1="0" x2="1800" y1="1420" y2="1420"/>\n'
        + "\n".join("    " + guide for guide in guides) + '\n  </g>\n'
        '  <g id="Symbols" fill="black">\n' + "\n".join(symbols) + '\n  </g>\n</svg>\n'
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify committed assets without writing.")
    args = parser.parse_args()
    files = {CATALOG / "Contents.json": json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n"}
    for name, rectangles, filled in layouts():
        folder = CATALOG / f"{name}.symbolset"
        files[folder / "Contents.json"] = json.dumps({
            "info": {"author": "xcode", "version": 1},
            "symbols": [{"filename": "symbol.svg", "idiom": "universal"}],
        }, indent=2) + "\n"
        files[folder / "symbol.svg"] = symbol_svg(name, rectangles, filled)
    for path, content in files.items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit(f"Generated symbol differs: {path.relative_to(ROOT)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    print(f"{'Verified' if args.check else 'Generated'} {(len(files) - 1) // 2} Multiview symbols.")


if __name__ == "__main__":
    main()
