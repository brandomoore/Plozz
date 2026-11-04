#!/usr/bin/env python3
"""Build a credential-free, unsigned device IPA from tracked working-tree files."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = {
    "ios": ("PlozziOS", "iOS", "iPhoneOS", "IOS"),
    "tvos": ("Plozz", "tvOS", "AppleTVOS", "TVOS"),
}
EMPTY_INFO_KEYS = (
    "OMDBAPIKey", "TMDBBearerToken", "TMDBProxyBaseURL", "TVDBAPIKey",
    "TraktClientID", "WetrakrClientID", "MALClientID", "SimklClientID",
    "AniListClientID", "AniListClientSecret", "LastFmAPIKey", "LastFmSharedSecret",
    "PlozzSentryDSN", "PlozzReleaseChannel", "PlozzReleaseID", "PlozzReleaseVersion",
)
MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe",
                b"\xca\xfe\xba\xbf", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"}


def command(args, *, cwd, env, fds=(), timeout=120, log=None):
    with log.open("wb") if log else open(os.devnull, "wb") as stream:
        process = subprocess.Popen(
            args, cwd=cwd, env=env, pass_fds=fds, start_new_session=True,
            stdout=stream if log else subprocess.PIPE,
            stderr=subprocess.STDOUT if log else subprocess.PIPE,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            except ProcessLookupError:
                pass
            raise
        finally:
            for pipe in (process.stdout, process.stderr):
                if pipe is not None:
                    pipe.close()
        if process.returncode:
            detail = f"; see {log}" if log else f": {(stderr or b'').decode(errors='replace')}"
            raise RuntimeError(f"{Path(args[0]).name} failed ({process.returncode}){detail}")
        return (stdout or b"").decode()


def snapshot(root, destination, paths):
    digest = hashlib.sha256()
    for name in sorted(paths):
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid tracked source path")
        source = root / relative
        if source.is_symlink() or any((root / parent).is_symlink() for parent in relative.parents):
            raise ValueError(f"Tracked source must not follow symlinks: {name}")
        if not source.exists():  # Include tracked working-tree deletions.
            continue
        if not source.is_file():
            raise ValueError(f"Expected a tracked file, not a submodule: {name}")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        digest.update(name.encode() + b"\0" + hashlib.sha256(target.read_bytes()).digest())
    return digest.hexdigest()


def build_environment(parent, source, build_number):
    allowed = {"PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "DEVELOPER_DIR", "LANG", "LC_ALL"}
    env = {key: value for key, value in parent.items()
           if key in allowed or key.startswith("APPLE_BUILD_LEASE_")}
    env.update({
        "GIT_CONFIG_PARAMETERS": "'safe.bareRepository=all'",
        "XDG_CONFIG_HOME": str(source / ".empty-config"),
        "PLOZZ_BUILD_NUMBER": build_number,
        "PLOZZ_ID_SUFFIX": ".selfbuild",
        "PLOZZ_NAME_SUFFIX": " Self-build",
        "PLOZZ_PAIRING_SERVICE_TYPE": "_plozz-self._tcp",
        "PLOZZ_URL_SCHEME": "plozz-selfbuild",
        "PLOZZ_TV_APP_ENTITLEMENTS": "App/Resources/Plozz.branded.entitlements",
        "PLOZZ_TV_TOPSHELF_ENTITLEMENTS": "TopShelf/TopShelf.branded.entitlements",
        "PLOZZ_IOS_APP_ENTITLEMENTS": "App/PlozziOS/PlozziOS.branded.entitlements",
    })
    return env


def prepare_public_config(source):
    # Prevent both generator and scheme pre-action from linking machine-local keys.
    private = source / "Config/Secrets.local.xcconfig"
    if private.exists() or private.is_symlink() or (source / ".env.fastlane").exists():
        raise ValueError("Private configuration must not be tracked in an unsigned build")
    private.write_text("// Intentionally empty for unsigned self-builds.\n")
    for line in (source / "Config/Secrets.xcconfig").read_text().splitlines():
        if re.match(r"^[A-Z][A-Z0-9_]*\s*=", line) and line.split("=", 1)[1].strip():
            raise ValueError("Committed integration defaults must be empty")


def verify_info(info, platform, *, extension=False, app_version=None):
    suffix = ".TopShelf" if extension else ""
    if info.get("CFBundleIdentifier") != "com.thatcube.Plozz.selfbuild" + suffix:
        raise ValueError("Unexpected self-build bundle identity")
    if info.get("CFBundleSupportedPlatforms") != [PLATFORMS[platform][2]]:
        raise ValueError("IPA must contain the selected device platform")
    for key in EMPTY_INFO_KEYS:
        if info.get(key, "") != "":
            raise ValueError(f"Unsigned build contains unexpected configuration: {key}")
    version = (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
    if not all(version) or (app_version is not None and version != app_version):
        raise ValueError("App and extension version identities must match")
    return version


def macho_files(app):
    result = []
    for path in sorted(app.rglob("*")):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGICS:
                    result.append(path)
    if not result:
        raise ValueError("App contains no Mach-O executables")
    return result


def verify_and_unsign(app, platform, run):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    version = verify_info(info, platform)
    extensions = list((app / "PlugIns").glob("*.appex"))
    if len(extensions) != (1 if platform == "tvos" else 0):
        raise ValueError("Unexpected app extension set")
    for extension in extensions:
        verify_info(plistlib.loads((extension / "Info.plist").read_bytes()), platform,
                    extension=True, app_version=version)
    if list(app.rglob("embedded.mobileprovision")):
        raise ValueError("Unsigned output must not contain provisioning profiles")
    binaries = macho_files(app)
    if app / info.get("CFBundleExecutable", "") not in binaries:
        raise ValueError("Missing app executable")
    for extension in extensions:
        ext_info = plistlib.loads((extension / "Info.plist").read_bytes())
        if extension / ext_info.get("CFBundleExecutable", "") not in binaries:
            raise ValueError("Missing extension executable")
    framework_names = {p.parent.name for p in binaries if p.parent.suffix == ".framework"}
    if "AetherEngine.framework" not in framework_names:
        raise ValueError("Missing embedded playback engine")
    inventory = []
    for binary in binaries:
        archs = run(["xcrun", "lipo", "-archs", str(binary)]).strip().split()
        if "arm64" not in archs or not set(archs) <= {"arm64", "arm64e"}:
            raise ValueError(f"Expected ARM device slices: {binary.name}")
        build = run(["xcrun", "vtool", "-show-build", str(binary)])
        platforms = re.findall(r"^\s*platform\s+(\S+)", build, re.MULTILINE)
        if not platforms or set(platforms) != {PLATFORMS[platform][3]}:
            raise ValueError(f"Wrong Mach-O platform: {binary.name}")
        links = run(["xcrun", "otool", "-L", "-arch", "all", str(binary)])
        for line in links.splitlines()[1:]:
            if not line.startswith(("\t", " ")):
                continue
            link = line.strip().split(" (", 1)[0]
            if link.startswith(("/System/Library/", "/usr/lib/")):
                continue
            relative = Path(link.removeprefix("@rpath/"))
            containers = [app] + [parent for parent in binary.parents if parent.suffix == ".appex"]
            if not link.startswith("@rpath/") or ".." in relative.parts or not any(
                container / "Frameworks" / relative in binaries for container in containers
            ):
                raise ValueError(f"Unresolved embedded dependency in {binary.name}: {link}")
        # Vendor frameworks may arrive signed even with app signing disabled.
        run(["codesign", "--remove-signature", str(binary)])
        commands = run(["xcrun", "otool", "-l", "-arch", "all", str(binary)])
        if "LC_CODE_SIGNATURE" in commands:
            raise ValueError(f"Signature remains in {binary.name}")
        inventory.append({"path": str(binary.relative_to(app)), "architectures": archs})
    for signature in app.rglob("_CodeSignature"):
        if signature.is_symlink() or not signature.is_dir():
            raise ValueError("Unexpected signature metadata")
        shutil.rmtree(signature)
    return {"bundleIdentifier": info["CFBundleIdentifier"], "version": version,
            "binaries": inventory}


def build(platform, root, env, fds):
    output = root / ".build/unsigned-ipa" / platform
    output.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="run-", dir=output))
    source = evidence / "source"
    source.mkdir()

    def run(args, *, timeout=120, log=None, cwd=source):
        return command(args, cwd=cwd, env=env, fds=fds, timeout=timeout, log=log)

    paths = run(["git", "ls-files", "-z"], cwd=root).rstrip("\0").split("\0")
    source_digest = snapshot(root, source, paths)
    prepare_public_config(source)
    revision = run(["git", "rev-parse", "HEAD"], cwd=root).strip()
    dirty = bool(run(["git", "status", "--porcelain"], cwd=root).strip())
    build_number = run(["git", "rev-list", "--count", "HEAD"], cwd=root).strip()
    env = build_environment(env, source, build_number)
    xcode = run(["xcodebuild", "-version"])
    match = re.search(r"^Xcode (\d+)", xcode)
    if not match or int(match[1]) < 27:
        raise ValueError("Select Xcode 27 or later with DEVELOPER_DIR before building")
    print(f"Building {platform}; evidence: {evidence}", flush=True)
    run(["tools/generate-project.sh"], log=evidence / "generate.log")
    packages = root / ".build/package-workspaces" / f"unsigned-ipa-{platform}"
    package_args = run([
        "/bin/bash", "-c",
        'set -euo pipefail; source tools/lib/swift-package-storage.sh; '
        'configure_plozz_package_resolution "$1"; printf "%s\\0" "${PACKAGE_RESOLUTION_ARGS[@]}"',
        "package-storage", str(packages),
    ]).rstrip("\0").split("\0")
    scheme, destination, _, _ = PLATFORMS[platform]
    base = [
        "xcodebuild", "-project", "Plozz.xcodeproj", "-scheme", scheme,
        "-configuration", "Release", "-destination", f"generic/platform={destination}",
        "-derivedDataPath", str(evidence / "DerivedData"), *package_args,
        "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
        "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE_SPECIFIER=", "ARCHS=arm64",
    ]
    run(base + ["build"], timeout=3600, log=evidence / "build.log")
    settings = json.loads(run(base + ["-showBuildSettings", "-json"], timeout=180))
    matches = [row["buildSettings"] for row in settings if row["target"] == scheme]
    if len(matches) != 1:
        raise ValueError("Expected exactly one app build target")
    app_path = Path(matches[0]["TARGET_BUILD_DIR"]) / matches[0]["FULL_PRODUCT_NAME"]
    if not app_path.is_relative_to(evidence / "DerivedData") or not app_path.is_dir():
        raise ValueError("Built app must belong to this invocation")
    payload = evidence / "Payload"
    payload.mkdir()
    app = payload / app_path.name
    run(["ditto", str(app_path), str(app)])
    receipt = verify_and_unsign(app, platform, run)
    ipa = evidence / f"Plozz-{platform}-unsigned.ipa"
    run(["ditto", "-c", "-k", "--norsrc", "--keepParent", str(payload), str(ipa)])
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None or not all(
            name.startswith("Payload/") and ".." not in Path(name).parts
            for name in archive.namelist()
        ):
            raise ValueError("Invalid IPA archive layout or checksum")
        verify_info(plistlib.loads(archive.read(f"Payload/{app.name}/Info.plist")), platform)
    receipt.update({
        "platform": platform, "signed": False, "sourceRevision": revision,
        "workingTreeModified": dirty, "sourceSHA256": source_digest,
        "ipaSHA256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
        "xcode": xcode.strip(), "packageLockSHA256":
            hashlib.sha256((source / "Package.resolved").read_bytes()).hexdigest(),
    })
    receipt_path = evidence / "receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    if github_output := os.environ.get("GITHUB_OUTPUT"):
        with open(github_output, "a") as stream:
            stream.write(f"ipa_path={ipa}\nreceipt_path={receipt_path}\n")
    print(f"Unsigned IPA: {ipa}\nSign it with your own identity before installation.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=PLATFORMS)
    args = parser.parse_args()

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    if not os.environ.get("APPLE_BUILD_LEASE_ID"):
        parser.error("Use tools/build-unsigned-ipa.sh to acquire the build lease")
    lease_fds = runpy.run_path(str(ROOT / "tools/run-bounded.py"))["inherited_lease_fds"]()
    directory = ROOT / ".build/unsigned-ipa"
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "build.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("Another unsigned build owns this checkout; wait for it to finish")
        build(args.platform, ROOT, dict(os.environ), lease_fds)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Unsigned build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
