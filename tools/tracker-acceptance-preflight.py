#!/usr/bin/env python3
"""Read-only, independent account/title baselines. This is not playback acceptance."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("provider_playback_runner", ROOT / "tools/run-provider-playback-tests.py")
_playback = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_playback)
Failure = _playback.ConfigurationError
PMDB = "https://publicmetadb.com"
PROVIDERS = ("jellyfin", "emby", "plex")


def require(condition, message):
    if not condition:
        raise Failure(message)


def identifier(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,256}", value), "Invalid exact identifier.")
    return value


def number(value, minimum=0):
    require(type(value) in (int, float) and math.isfinite(value) and value >= minimum, "Invalid numeric state.")
    return value


def content(value):
    require(isinstance(value, dict), "Missing catalog identity.")
    require(type(value.get("tmdb_id")) is int and value["tmdb_id"] > 0, "Missing TMDB identity.")
    require(value.get("media_type") in ("movie", "tv"), "Unsupported catalog kind.")
    result = {key: value[key] for key in ("tmdb_id", "media_type")}
    if value["media_type"] == "tv":
        require(type(value.get("season")) is int and value["season"] >= 0
                and type(value.get("episode")) is int and value["episode"] > 0, "An exact episode is required.")
        result.update(season=value["season"], episode=value["episode"])
    else:
        require(value.get("season") is None and value.get("episode") is None, "Movie has episode coordinates.")
    return result


def credential_reference(value):
    require(isinstance(value, dict), "Missing credential reference.")
    for name in ("tokenKeychainService", "tokenKeychainAccount"):
        require(isinstance(value.get(name), str) and 0 < len(value[name]) <= 256
                and not any(ord(c) < 32 for c in value[name]), "Missing dedicated Keychain reference.")


def validate_config(value):
    require(isinstance(value, dict) and type(value.get("schemaVersion")) is int
            and value["schemaVersion"] == 1, "Unsupported configuration.")
    tracker = value.get("publicMetaDB")
    credential_reference(tracker)
    identifier(tracker.get("ownedTestListID"))
    servers = value.get("servers")
    require(isinstance(servers, dict) and servers and set(servers).issubset(PROVIDERS),
            "Choose explicit Plex, Jellyfin or Emby servers; other baseline readers are not implemented.")
    for server in servers.values():
        credential_reference(server)
        identifier(server.get("serverID"))
        identifier(server.get("userID"))
        try:
            url = urllib.parse.urlsplit(server.get("baseURL", ""))
            port = url.port
        except (ValueError, TypeError):
            raise Failure("Invalid credential-free server URL.") from None
        require(url.scheme in ("http", "https") and url.hostname and not url.username and not url.password
                and not url.query and not url.fragment and (port is None or 1 <= port <= 65535)
                and "\\" not in server["baseURL"] and not any(c.isspace() for c in server["baseURL"]),
                "Invalid credential-free server URL.")
    cases = value.get("titles")
    require(isinstance(cases, list) and 1 <= len(cases) <= 10, "Choose one to ten exact catalog titles.")
    seen = set()
    for case in cases:
        require(isinstance(case, dict), "Invalid title allowlist.")
        identifier(case.get("caseID"))
        require(case["caseID"] not in seen, "Duplicate case identity.")
        seen.add(case["caseID"])
        require(case.get("provider") in servers, "Title server is not configured.")
        identifier(case.get("itemID"))
        canonical = content(case.get("content"))
        if canonical["media_type"] == "tv":
            identifier(case.get("seriesItemID"))
            require(case.get("episodeOrder") == "tmdb", "Explicit TMDB episode-order confirmation is required.")
    require(set(servers) == {case["provider"] for case in cases}, "Every selected provider must have a title.")
    return value


def read_token(reference):
    raw = _playback.keychain_token(reference["tokenKeychainService"], reference["tokenKeychainAccount"])
    try:
        token = raw.decode("ascii")
    except UnicodeDecodeError:
        raise Failure("Invalid dedicated test credential.") from None
    require(0 < len(token) <= 16384 and all(33 <= ord(c) <= 126 for c in token), "Invalid dedicated test credential.")
    return token


class ReadOnlyHTTP:
    def __init__(self, budget=110, opener=None):
        self.deadline = time.monotonic() + budget
        self.opener = opener or urllib.request.build_opener(_playback.NoRedirect)
        self.requests = 0
        self.last_request = None

    def get(self, base, path, headers, query=None):
        require(path.startswith("/") and not path.startswith("//"), "Invalid reader path.")
        require(self.requests < 100, "Read request budget exhausted.")
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, "Read deadline exceeded.")
        if self.last_request is not None:
            time.sleep(min(max(0, 0.1 - (time.monotonic() - self.last_request)), remaining))
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, "Read deadline exceeded.")
        url = base.rstrip("/") + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        request = urllib.request.Request(
            url, headers={"Accept": "application/json", "Cache-Control": "no-cache", **headers}, method="GET"
        )
        self.requests += 1
        self.last_request = time.monotonic()
        try:
            with self.opener.open(request, timeout=min(15, remaining)) as response:
                require(response.status == 200, "Reader did not receive a complete HTTP 200 response.")
                body = response.read(8 * 1024 * 1024 + 1)
                require(len(body) <= 8 * 1024 * 1024, "Reader response exceeds byte limit.")
            require(time.monotonic() < self.deadline, "Read deadline exceeded.")
            return json.loads(body, parse_constant=lambda _: reject_constant())
        except urllib.error.HTTPError as error:
            # Do not print server bodies, URLs, or credential-bearing exception text.
            code = error.code
            error.close()
            raise Failure(f"Read rejected (HTTP {code}); no retries or writes attempted.") from None
        except (OSError, ValueError, RecursionError, http.client.HTTPException):
            raise Failure("Read failed or returned invalid JSON; no retries or writes attempted.") from None


def reject_constant():
    raise Failure("Non-finite JSON number.")


def complete_pages(http, token, path, query=None):
    result, seen, expected_total, expected_size = [], set(), None, None
    for page in range(1, 21):
        value = http.get(PMDB, "/api/external" + path, {"Authorization": "Bearer " + token},
                         {**(query or {}), "page": page, "perPage": 500})
        require(isinstance(value, dict), "Missing paginated response.")
        total, size, pages = (value.get(key) for key in ("total", "perPage", "totalPages"))
        require(all(type(item) is int for item in (total, size, pages, value.get("page")))
                and total >= 0 and 1 <= size <= 500 and value["page"] == page, "Invalid page metadata.")
        require(pages == math.ceil(total / size) or (total == 0 and pages == 1), "Invalid page count.")
        require(expected_total in (None, total) and expected_size in (None, size), "Pagination changed during read.")
        expected_total, expected_size = total, size
        items = value.get("items")
        require(isinstance(items, list) and len(items) <= size and len(result) + len(items) <= total,
                "Invalid page contents.")
        require((total == 0 and page == 1 and not items)
                or (page <= pages and items and (page == pages or len(items) == size)), "Incomplete page.")
        for item in items:
            require(isinstance(item, dict), "Invalid remote record.")
            record_id = identifier(item.get("id"))
            require(record_id not in seen, "Duplicate remote record.")
            seen.add(record_id)
        result.extend(items)
        if page >= pages:
            require(len(result) == total, "Incomplete remote collection.")
            return result
    raise Failure("Page budget exhausted; collection is incomplete.")


def tracker_state(http, token, canonical):
    snapshot = {}
    for path in ("/watched", "/resume"):
        records = complete_pages(http, token, path, canonical)
        projected = []
        for record in records:
            require(content(record) == canonical, "Tracker returned a different catalog identity.")
            item = {"id": record["id"], "content": canonical}
            if path == "/watched":
                require("watched_at" in record, "Watched date is absent, not explicitly unknown.")
                item["watchedAt"] = timestamp(record["watched_at"])
            else:
                position = number(record.get("position_ms"))
                runtime = number(record.get("runtime_ms"))
                require(runtime > 0 and position <= runtime, "Invalid remote resume point.")
                item.update(positionMilliseconds=position, runtimeMilliseconds=runtime,
                            updatedAt=timestamp(record.get("updated")))
            projected.append(item)
        require(path != "/resume" or len(projected) <= 1, "Ambiguous resume points for one title.")
        snapshot[path[1:]] = sorted(projected, key=lambda item: item["id"])
    return snapshot


def timestamp(value):
    if value is None:
        return None
    require(isinstance(value, str), "Invalid remote timestamp.")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise Failure("Invalid remote timestamp.") from None
    require(parsed.tzinfo is not None, "Remote timestamp has no timezone.")
    return value


def plex_item(http, server, token, item_id):
    value = http.get(server["baseURL"], "/library/metadata/" + identifier(item_id),
                     {"X-Plex-Token": token}, {"includeGuids": "1"})
    require(isinstance(value, dict) and isinstance(value.get("MediaContainer"), dict), "Missing Plex metadata.")
    items = value["MediaContainer"].get("Metadata")
    require(isinstance(items, list) and len(items) == 1 and isinstance(items[0], dict)
            and items[0].get("ratingKey") == item_id, "Plex returned a different item.")
    return items[0]


def server_state(http, provider, server, token, case):
    canonical = content(case["content"])
    episode = canonical["media_type"] == "tv"
    if provider == "plex":
        item = plex_item(http, server, token, case["itemID"])
        require(item.get("type") == ("episode" if episode else "movie"), "Wrong Plex media kind.")
        catalog_item = item
        if episode:
            require(item.get("grandparentRatingKey") == case["seriesItemID"]
                    and item.get("parentIndex") == canonical["season"]
                    and item.get("index") == canonical["episode"], "Plex episode identity mismatch.")
            catalog_item = plex_item(http, server, token, case["seriesItemID"])
            require(catalog_item.get("type") == "show", "Plex parent is not a series.")
        guids = catalog_item.get("Guid")
        require(isinstance(guids, list) and all(isinstance(guid, dict) and isinstance(guid.get("id"), str)
                                              for guid in guids), "Missing Plex catalog IDs.")
        require({guid.get("id") for guid in guids if str(guid.get("id", "")).startswith("tmdb://")}
                == {f'tmdb://{canonical["tmdb_id"]}'}, "Plex TMDB identity mismatch.")
        runtime = number(item.get("duration"))
        require(runtime > 0, "Missing Plex runtime.")
        state = {}
        for key in ("viewOffset", "viewCount", "lastViewedAt"):
            state[key] = number(item[key]) if item.get(key) is not None else None
        require(state["viewOffset"] is None or state["viewOffset"] <= runtime, "Plex position exceeds runtime.")
        # Preserve absent Plex fields; the baseline must not invent an explicit reset.
        return {"runtimeMilliseconds": runtime, "state": state}
    headers = {"X-Emby-Token": token}
    prefix = "/Users/" + server["userID"] + "/Items/"
    item = http.get(server["baseURL"], prefix + case["itemID"], headers,
                    {"Fields": "ProviderIds", "EnableUserData": "true"})
    require(isinstance(item, dict) and item.get("Id") == case["itemID"]
            and item.get("Type") == ("Episode" if episode else "Movie"), "Server item identity mismatch.")
    catalog_item = item
    if episode:
        require(item.get("SeriesId") == case["seriesItemID"]
                and item.get("ParentIndexNumber") == canonical["season"] and item.get("IndexNumber") == canonical["episode"]
                and item.get("IndexNumberEnd") in (None, canonical["episode"]), "Server episode identity mismatch.")
        catalog_item = http.get(server["baseURL"], prefix + case["seriesItemID"], headers, {"Fields": "ProviderIds"})
        require(isinstance(catalog_item, dict) and catalog_item.get("Id") == case["seriesItemID"]
                and catalog_item.get("Type") == "Series", "Wrong parent series.")
    ids = catalog_item.get("ProviderIds")
    require(isinstance(ids, dict) and {str(value) for key, value in ids.items() if key.lower() == "tmdb"}
            == {str(canonical["tmdb_id"])}, "Server TMDB identity mismatch.")
    runtime = number(item.get("RunTimeTicks"))
    require(runtime > 0, "Missing server runtime.")
    data = item.get("UserData")
    require(isinstance(data, dict) and type(data.get("Played")) is bool, "Missing explicit user watch state.")
    position = number(data.get("PlaybackPositionTicks"))
    require(position <= runtime, "Server position exceeds runtime.")
    return {"runtimeMilliseconds": runtime / 10000,
            "state": {"played": data["Played"], "playCount": number(data.get("PlayCount")),
                      "positionMilliseconds": position / 10000, "lastPlayedAt": timestamp(data.get("LastPlayedDate"))}}


def baseline(config, http, token_reader=read_token):
    started = datetime.now(timezone.utc).isoformat()
    validate_config(config)
    key = token_reader(config["publicMetaDB"])
    require(re.fullmatch(r"pm-[A-Za-z0-9]{60}", key), "Invalid PublicMetaDB test key.")
    lists = complete_pages(http, key, "/lists")
    require(any(item["id"] == config["publicMetaDB"]["ownedTestListID"] for item in lists),
            "Key does not own the allowlisted test list; account scope is unverified.")
    tokens = {}
    for provider, server in config["servers"].items():
        token = token_reader(server)
        tokens[provider] = token
        if provider == "plex":
            headers = {"X-Plex-Token": token, "X-Plex-Client-Identifier": "plozz-tracker-acceptance-readonly"}
            identity = http.get(server["baseURL"], "/identity", headers)
            user = http.get("https://plex.tv", "/api/v2/user", headers)
            require(isinstance(identity, dict) and isinstance(identity.get("MediaContainer"), dict)
                    and identity["MediaContainer"].get("machineIdentifier") == server["serverID"],
                    "Plex server identity mismatch.")
            require(isinstance(user, dict) and str(user.get("id")) == server["userID"], "Plex user identity mismatch.")
        else:
            headers = {"X-Emby-Token": token}
            identity = http.get(server["baseURL"], "/System/Info/Public", headers)
            user = http.get(server["baseURL"], "/Users/Me", headers)
            require(isinstance(identity, dict) and identity.get("Id") == server["serverID"], "Server identity mismatch.")
            require(isinstance(user, dict) and user.get("Id") == server["userID"], "Server user identity mismatch.")
    cases = []
    for case in config["titles"]:
        provider = case["provider"]
        server = config["servers"][provider]
        observed = server_state(http, provider, server, tokens[provider], case)
        remote = tracker_state(http, key, content(case["content"]))
        cases.append({"caseID": case["caseID"], "provider": provider, "serverID": server["serverID"],
                      "userID": server["userID"], "itemID": case["itemID"], "content": content(case["content"]),
                      "server": observed, "tracker": remote})
    return {"schemaVersion": 1, "kind": "read-only-tracker-preflight", "acceptanceVerified": False,
            "writesAttempted": 0, "startedAt": started, "capturedAt": datetime.now(timezone.utc).isoformat(),
            "configurationSHA256": hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest(),
            "trackerCredentialSHA256": hashlib.sha256(key.encode()).hexdigest(),
            "serverCredentialSHA256": {provider: hashlib.sha256(token.encode()).hexdigest()
                                       for provider, token in tokens.items()}, "cases": cases}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New private baseline JSON; never overwritten.")
    args = parser.parse_args()
    os.umask(0o077)
    def deadline(_signal, _frame):
        raise Failure("Preflight exceeded its 120-second deadline.")
    signal.signal(signal.SIGALRM, deadline)
    signal.setitimer(signal.ITIMER_REAL, 120)
    try:
        path = _playback.private_file(args.config)
        config = validate_config(json.loads(path.read_text(), parse_constant=lambda _: reject_constant()))
        require(not args.output.exists() and args.output.parent.is_dir(), "Output must be a new file in an existing private directory.")
        parent = args.output.parent.stat()
        require(parent.st_uid == os.getuid() and parent.st_mode & 0o077 == 0, "Output directory must be owned by you and mode 700.")
        result = baseline(config, ReadOnlyHTTP())
        with args.output.open("x") as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(result, output, indent=2, allow_nan=False)
            output.write("\n")
        print("Read-only baseline captured. Playback, import, cancellation and recovery acceptance remain unverified.")
        return 0
    except (Failure, OSError, ValueError, RecursionError) as error:
        message = str(error) if isinstance(error, Failure) else "Private preflight input/output is invalid or unavailable."
        print("Preflight failed: " + message, file=sys.stderr)
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == "__main__":
    sys.exit(main())
