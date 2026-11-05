#!/usr/bin/env python3
"""Generate original Java navigation metadata over the existing color/sine clips."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools/disc-menu-lab"))
import fixture


def main():
    work = ROOT / ".build/disc-menu-lab"
    pins = json.loads((ROOT / "tools/disc-menu-lab/dependencies.json").read_text())
    pin = pins["host-jdk"]
    java = work / "dependencies" / f"host-jdk-{pin['sha256'][:16]}" / pin["root"] / "Contents/Home/bin"
    runtime = Path(json.loads((ROOT / ".build/disc-runtime/appletvsimulator.json").read_text())["runtime"])
    destination = ROOT / "Tests/SubtitlePresentationSupport/Fixtures/bdj-navigation/BDMV"
    for folder in ("PLAYLIST", "CLIPINF", "BDJO", "JAR"):
        (destination / folder).mkdir(parents=True, exist_ok=True)
    (destination / "index.bdmv").write_bytes(fixture.index())
    (destination / "BDJO/00000.bdjo").write_bytes(fixture.bdjo())
    for clip in ("00001", "00002"):
        original = ROOT / f"Tests/SubtitlePresentationSupport/Fixtures/bluray-test-pattern/BDMV/STREAM/{clip}.m2ts"
        size = original.stat().st_size
        if not size or size % 192:
            raise SystemExit("Invalid original M2TS fixture")
        (destination / f"PLAYLIST/{clip}.mpls").write_bytes(fixture.playlist(clip))
        (destination / f"CLIPINF/{clip}.clpi").write_bytes(fixture.clip_info(size // 192))
    classes = ROOT / ".build/bdj-fixture-classes"
    classes.mkdir(exist_ok=True)
    source = ROOT / ".build/bdj-fixture-src/MenuXlet.java"
    source.parent.mkdir(exist_ok=True)
    text = (ROOT / "tools/disc-menu-lab/MenuXlet.java").read_text()
    before = "            player.start();"
    if text.count(before) != 1:
        raise SystemExit("Original fixture playback entry changed")
    # The hosted variant exposes the real video surface after choosing a clip.
    source.write_text(text.replace(before, before + "\n            scene.setVisible(false);"))
    subprocess.run([java / "javac", "--release", "8", "-classpath",
                    runtime / "jars/libbluray-j2se-1.5.0.jar", "-d", classes,
                    source], check=True, timeout=60)
    subprocess.run([java / "jar", "--create", "--date=2026-01-01T00:00:00Z",
                    "--file", destination / "JAR/00000.jar", "-C", classes, "."], check=True, timeout=60)


if __name__ == "__main__":
    main()
