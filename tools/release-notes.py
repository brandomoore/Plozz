#!/usr/bin/env python3
"""Validate and render Plozz's committed release-notes catalog."""

from __future__ import annotations

import argparse
from datetime import date
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CATALOG = ROOT / "App" / "Resources" / "ReleaseNotes.json"
CATEGORIES = ("New", "Updated", "Fixed")
PLATFORMS = ("tvOS", "iOS")


def fail(message: str) -> None:
    raise ValueError(message)


def marketing_version(release: dict[str, Any]) -> str:
    return release.get("marketingVersion", release["version"])


def build_parts(value: Any) -> tuple[int, int, int]:
    if type(value) not in (int, str) or not re.fullmatch(
        r"[1-9][0-9]{0,3}(?:\.(?:0|[1-9][0-9]?)){0,2}", str(value)
    ):
        fail(f"invalid build: {value}")
    parts = tuple(int(part) for part in str(value).split("."))
    return (parts + (0, 0))[:3]


def release_tag(build: int | str) -> str:
    build_parts(build)
    parts = str(build).split(".")
    return "release/" + ".".join([f"{int(parts[0]):03d}", *parts[1:]])


def version_parts(value: Any, counts: tuple[int, ...]) -> tuple[int, ...]:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", value):
        fail(f"invalid version: {value}")
    parts = tuple(int(part) for part in value.split("."))
    if len(parts) not in counts:
        fail(f"invalid version: {value}")
    return parts


def normalized_item(item: Any, release_id: str) -> tuple[str, list[str] | None]:
    if isinstance(item, str):
        return item, None
    if not isinstance(item, dict):
        fail(f"{release_id} contains an invalid release-note item")

    text = item.get("text")
    platforms = item.get("platforms")
    if platforms is not None:
        if not isinstance(platforms, list) or not platforms:
            fail(f"{release_id} contains an item with no platforms")
        if any(platform not in PLATFORMS for platform in platforms):
            fail(f"{release_id} contains an unknown platform")
        if len(set(platforms)) != len(platforms):
            fail(f"{release_id} repeats a platform on an item")
    return text, platforms


def load_catalog(path: Path) -> dict[str, Any]:
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"release-notes catalog not found: {path}")
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {path}: {error}")

    if catalog.get("schemaVersion") != 1:
        fail("schemaVersion must be 1")
    releases = catalog.get("releases")
    if not isinstance(releases, list):
        fail("releases must be an array")

    ids: set[str] = set()
    builds: set[tuple[int, int, int]] = set()
    previous_build: tuple[int, int, int] | None = None
    previous_version: tuple[int, ...] | None = None
    previous_marketing_version: tuple[int, ...] | None = None
    for release in releases:
        if not isinstance(release, dict):
            fail("every release must be an object")
        release_id = release.get("id")
        build = release.get("build")
        version = release.get("version")
        released_at = release.get("releasedAt")
        sections = release.get("sections")

        build_tuple = build_parts(build)
        if release_id != release_tag(build):
            fail(f"{release_id} does not match build {build}")
        if release_id in ids:
            fail(f"duplicate release id: {release_id}")
        if build_tuple in builds:
            fail(f"duplicate release build: {build}")
        if previous_build is not None and build_tuple >= previous_build:
            fail("releases must be sorted by descending build")
        version_tuple = version_parts(version, (3,))
        apple_version = version_parts(marketing_version(release), (3,))
        if "marketingVersion" in release:
            if version != ".".join(map(str, version_tuple)):
                fail(f"{release_id} has an invalid release date version")
            if not 1 <= version_tuple[0] <= 9999:
                fail(f"{release_id} has an invalid release year")
            if date(*version_tuple).isoformat() != released_at:
                fail(f"{release_id} version date must match releasedAt")
        if previous_version is not None and version_tuple > previous_version:
            fail("release versions must be sorted newest first")
        if previous_marketing_version is not None and apple_version > previous_marketing_version:
            fail("Apple marketing versions must be sorted newest first")
        if not isinstance(released_at, str) or not re.fullmatch(
            r"\d{4}-\d{2}-\d{2}", released_at
        ):
            fail(f"{release_id} has an invalid releasedAt date")
        if not isinstance(sections, list) or not sections:
            fail(f"{release_id} must have release-note sections")

        section_names = [section.get("category") for section in sections]
        expected = [category for category in CATEGORIES if category in section_names]
        if section_names != expected:
            fail(f"{release_id} sections must follow New, Updated, Fixed order")
        for section in sections:
            items = section.get("items")
            if not isinstance(items, list) or not items:
                fail(f"{release_id} {section.get('category')} section is empty")
            normalized = [
                normalized_item(item, release_id)
                for item in items
            ]
            if any(not isinstance(text, str) or not text.strip() for text, _ in normalized):
                fail(f"{release_id} contains an empty release-note item")
            if len({text for text, _ in normalized}) != len(normalized):
                fail(f"{release_id} repeats a release-note item")

        ids.add(release_id)
        builds.add(build_tuple)
        previous_build = build_tuple
        previous_version = version_tuple
        previous_marketing_version = apple_version

    return catalog


def selected_release(
    catalog: dict[str, Any],
    release_id: str,
    version: str | None,
    build: int | str | None,
) -> dict[str, Any]:
    release = next(
        (entry for entry in catalog["releases"] if entry["id"] == release_id),
        None,
    )
    if release is None:
        fail(f"release id {release_id} is not in the catalog")
    if version is not None and marketing_version(release) != version:
        fail(
            f"{release_id} uses Apple version {marketing_version(release)}, "
            f"but the build is Apple version {version}"
        )
    if build is not None and str(release["build"]) != str(build):
        fail(
            f"{release_id} is build {release['build']}, "
            f"but App Store Connect assigned build {build}"
        )
    return release


def build_identity(
    catalog: dict[str, Any], release_id: str | None, version: str | None, build: int | str | None
) -> dict[str, str]:
    if not catalog["releases"]:
        fail("A committed release is required to determine the stable Apple version")
    if release_id:
        release = selected_release(catalog, release_id, version, build)
        return {
            "marketingVersion": marketing_version(release),
            "releaseVersion": release["version"],
            "releaseID": release["id"],
        }
    apple_version = version or marketing_version(catalog["releases"][0])
    version_parts(apple_version, (3,))
    return {"marketingVersion": apple_version, "releaseVersion": "", "releaseID": ""}


def next_release_version(catalog: dict[str, Any], day: date) -> str:
    version = (day.year, day.month, day.day)
    for release in catalog["releases"]:
        if version_parts(release["version"], (3,)) > version:
            fail("Release date precedes an existing release version")
    return ".".join(map(str, version))


def render(
    release: dict[str, Any], platform: str | None = None, empty_text: str | None = None
) -> str:
    blocks = []
    for section in release["sections"]:
        visible = []
        for item in section["items"]:
            text, platforms = normalized_item(item, release["id"])
            if platform is None or platforms is None or platform in platforms:
                visible.append(text)
        if not visible:
            continue
        items = "\n".join(f"• {item}" for item in visible)
        blocks.append(f"{section['category']}\n{items}")
    text = "\n\n".join(blocks) if blocks else empty_text or ""
    if text and "marketingVersion" in release:
        return f"Plozz {release['version']} ({release['build']})\n\n{text}"
    return text


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    subparsers = result.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--release-id")
    validate.add_argument("--version", help="Expected Apple marketing version")
    validate.add_argument("--build")

    render_command = subparsers.add_parser("render")
    render_command.add_argument("--release-id", required=True)
    render_command.add_argument("--platform", choices=PLATFORMS)
    render_command.add_argument("--empty-text", help="Explicit no-change fallback for an empty platform")
    identity = subparsers.add_parser("identity")
    identity.add_argument("--release-id")
    identity.add_argument("--version", help="Explicit Apple marketing version override")
    identity.add_argument("--build")
    next_version = subparsers.add_parser("next-version")
    next_version.add_argument("--date", type=date.fromisoformat, default=date.today())
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        catalog = load_catalog(args.catalog)
        if args.command == "validate":
            if args.release_id:
                release = selected_release(
                    catalog,
                    args.release_id,
                    args.version,
                    args.build,
                )
                print(
                    f"Validated {release['id']} "
                    f"(version {release['version']}, build {release['build']})"
                )
            else:
                print(f"Validated {len(catalog['releases'])} releases")
        elif args.command == "identity":
            print(json.dumps(build_identity(catalog, args.release_id, args.version, args.build)))
        elif args.command == "next-version":
            print(next_release_version(catalog, args.date))
        else:
            release = selected_release(catalog, args.release_id, None, None)
            rendered = render(release, args.platform, args.empty_text)
            if args.platform is not None and not rendered:
                print(
                    f"warning: {release['id']} has no {args.platform} notes",
                    file=sys.stderr,
                )
            print(rendered)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
