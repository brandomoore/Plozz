#!/usr/bin/env python3
"""Embed and sign a previously built, matching-platform BD-J runtime."""
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile


def replace_file(source, destination):
    descriptor, temporary = tempfile.mkstemp(prefix=".disc-runtime-", dir=Path(destination).parent)
    os.close(descriptor)
    try:
        shutil.copy2(source, temporary)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return destination


def main():
    root = Path(__file__).resolve().parents[1]
    sdk = os.environ["PLATFORM_NAME"]
    receipt = root / ".build/disc-runtime" / f"{sdk}.json"
    if not receipt.is_file():
        raise SystemExit(f"Missing BD-J runtime. Run python3 tools/build-disc-runtime.py --sdk {sdk}")
    info = json.loads(receipt.read_text())
    current = runpy.run_path(str(root / "tools/build-disc-runtime.py"))["source_fingerprint"]()
    if info.get("sourceFingerprint") != current:
        raise SystemExit(f"Outdated BD-J runtime. Run python3 tools/build-disc-runtime.py --sdk {sdk}")
    source = Path(info["runtime"]).resolve()
    if info["sdk"] != sdk or not source.is_relative_to(root / ".build/disc-menu-lab/runs"):
        raise SystemExit("Invalid BD-J runtime build receipt")
    destination = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / "DiscRuntime"
    shutil.copytree(source, destination, dirs_exist_ok=True, copy_function=replace_file)
    if os.environ.get("CODE_SIGNING_ALLOWED") != "NO":
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
        for library in sorted(destination.rglob("*.dylib")):
            subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", str(library)],
                           check=True, timeout=30)


if __name__ == "__main__":
    main()
