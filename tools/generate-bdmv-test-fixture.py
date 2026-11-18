#!/usr/bin/env python3
"""Generate original test-pattern clips and a two-clip Blu-ray playlist fixture."""
import argparse
from pathlib import Path
import struct
import subprocess


def playlist(clips):
    items = bytearray()
    for clip, seconds in clips:
        body = clip.encode("ascii") + b"M2TS"
        body += struct.pack(">H B II", 1, 0, 0, seconds * 45000)
        body += bytes(12)
        items += struct.pack(">H", len(body)) + body
    content = struct.pack(">HHH", 0, len(clips), 0) + items
    header = b"MPLS0200" + struct.pack(">III", 40, 0, 0) + bytes(20)
    return header + struct.pack(">I", len(content)) + content


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    output = parser.parse_args().output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    for name in ("PLAYLIST", "STREAM", "CLIPINF"):
        (output / "BDMV" / name).mkdir(parents=True)
    # Recognition is playlist-driven; this synthetic index has no menus or BD-J.
    (output / "BDMV/index.bdmv").write_bytes(b"INDX0200" + bytes(32))
    for clip, color, frequency, duration in (
        ("00001", "red", 440, 8), ("00002", "blue", 880, 8), ("00003", "green", 220, 20),
        ("00004", "yellow", 660, 8)
    ):
        mapping = ["-map", "0:v", "-map", "1:a"]
        if clip == "00004":
            mapping += ["-map", "1:a"]
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-n",
            "-f", "lavfi", "-i", f"color=c={color}:size=1280x720:rate=24",
            "-f", "lavfi", "-i", f"sine=frequency={frequency}:sample_rate=48000",
            *mapping,
            "-t", str(duration), "-c:v", "libx264", "-preset", "veryfast",
            "-threads", "2", "-pix_fmt", "yuv420p", "-g", "24", "-bf", "0",
            "-c:a", "ac3", "-b:a", "192k", "-ac", "2",
            "-mpegts_m2ts_mode", "1", "-muxdelay", "0", "-muxpreload", "0",
            "-f", "mpegts", str(output / f"BDMV/STREAM/{clip}.m2ts"),
        ], check=True, timeout=120)
    (output / "BDMV/PLAYLIST/00001.mpls").write_bytes(playlist([("00001", 8), ("00002", 8)]))
    # The largest clip is deliberately NOT the main title.
    (output / "BDMV/PLAYLIST/00002.mpls").write_bytes(playlist([("00003", 2)]))
    print(output)


if __name__ == "__main__":
    main()
