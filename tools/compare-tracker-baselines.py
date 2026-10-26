#!/usr/bin/env python3
"""Compare independent private snapshots; unchanged state is not proof of no writes."""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("tracker_preflight", ROOT / "tools/tracker-acceptance-preflight.py")
reader = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(reader)
Failure = reader.Failure
require = reader.require
MAX_BYTES = 32 * 1024 * 1024


def fields(value, expected):
    require(isinstance(value, dict) and set(value) == set(expected), "Incomplete or unsupported evidence fields.")


def digest(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value), "Missing evidence scope digest.")


def date(value, *, nullable=False):
    require(nullable or value is not None, "Missing evidence timestamp.")
    reader.timestamp(value)
    return None if value is None else datetime.fromisoformat(value.replace("Z", "+00:00"))


def validate_server(value, provider):
    fields(value, ("runtimeMilliseconds", "state"))
    runtime = reader.number(value["runtimeMilliseconds"])
    require(runtime > 0, "Missing server runtime.")
    state = value["state"]
    if provider == "plex":
        fields(state, ("viewOffset", "viewCount", "lastViewedAt"))
        for number in state.values():
            if number is not None:
                reader.number(number)
        position = state["viewOffset"]
    else:
        fields(state, ("played", "playCount", "positionMilliseconds", "lastPlayedAt"))
        require(type(state["played"]) is bool, "Missing explicit server watch state.")
        reader.number(state["playCount"])
        position = reader.number(state["positionMilliseconds"])
        date(state["lastPlayedAt"], nullable=True)
    require(position is None or position <= runtime, "Server position exceeds runtime.")


def validate_tracker(value, canonical):
    fields(value, ("watched", "resume"))
    normalized = {}
    for kind, records in value.items():
        require(isinstance(records, list) and len(records) <= (1 if kind == "resume" else 10000),
                "Invalid tracker collection.")
        seen = set()
        for record in records:
            expected = ("id", "content", "watchedAt") if kind == "watched" else (
                "id", "content", "positionMilliseconds", "runtimeMilliseconds", "updatedAt")
            fields(record, expected)
            identifier = reader.identifier(record["id"])
            require(identifier not in seen, "Duplicate tracker record.")
            seen.add(identifier)
            require(reader.content(record["content"]) == canonical and record["content"] == canonical,
                    "Tracker catalog identity mismatch.")
            if kind == "watched":
                date(record["watchedAt"], nullable=True)
            else:
                position = reader.number(record["positionMilliseconds"])
                runtime = reader.number(record["runtimeMilliseconds"])
                require(runtime > 0 and position <= runtime, "Invalid tracker resume state.")
                date(record["updatedAt"], nullable=True)
        normalized[kind] = sorted(records, key=lambda record: record["id"])
    return normalized


def validate_snapshot(value):
    fields(value, ("schemaVersion", "kind", "acceptanceVerified", "writesAttempted", "startedAt", "capturedAt",
                   "configurationSHA256", "trackerCredentialSHA256", "serverCredentialSHA256", "cases"))
    require(type(value["schemaVersion"]) is int and value["schemaVersion"] == 1
            and value["kind"] == "read-only-tracker-preflight" and value["acceptanceVerified"] is False
            and type(value["writesAttempted"]) is int and value["writesAttempted"] == 0,
            "Expected independent read-only preflight evidence.")
    started, captured = date(value["startedAt"]), date(value["capturedAt"])
    require(0 <= (captured - started).total_seconds() <= 120, "Invalid or unbounded observation interval.")
    for name in ("configurationSHA256", "trackerCredentialSHA256"):
        digest(value[name])
    credentials = value["serverCredentialSHA256"]
    require(isinstance(credentials, dict) and credentials and set(credentials).issubset(reader.PROVIDERS),
            "Missing server credential scopes; capture new baselines.")
    for credential in credentials.values():
        digest(credential)
    cases = value["cases"]
    require(isinstance(cases, list) and 1 <= len(cases) <= 10, "Missing exact case coverage.")
    indexed = {}
    for case in cases:
        fields(case, ("caseID", "provider", "serverID", "userID", "itemID", "content", "server", "tracker"))
        for name in ("caseID", "serverID", "userID", "itemID"):
            reader.identifier(case[name])
        require(case["caseID"] not in indexed, "Duplicate case identity.")
        require(isinstance(case["provider"], str) and case["provider"] in credentials, "Unsupported case provider.")
        canonical = reader.content(case["content"])
        require(case["content"] == canonical, "Unexpected catalog identity fields.")
        validate_server(case["server"], case["provider"])
        tracker = validate_tracker(case["tracker"], canonical)
        indexed[case["caseID"]] = {**case, "tracker": tracker}
    require(set(credentials) == {case["provider"] for case in cases}, "Incomplete provider coverage.")
    return started, captured, indexed


def compare(before, after):
    _, before_end, old = validate_snapshot(before)
    after_start, _, new = validate_snapshot(after)
    require(before_end < after_start, "After observations must start after baseline capture finishes.")
    for name in ("configurationSHA256", "trackerCredentialSHA256", "serverCredentialSHA256"):
        require(before[name] == after[name], "Configuration or credential scope changed.")
    require(set(old) == set(new), "Case coverage changed.")
    cases = []
    for case_id in sorted(old):
        a, b = old[case_id], new[case_id]
        require(all(a[name] == b[name] for name in ("provider", "serverID", "userID", "itemID", "content")),
                "Server, user or catalog scope changed.")
        cases.append({"caseID": case_id, "serverUnchanged": a["server"] == b["server"],
                      "trackerUnchanged": a["tracker"] == b["tracker"]})
    server_unchanged = all(case["serverUnchanged"] for case in cases)
    tracker_unchanged = all(case["trackerUnchanged"] for case in cases)
    return {"schemaVersion": 1, "kind": "read-only-tracker-state-comparison", "acceptanceVerified": False,
            "writesAttempted": 0, "serverStatesUnchanged": server_unchanged,
            "trackerStatesUnchanged": tracker_unchanged, "statesUnchanged": server_unchanged and tracker_unchanged,
            "cases": cases}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON evidence field.")
        result[key] = value
    return result


def read_snapshot(path):
    path = reader._playback.private_file(path)
    with path.open("rb") as source:
        body = source.read(MAX_BYTES + 1)
    require(len(body) <= MAX_BYTES, "Evidence exceeds byte limit.")
    value = json.loads(body, object_pairs_hook=unique_object, parse_constant=lambda _: reader.reject_constant())
    return value, hashlib.sha256(body).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", required=True, type=Path)
    parser.add_argument("--after", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New private comparison JSON; never overwritten.")
    parser.add_argument("--require-unchanged", choices=("all", "server"), default="all")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        require(not args.output.exists() and args.output.parent.is_dir(), "Output must be new in a private directory.")
        parent = args.output.parent.stat()
        require(parent.st_uid == os.getuid() and parent.st_mode & 0o077 == 0,
                "Output directory must be owned by you and mode 700.")
        before, before_sha = read_snapshot(args.before)
        after, after_sha = read_snapshot(args.after)
        result = compare(before, after)
        result.update(beforeSHA256=before_sha, afterSHA256=after_sha, requiredUnchanged=args.require_unchanged)
        with args.output.open("x") as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(result, output, indent=2, allow_nan=False)
            output.write("\n")
        matched = result["statesUnchanged" if args.require_unchanged == "all" else "serverStatesUnchanged"]
        print("Required snapshot state is unchanged." if matched else "Required snapshot state changed.")
        print("This does not prove zero intervening writes or production-app acceptance.")
        return 0 if matched else 2
    except (Failure, OSError, ValueError, RecursionError, OverflowError) as error:
        message = str(error) if isinstance(error, Failure) else "Private comparison input/output is invalid or unavailable."
        print("Comparison failed: " + message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
