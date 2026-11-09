#!/usr/bin/env python3
"""Select an available tvOS simulator matching the CI build SDK."""

import argparse
import json
import subprocess
import sys

RUNTIME_PREFIX = "com.apple.CoreSimulator.SimRuntime.tvOS-"


def runtime_version(identifier: str) -> tuple[int, ...] | None:
    if not identifier.startswith(RUNTIME_PREFIX):
        return None
    raw = identifier.removeprefix(RUNTIME_PREFIX)
    try:
        return tuple(int(part) for part in raw.split("-"))
    except ValueError:
        return None


def healthy_runtimes(runtimes: dict | None) -> set[str]:
    if runtimes is None:
        return set()
    return {
        runtime["identifier"]
        for runtime in runtimes.get("runtimes", [])
        if runtime.get("identifier", "").startswith(RUNTIME_PREFIX)
        and runtime.get("isAvailable") is True
        and not runtime.get("availabilityError")
    }


def select_candidates(
    devices: dict, sdk_version: str, runtimes: dict | None = None,
) -> list[tuple[str, str]]:
    requested = tuple(int(part) for part in sdk_version.split(".") if part.isdigit())
    available = {
        runtime: members
        for runtime, members in devices.get("devices", {}).items()
        if runtime_version(runtime) is not None
    }
    healthy = healthy_runtimes(runtimes)
    if healthy:
        available = {runtime: members for runtime, members in available.items() if runtime in healthy}

    if not available:
        raise ValueError(
            f"No healthy tvOS simulator runtime for SDK {sdk_version}"
        )

    # Prefer the newest healthy tvOS runtime. Hosted images have shipped broken
    # older runtimes that disappear after boot; the current Xcode can run the
    # newer simulator runtime. The SDK match remains a tiebreaker.
    ordered = sorted(
        available,
        key=lambda runtime: (
            tuple(-part for part in (runtime_version(runtime) or ())),
            runtime_version(runtime) != requested,
        ),
    )
    candidates: list[tuple[str, str]] = []
    for runtime in ordered:
        members = [
            device for device in available[runtime]
            if device.get("isAvailable") and "Apple TV" in device.get("name", "")
        ]
        members.sort(key=lambda device: (
            "1080p" not in device["name"],
            "4K" not in device["name"],
            device["name"],
            device["udid"],
        ))
        candidates.extend((device["udid"], device["name"]) for device in members)
    return candidates


def select_device(
    devices: dict, sdk_version: str, runtimes: dict | None = None,
) -> tuple[str, str]:
    candidates = select_candidates(devices, sdk_version, runtimes)
    if not candidates:
        raise ValueError(f"No available Apple TV simulator for {sdk_version}")
    return candidates[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-version", required=True)
    args = parser.parse_args()
    try:
        devices = json.loads(subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "--json"],
            capture_output=True, text=True, check=True, timeout=300,
        ).stdout)
        runtimes = json.loads(subprocess.run(
            ["xcrun", "simctl", "list", "runtimes", "--json"],
            capture_output=True, text=True, check=True, timeout=300,
        ).stdout)
        candidates = select_candidates(devices, args.sdk_version, runtimes)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"CI simulator selection failed: {error}", file=sys.stderr)
        return 1

    failures: list[str] = []
    for identifier, name in candidates:
        try:
            subprocess.run(
                ["xcrun", "simctl", "bootstatus", identifier, "-b"],
                capture_output=True, text=True, check=True, timeout=300,
            )
        except (OSError, subprocess.SubprocessError) as error:
            failures.append(f"{name} ({identifier}): {error}")
            continue
        print(f"Selected tvOS {args.sdk_version}: {name} ({identifier})", file=sys.stderr)
        print(identifier)
        return 0
    print(
        "CI simulator selection failed: no bootable tvOS simulator; " + "; ".join(failures),
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
