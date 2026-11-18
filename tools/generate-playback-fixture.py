#!/usr/bin/env python3
"""Generate a synthetic, native-compatible video with an audible sine track.

Import the result into dedicated test libraries yourself. No server or library
administration is performed, and existing files are never overwritten.
"""
import argparse
from pathlib import Path
import runpy
import subprocess
import sys


def command(output, offline_downloads=False):
    if offline_downloads:
        return [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-n",
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000",
            "-t", "24", "-map", "0:v", "-map", "1:a", "-map", "2:a",
            "-c:v", "libx264", "-preset", "veryfast", "-threads", "2",
            "-pix_fmt", "yuv420p", "-g", "48", "-b:v", "800k",
            "-c:a", "aac", "-b:a", "64k", "-ac", "1",
            "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=fra",
            "-disposition:a:0", "default", "-disposition:a:1", "0",
            "-movflags", "+faststart", str(output),
        ]
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
    parser.add_argument("--offline-downloads", action="store_true",
                        help="Generate a 24-second two-language fixture plus primary.mp4 and alternate.m4a.")
    args = parser.parse_args()
    output = args.output.resolve()
    companions = [output.with_name("primary.mp4"), output.with_name("alternate.m4a")]
    outputs = [output, *companions] if args.offline_downloads else [output]
    if len(set(outputs)) != len(outputs) or any(path.exists() for path in outputs):
        parser.error("Outputs must be distinct and must not exist; use a new directory.")
    output.parent.mkdir(parents=True, exist_ok=True)
    root = Path(__file__).resolve().parents[1]
    lease_fds = runpy.run_path(str(root / "tools/run-bounded.py"))["inherited_lease_fds"]()
    result = subprocess.run([
        sys.executable, str(root / "tools/run-bounded.py"), "240", "synthetic playback fixture", "--",
        *command(output, args.offline_downloads),
    ], pass_fds=lease_fds)
    if result.returncode:
        print("Fixture generation failed; partial output retained.", file=sys.stderr)
        return result.returncode
    if args.offline_downloads:
        result = subprocess.run([
            sys.executable, str(root / "tools/run-bounded.py"), "60", "offline fixture tracks", "--",
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-n", "-i", str(output),
            "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", "-movflags", "+faststart", str(companions[0]),
            "-map", "0:a:1", "-c", "copy", str(companions[1]),
        ], pass_fds=lease_fds)
        if result.returncode:
            print("Track fixture generation failed; output retained.", file=sys.stderr)
            return result.returncode
    print(f"Generated synthetic playback fixture: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
