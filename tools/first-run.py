#!/usr/bin/env python3
"""Build a real-cloud first-user case without resetting any existing installation."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import runpy
import shlex
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "com.thatcube.Plozz.first-run."
CONTAINER = "iCloud.com.thatcube.Plozz.FirstRun"
PLISTS = ["App/Resources/Info.plist", "App/PlozziOS/Info.plist"]
OVERRIDES = [
    "PLOZZ_ID_SUFFIX", "PLOZZ_NAME_SUFFIX", "PLOZZ_PAIRING_SERVICE_TYPE", "PLOZZ_URL_SCHEME",
    "PLOZZ_TV_APP_ENTITLEMENTS", "PLOZZ_TV_TOPSHELF_ENTITLEMENTS", "PLOZZ_IOS_APP_ENTITLEMENTS",
]


def case_identity(value):
    parsed = str(uuid.UUID(value))
    if parsed != value:
        raise ValueError("Case must be a canonical lowercase UUID.")
    return {
        "case": parsed, "bundle": PREFIX + parsed, "container": CONTAINER,
        "pairingService": "_plz" + parsed.replace("-", "")[:12] + "._tcp",
        "urlScheme": "plozz-first-run-" + parsed,
    }


def entitlements(identity, platform):
    result = {
        "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-environment": "Development",
        "com.apple.developer.ubiquity-kvstore-identifier": "$(TeamIdentifierPrefix)$(CFBundleIdentifier)",
        "aps-environment": "development",
        "com.apple.developer.aps-environment": "development",
    }
    if platform == "tvos":
        result["com.apple.developer.user-management"] = ["runs-as-current-user-with-user-independent-keychain"]
    return result


def verify_identity(info, signed, identity, platform):
    bundle = identity["bundle"]
    if info.get("CFBundleIdentifier") != bundle:
        raise ValueError("Refusing an app outside the selected first-run case.")
    app_id = signed.get("application-identifier", "")
    team = signed.get("com.apple.developer.team-identifier", "")
    if not team or app_id != team + "." + bundle:
        raise ValueError("Signed application identity does not match the test case.")
    if signed.get("com.apple.developer.icloud-container-identifiers") != [CONTAINER]:
        raise ValueError("Test app must have ONLY the dedicated first-run CloudKit container.")
    if signed.get("com.apple.developer.icloud-container-environment") != "Development":
        raise ValueError("Test app must use CloudKit Development.")
    if signed.get("com.apple.developer.icloud-services") != ["CloudKit"]:
        raise ValueError("Real CloudKit capability is required; offline fallback is not a first-run cloud test.")
    if signed.get("com.apple.developer.ubiquity-kvstore-identifier") != app_id:
        raise ValueError("iCloud key-value storage is not isolated to this case.")
    if signed.get("keychain-access-groups", [app_id]) != [app_id]:
        raise ValueError("Keychain access must be isolated to this case.")
    if signed.get("com.apple.security.application-groups") or signed.get("com.apple.developer.associated-domains"):
        raise ValueError("A first-run app must not share app groups or universal links with normal Plozz.")
    if not signed.get("get-task-allow"):
        raise ValueError("First-run cases require a development-signed Debug app.")
    if platform == "tvos" and signed.get("com.apple.developer.user-management") != [
        "runs-as-current-user-with-user-independent-keychain"
    ]:
        raise ValueError("First-run tvOS must retain the real household Keychain capability.")
    if identity["pairingService"] not in info.get("NSBonjourServices", []) \
            or "_plozz-pair._tcp" in info.get("NSBonjourServices", []):
        raise ValueError("Setup discovery is not isolated.")
    schemes = [scheme for entry in info.get("CFBundleURLTypes", [])
               for scheme in entry.get("CFBundleURLSchemes", [])]
    if schemes != [identity["urlScheme"]]:
        raise ValueError("Test app must not register normal Plozz deep links.")


def signing_arguments(environment):
    values = dict(environment)
    config = ROOT / ".env.fastlane"
    if config.exists():
        for line in config.read_text().splitlines():
            key, separator, value = line.partition("=")
            if separator and key.strip() in {"ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID"}:
                fields = shlex.split(value, comments=True)
                if len(fields) == 1:
                    values.setdefault(key.strip(), fields[0])
    keys = ["ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID"]
    present = [bool(values.get(key)) for key in keys]
    if any(present) and not all(present):
        raise ValueError("App Store Connect provisioning configuration is incomplete.")
    if not all(present):
        return []
    if not Path(values["ASC_KEY_PATH"]).is_file():
        raise ValueError("Configured provisioning key file is missing.")
    return ["-authenticationKeyPath", values["ASC_KEY_PATH"], "-authenticationKeyID", values["ASC_KEY_ID"],
            "-authenticationKeyIssuerID", values["ASC_ISSUER_ID"]]


def command(arguments, environment, timeout=60, output=None):
    lease_fds = runpy.run_path(str(ROOT / "tools/run-bounded.py"))["inherited_lease_fds"]()
    handle = output.open("wb") if output else None
    try:
        with subprocess.Popen(
            list(arguments), cwd=ROOT, env=environment, start_new_session=True, pass_fds=lease_fds,
            stdout=handle or subprocess.PIPE, stderr=subprocess.STDOUT if handle else subprocess.PIPE
        ) as process:
            try:
                stdout, stderr = process.communicate(timeout=timeout)
            except BaseException:
                # Stop only this command's owned process group before restoring project files.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
                finally:
                    # A parent can exit while a descendant still ignores SIGTERM.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate()
                raise
            if process.returncode:
                detail = f"see {output}" if output else (stderr or b"").decode(errors="replace")[-3000:]
                raise RuntimeError(f"Command failed ({process.returncode}); {detail}")
            return stdout or b""
    finally:
        if handle:
            handle.close()


def interrupted(signum, _frame):
    raise InterruptedError(f"First-run operation interrupted by signal {signum}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    case = parser.add_mutually_exclusive_group(required=True)
    case.add_argument("--new", action="store_true", help="Create a fresh case; never erase an old one.")
    case.add_argument("--case", help="Reuse a case for a second device or subsequent launch.")
    parser.add_argument("--platform", choices=["tvos", "ios"], required=True)
    parser.add_argument("--provisioning", choices=["api", "xcode"], default="xcode",
                        help="Use the configured API key or the account already signed into Xcode.")
    parser.add_argument("--device", help="Install on this explicit CoreDevice ID after signed-isolation checks.")
    args = parser.parse_args()
    if not os.environ.get("APPLE_BUILD_LEASE_ID"):
        parser.error("Use tools/first-run.sh to hold the build-protection lease.")
    identity = case_identity(str(uuid.uuid4()) if args.new else args.case)
    case_dir = ROOT / ".build/first-run" / identity["case"]
    manifest = case_dir / "case.json"
    if args.new:
        case_dir.mkdir(parents=True, exist_ok=False)
        manifest.write_text(json.dumps(identity, indent=2) + "\n")
    elif not manifest.is_file() or json.loads(manifest.read_text()) != identity:
        parser.error("Unknown or mismatched case; use --new rather than adopting unverified storage.")
    evidence = case_dir / (args.platform + "-" + time.strftime("%Y%m%d-%H%M%S"))
    evidence.mkdir(exist_ok=False)
    print(f"First-run case: {identity['case']}\nApp: {identity['bundle']}\nEvidence: {evidence}", flush=True)
    source = {
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "diffSHA256": hashlib.sha256(subprocess.check_output(["git", "diff", "HEAD"], cwd=ROOT)).hexdigest(),
        "untrackedSHA256": {
            name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
            for name in subprocess.check_output(
                ["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=ROOT, text=True
            ).split("\0") if name and (ROOT / name).is_file()
        },
    }
    environment = {key: value for key, value in os.environ.items() if key not in OVERRIDES}
    environment["GIT_CONFIG_PARAMETERS"] = "'safe.bareRepository=all'"
    environment.update({
        "PLOZZ_ID_SUFFIX": ".first-run." + identity["case"],
        "PLOZZ_NAME_SUFFIX": " First Run " + identity["case"][:4],
        "PLOZZ_PAIRING_SERVICE_TYPE": identity["pairingService"],
        "PLOZZ_URL_SCHEME": identity["urlScheme"],
    })
    for platform, key in [("tvos", "PLOZZ_TV_APP_ENTITLEMENTS"), ("ios", "PLOZZ_IOS_APP_ENTITLEMENTS")]:
        path = evidence / (platform + ".entitlements")
        path.write_bytes(plistlib.dumps(entitlements(identity, platform)))
        environment[key] = str(path)
    environment["PLOZZ_TV_TOPSHELF_ENTITLEMENTS"] = "TopShelf/TopShelf.branded.entitlements"
    originals = {name: (ROOT / name).read_bytes() for name in PLISTS}
    for name, data in originals.items():
        (evidence / (name.replace("/", "-") + ".original")).write_bytes(data)
    generated = {}
    try:
        command(["tools/generate-project.sh"], environment, output=evidence / "generate.log")
        generated = {name: (ROOT / name).read_bytes() for name in PLISTS}
        scheme = "Plozz" if args.platform == "tvos" else "PlozziOS"
        destination = "generic/platform=" + ("tvOS" if args.platform == "tvos" else "iOS")
        workspace = ROOT / ".build/package-workspaces" / ("deploy-tv" if args.platform == "tvos" else "deploy-ios")
        package_args = command([
            "bash", "-c", 'source tools/lib/swift-package-storage.sh; '
            'configure_plozz_package_resolution "$1"; printf "%s\\0" "${PACKAGE_RESOLUTION_ARGS[@]}"',
            "first-run", str(workspace),
        ], environment).decode().rstrip("\0").split("\0")
        base = ["xcodebuild", "-project", "Plozz.xcodeproj", "-scheme", scheme, "-configuration", "Debug",
                "-destination", destination, *package_args, "SWIFT_OPTIMIZATION_LEVEL=-O"]
        rows = json.loads(command(base + ["-showBuildSettings", "-json"], environment, timeout=90))
        settings = next(row["buildSettings"] for row in rows if row.get("target") == scheme)
        app = Path(settings["CODESIGNING_FOLDER_PATH"])
        authentication = signing_arguments(environment) if args.provisioning == "api" else []
        command(base + ["-allowProvisioningUpdates", *authentication, "build"],
                environment, timeout=1200, output=evidence / "build.log")
        command(["codesign", "--verify", "--deep", "--strict", str(app)], environment)
        info = plistlib.loads((app / "Info.plist").read_bytes())
        signed = plistlib.loads(command(["codesign", "-d", "--entitlements", ":-", str(app)], environment))
        verify_identity(info, signed, identity, args.platform)
        expected_platform = "AppleTVOS" if args.platform == "tvos" else "iPhoneOS"
        if info.get("CFBundleSupportedPlatforms") != [expected_platform]:
            raise ValueError("Built app does not match the requested device platform.")
        extension = app / "PlugIns/PlozzTopShelf.appex"
        if extension.exists():
            ext_info = plistlib.loads((extension / "Info.plist").read_bytes())
            ext_signed = plistlib.loads(command(["codesign", "-d", "--entitlements", ":-", str(extension)], environment))
            if ext_info.get("CFBundleIdentifier") != identity["bundle"] + ".TopShelf" \
                    or ext_signed.get("com.apple.security.application-groups") \
                    or ext_signed.get("com.apple.developer.icloud-container-identifiers"):
                raise ValueError("Top Shelf extension is not isolated.")
            for key in ["CFBundleVersion", "CFBundleShortVersionString"]:
                if ext_info.get(key) != info.get(key):
                    raise ValueError("App and Top Shelf versions differ.")
        for key in ["TMDBBearerToken", "TVDBAPIKey", "TraktClientID", "TraktClientSecret"]:
            value = info.get(key, "")
            if not value or "$(" in value:
                raise ValueError(f"Expected metadata/integration configuration is missing: {key}")
        preserved = evidence / "Plozz.app"
        command(["ditto", str(app), str(preserved)], environment, timeout=120)
        (evidence / "artifact.json").write_text(json.dumps({
            **identity, "app": str(preserved), "version": info["CFBundleShortVersionString"],
            "build": info["CFBundleVersion"], "signedIsolationVerified": True,
            "source": source,
            "executableSHA256": hashlib.sha256((app / info["CFBundleExecutable"]).read_bytes()).hexdigest(),
        }, indent=2) + "\n")
        if args.device:
            # The shared installer owns its bounded retries; do not wrap it in a shorter timeout.
            command(["tools/install-verified.sh", args.device, str(preserved), "--force", "--no-launch"],
                    environment, timeout=None, output=evidence / "install.log")
            print("First-run app installation succeeded.", flush=True)
            command(["xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
                     "--timeout", "20", identity["bundle"]], environment, timeout=25,
                    output=evidence / "launch.log")
        print(f"Signed first-run artifact ready: {preserved}", flush=True)
    finally:
        # Preserve pre-existing edits rather than checking tracked files out of Git.
        conflicts = []
        for name, original in originals.items():
            current = (ROOT / name).read_bytes()
            if name in generated and current != generated[name]:
                conflicts.append(name)
            else:
                (ROOT / name).write_bytes(original)
        if conflicts:
            raise RuntimeError("Concurrent plist edits preserved; restore manually using evidence: " + ", ".join(conflicts))
        normal = {key: value for key, value in environment.items() if key not in OVERRIDES}
        command(["tools/generate-project.sh"], normal, output=evidence / "restore-project.log")
        for name, original in originals.items():
            (ROOT / name).write_bytes(original)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"First-run setup failed: {error}", file=sys.stderr)
        sys.exit(1)
