#!/usr/bin/env python3
"""Request the fixed website roadmap workflow; never publish unverified data."""

from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import os
import sys
import time
import urllib.error
import urllib.request


DISPATCH_URL = (
    "https://api.github.com/repos/brandomoore/plozz-website"
    "/actions/workflows/roadmap-feed.yml/dispatches"
)
RETRYABLE_STATUS = {408, 429, 500, 502, 503, 504}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def retry_delay(header, attempt):
    delay = 2 ** attempt
    if header:
        try:
            requested = int(header)
        except ValueError:
            try:
                requested = (parsedate_to_datetime(header) - datetime.now(timezone.utc)).total_seconds()
            except (TypeError, ValueError, OverflowError):
                requested = 0
        delay = max(delay, requested)
    if delay > 30:
        raise RuntimeError("Roadmap dispatch rate limit exceeds the bounded retry window.")
    return delay


def dispatch(token, open_url=None, sleep=time.sleep):
    if not token:
        raise RuntimeError("Configure WEBSITE_ROADMAP_DISPATCH_TOKEN before enabling roadmap refresh.")
    if open_url is None:
        open_url = urllib.request.build_opener(NoRedirect()).open
    deadline = time.monotonic() + 120
    for attempt in range(4):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("Roadmap dispatch exceeded its retry budget.")
        request = urllib.request.Request(
            DISPATCH_URL,
            data=b'{"ref":"main"}',
            method="POST",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "Plozz-roadmap-refresh",
            },
        )
        retry_after = None
        try:
            with open_url(request, timeout=min(20, remaining)) as response:
                if response.status != 204:
                    raise RuntimeError(f"Unexpected roadmap dispatch response ({response.status}).")
                return
        except urllib.error.HTTPError as error:
            status = error.code
            retry_after = error.headers.get("Retry-After")
            error.close()
            if status not in RETRYABLE_STATUS:
                raise RuntimeError(f"Roadmap dispatch failed (HTTP {status}); check workflow access.") from None
        except (urllib.error.URLError, TimeoutError):
            status = "network/timeout"
        if attempt == 3:
            raise RuntimeError(f"Roadmap dispatch failed after four attempts ({status}).")
        delay = retry_delay(retry_after, attempt)
        if delay >= deadline - time.monotonic():
            raise RuntimeError("Roadmap dispatch exceeded its retry budget.")
        print(f"Roadmap dispatch retry {attempt + 1}/3 ({status}) in {delay}s.", file=sys.stderr)
        sleep(delay)


def main():
    try:
        dispatch(os.environ.get("WEBSITE_ROADMAP_DISPATCH_TOKEN"))
    except RuntimeError as error:
        print(f"Website roadmap refresh failed: {error}", file=sys.stderr)
        return 1
    print("Requested fresh website roadmap verification; check the website workflow for publication.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
