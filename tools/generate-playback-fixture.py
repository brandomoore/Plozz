#!/usr/bin/env python3
"""Generate a synthetic, native-compatible video with an audible sine track.

Import the result into dedicated test libraries yourself. No server or library
administration is performed, and existing files are never overwritten.
"""
import argparse
from pathlib import Path
import subprocess
import sys


def command(output):
    return [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-n",
        "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-t", "90", "-c:v", "libx264", "-preset", "veryfast", "-threads", "2",
        "-pix_fmt", "yuv420p", "-profile:v", "high", "-g", "48",
        "-b:v", "4000k", "-minrate", "4000k", "-maxrate", "4000k", "-bufsize", "8000k",
        "-x264-params", "nal-hrd=cbr", "-c:a", "aac", "-b:a", "128k", "-ac", "2",
        "-movflags", "+faststart", str(output),
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(".build/provider-playback-fixtures/Plozz-E2E-SDR.mp4"))
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error("Output already exists; use a new path.")
    output.parent.mkdir(parents=True, exist_ok=True)
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run([
        sys.executable, str(root / "tools/run-bounded.py"), "240", "synthetic playback fixture", "--",
        *command(output),
    ])
    if result.returncode:
        print("Fixture generation failed; partial output retained.", file=sys.stderr)
        return result.returncode
    print(f"Generated synthetic 90-second 1080p H.264 / AAC stereo fixture: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
