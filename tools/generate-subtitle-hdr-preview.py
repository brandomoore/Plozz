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
DURATION = 16
SHADOW = (0.6, 1.8, 4.5)
BLUE = (22, 45, 85)
HIGHLIGHT = (1000, 1000, 1000)
PEAK_LUMINANCE = sum(weight * value for weight, value in zip((0.2627, 0.678, 0.0593), HIGHLIGHT))


def scene_nits(x, y, seconds):
    phase = 2 * math.pi * seconds / DURATION
    center = 0.45 + 0.22 * math.sin(phase) + 0.16 * math.sin(2.8 * x - 0.55 * math.cos(phase))
    distance = y - center
    wash = math.exp(-(distance / 0.38) ** 2)
    glint = (
        math.exp(-((distance - 0.08) / 0.045) ** 2)
        * (0.72 + 0.28 * math.cos(2 * math.pi * (x - 0.5 - 0.12 * math.cos(phase))))
    )
    base = [low + (high - low) * wash for low, high in zip(SHADOW, BLUE)]
    return tuple(value + (peak - value) * glint for value, peak in zip(base, HIGHLIGHT))


def authored_average(seconds):
    samples = [
        scene_nits(x / 128, y / 72, seconds)
        for y in range(72) for x in range(128)
    ]
    return sum(0.2627 * r + 0.678 * g + 0.0593 * b for r, g, b in samples) / len(samples)


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
    highlights = sum(value > 400 for value in samples) / len(samples)
    expected_average = authored_average(0)
    if not 900 < peak < 1100 or abs(average - expected_average) > 5 or not 0.02 < highlights < 0.12:
        raise SystemExit(f"HDR pixel verification failed: peak={peak}, mean={average} nits.")
    if not PEAK_LUMINANCE * 0.9 < max(samples) < PEAK_LUMINANCE * 1.1:
        raise SystemExit("The decoded scene must retain actual luminance above SDR reference white.")
    if abs(float(stream["duration"]) - DURATION) > 0.02:
        raise SystemExit("Unexpected HDR loop duration.")
    return {"stream": stream, "decodedPeakChannelNits": peak, "sampledPeakLuminanceNits": max(samples),
            "sampledFrameAverageNits": average,
            "highlightFractionAbove400Nits": highlights}


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
    # A broad blue wash and a luminous crease move together, without circular hotspots.
    phase = f"(2*PI*T/{DURATION})"
    center = f"(0.45+0.22*sin({phase})+0.16*sin(2.8*X/W-0.55*cos({phase})))"
    distance = f"(Y/H-{center})"
    wash = f"exp(-pow({distance}/0.38,2))"
    glint = (
        f"exp(-pow(({distance}-0.08)/0.045,2))"
        f"*(0.72+0.28*cos(2*PI*(X/W-0.5-0.12*cos({phase}))))"
    )
    components = []
    for low, high, peak in zip(SHADOW, BLUE, HIGHLIGHT):
        base = f"({low}+({high}-{low})*{wash})"
        components.append(pq_expression(f"{base}+({peak}-{base})*{glint}"))
    video_filter = (
        f"nullsrc=s=640x360:r=60:d={DURATION},format=gbrp16le,"
        f"geq=r='{components[0]}':g='{components[1]}':b='{components[2]}',"
        "scale=1920:1080:flags=spline+accurate_rnd+full_chroma_int:"
        "in_color_matrix=bt2020:out_color_matrix=bt2020:in_range=full:out_range=tv,"
        "format=yuv420p10le"
    )
    averages = [authored_average(index / 4) for index in range(DURATION * 4)]
    average_nits = averages[0]
    max_fall = math.ceil(max(averages) + 2)
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
        f"max-cll={math.ceil(PEAK_LUMINANCE)},{max_fall}",
        "-movflags", "+faststart", str(output),
    ], check=True, timeout=600)
    report = verify(output, ffmpeg, ffprobe)
    print(json.dumps({"asset": str(output), "bytes": output.stat().st_size,
                      "authoredPeakLuminanceNits": PEAK_LUMINANCE, "authoredAverageNits": average_nits,
                      **report}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    generate(args.output.resolve(), args.verify_only)
