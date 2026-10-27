#!/usr/bin/env python3
"""Fail-closed validation for unbound production-app connection checks."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys

APP_ID = "com.thatcube.Plozz"
METHOD = "PublicMetaDBLiveConnectionTests/testLivePairingCancellationAndInvalidKey()"
METHODS = {
    "negative": METHOD,
    "setup": "PublicMetaDBLiveSetupTests/testNormalOnboarding()",
    "browser": "PublicMetaDBLiveConnectionTests/testLiveBrowserConnection()",
    "persistence": "PublicMetaDBLiveConnectionTests/testSavedConnectionAfterRelaunch()",
    "disconnect": "PublicMetaDBLiveConnectionTests/testReplacementCancellationAndDisconnect()",
    "manual": "PublicMetaDBLiveConnectionTests/testLiveManualConnection()",
}
TARGETS = {"tvOS": "PlozzTrackerConnectionTests", "iOS": "PlozziOSTrackerConnectionTests"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def manifest_targets(data):
    if "TestConfigurations" in data:
        configurations = data["TestConfigurations"]
        require(isinstance(configurations, list) and len(configurations) == 1,
                "Expected one test configuration.")
        targets = configurations[0].get("TestTargets")
        require(isinstance(targets, list), "Missing test targets.")
        return targets
    return [value for key, value in data.items() if not key.startswith("__") and isinstance(value, dict)]


def validate_manifest(data, platform):
    targets = manifest_targets(data)
    require(len(targets) == 1 and targets[0].get("BlueprintName") == TARGETS[platform],
            "Wrong or additional test target; rebuild the dedicated connection scheme.")
    target = targets[0]
    require(not target.get("UITargetAppPath") and not target.get("UITargetAppBundleIdentifier"),
            "Refusing an application-bound runner.")
    require(target.get("IsUITestBundle") is True, "Expected a UI test runner.")
    host = target.get("TestHostPath", "")
    products = "__TESTROOT__/Debug-" + {"tvOS": "appletvsimulator", "iOS": "iphonesimulator"}[platform]
    runner = products + "/" + TARGETS[platform] + "-Runner.app"
    require(host in (runner, runner + "/" + TARGETS[platform] + "-Runner"),
            "Unexpected test host.")
    dependencies = target.get("DependentProductPaths", [])
    require(isinstance(dependencies, list) and all(isinstance(path, str) for path in dependencies),
            "Invalid runner dependencies.")
    for path in dependencies:
        require(path in (runner, runner + "/PlugIns/" + TARGETS[platform] + ".xctest"),
                "Refusing application or fixture installation through runner dependencies.")
    require(target.get("SystemAttachmentLifetime") == "keepNever"
            and target.get("PreferredScreenCaptureFormat") == "screenshots",
            "Automatic screenshots/recordings must be disabled.")
    require(not target.get("UITargetAppCommandLineArguments"), "Refusing application launch arguments.")
    generated_environment = {
        "APP_DISTRIBUTOR_ID_OVERRIDE": "com.apple.AppStore",
        "DYLD_FRAMEWORK_PATH": products + ":" + products + "/PackageFrameworks",
        "DYLD_LIBRARY_PATH": products,
        "XCODE_SCHEME_NAME": TARGETS[platform],
        "__XCODE_BUILT_PRODUCTS_DIR_PATHS": products,
        "__XPC_DYLD_FRAMEWORK_PATH": products,
        "__XPC_DYLD_LIBRARY_PATH": products,
    }
    environment = target.get("UITargetAppEnvironmentVariables", {})
    require(isinstance(environment, dict)
            and all(key in generated_environment and value == generated_environment[key]
                    for key, value in environment.items()),
            "Refusing custom application environment injection.")
    return target


def installed_app(app_path, expected_sha256):
    require(re.fullmatch(r"[0-9a-f]{64}", expected_sha256), "An exact expected application executable SHA-256 is required.")
    path = Path(app_path)
    require(path.is_absolute() and path.is_dir(), "Missing installed application path.")
    info = plistlib.loads((path / "Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == APP_ID, "Installed application identity mismatch.")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and executable and Path(executable).name == executable,
            "Invalid application executable name.")
    binary = path / executable
    with binary.open("rb") as source:
        actual = hashlib.file_digest(source, "sha256").hexdigest()
    require(actual == expected_sha256, "Installed app does not match the explicitly selected build.")
    return {"bundleID": APP_ID, "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"), "executableSHA256": actual}


def validate_summary(summary, tests, target, scenario="negative"):
    require(scenario in METHODS, "Unknown live scenario.")
    require(summary.get("result") == "Passed"
            and type(summary.get("totalTestCount")) is int and summary["totalTestCount"] == 1
            and type(summary.get("passedTests")) is int and summary["passedTests"] == 1
            and type(summary.get("failedTests")) is int and summary["failedTests"] == 0
            and type(summary.get("skippedTests")) is int and summary["skippedTests"] == 0
            and type(summary.get("expectedFailures")) is int and summary["expectedFailures"] == 0
            and summary.get("testFailures") == [], "Missing complete one-test, zero-skip live verdict.")
    found = []
    bundles = []

    def walk(node):
        require(isinstance(node, dict), "Malformed test result tree.")
        if node.get("nodeType") == "UI test bundle":
            bundles.append(node.get("name"))
        if node.get("nodeType") == "Test Case":
            found.append(node)
        for child in node.get("children", []):
            walk(child)

    require(isinstance(tests, dict) and isinstance(tests.get("testNodes"), list), "Missing test result tree.")
    for node in tests["testNodes"]:
        walk(node)
    require(bundles == [target] and len(found) == 1
            and found[0].get("nodeIdentifier") == METHODS[scenario] and found[0].get("result") == "Passed",
            "The exact live test and bundle must have passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    manifest = sub.add_parser("manifest")
    manifest.add_argument("path", type=Path)
    manifest.add_argument("platform", choices=TARGETS)
    app = sub.add_parser("app")
    app.add_argument("expected_sha256")
    verdict = sub.add_parser("verdict")
    verdict.add_argument("summary", type=Path)
    verdict.add_argument("tests", type=Path)
    verdict.add_argument("platform", choices=TARGETS)
    verdict.add_argument("--scenario", choices=METHODS, default="negative")
    args = parser.parse_args()
    try:
        if args.operation == "manifest":
            target = validate_manifest(plistlib.loads(args.path.read_bytes()), args.platform)
            print(json.dumps({"target": target["BlueprintName"], "applicationBound": False, "automaticCapture": False}))
        elif args.operation == "app":
            print(json.dumps(installed_app(sys.stdin.read().strip(), args.expected_sha256)))
        else:
            validate_summary(json.loads(args.summary.read_bytes()), json.loads(args.tests.read_bytes()),
                             TARGETS[args.platform], args.scenario)
            print(f"Exact native {args.scenario} scenario passed; broader playback/history acceptance is not implied.")
        return 0
    except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException):
        print("Connection evidence validation failed; no live pass recorded. Inspect private evidence and prerequisites.",
              file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
