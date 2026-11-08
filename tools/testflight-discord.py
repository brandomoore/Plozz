#!/usr/bin/env python3
"""Announce externally available TestFlight builds using the existing Plozz bot."""

from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import sys
import time
from urllib.parse import parse_qsl, quote, urlsplit


ROOT = Path(__file__).resolve().parents[1]


def load_tool(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "tools" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BRIDGE = load_tool("discord-bridge")
NOTES = load_tool("release-notes")
Error = BRIDGE.BridgeError
CHANNEL = "1560139816757235762"
BUNDLE = "com.thatcube.Plozz"
GROUP = "Plozz External"
TESTFLIGHT = "https://testflight.apple.com/join/EKfReNMu"
ROADMAP = "https://plozz.app/roadmap/"
PLATFORMS = {"TV_OS": "Apple TV", "IOS": "iPhone and iPad"}
NOTE_PLATFORMS = {"TV_OS": "tvOS", "IOS": "iOS"}
DESCRIPTION_LIMIT = 4096


def apple_token():
    import jwt

    required = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY")
    if any(not os.environ.get(key) for key in required):
        raise Error("Missing App Store Connect announcement credentials.")
    now = int(time.time())
    try:
        return jwt.encode(
            {"iss": os.environ["ASC_ISSUER_ID"], "iat": now - 30, "exp": now + 600, "aud": "appstoreconnect-v1"},
            os.environ["ASC_PRIVATE_KEY"],
            algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
        )
    except (ValueError, TypeError, jwt.PyJWTError):
        raise Error("Could not sign the App Store Connect token; check the configured key.") from None


def apple_collection(apple, path, query=None):
    data, included, visited = [], {}, set()
    for _ in range(100):
        cursor = (path, json.dumps(query, sort_keys=True))
        if cursor in visited:
            raise Error("App Store Connect pagination made no progress.")
        visited.add(cursor)
        page = apple.call("GET", path, query=query)
        if not isinstance(page.get("data"), list):
            raise Error("App Store Connect returned an invalid collection.")
        data.extend(page["data"])
        for item in page.get("included", []):
            key = (item["type"], item["id"])
            if key in included and included[key] != item:
                raise Error("App Store Connect changed related data during pagination; retry the check.")
            included[key] = item
        next_url = page.get("links", {}).get("next")
        if not next_url:
            return data, included
        url = urlsplit(next_url)
        if url.scheme != "https" or url.netloc != "api.appstoreconnect.apple.com" or not url.path.startswith("/v1/") or url.fragment:
            raise Error("Refused an App Store Connect pagination link outside its API.")
        path, query = url.path.removeprefix("/v1"), dict(parse_qsl(url.query))
    raise Error("App Store Connect pagination exceeded the run budget.")


def only(items, label):
    if len(items) != 1:
        raise Error(f"Expected exactly one {label}.")
    return items[0]


def related(build, name, included):
    reference = build.get("relationships", {}).get(name, {}).get("data")
    if not isinstance(reference, dict) or (reference.get("type"), reference.get("id")) not in included:
        raise Error(f"App Store Connect omitted {name}; refusing an unverified availability claim.")
    return included[(reference["type"], reference["id"])]["attributes"]


def available_builds(apple, minimum):
    apps, _ = apple_collection(apple, "/apps", {"filter[bundleId]": BUNDLE, "limit": 200})
    app = only(apps, "Plozz App Store Connect app")
    groups, _ = apple_collection(apple, f"/apps/{quote(app['id'], safe='')}/betaGroups", {"limit": 200})
    group = only([
        group for group in groups if group["attributes"].get("name") == GROUP
        and group["attributes"].get("isInternalGroup") is False
    ], "Plozz external beta group")
    if group["attributes"].get("publicLink") != TESTFLIGHT or group["attributes"].get("publicLinkEnabled") is not True:
        raise Error("The configured external group's public TestFlight link is not enabled or does not match.")
    members, _ = apple_collection(
        apple, f"/betaGroups/{quote(group['id'], safe='')}/builds",
        {"limit": 200},
    )
    member_ids = {item["id"] for item in members}
    numbers = {
        item["attributes"]["version"] for item in members
        if NOTES.build_parts(item["attributes"]["version"]) >= minimum
        and item["attributes"].get("expired") is False
        and item["attributes"].get("processingState") == "VALID"
    }
    builds, included = [], {}
    # Apple's broad build queries can omit included details for older rows.
    for number in sorted(numbers, key=NOTES.build_parts):
        batch, relationships = apple_collection(
            apple, "/builds",
            {"filter[app]": app["id"], "filter[version]": number,
             "include": "preReleaseVersion,buildBetaDetail", "limit": 200},
        )
        builds.extend(batch)
        included.update(relationships)
    releases = {}
    for build in builds:
        if build["id"] not in member_ids:
            continue
        attributes = build["attributes"]
        number = attributes["version"]
        parts = NOTES.build_parts(number)
        if parts < minimum or attributes.get("expired") is not False or attributes.get("processingState") != "VALID":
            continue
        version = related(build, "preReleaseVersion", included)
        platform = version["platform"]
        if platform not in PLATFORMS:
            continue
        detail = related(build, "buildBetaDetail", included)
        if detail.get("externalBuildState") != "IN_BETA_TESTING":
            continue
        marketing = version["version"]
        NOTES.version_parts(marketing, (3,))
        key = (marketing, parts)
        release = releases.setdefault(key, {"marketing": marketing, "build": number, "platforms": set()})
        if platform in release["platforms"]:
            raise Error("Duplicate available builds have the same platform and release identity.")
        release["platforms"].add(platform)
    return sorted(releases.values(), key=lambda release: (NOTES.version_parts(release["marketing"], (3,)), NOTES.build_parts(release["build"])))


def inspect_channel(discord):
    user = discord.call("GET", "/users/@me")
    if user.get("id") != BRIDGE.BOT or user.get("bot") is not True:
        raise Error("The Discord credential does not identify the configured Plozz bot.")
    channel = discord.call("GET", f"/channels/{CHANNEL}")
    if channel.get("id") != CHANNEL or channel.get("guild_id") != BRIDGE.GUILD or channel.get("type") not in (0, 5):
        raise Error("The announcement channel is unavailable, has the wrong type, or belongs to another server.")
    BRIDGE.require_channel_permissions(discord, channel, {
        "View Channel": 10, "Send Messages": 11, "Embed Links": 14, "Read Message History": 16,
    })
    return channel


def published_release(build, github_releases):
    matches = [
        item for item in github_releases
        if item.get("tag_name") == NOTES.release_tag(build) and item.get("draft") is False
    ]
    if len(matches) > 1:
        raise Error("Duplicate published GitHub releases have the same release tag.")
    return matches[0] if matches else None


def announcement_catalog(release, catalog, github_releases, github):
    if published_release(release["build"], github_releases) is None:
        return catalog
    tag = NOTES.release_tag(release["build"])
    response = github.call(
        "GET", f"/repos/{BRIDGE.REPO}/contents/App/Resources/ReleaseNotes.json",
        query={"ref": f"refs/tags/{tag}"},
    )
    if (
        not isinstance(response, dict) or response.get("type") != "file"
        or response.get("encoding") != "base64" or not isinstance(response.get("content"), str)
    ):
        raise Error("GitHub returned an invalid tagged release catalog.")
    try:
        content = base64.b64decode("".join(response["content"].split()), validate=True)
        tagged = NOTES.validate_catalog(json.loads(content.decode("utf-8")))
        entry = NOTES.selected_release(tagged, tag, release["marketing"], None)
        if NOTES.build_parts(entry["build"]) != NOTES.build_parts(release["build"]):
            raise ValueError("Tagged build does not match TestFlight.")
    except (ValueError, KeyError, TypeError):
        raise Error("The tagged release catalog is invalid or does not match the TestFlight build.") from None
    return tagged


def with_release_notes(description, entry, platforms, url):
    parts = []
    for section in entry["sections"]:
        first = True
        for item in section["items"]:
            text, scope = NOTES.normalized_item(item, entry["id"])
            visible = [
                platform for platform in PLATFORMS
                if platform in platforms and (scope is None or NOTE_PLATFORMS[platform] in scope)
            ]
            if not visible:
                continue
            prefix = ""
            if set(visible) != platforms:
                prefix = f"**{' and '.join(PLATFORMS[platform] for platform in visible)}:** "
            heading = f"\n\n**{section['category']}**" if first else ""
            parts.append(f"{heading}\n• {prefix}{text}")
            first = False
    if not parts:
        return description + "\n\nNo changes for this platform in this build."
    # Discord counts astral characters as two UTF-16 units.
    units = lambda value: len(value.encode("utf-16-le")) // 2
    complete = description + "".join(parts)
    if units(complete) <= DESCRIPTION_LIMIT:
        return complete
    notice = f"\n\nNotes shortened to fit Discord. [Read the full release notes]({url})."
    if units(description + notice) > DESCRIPTION_LIMIT:
        raise Error("Announcement links exceed Discord's description limit.")
    for part in parts:
        if units(description + part + notice) > DESCRIPTION_LIMIT:
            break
        description += part
    return description + notice


def announcement(release, catalog, github_releases, *, roadmap_enabled=False):
    build, marketing = release["build"], release["marketing"]
    entries = [
        entry for entry in catalog["releases"]
        if NOTES.build_parts(entry["build"]) == NOTES.build_parts(build)
        and NOTES.marketing_version(entry) == marketing
    ]
    label = f"{entries[0]['version']} ({build})" if entries else f"build {build}"
    tag = NOTES.release_tag(build)
    platforms = " and ".join(f"**{label}**" for platform, label in PLATFORMS.items() if platform in release["platforms"])
    description = f"Available now for {platforms}.\n\n[Update in TestFlight]({TESTFLIGHT})"
    if roadmap_enabled:
        description += f" | [Roadmap]({ROADMAP})"
    if published_release(build, github_releases) is not None:
        url = f"https://github.com/{BRIDGE.REPO}/releases/tag/{tag}"
        description += f" | [Full release notes]({url})"
        description = with_release_notes(
            description, only(entries, "matching tagged release-note entry"), release["platforms"], url,
        )
    else:
        description += "\nRelease notes are available in TestFlight."
    return {
        "title": f"Plozz {label} is on TestFlight",
        "description": description,
        "url": TESTFLIGHT,
    }


def synchronize(discord, apple, github, catalog, minimum, *, publish=False, roadmap_enabled=False):
    channel = inspect_channel(discord)
    releases = available_builds(apple, minimum)
    github_releases = github.pages(f"/repos/{BRIDGE.REPO}/releases")
    messages = BRIDGE.thread_messages(discord, CHANNEL)
    for release in releases:
        selected_catalog = announcement_catalog(release, catalog, github_releases, github)
        embed = announcement(release, selected_catalog, github_releases, roadmap_enabled=roadmap_enabled)
        key = f"testflight:{release['marketing']}:{'.'.join(map(str, NOTES.build_parts(release['build'])))}"
        if publish:
            BRIDGE.discord_upsert(discord, channel, messages, key, embed)
        print(json.dumps({"build": release["build"], "platforms": sorted(release["platforms"]), "mode": "sync" if publish else "check", "announcement": embed}))
    print(f"Verified {len(releases)} externally available TestFlight releases.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("check", "sync"), default="check")
    args = parser.parse_args()
    try:
        minimum = NOTES.build_parts(os.environ.get("TESTFLIGHT_DISCORD_MIN_BUILD", ""))
        if args.mode == "sync" and os.environ.get("TESTFLIGHT_DISCORD_ENABLED") != "true":
            raise Error("TestFlight Discord announcements are not explicitly enabled.")
        synchronize(
            BRIDGE.API("Discord", os.environ.get("DISCORD_BOT_TOKEN"), write=args.mode == "sync"),
            BRIDGE.API("App Store Connect", apple_token()),
            BRIDGE.API("GitHub", os.environ.get("GITHUB_TOKEN")),
            NOTES.load_catalog(NOTES.DEFAULT_CATALOG), minimum, publish=args.mode == "sync",
            roadmap_enabled=os.environ.get("DISCORD_ROADMAP_LINK_ENABLED") == "true",
        )
    except (Error, ValueError, KeyError, TypeError) as error:
        if isinstance(error, Error):
            print(f"ERROR: {error}", file=sys.stderr)
        else:
            print("ERROR: Invalid release configuration or API response; no unverified announcement was sent.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
