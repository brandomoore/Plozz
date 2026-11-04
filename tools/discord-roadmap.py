#!/usr/bin/env python3
"""Maintain a deterministic Discord view of GitHub issues and verified delivery."""

from __future__ import annotations

import argparse
from datetime import datetime
from functools import lru_cache
import os
from pathlib import Path
import re
import runpy
import sys
from urllib.parse import quote


RES = runpy.run_path(str(Path(__file__).with_name("testflight-resolutions.py")))
ANN = RES["ANNOUNCEMENTS"]
BRIDGE = ANN.BRIDGE
Error = BRIDGE.BridgeError
CHANNEL = "1567621289106219069"
MAINTAINER = "brandomoore"
STAGES = ("Backlog", "Planned", "In progress", "In beta", "Released")
COMMITMENT_LABELS = {"roadmap: planned": "Planned", "roadmap: in progress": "In progress"}
PREFIX = "roadmap:v1:"
GUIDE = (
    "GitHub is the canonical backlog. This board includes bugs and feature requests.\n\n"
    "**Backlog:** tracked, not a commitment.\n"
    "**Planned / In progress:** chosen by Brandon, without promised dates.\n"
    "**In beta:** available to external TestFlight testers on every affected platform "
    "(or already released on one of them).\n"
    "**Released:** verified App Store availability on every affected platform.\n\n"
    "Bug-assessment labels are separate from these stages. A merge or closed issue "
    "does not prove delivery. Closed reports without verified delivery and duplicates "
    "are omitted. Reopened reports need a new fix declaration.\n\n"
    "Follow an item's GitHub or Discord discussion to contribute. "
    "Updates normally run every 15 minutes. A failed update can leave some pages older; "
    "GitHub remains authoritative."
)


def units(text):
    return len(text.encode("utf-16-le")) // 2


def title_text(text):
    text = " ".join(text.split())
    if len(text) > 160:
        text = text[:157] + "..."
    return re.sub(r"([\\`*_{}\[\]()<>#|~])", r"\\\1", text).replace("@", "@\u200b")


def app_store_builds(apple):
    apps, _ = ANN.apple_collection(apple, "/apps", {"filter[bundleId]": ANN.BUNDLE, "limit": 200})
    app = ANN.only(apps, "Plozz App Store Connect app")
    versions, included = ANN.apple_collection(
        apple, f"/apps/{quote(app['id'], safe='')}/appStoreVersions",
        {"include": "build", "limit": 200},
    )
    current = {}
    for version in versions:
        attributes = version["attributes"]
        platform = attributes["platform"]
        if platform not in ANN.PLATFORMS:
            continue
        # Both Apple API spellings are explicit distribution states, not approval,
        # preorder, phased-release progress, or pending developer release.
        state = attributes.get("appVersionState") or attributes.get("appStoreState")
        if state not in ("READY_FOR_DISTRIBUTION", "READY_FOR_SALE"):
            continue
        number = ANN.NOTES.version_parts(attributes["versionString"], (3,))
        previous = current.get(platform)
        if previous:
            previous_number = ANN.NOTES.version_parts(previous["attributes"]["versionString"], (3,))
            if number == previous_number:
                raise Error("Duplicate distributed App Store versions exist for one platform.")
            if number < previous_number:
                continue
        # Apple can retain the distribution state on superseded versions.
        current[platform] = version
    releases = []
    for platform, version in current.items():
        attributes = version["attributes"]
        build = ANN.related(version, "build", included)
        if build.get("processingState") != "VALID":
            raise Error("A live App Store version has an unverified build.")
        ANN.NOTES.build_parts(build["version"])
        ANN.NOTES.version_parts(attributes["versionString"], (3,))
        releases.append({
            "marketing": attributes["versionString"], "build": build["version"],
            "platforms": {platform},
        })
    return releases


def verified_releases(releases, published):
    result = []
    for release in releases:
        if ANN.published_release(release["build"], published) is not None:
            tag = ANN.NOTES.release_tag(release["build"])
            catalog = RES["git"](
                "ls-tree", "--name-only", f"refs/tags/{tag}^{{commit}}",
                "--", "App/Resources/ReleaseNotes.json",
            )
            if not catalog:
                print(f"Build {release['build']}: tagged source has no release catalog; "
                      "roadmap delivery is not inferred.")
                continue
            result.append(RES["verified_release_source"](release))
        else:
            print(f"Build {release['build']}: no published source tag; roadmap delivery is not inferred.")
    return result


@lru_cache(maxsize=4096)
def includes_fix(commit, source):
    return RES["ancestor"](commit, source) and not RES["reverted"](commit, source)


def delivery_stage(receipt, events, beta, store):
    commit = receipt["commit"]
    declarations = RES["commit_declarations"](commit, RES["git"]("show", "-s", "--format=%B", commit))
    if not any(d["issue"] == receipt["issue"] and set(d["platforms"]) == set(receipt["platforms"])
               for d in declarations):
        raise Error("A roadmap delivery receipt does not match its fixing commit.")
    if not RES["ancestor"](commit, "HEAD"):
        raise Error("A roadmap fixing commit is not in the checked-out main history.")
    declared = datetime.fromisoformat(RES["git"]("show", "-s", "--format=%cI", commit))
    if any(e.get("event") == "reopened" and datetime.fromisoformat(
            e["created_at"].replace("Z", "+00:00")) >= declared for e in events):
        return None

    def covers(platform, releases):
        return any(RES["PLATFORMS"][platform] in r["platforms"] and includes_fix(commit, r["source"])
                   for r in releases)

    if all(covers(p, store) for p in receipt["platforms"]):
        return "Released"
    if all(covers(p, beta + store) for p in receipt["platforms"]):
        return "In beta"
    return None


def commitment(issue, events):
    labels = {label["name"] for label in issue.get("labels", [])} & COMMITMENT_LABELS.keys()
    if len(labels) > 1:
        raise Error(f"Issue #{issue['number']} has conflicting roadmap commitment labels.")
    if not labels:
        return "Backlog"
    label = next(iter(labels))
    changes = [e for e in events if e.get("event") in ("labeled", "unlabeled")
               and e.get("label", {}).get("name") == label]
    latest = max(changes, key=lambda e: (e["created_at"], e["id"]), default=None)
    if not latest or latest["event"] != "labeled" or latest.get("actor", {}).get("login") != MAINTAINER:
        raise Error(f"Issue #{issue['number']}'s roadmap commitment was not verified as Brandon's choice.")
    return COMMITMENT_LABELS[label]


def board(index, beta, store):
    result = {stage: [] for stage in STAGES}
    for number, issue in sorted(index.issues.items()):
        labels = {label["name"] for label in issue.get("labels", [])}
        if not labels & {"bug", "enhancement"} or "duplicate" in labels:
            continue
        receipt = BRIDGE.latest_release_resolution(index, number)
        events = index.api.pages(f"/repos/{BRIDGE.REPO}/issues/{number}/events") if (
            receipt or labels & COMMITMENT_LABELS.keys()
        ) else []
        stage = delivery_stage(receipt, events, beta, store) if receipt else None
        if stage is None:
            if issue["state"] != "open":
                continue
            stage = commitment(issue, events)
        kind = "Bug" if "bug" in labels else "Feature"
        lines = [f"- [{kind} #{number}](https://github.com/{BRIDGE.REPO}/issues/{number}): {title_text(issue['title'])}"]
        for thread, record in sorted(index.reports.items(), key=lambda pair: int(pair[0])):
            if record["number"] == number:
                lines.append(f"  [Discord discussion]({BRIDGE.message_link(thread, record['meta']['message'])})")
        result[stage].extend(lines)
    return result


def pages(lines):
    result, current = [], []
    for line in lines:
        if units(line) > 3600:
            raise Error("One roadmap line exceeds Discord's message budget.")
        if current and units("\n".join(current + [line])) > 3600:
            result.append("\n".join(current))
            current = []
        current.append(line)
    return result + ["\n".join(current)] if current else result or ["No items in this stage."]


def inspect_channel(discord, *, pin=False, read_only=False):
    user = discord.call("GET", "/users/@me")
    if user.get("id") != BRIDGE.BOT or user.get("bot") is not True:
        raise Error("The Discord credential does not identify the configured Plozz bot.")
    channel = discord.call("GET", f"/channels/{CHANNEL}")
    if channel.get("id") != CHANNEL or channel.get("guild_id") != BRIDGE.GUILD or channel.get("type") != 0:
        raise Error("The configured roadmap is not a text channel in the Plozz server.")
    required = {"View Channel": 10, "Send Messages": 11, "Embed Links": 14, "Read Message History": 16}
    if pin:
        required["Pin Messages"] = 51
    if read_only:
        required["Manage Permissions"] = 28
    BRIDGE.require_channel_permissions(discord, channel, required)
    return channel


def roadmap_records(messages):
    records = {}
    for message in messages:
        if message.get("author", {}).get("id") != BRIDGE.BOT:
            continue
        embeds = message.get("embeds", [])
        if len(embeds) != 1:
            continue
        footer = embeds[0].get("footer", {}).get("text", "")
        if not footer.startswith(BRIDGE.FOOTER + PREFIX):
            continue
        key = footer.removeprefix(BRIDGE.FOOTER)
        if message.get("author", {}).get("bot") is not True or key in records:
            raise Error("Duplicate or invalid bot-owned roadmap records.")
        if key != PREFIX + "guide" and not re.fullmatch(r"roadmap:v1:[0-4]:[0-9]+", key):
            raise Error("Unknown bot-owned roadmap record; refusing an ambiguous update.")
        records[key] = message
    return records


def verified_message(discord, messages, key, embed):
    match = ANN.only(BRIDGE.discord_records(messages, key), "bot-owned roadmap message")
    actual = discord.call("GET", f"/channels/{CHANNEL}/messages/{BRIDGE.snowflake(match['id'])}")
    expected = {**embed, "footer": {"text": BRIDGE.FOOTER + key}}
    if (actual.get("author", {}).get("id") != BRIDGE.BOT or actual.get("author", {}).get("bot") is not True
            or len(actual.get("embeds", [])) != 1
            or any(actual["embeds"][0].get(k, [] if k == "fields" else None) != v for k, v in expected.items())):
        raise Error("Discord did not confirm the requested roadmap content.")
    return actual


def synchronize(discord, channel, stages, *, publish=False, pin=False, read_only=False):
    messages = BRIDGE.thread_messages(discord, CHANNEL)
    old = roadmap_records(messages)
    planned = {}
    for index, stage in enumerate(STAGES):
        for page, description in enumerate(pages(stages[stage])):
            planned[f"{PREFIX}{index}:{page}"] = {"title": f"{stage} - {page + 1}", "description": description}
    if len(planned) > 50:
        raise Error("Roadmap exceeds 50 pages; nothing was silently truncated.")
    guide_key = PREFIX + "guide"
    stale = set(old) - set(planned) - {guide_key}
    if not publish:
        print(f"Roadmap preview: {len(planned)} active pages, {len(stale)} surplus pages to retire; no writes.")
        for key, embed in planned.items():
            print(f"{key}: {embed['title']}\n{embed['description']}")
        return
    if read_only:
        channel = BRIDGE.make_channel_read_only(discord, channel)
        BRIDGE.require_channel_permissions(discord, channel, {"Send Messages": 11})
    # Create the explanation first so it is above the board on initial setup.
    if guide_key not in old:
        BRIDGE.discord_upsert(discord, channel, messages, guide_key, {"title": "Plozz roadmap", "description": GUIDE})
    page_messages = {}
    for key, embed in planned.items():
        BRIDGE.discord_upsert(discord, channel, messages, key, embed)
        message = verified_message(discord, messages, key, embed)
        page_messages[key] = message
    fields = []
    for index, stage in enumerate(STAGES):
        keys = [key for key in planned if key.startswith(f"{PREFIX}{index}:")]
        first = BRIDGE.message_link(CHANNEL, page_messages[keys[0]]["id"])
        fields.append({"name": stage, "value": f"[Open {stage}]({first}) ({len(keys)} pages)", "inline": False})
        for page, key in enumerate(keys):
            neighbors = []
            for other, label in ((page - 1, "Previous"), (page + 1, "Next")):
                if 0 <= other < len(keys):
                    link = BRIDGE.message_link(CHANNEL, page_messages[keys[other]]["id"])
                    neighbors.append(f"[{label}]({link})")
            embed = {**planned[key], "fields": (
                [{"name": "Pages", "value": " | ".join(neighbors), "inline": False}] if neighbors else []
            )}
            BRIDGE.discord_upsert(discord, channel, messages, key, embed)
            verified_message(discord, messages, key, embed)
    # Never delete messages or leave removed issues advertised as current entries.
    for key in sorted(stale):
        embed = {"title": "Roadmap page retired", "description": "No current entries. Use the pinned roadmap index."}
        BRIDGE.discord_upsert(discord, channel, messages, key, embed)
        verified_message(discord, messages, key, embed)
    guide = {"title": "Plozz roadmap", "description": GUIDE, "fields": fields}
    BRIDGE.discord_upsert(discord, channel, messages, guide_key, guide)
    message = verified_message(discord, messages, guide_key, guide)
    if pin and not message.get("pinned"):
        discord.call("PUT", f"/channels/{CHANNEL}/messages/pins/{message['id']}")
        if discord.call("GET", f"/channels/{CHANNEL}/messages/{message['id']}").get("pinned") is not True:
            raise Error("Discord did not confirm the roadmap explanation pin.")
    print(f"Roadmap verified: {BRIDGE.message_link(CHANNEL, message['id'])}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("check", "sync", "setup"), default="check")
    parser.add_argument("--pin-guide", action="store_true")
    parser.add_argument("--make-read-only", action="store_true")
    args = parser.parse_args()
    if (args.pin_guide or args.make_read_only) and args.mode != "setup":
        raise Error("Channel setup is allowed only in explicit setup mode.")
    if os.environ.get("GITHUB_REPOSITORY") != BRIDGE.REPO or os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise Error("Roadmap operations must use this repository's main branch.")
    if args.mode == "setup" and os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
        raise Error("Roadmap setup requires an explicit manual workflow dispatch.")
    publish = args.mode != "check"
    if publish and os.environ.get("DISCORD_ROADMAP_ENABLED") != "true":
        raise Error("Live roadmap publication is not enabled.")
    discord = BRIDGE.API("Discord", os.environ.get("DISCORD_BOT_TOKEN"), write=publish)
    github = BRIDGE.API("GitHub", os.environ.get("GITHUB_TOKEN"))
    channel = inspect_channel(discord, pin=args.pin_guide, read_only=args.make_read_only)
    index = BRIDGE.GitHubIndex(github)
    apple = BRIDGE.API("App Store Connect", ANN.apple_token())
    published = github.pages(f"/repos/{BRIDGE.REPO}/releases")
    beta = verified_releases(ANN.available_builds(apple, (0,)), published)
    store = verified_releases(app_store_builds(apple), published)
    stages = board(index, beta, store)
    synchronize(discord, channel, stages, publish=publish, pin=args.pin_guide, read_only=args.make_read_only)


if __name__ == "__main__":
    try:
        main()
    except (Error, ValueError, KeyError, TypeError) as error:
        print(f"Discord roadmap stopped: {error}", file=sys.stderr)
        raise SystemExit(1)
