#!/usr/bin/env python3
"""Generate Plozz's original, silent HDR10 subtitle-preview loop.

The procedural scene is authored in nits, encoded with the ST 2084 transfer
function, and tagged BT.2020/HDR10. No external footage or font assets are used.
Requires ffmpeg with libx265 and ffprobe; no network access is performed.
"""

import argparse
import array
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "Sources/FeaturePlayback/Resources/SubtitleHDRPreview.mp4"
DURATION = 8


def pq_expression(nits):
    normalized = f"pow(({nits})/10000,2610/16384)"
    return f"65535*pow((3424/4096+(2413/128)*{normalized})/(1+(2392/128)*{normalized}),2523/32)"

def verify(output, ffmpeg, ffprobe):
    probe = json.loads(subprocess.check_output([
        ffprobe, "-v", "error", "-select_streams", "v:0",
        "-show_entries",
        "stream=codec_name,profile,pix_fmt,color_space,color_transfer,color_primaries,width,height,r_frame_rate,duration",
        "-of", "json", str(output),
    ], text=True))
    stream = probe["streams"][0]
    expected = {
        "codec_name": "hevc", "profile": "Main 10", "pix_fmt": "yuv420p10le",
        "color_space": "bt2020nc", "color_transfer": "smpte2084", "color_primaries": "bt2020",
        "width": 1920, "height": 1080, "r_frame_rate": "60/1",
    }
    for key, value in expected.items():
        if stream.get(key) != value:
            raise SystemExit(f"Unexpected HDR asset {key}: {stream.get(key)!r}, expected {value!r}")
    raw = subprocess.check_output([
        ffmpeg, "-v", "error", "-i", str(output),
        "-vf", "scale=in_color_matrix=bt2020:out_color_matrix=bt2020:in_range=tv:out_range=full,format=gbrp16le",
        "-frames:v", "1", "-f", "rawvideo", "pipe:1",
    ], timeout=60)
    values = array.array("H")
    values.frombytes(raw)
    if sys.byteorder != "little":
        values.byteswap()
    plane = stream["width"] * stream["height"]
    if len(values) != plane * 3:
        raise SystemExit("Unexpected decoded HDR frame size.")

    def nits(value):
        p = (value / 65535) ** (32 / 2523)
        return 10000 * (max(p - 3424 / 4096, 0) / (2413 / 128 - 2392 / 128 * p)) ** (16384 / 2610)

    peak = max(nits(max(values[i * plane:(i + 1) * plane])) for i in range(3))
    samples = [
        0.678 * nits(values[i]) + 0.0593 * nits(values[plane + i]) + 0.2627 * nits(values[2 * plane + i])
        for i in range(0, plane, 509)
    ]
    average = sum(samples) / len(samples)
    if not 900 < peak < 1100 or not 90 < average < 130:
        raise SystemExit(f"HDR pixel verification failed: peak={peak}, mean={average} nits.")
    return {"stream": stream, "decodedPeakNits": peak, "sampledFrameAverageNits": average}


def generate(output, verify_only=False):
    ffmpeg = shutil.which("ffmpeg")
    ffprobe = shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise SystemExit("ffmpeg (with libx265) and ffprobe are required.")
    if verify_only:
        print(json.dumps(verify(output, ffmpeg, ffprobe), indent=2))
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    # A low-frequency field can be authored at 640x360 and smoothly upsampled.
    # Both phases are periodic in eight seconds, including their derivatives.
    wave = (
        f"(2+sin(2*PI*X/W+0.8*sin(2*PI*T/{DURATION}))"
        f"+cos(2*PI*Y/H+0.7*cos(2*PI*T/{DURATION})))/4"
    )
    intensity = f"pow(({wave}),6)"
    components = [pq_expression(f"{floor}+(1000-{floor})*{intensity}") for floor in (0.2, 0.7, 1.8)]
    video_filter = (
        f"nullsrc=s=640x360:r=60:d={DURATION},format=gbrp16le,"
        f"geq=r='{components[0]}':g='{components[1]}':b='{components[2]}',"
        "scale=1920:1080:flags=spline+accurate_rnd+full_chroma_int:"
        "in_color_matrix=bt2020:out_color_matrix=bt2020:in_range=full:out_range=tv,"
        "format=yuv420p10le"
    )
    # The source's frame-average luminance is invariant under the periodic shifts.
    moment = 0.0
    for i in range(0, 7, 2):
        for j in range(0, 7 - i, 2):
            k = 6 - i - j
            moment += (
                math.factorial(6) / (math.factorial(i) * math.factorial(j) * math.factorial(k))
                * 2**k * math.comb(i, i // 2) / 2**i
                * math.comb(j, j // 2) / 2**j / 4**6
            )
    average_nits = 0.63388 + (1000 - 0.63388) * moment
    max_fall = math.ceil(average_nits + 2)
    subprocess.run([
        ffmpeg, "-hide_banner", "-loglevel", "warning", "-y",
        "-f", "lavfi", "-i", video_filter,
        "-an", "-c:v", "libx265", "-preset", "medium", "-crf", "18",
        "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1",
        "-color_primaries", "bt2020", "-color_trc", "smpte2084",
        "-colorspace", "bt2020nc", "-color_range", "tv",
        "-x265-params",
        "pools=4:frame-threads=2:log-level=error:repeat-headers=1:"
        "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:"
        "master-display=G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1):"
        f"max-cll=1000,{max_fall}",
        "-movflags", "+faststart", str(output),
    ], check=True, timeout=600)
    report = verify(output, ffmpeg, ffprobe)
    print(json.dumps({"asset": str(output), "bytes": output.stat().st_size,
                      "authoredPeakNits": 1000, "authoredAverageNits": average_nits,
                      **report}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    generate(args.output.resolve(), args.verify_only)
