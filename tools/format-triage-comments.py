#!/usr/bin/env python3
"""Collapse machine-readable triage records without changing their contents."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys


REPO = "brandomoore/Plozz"
MARKER = f"<!-- gh-aw-workflow-call-id: {REPO}/issue-triage -->"
OPEN = "<details>\n<summary>Automation details</summary>\n\n"
CLOSE = "\n\n</details>"
RECORD = re.compile(r"^Structured data:\s*\n```json\n(?P<data>.*?)\n```", re.M | re.S)
ISSUE_URL = re.compile(rf"https://api\.github\.com/repos/{REPO}/issues/([1-9][0-9]*)")


def owned(comment):
    user = comment.get("user", {})
    return (
        user.get("login") == "github-actions[bot]"
        and user.get("type") == "Bot"
        and MARKER in (comment.get("body") or "")
        and ISSUE_URL.fullmatch(comment.get("issue_url", "")) is not None
    )


def collapsed_body(comment):
    if not owned(comment):
        return None
    body = comment["body"]
    matches = list(RECORD.finditer(body))
    if len(matches) != 1:
        raise ValueError("Expected exactly one structured triage record")
    match = matches[0]
    data = json.loads(match["data"])
    number = int(ISSUE_URL.fullmatch(comment["issue_url"])[1])
    if not isinstance(data, dict) or data.get("schema_version") not in (1, 2, 3) or data.get("issue_number") != number:
        raise ValueError("Unsupported or mismatched triage record")
    before, after = body[:match.start()], body[match.end():]
    if before.endswith(OPEN) and after.startswith(CLOSE):
        return None
    if "<details" in before or "</details>" in after:
        raise ValueError("Unexpected existing disclosure markup")
    return before + OPEN + match[0] + CLOSE + after


def public_prose(comment):
    if not owned(comment):
        raise ValueError("Expected a bot-owned triage assessment")
    collapsed_body(comment)
    before = comment["body"][:RECORD.search(comment["body"]).start()]
    return before.removesuffix(OPEN).replace(MARKER, "").strip()


def api(path, *, body=None, paginate=False):
    args = ["gh", "api", path]
    if paginate:
        args += ["--paginate", "--slurp"]
    if body is not None:
        args += ["--method", "PATCH", "--input", "-"]
    result = subprocess.run(
        args, input=json.dumps({"body": body}) if body is not None else None,
        text=True, capture_output=True, timeout=180,
    )
    if result.returncode:
        raise RuntimeError(f"GitHub API request failed for {path} (exit {result.returncode})")
    return json.loads(result.stdout)


def synchronize(*, apply=False):
    pages = api(f"repos/{REPO}/issues/comments?per_page=100", paginate=True)
    changed = 0
    failures = []
    for comment in (comment for page in pages for comment in page):
        if not owned(comment):
            continue
        try:
            new_body = collapsed_body(comment)
            if new_body is None:
                continue
            if apply:
                path = f"repos/{REPO}/issues/comments/{int(comment['id'])}"
                # Re-read immediately before editing so a stale inventory cannot replace newer prose.
                current = api(path)
                new_body = collapsed_body(current)
                if new_body is None:
                    continue
                updated = api(path, body=new_body)
                if updated.get("body") != new_body:
                    raise RuntimeError("GitHub did not retain the requested presentation")
            changed += 1
            print(f"{'Updated' if apply else 'Would update'} comment {comment['id']}")
        except (ValueError, RuntimeError) as error:
            failures.append(comment["id"])
            print(f"Comment {comment['id']}: {error}", file=sys.stderr)
    print(f"{'Updated' if apply else 'Would update'} {changed} comments; {len(failures)} failures.")
    if failures:
        raise RuntimeError("Some triage comments could not be formatted; see comment IDs above")
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Update bot-owned comments in place")
    args = parser.parse_args()
    try:
        synchronize(apply=args.apply)
    except (ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Triage formatting failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
