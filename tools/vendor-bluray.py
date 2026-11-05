#!/usr/bin/env python3
"""Import the pinned, unmodified HDMV sources; platform adapters remain separate."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    pin = json.loads((root / "tools/disc-menu-lab/dependencies.json").read_text())["libbluray"]
    if hashlib.sha256(args.archive.read_bytes()).hexdigest() != pin["sha256"]:
        raise SystemExit("libbluray archive checksum mismatch")
    destination = root / "Vendor/Libbluray"
    with tarfile.open(args.archive) as archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if not member.isfile() or path.parts[0] != pin["root"]:
                continue
            relative = PurePosixPath(*path.parts[1:])
            if ".." in relative.parts:
                raise SystemExit("Invalid archive path")
            selected = (
                str(relative) == "COPYING"
                or str(relative) == "contrib/libudfread/COPYING"
                or (str(relative).startswith("src/") and relative.suffix in (".c", ".h"))
                or (str(relative).startswith("contrib/libudfread/src/") and relative.suffix in (".c", ".h"))
            )
            if not selected:
                continue
            source = archive.extractfile(member)
            if source is None:
                raise SystemExit("Missing archive member")
            output = destination / str(relative)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(source.read())
        version = archive.extractfile(f"{pin['root']}/src/libbluray/bluray-version.h.in")
        if version is None:
            raise SystemExit("Missing version template")
        text = version.read().decode()
        for name, value in (("MAJOR", "1"), ("MINOR", "5"), ("MICRO", "0")):
            text = text.replace(f"@BLURAY_VERSION_{name}@", value)
        (destination / "src/libbluray/bluray-version.h").write_text(text)
    (destination / "UPSTREAM.json").write_text(json.dumps(pin, indent=2) + "\n")
    notices = (
        "libbluray 1.5.0 and bundled libudfread\n"
        f"Source archive: {pin['url']}\n"
        "Plozz build adaptations: Vendor/Libbluray and Sources/DiscNavigation.\n\n"
        + (destination / "COPYING").read_text()
        + "\n\nBundled libudfread:\n\n"
        + (destination / "contrib/libudfread/COPYING").read_text()
    )
    (root / "App/Resources/LibblurayNotices.txt").write_text(notices)


if __name__ == "__main__":
    main()
