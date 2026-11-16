#!/usr/bin/env python3
"""Deterministic CI shard planner.

GitHub Actions jobs on the free runners are capped (3600s), and both heavy lanes
used to exceed that in a single job. This splits their work without maintaining a
second list of tests:

  package  -- test targets discovered from `swift package dump-package`
  focus    -- XCTestCase classes compiled into the PlozzFocusTests target, read
              from the paths listed for that target in project.yml

Both modes print one selection per line, in a stable order, and partition the
whole set exactly once across `--count` shards (`--index` is 1-based). Stable
ordering matters: a shard that moves between runs makes cache keys and failures
unreproducible.

Usage:
  ci-shards.py package --index 1 --count 3     -> target names, one per line
  ci-shards.py focus   --index 2 --count 3     -> -only-testing args, one per line
  ci-shards.py package --count 3 --verify      -> coverage summary, exits non-zero
                                                  if the shards do not partition
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def package_test_targets() -> list[str]:
    manifest = subprocess.run(
        ["swift", "package", "dump-package"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    data = json.loads(manifest.stdout)
    targets = [t["name"] for t in data.get("targets", []) if t.get("type") == "test"]
    if not targets:
        sys.exit("ci-shards.py: no test targets found in Package.swift")
    return sorted(targets)


def focus_source_paths() -> list[pathlib.Path]:
    """Paths declared for the PlozzFocusTests target in project.yml."""
    lines = (ROOT / "project.yml").read_text().splitlines()
    paths: list[pathlib.Path] = []
    inside = False
    for line in lines:
        if re.match(r"^  PlozzFocusTests:\s*$", line):
            inside = True
            continue
        if inside and re.match(r"^  [A-Za-z0-9_]+:\s*$", line):
            break
        if inside:
            match = re.match(r"^\s*-\s*path:\s*(\S+)\s*$", line)
            if match:
                paths.append(ROOT / match.group(1))
    if not paths:
        sys.exit("ci-shards.py: could not read PlozzFocusTests sources from project.yml")
    return paths


def focus_test_classes() -> list[str]:
    class_re = re.compile(r"^\s*(?:final\s+|public\s+|internal\s+)*class\s+(\w+)\s*:\s*[^X\n]*XCTestCase\b", re.M)
    classes: set[str] = set()
    for path in focus_source_paths():
        files = [path] if path.is_file() else sorted(path.rglob("*.swift"))
        for file in files:
            try:
                text = file.read_text()
            except (OSError, UnicodeDecodeError):
                continue
            classes.update(class_re.findall(text))
    if not classes:
        sys.exit("ci-shards.py: no XCTestCase classes found for the focus target")
    return sorted(classes)


def partition(items: list[str], index: int, count: int) -> list[str]:
    if count < 1:
        sys.exit("ci-shards.py: --count must be >= 1")
    if not 1 <= index <= count:
        sys.exit(f"ci-shards.py: --index {index} outside 1..{count}")
    # Round-robin over a sorted list: deterministic, and balanced by construction
    # rather than by hand-maintained grouping.
    return [item for position, item in enumerate(items) if position % count == index - 1]


def verify(items: list[str], count: int) -> int:
    shards = [partition(items, index, count) for index in range(1, count + 1)]
    seen = [item for shard in shards for item in shard]
    duplicates = {item for item in seen if seen.count(item) > 1}
    missing = set(items) - set(seen)
    for index, shard in enumerate(shards, start=1):
        print(f"shard {index}/{count}: {len(shard)} items")
    if duplicates or missing:
        print(f"FAIL duplicates={sorted(duplicates)} missing={sorted(missing)}", file=sys.stderr)
        return 1
    print(f"OK {len(items)} items partitioned across {count} shards")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=["package", "focus"])
    parser.add_argument("--index", type=int, default=1)
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()

    if args.kind == "package":
        items = package_test_targets()
        select = lambda item: item
    else:
        items = focus_test_classes()
        select = lambda item: f"-only-testing:PlozzFocusTests/{item}"

    if args.verify:
        return verify(items, args.count)

    for item in partition(items, args.index, args.count):
        print(select(item))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
