#!/usr/bin/env python3
"""Exclude Java by default; embed the experimental runtime only in local Debug builds."""
import json
import os
from pathlib import Path
import plistlib
import re
import runpy
import shutil
import subprocess
import tempfile


def experimental_enabled(environment):
    value = environment.get("PLOZZ_EXPERIMENTAL_BDJ", "0")
    if value not in ("0", "1"):
        raise ValueError("PLOZZ_EXPERIMENTAL_BDJ must be 0 or 1")
    if value == "1" and (environment.get("CONFIGURATION") != "Debug"
                         or environment.get("ACTION") == "install"
                         or environment.get("PLOZZ_RELEASE_CHANNEL")):
        raise ValueError("Experimental Java disc menus are restricted to local Debug builds")
    return value == "1"


def remove_runtime(app):
    """Remove only this embedder's outputs when reusing an experimental build directory."""
    targets = [app / "DiscRuntime"]
    frameworks = app / "Frameworks"
    if frameworks.is_symlink():
        raise ValueError("Refusing to clean a symlinked Frameworks directory")
    if frameworks.is_dir():
        targets += [path for path in frameworks.iterdir()
                    if path.name.startswith("PlozzBDJ") and path.suffix == ".framework"]
    for path in targets:
        if path.is_symlink():
            path.unlink()
        elif path.exists():
            if not path.resolve().is_relative_to(app.resolve()):
                raise ValueError("Disc runtime output escapes the application bundle")
            if not path.is_dir():
                raise ValueError(f"Unexpected disc runtime output: {path.name}")
            shutil.rmtree(path)


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


def framework_name(library):
    match = re.fullmatch(r"lib([A-Za-z0-9_]+)\.dylib", library)
    if not match:
        raise ValueError(f"Unexpected runtime library name: {library}")
    return "PlozzBDJ" + match[1]


def framework_install_name(library):
    name = framework_name(library)
    return f"@rpath/{name}.framework/{name}"


def embed_libraries(source, frameworks, sdk, minimum_os, bundle_id, identity):
    platforms = {
        "appletvos": "AppleTVOS", "appletvsimulator": "AppleTVSimulator",
        "iphoneos": "iPhoneOS", "iphonesimulator": "iPhoneSimulator",
    }
    libraries = {}
    for library in sorted((source / "lib").rglob("*.dylib")):
        framework_name(library.name)
        if library.name in libraries and library.read_bytes() != libraries[library.name].read_bytes():
            raise ValueError(f"Conflicting runtime library copies: {library.name}")
        libraries[library.name] = library
    if "libjvm.dylib" not in libraries:
        raise ValueError("Runtime is missing its JVM library")
    for filename, library in libraries.items():
        name = framework_name(filename)
        directory = frameworks / f"{name}.framework"
        directory.mkdir(parents=True, exist_ok=True)
        binary = directory / name
        replace_file(library, binary)
        binary.chmod(0o755)
        output = subprocess.check_output(["otool", "-L", str(binary)], text=True, timeout=30)
        changes = ["install_name_tool", "-id", framework_install_name(filename)]
        for line in output.splitlines()[2:]:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            dependency_name = Path(dependency).name
            if dependency_name not in libraries:
                raise ValueError(f"Unbundled runtime dependency: {filename}: {dependency}")
            changes.extend(["-change", dependency, framework_install_name(dependency_name)])
        subprocess.run([*changes, str(binary)], check=True, timeout=30)
        metadata = {
            "CFBundleExecutable": name,
            "CFBundleIdentifier": f"{bundle_id}.bdj.{filename[3:-6].replace('_', '-')}",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": name,
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleSupportedPlatforms": [platforms[sdk]],
            "MinimumOSVersion": minimum_os,
        }
        with (directory / "Info.plist").open("wb") as stream:
            plistlib.dump(metadata, stream)
        if identity is not None:
            subprocess.run(["codesign", "--force", "--sign", identity, "--timestamp=none", str(directory)],
                           check=True, timeout=30)


def main():
    root = Path(__file__).resolve().parents[1]
    enabled = experimental_enabled(os.environ)
    build = Path(os.environ["TARGET_BUILD_DIR"]).resolve()
    app = build / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"]
    if app.is_symlink() or not app.resolve().is_relative_to(build) or app == build:
        raise ValueError("Invalid app resource destination")
    if not enabled:
        remove_runtime(app)
        print("Native disc navigation: Java runtime excluded.")
        return
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
    destination = app / "DiscRuntime"
    # Relinking invalidates the linker signature; arm64 simulator loading still
    # requires an ad-hoc signature when Xcode's app signing phase is disabled.
    identity = "-" if os.environ.get("CODE_SIGNING_ALLOWED") == "NO" else (
        os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-")
    minimum_os = os.environ["IPHONEOS_DEPLOYMENT_TARGET" if sdk.startswith("iphone") else "TVOS_DEPLOYMENT_TARGET"]
    embed_libraries(source, build / os.environ["FRAMEWORKS_FOLDER_PATH"], sdk, minimum_os,
                    os.environ["PRODUCT_BUNDLE_IDENTIFIER"], identity)
    shutil.copytree(source, destination, dirs_exist_ok=True, copy_function=replace_file,
                    ignore=shutil.ignore_patterns("*.dylib"))
    for library in destination.rglob("*.dylib"):
        library.unlink()
    for resource in destination.rglob("*"):
        if resource.is_file():
            resource.chmod(0o644)


if __name__ == "__main__":
    main()
