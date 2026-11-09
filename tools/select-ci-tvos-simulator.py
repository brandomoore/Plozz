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


def best_device(devices: list[dict]) -> dict | None:
    candidates = [
        device for device in devices
        if device.get("isAvailable") and "Apple TV" in device.get("name", "")
    ]
    if not candidates:
        return None
    candidates.sort(key=lambda device: (
        "1080p" not in device["name"],
        "4K" not in device["name"],
        device["name"],
        device["udid"],
    ))
    return candidates[0]


def select_device(
    devices: dict, sdk_version: str, runtimes: dict | None = None,
) -> tuple[str, str]:
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

    # Prefer the runtime matching the selected Xcode SDK, then the newest
    # healthy tvOS runtime. Hosted images have shipped malformed older runtimes;
    # Xcode can run a newer simulator runtime than its SDK.
    ordered = sorted(
        available,
        key=lambda runtime: (
            runtime_version(runtime) != requested,
            tuple(-part for part in (runtime_version(runtime) or ())),
        ),
    )
    for runtime in ordered:
        device = best_device(available[runtime])
        if device is not None:
            return device["udid"], device["name"]
    raise ValueError(f"No available Apple TV simulator for {sdk_version}")


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
        identifier, name = select_device(devices, args.sdk_version, runtimes)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"CI simulator selection failed: {error}", file=sys.stderr)
        return 1
    print(f"Selected tvOS {args.sdk_version}: {name} ({identifier})", file=sys.stderr)
    print(identifier)
    return 0


if __name__ == "__main__":
    sys.exit(main())
