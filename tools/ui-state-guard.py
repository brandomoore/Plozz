#!/usr/bin/env python3
"""Guard the UI loading-state conventions.

Two rules, both from real regressions in this repository:

1. **No time-gated loading states.** A skeleton or placeholder chosen by
   `Task.sleep` produces behaviour nobody can reproduce: it appears whenever the
   real work outruns the delay, and disappears when caching makes it faster. The
   Home page shipped 250ms -> 2s -> 6s graces and every one of them failed the same
   way; the detail rail shipped a 250ms grace and still painted a skeleton.

2. **Reserve geometry, don't invent it.** A view that shows a skeleton while its
   content loads must lay that skeleton out at the content's real height (use
   `PlozzReservedPlaceholder` in CoreUI). Suppressing the skeleton instead of
   hiding it removes the reservation and the page reflows when content lands —
   the detail page's episode rail did exactly that.

The rules are intentionally narrow: they look for the specific shapes that have
already caused reflows, not for every use of a timer or a placeholder. Run with
`--verbose` to see the evidence for each finding.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
UI_DIRS = ["Sources/AppShelliOS", "Sources/CoreUI", "Sources/FeatureHome", "Sources/HeroUI"]

# A view that mints a "loading" flag by waiting is the anti-pattern.
ARMED_PATTERN = re.compile(
    r"(?i)\b(?:skeleton|placeholder|loading|spinner)\w*\s*=\s*(?:false|true)\b"
)
SLEEP_PATTERN = re.compile(r"Task\.sleep\(\s*for:\s*\.(milliseconds|seconds)\(")

# Skeleton/placeholder views must be laid out, not swapped out entirely: a bare
# `if isLoading { Skeleton } else { content }` deletes the reservation the moment
# content is pending-but-hidden.
SKELETON_VIEW = re.compile(r"\b\w*(?:Skeleton|Placeholder)\w*\s*\(")
RESERVED_VIEW = re.compile(r"\bPlozzReservedPlaceholder\s*\(")


def rel(path: pathlib.Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def swift_files() -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for directory in UI_DIRS:
        base = ROOT / directory
        if base.is_dir():
            files.extend(sorted(base.rglob("*.swift")))
    return files


def check_time_gated_loading(path: pathlib.Path) -> list[str]:
    """A *loading affordance* must never be armed by a delay.

    Narrow on purpose: background loops, debounces and automation all sleep, and
    none of them are the problem. The problem is a flag that decides whether a
    skeleton/placeholder/spinner is painted being set after a sleep.
    """
    text = path.read_text(encoding="utf-8", errors="replace")
    if not SLEEP_PATTERN.search(text):
        return []
    loading_flag = re.compile(
        r"(?i)\b\w*(?:skeleton|placeholder|spinner)\w*\s*=\s*(?:true|false)\b"
    )
    findings: list[str] = []
    if loading_flag.search(text) and re.search(r"(?i)\b\w*Armed\b", text):
        findings.append(
            f"{rel(path)}: a skeleton/placeholder flag is armed after a "
            "sleep — derive it from state instead"
        )
    return findings


def check_reserved_geometry(path: pathlib.Path) -> list[str]:
    """Skeleton views are fine; skeletons swapped out by a boolean are not."""
    text = path.read_text(encoding="utf-8", errors="replace")
    if not SKELETON_VIEW.search(text) or RESERVED_VIEW.search(text):
        return []
    findings: list[str] = []
    for number, line in enumerate(text.splitlines(), start=1):
        # `if isLoading { SomeSkeleton() }` — the branch removes the reservation.
        if re.search(r"if\s+\w*[Ll]oading\w*\s*\{\s*$", line) and number <= len(text.splitlines()):
            following = "\n".join(text.splitlines()[number - 1:number + 2])
            if SKELETON_VIEW.search(following):
                findings.append(
                    f"{rel(path)}:{number}: skeleton shown conditionally instead of "
                    "reserved — use PlozzReservedPlaceholder so pending content keeps its space"
                )
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    findings: list[str] = []
    for path in swift_files():
        findings.extend(check_time_gated_loading(path))
        findings.extend(check_reserved_geometry(path))

    if findings:
        print("UI loading-state guard failed:\n", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        print(
            "\nSee docs/swiftui-guidelines.md (loading states, PlozzReservedPlaceholder).",
            file=sys.stderr,
        )
        return 1

    if args.verbose:
        print(f"checked {len(swift_files())} UI files: no time-gated loading state, "
              "skeletons reserve geometry")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
