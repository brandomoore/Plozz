"""Build the isolated AetherEngine adapter with the application's exact dependency lock."""
import argparse
import json
from pathlib import Path
import shutil

from lab import HERE, ROOT, WORK, Lab


def build(lab, *, simulator=False):
    source = HERE / "player"
    package = WORK / "player-package"
    package.mkdir(exist_ok=True)
    shutil.copy2(source / "Package.swift", package / "Package.swift")
    shutil.copytree(source / "Sources", package / "Sources", dirs_exist_ok=True)
    lock = json.loads((ROOT / "Package.resolved").read_text())
    engine = next(pin for pin in lock["pins"] if pin["identity"].lower() == "aetherengine")
    if engine["state"]["revision"] not in (source / "Package.swift").read_text():
        raise ValueError("Lab player pin must match Plozz's resolved engine revision")
    shutil.copy2(ROOT / "Package.resolved", package / "Package.resolved")
    xcode_lock = package / ".swiftpm/xcode/package.xcworkspace/xcshareddata/swiftpm"
    xcode_lock.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "Package.resolved", xcode_lock / "Package.resolved")
    variant = "simulator" if simulator else "device"
    derived = WORK / f"player-{variant}-derived-data"
    workspace = ROOT / ".build/package-workspaces/disc-menu-player"
    destination = "generic/platform=tvOS Simulator" if simulator else "generic/platform=tvOS"
    lab.run("resolve-isolated-player-lock", [
        "xcodebuild", "-resolvePackageDependencies", "-scheme", "DiscMenuPlayer",
        "-clonedSourcePackagesDirPath", workspace,
        "-packageCachePath", Path.home() / "Library/Caches/org.swift.swiftpm",
        "-skipPackageUpdates",
    ], cwd=package, timeout=600)
    resolved = json.loads((package / "Package.resolved").read_text())
    expected = {pin["identity"].lower(): pin for pin in lock["pins"]}
    for pin in resolved["pins"]:
        original = expected.get(pin["identity"].lower())
        if original is None or pin["state"] != original["state"]:
            raise ValueError(f"Isolated player changed dependency {pin['identity']}")
    lab.run(f"build-aether-player-{variant}", [
        "xcodebuild", "-scheme", "DiscMenuPlayer", "-configuration", "Debug",
        "-destination", destination, "-derivedDataPath", derived,
        "-clonedSourcePackagesDirPath", workspace,
        "-packageCachePath", Path.home() / "Library/Caches/org.swift.swiftpm",
        "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates",
        "CODE_SIGNING_ALLOWED=NO", "SWIFT_INSTALL_OBJC_HEADER=YES",
        "-jobs", "4", "build",
    ], cwd=package, timeout=1800)
    products = derived / "Build/Products" / (
        "Debug-appletvsimulator" if simulator else "Debug-appletvos"
    )
    (lab.run_dir / "player-build.json").write_text(json.dumps({
        "status": "built", "products": str(products), "simulator": simulator,
        "aether_revision": engine["state"]["revision"],
    }, indent=2) + "\n")
    return products


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator", action="store_true")
    arguments = parser.parse_args()
    build(Lab(), simulator=arguments.simulator)
