#!/usr/bin/env python3
"""Resolve explicitly declared fixes after external TestFlight delivery, without an LLM."""

from __future__ import annotations

import argparse
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("testflight_announcements", ROOT / "tools/testflight-discord.py")
ANNOUNCEMENTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANNOUNCEMENTS)
BRIDGE = ANNOUNCEMENTS.BRIDGE
NOTES = ANNOUNCEMENTS.NOTES
Error = BRIDGE.BridgeError
AWAITING_LABEL = "awaiting release"
PLATFORMS = {"tvOS": "TV_OS", "iOS": "IOS"}
NAMES = {"tvOS": "Apple TV", "iOS": "iPhone and iPad"}
DECLARATION_KEYS = ("TestFlight-Issue:", "TestFlight-Fix:")
TRAILER = re.compile(
    r"(?:TestFlight-Issue: |TestFlight-Fix: #)([1-9][0-9]*) \[(tvOS|iOS|tvOS,iOS|iOS,tvOS)\]"
)
SESSION_FOOTER = re.compile(
    r"\n\n+(Copilot-Session: [0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\s*\Z"
)


class InvalidDeclaration(Error):
    pass


def git(*args, input=None, allow_nonancestor=False):
    result = subprocess.run(
        ["git", *args], cwd=ROOT, input=input, capture_output=True, text=True, timeout=60,
    )
    if allow_nonancestor and result.returncode == 1:
        return None
    if result.returncode != 0:
        raise Error(f"Git {args[0]} failed; source inclusion could not be verified.")
    return result.stdout.strip()


def ancestor(commit, source):
    return git("merge-base", "--is-ancestor", commit, source, allow_nonancestor=True) is not None


def reverted(commit, source):
    return bool(git(
        "log", "--format=%H", "--fixed-strings", f"--grep=This reverts commit {commit}.",
        f"{commit}..{source}",
    ))


def commit_declarations(commit, body):
    # Older clients appended this independent footer after an otherwise valid
    # trailer block. Normalize only that terminal metadata, never prose/examples.
    normalized = SESSION_FOOTER.sub(r"\n\1", body)
    trailers = git("interpret-trailers", "--parse", input=normalized + "\n").splitlines()
    declarations = [line for line in trailers if line.startswith(DECLARATION_KEYS)]
    raw = [line for line in body.splitlines() if line.startswith(DECLARATION_KEYS)]
    if not declarations or declarations != raw:
        raise InvalidDeclaration(f"{commit}: TestFlight declarations must be in the final trailer block.")
    result = []
    seen = set()
    for line in declarations:
        match = TRAILER.fullmatch(line)
        if not match:
            raise InvalidDeclaration(f"{commit}: invalid TestFlight declaration; expected TestFlight-Issue: 123 [tvOS,iOS].")
        number = int(match[1])
        if number in seen:
            raise InvalidDeclaration(f"{commit}: issue #{number} is declared more than once.")
        seen.add(number)
        result.append({"issue": number, "commit": commit, "platforms": sorted(match[2].split(","))})
    return result


def declared_fixes(sources=("HEAD",)):
    fixes = {}
    failures = []
    invalid = []
    competing = set()
    for commit in git(
        "log", "--topo-order", "--format=%H",
        "--grep=^TestFlight-Issue:", "--grep=^TestFlight-Fix:", *sources,
    ).splitlines():
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise Error("Git returned an invalid fixing commit.")
        body = git("show", "-s", "--format=%B", commit)
        try:
            declarations = commit_declarations(commit, body)
        except InvalidDeclaration as error:
            lines = [line for line in body.splitlines() if line.startswith(DECLARATION_KEYS)]
            references = [
                re.match(r"TestFlight-(?:Issue|Fix):\s*#?([1-9][0-9]*)(?=\s|\[|$)", line)
                for line in lines
            ]
            # A partially identified block is still unidentifiable: do not let
            # its recognized issues hide another malformed declaration.
            referenced = {int(match[1]) for match in references} if all(references) else set()
            invalid.append((commit, referenced, str(error)))
            continue
        for fix in declarations:
            number = fix["issue"]
            previous = fixes.get(number)
            if previous:
                if ancestor(commit, previous["commit"]):
                    continue
                if not ancestor(previous["commit"], commit):
                    failures.append(f"Issue #{number} has competing fixes; add one final declaration after integration.")
                    competing.add(number)
                    continue
            fixes[number] = fix
    for commit, referenced, failure in invalid:
        if referenced and all(
            number in fixes and number not in competing and ancestor(commit, fixes[number]["commit"])
            for number in referenced
        ):
            continue
        failures.append(failure)
        for number, fix in list(fixes.items()):
            # An unidentifiable declaration cannot authorize an older fix.
            # A new explicit declaration after the bad commit can supersede it.
            if (not referenced or number in referenced) and not ancestor(commit, fix["commit"]):
                del fixes[number]
    return sorted(
        (fix for number, fix in fixes.items() if number not in competing),
        key=lambda item: item["issue"],
    ), failures


def delivered_releases(apple, github, minimum):
    published = github.pages(f"/repos/{BRIDGE.REPO}/releases")
    result = []
    for release in ANNOUNCEMENTS.available_builds(apple, minimum):
        if ANNOUNCEMENTS.published_release(release["build"], published) is None:
            continue
        tag = NOTES.release_tag(release["build"])
        source = git("rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}")
        if not re.fullmatch(r"[0-9a-f]{40}", source):
            raise Error("A release tag has an invalid source commit.")
        catalog = NOTES.validate_catalog(json.loads(git("show", f"{source}:App/Resources/ReleaseNotes.json")))
        entry = NOTES.selected_release(catalog, tag, release["marketing"], release["build"])
        result.append({
            **release, "source": source, "tag": tag, "version": entry["version"],
        })
    return result


def resolution_body(receipt):
    metadata = BRIDGE.RESOLUTION_HEADER + json.dumps(receipt, sort_keys=True, separators=(",", ":")) + " -->"
    lines = []
    for platform in BRIDGE.RESOLUTION_PLATFORMS:
        if delivery := receipt["deliveries"].get(platform):
            lines.append(
                f"- **{NAMES[platform]}:** fixed in **build {delivery['build']}** "
                f"(Plozz {delivery['version']}). "
                f"[Release notes](https://github.com/{BRIDGE.REPO}/releases/tag/{delivery['tag']})"
            )
    missing = set(receipt["platforms"]) - set(receipt["deliveries"])
    if missing:
        names = ", ".join(NAMES[p] for p in BRIDGE.RESOLUTION_PLATFORMS if p in missing)
        text = f"Implemented; **awaiting external TestFlight availability for {names}**. This issue stays open until delivery."
    elif receipt["status"] == "awaiting_release":
        text = "Delivery history is recorded below. This issue stays open until a qualifying build is currently available on every affected platform."
    else:
        text = f"The fix has reached external TestFlight testers. [Update in TestFlight]({ANNOUNCEMENTS.TESTFLIGHT})."
    if lines:
        text += "\n\n" + "\n".join(lines)
    text += (
        f"\n\n[Fixing commit `{receipt['commit'][:9]}`]"
        f"(https://github.com/{BRIDGE.REPO}/commit/{receipt['commit']})."
    )
    return metadata + "\n\n" + text


def fix_record(comments, fix):
    matches = {}
    for comment in comments:
        if receipt := BRIDGE.release_resolution(comment, fix["issue"]):
            if receipt["commit"] == fix["commit"]:
                if receipt["platforms"] != fix["platforms"]:
                    raise Error(f"Issue #{fix['issue']}'s recorded platforms differ from its fixing commit.")
                delivered = receipt["status"] == "delivered"
                if delivered in matches:
                    raise Error(f"Issue #{fix['issue']} has duplicate release records; refusing an ambiguous update.")
                matches[delivered] = (comment, receipt)
    return matches.get(True) or matches.get(False) or (None, {**fix, "deliveries": {}, "status": "awaiting_release"})


def was_reopened(github, number, declared_at):
    return any(
        event.get("event") == "reopened"
        and datetime.fromisoformat(event["created_at"].replace("Z", "+00:00")) >= declared_at
        for event in github.pages(f"/repos/{BRIDGE.REPO}/issues/{number}/events")
    )


def ensure_awaiting_label(github, issue):
    if AWAITING_LABEL in {label["name"] for label in issue.get("labels", [])}:
        return
    path = f"/repos/{BRIDGE.REPO}/labels/{quote(AWAITING_LABEL, safe='')}"
    try:
        github.call("GET", path)
    except BRIDGE.APIError as error:
        if error.status != 404:
            raise
        github.call("POST", f"/repos/{BRIDGE.REPO}/labels", {
            "name": AWAITING_LABEL, "color": "d4c5f9",
            "description": "Implemented; awaiting verified external TestFlight delivery.",
        })
    github.call("POST", f"/repos/{BRIDGE.REPO}/issues/{issue['number']}/labels", {"labels": [AWAITING_LABEL]})


def resolve_issues(github, fixes, releases, *, publish=False):
    failures = []
    for fix in fixes:
        number = fix["issue"]
        path = f"/repos/{BRIDGE.REPO}/issues/{number}"
        try:
            issue = github.call("GET", path)
            if "pull_request" in issue:
                raise Error(f"#{number} is a pull request, not an issue.")
            if issue["state"] != "open":
                continue
            comments = github.pages(path + "/comments")
            comment, receipt = fix_record(comments, fix)
            previously_delivered = receipt["status"] == "delivered"
            declared_at = datetime.fromisoformat(git("show", "-s", "--format=%cI", fix["commit"]))
            if was_reopened(github, number, declared_at):
                print(f"Issue #{number}: reopened after this fix; requires a new fixing-commit declaration.")
                continue
            if reverted(fix["commit"], "HEAD"):
                print(f"WARNING: issue #{number}'s fixing commit was reverted; leaving it open.")
                continue
            available = set()
            for release in releases:
                if not ancestor(fix["commit"], release["source"]) or reverted(fix["commit"], release["source"]):
                    continue
                for platform in fix["platforms"]:
                    if PLATFORMS[platform] in release["platforms"]:
                        available.add(platform)
                        receipt["deliveries"].setdefault(platform, {
                            key: release[key] for key in ("build", "version", "tag", "source")
                        })
            ready = available == set(fix["platforms"])
            if ready:
                receipt["status"] = "delivered"
            body = resolution_body(receipt)
            print(f"Issue #{number}: {'delivered; close' if ready else 'awaiting release'} ({'sync' if publish else 'check'})")
            if not publish:
                continue
            # Recheck after the source/API reads; do not overwrite a new human decision.
            current = github.call("GET", path)
            if current["state"] != "open" or current["updated_at"] != issue["updated_at"]:
                print(f"WARNING: issue #{number} changed during verification; deferred to the next run.")
                continue
            if comment is None or (ready and not previously_delivered):
                comment = github.call("POST", path + "/comments", {"body": body})
            elif comment["body"] != body:
                github.call("PATCH", f"/repos/{BRIDGE.REPO}/issues/comments/{comment['id']}", {"body": body})
            if not ready:
                ensure_awaiting_label(github, current)
                continue
            if was_reopened(github, number, declared_at):
                print(f"WARNING: issue #{number} was reopened during notification; not closing it.")
                continue
            current = github.call("GET", path)
            if current["state"] != "open":
                continue
            if AWAITING_LABEL in {label["name"] for label in current.get("labels", [])}:
                github.call("DELETE", path + "/labels/" + quote(AWAITING_LABEL, safe=""))
            github.call("PATCH", path, {"state": "closed", "state_reason": "completed"})
            verified = github.call("GET", path)
            if verified["state"] != "closed" or verified.get("state_reason") != "completed":
                raise Error(f"Issue #{number}'s completed state did not persist.")
        except (Error, ValueError, KeyError, TypeError) as error:
            detail = str(error) if isinstance(error, Error) else "Invalid resolution metadata or API response."
            failures.append(f"Issue #{number}: {detail}")
    if failures:
        raise Error("\n".join(failures))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("check", "sync"), default="check")
    args = parser.parse_args()
    publish = args.mode == "sync"
    try:
        if publish and os.environ.get("TESTFLIGHT_RESOLUTION_ENABLED") != "true":
            raise Error("TestFlight issue resolution is not explicitly enabled.")
        github = BRIDGE.API("GitHub", os.environ.get("GITHUB_TOKEN"), write=publish)
        failures = []
        try:
            releases = delivered_releases(
                BRIDGE.API("App Store Connect", ANNOUNCEMENTS.apple_token()), github,
                NOTES.build_parts(os.environ.get("TESTFLIGHT_DISCORD_MIN_BUILD", "")),
            )
            fixes, declaration_failures = declared_fixes(("HEAD", *(release["source"] for release in releases)))
            failures.extend(declaration_failures)
            resolve_issues(github, fixes, releases, publish=publish)
            if not fixes:
                print("No eligible TestFlight declarations on main or available release tags; no GitHub issues changed.")
        except (Error, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            failures.append(str(error) if isinstance(error, Error) else "Invalid release metadata or source history.")
        if os.environ.get("DISCORD_BRIDGE_ENABLED") == "true":
            try:
                BRIDGE.sync_release_resolutions(
                    BRIDGE.API("Discord", os.environ.get("DISCORD_BOT_TOKEN"), write=publish),
                    github, publish=publish,
                )
            except Error as error:
                failures.append(str(error))
        else:
            print("Discord issue mirroring is disabled; no Discord posts changed.")
        if failures:
            raise Error("\n".join(failures))
    except (Error, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        detail = str(error) if isinstance(error, Error) else "Invalid configuration, source history, or API response."
        print(f"ERROR: {detail}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
