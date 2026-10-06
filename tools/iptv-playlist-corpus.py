#!/usr/bin/env python3
"""Capture public playlist inputs for the opt-in ProviderIPTV corpus test.

Downloads playlists only, never their streams, artwork, or programme guides.
Snapshots stay in ignored .build storage; ordinary tests require no network.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import urllib.error
import urllib.request


SOURCES = {
    "free-tv": "https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8",
    "iptv-org-all": "https://iptv-org.github.io/iptv/index.m3u",
    "iptv-org-news": "https://iptv-org.github.io/iptv/categories/news.m3u",
    "iptv-org-us": "https://iptv-org.github.io/iptv/countries/us.m3u",
    "iptv-org-de": "https://iptv-org.github.io/iptv/countries/de.m3u",
    "tdtchannels": "https://www.tdtchannels.com/lists/tv.m3u8",
    "kodinerds": "https://raw.githubusercontent.com/jnk22/kodinerds-iptv/master/iptv/clean/clean_tv.m3u",
    "iptv-org-ca": "https://iptv-org.github.io/iptv/countries/ca.m3u",
    "iptv-org-jp": "https://iptv-org.github.io/iptv/countries/jp.m3u",
}
MAXIMUM_BYTES = 32 * 1024 * 1024


def download(item, directory):
    name, url = item
    row = {"name": name, "url": url, "file": name + ".m3u8"}
    try:
        request = urllib.request.Request(url, headers={"User-Agent": "Plozz-playlist-compatibility"})
        with urllib.request.urlopen(request, timeout=45) as response:
            data = response.read(MAXIMUM_BYTES + 1)
            if response.status != 200:
                raise ValueError(f"HTTP {response.status}")
        if len(data) > MAXIMUM_BYTES:
            raise ValueError("Snapshot exceeds 32 MiB")
        text = data.decode("utf-8-sig")
        if not text.lstrip().startswith("#EXTM3U"):
            raise ValueError("Response is not an M3U playlist")
        entries = sum(line.startswith("#EXTINF:") for line in text.splitlines())
        if entries == 0:
            raise ValueError("Playlist contains no EXTINF entries")
        (directory / row["file"]).write_bytes(data)
        http_entries = sum(line.strip().lower().startswith(("http://", "https://")) for line in text.splitlines())
        row.update(
            bytes=len(data), entries=entries, httpEntries=http_entries,
            sha256=hashlib.sha256(data).hexdigest(),
        )
    except (OSError, ValueError, urllib.error.URLError) as error:
        row["error"] = str(error)
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path,
        default=Path(__file__).resolve().parents[1] / ".build/iptv-playlist-corpus",
    )
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=3) as pool:
        rows = list(pool.map(lambda item: download(item, args.output), SOURCES.items()))
    manifest = {"capturedAt": datetime.now(timezone.utc).isoformat(), "sources": rows}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for row in rows:
        print(f"{row['name']}: {row.get('error', str(row.get('entries', 0)) + ' entries')}")
    print(f"Manifest: {args.output / 'manifest.json'}")
    return int(any("error" in row for row in rows))


if __name__ == "__main__":
    raise SystemExit(main())
