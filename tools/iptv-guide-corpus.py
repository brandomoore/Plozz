#!/usr/bin/env python3
"""Capture public XMLTV guides for opt-in, offline production-parser tests.

Never downloads streams or artwork. Raw public snapshots remain in ignored
.build storage. An independent XML reader supplies exact-ID reference counts;
those do not establish fuzzy matching accuracy or a commercial provider's limits.
"""

import argparse
from datetime import datetime, timedelta, timezone
import gzip
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import xml.etree.ElementTree as ET


SOURCES = {
    "pluto-us": "https://i.mjh.nz/PlutoTV/us.xml.gz",
    "epgshare-us": "https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz",
}
MAXIMUM_COMPRESSED_BYTES = 32 * 1024 * 1024
MAXIMUM_EXPANDED_BYTES = 256 * 1024 * 1024


def timestamp(text):
    if text is None:
        return None
    parts = text.strip().split()
    if not parts or len(parts) > 2 or len(parts[0]) not in (4, 6, 8, 10, 12, 14):
        return None
    digits = parts[0]
    if not digits.isascii() or not digits.isdigit():
        return None
    digits += "0101000000"[len(digits) - 4:]
    offset = parts[1] if len(parts) == 2 else "+0000"
    if offset in ("UTC", "GMT", "Z"):
        offset = "+0000"
    try:
        return datetime.strptime(digits + " " + offset, "%Y%m%d%H%M%S %z")
    except ValueError:
        return None


def inspect(data, now):
    """Reference only explicitly timed, nonempty programmes on sampled exact IDs."""
    lower, upper = now - timedelta(days=1), now + timedelta(days=7)
    names, listings = {}, {}
    total = 0
    with gzip.GzipFile(fileobj=io.BytesIO(data)) as compressed:
        xml = compressed.read(MAXIMUM_EXPANDED_BYTES + 1)
    if len(xml) > MAXIMUM_EXPANDED_BYTES:
        raise ValueError("Expanded guide exceeds the corpus budget")
    for event, element in ET.iterparse(io.BytesIO(xml), events=("end",)):
        if element.tag == "channel":
            identity = element.get("id")
            if identity:
                names.setdefault(identity, element.findtext("display-name") or identity)
            element.clear()
        elif element.tag == "programme":
            total += 1
            identity = element.get("channel")
            start, end = timestamp(element.get("start")), timestamp(element.get("stop"))
            title = element.findtext("title")
            if identity and start and end and end > start and start < upper and end > lower and title and title.strip():
                listings.setdefault(identity, set()).add((start.timestamp(), end.timestamp()))
            element.clear()
    identities = sorted(identity for identity in listings if identity in names)[:12]
    if not identities:
        raise ValueError("Guide has no current, explicitly timed sample channels")
    return {
        "expandedBytes": len(xml),
        "guideChannels": len(names),
        "sourceProgrammes": total,
        "channels": [
            {
                "id": identity, "name": names[identity],
                "intervals": [list(interval) for interval in sorted(listings[identity])],
            }
            for identity in identities
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / ".build/iptv-guide-corpus")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).replace(microsecond=0)
    rows = []
    for name, url in SOURCES.items():
        request = urllib.request.Request(url, headers={"User-Agent": "Plozz-guide-compatibility"})
        with urllib.request.urlopen(request, timeout=45) as response:
            if response.status != 200:
                raise ValueError(f"{name}: HTTP {response.status}")
            data = response.read(MAXIMUM_COMPRESSED_BYTES + 1)
        if len(data) > MAXIMUM_COMPRESSED_BYTES:
            raise ValueError(f"{name}: Compressed guide exceeds the corpus budget")
        row = dict(name=name, url=url, file=name + ".xml.gz", bytes=len(data),
                   sha256=hashlib.sha256(data).hexdigest(), **inspect(data, now))
        (args.output / row["file"]).write_bytes(data)
        rows.append(row)
        print(f"{name}: {row['guideChannels']} stations, {row['sourceProgrammes']} programmes, {len(data)} compressed bytes")
    manifest = {"capturedAt": now.timestamp(), "sources": rows}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Manifest: {args.output / 'manifest.json'}")


if __name__ == "__main__":
    main()
