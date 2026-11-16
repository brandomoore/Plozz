#!/usr/bin/env python3
"""Automated Home-load timing diff between two installed iOS builds.

The TestFlight app and the self-build are separate bundle identifiers, so they can
both be installed on one phone. Both emit the same `PLZBOOT` Home-load telemetry
when launched with `PLZBOOT_STDOUT=1`; this script launches each one through
`devicectl --console`, timestamps the streamed lines, and records the app-side
aggregate/row measurements. It never touches the simulator or a test host.

Usage:
    python3 tools/device-timing-diff.py --device <udid>
    python3 tools/device-timing-diff.py --device <udid> --runs 5 \
        --output docs/measurements/device-home-timing.md

The report is Markdown for review; the raw per-run samples live in the sibling
JSON file so a later run can be compared or re-analysed without a device.
"""

from __future__ import annotations

import argparse
import json
import queue
import re
import statistics
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

PRODUCTION_BUNDLE = "com.thatcube.Plozz"
SELF_BUILD_BUNDLE = "com.thatcube.Plozz.selfbuild"

LAUNCH_START = re.compile(
    r"PLZBOOT HomeVM\.load START .*accounts=(?P<accounts>\d+) "
    r"state=(?P<state>\w+) silent=(?P<silent>\w+)"
)
AGGREGATE = re.compile(r"PLZBOOT HomeAgg\.fanout accounts=(?P<accounts>\d+) ms=(?P<ms>\d+)")
ROW_READY = re.compile(r"PLZBOOT HomeAgg\.rowReady row=(?P<row>[\w-]+) ms=(?P<ms>\d+)")
REQUEST = re.compile(
    r"PLZBOOT HomeAgg\.request row=(?P<row>[\w-]+) provider=(?P<provider>[\w-]+) "
    r"ms=(?P<ms>\d+)"
)
ROW_NAMES = ("recentlyAdded", "libraries", "watchlist", "continueWatching", "server-sections")


def parse_boot_lines(lines: list[str]) -> dict:
    """Turn one launch's `PLZBOOT` lines into the metrics used by the report.

    `lines` are already stripped and in arrival order. Wall offsets are added by
    the caller; this function only reads the app-side values so it stays
    deterministic and easy to unit test.
    """
    out: dict = {
        "start": None,
        "aggregate": None,
        "rows": {},
        "requests": [],
    }
    for line in lines:
        if match := LAUNCH_START.search(line):
            out["start"] = {
                "accounts": int(match["accounts"]),
                "state": match["state"],
                "silent": match["silent"] == "true",
            }
        elif match := AGGREGATE.search(line):
            out["aggregate"] = int(match["ms"])
        elif match := ROW_READY.search(line):
            out["rows"][match["row"]] = int(match["ms"])
        elif match := REQUEST.search(line):
            out["requests"].append(
                {
                    "row": match["row"],
                    "provider": match["provider"],
                    "ms": int(match["ms"]),
                }
            )
    return out


def _read_stream(stream, event: queue.Queue) -> None:
    for raw in iter(stream.readline, ""):
        event.put(raw.rstrip("\n"))
    event.put(None)


def launch_and_collect(
    device: str,
    bundle: str,
    timeout: float,
) -> tuple[list[tuple[float, str]], float, float]:
    """Launch `bundle`, wait for the Home aggregate, and return timestamped lines.

    The timer starts just before `devicectl`, so the first line includes the
    process launch and the app's own startup. `HomeAgg.fanout` is the completion
    marker; a short grace period lets `HomeVM.load DONE` and the row-ready lines
    that follow it arrive.
    """
    command = [
        "xcrun",
        "devicectl",
        "device",
        "process",
        "launch",
        "--device",
        device,
        "--console",
        "--terminate-existing",
        "-e",
        json.dumps({"PLZBOOT_STDOUT": "1"}),
        bundle,
    ]
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None
    events: queue.Queue[str | None] = queue.Queue()
    reader = threading.Thread(target=_read_stream, args=(process.stdout, events), daemon=True)
    reader.start()

    lines: list[tuple[float, str]] = []
    deadline = started + timeout
    saw_completion = False
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                line = events.get(timeout=min(remaining, 0.25))
            except queue.Empty:
                continue
            if line is None:
                break
            elapsed_ms = (time.monotonic() - started) * 1000
            lines.append((elapsed_ms, line))
            if "HomeAgg.fanout " in line:
                saw_completion = True
                # The rows and `HomeVM.load DONE` follow the aggregate line.
                time.sleep(0.35)
                while True:
                    try:
                        extra = events.get_nowait()
                    except queue.Empty:
                        break
                    if extra is None:
                        break
                    lines.append(((time.monotonic() - started) * 1000, extra))
                break
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
        reader.join(timeout=1)

    finished = time.monotonic()
    if not saw_completion:
        # The caller still records the partial run; the report marks it incomplete.
        lines.append(((finished - started) * 1000, "PLZBOOT (timing timeout)"))
    return lines, started, finished


def installed_apps(device: str) -> dict[str, dict]:
    result = subprocess.run(
        [
            "xcrun",
            "devicectl",
            "device",
            "info",
            "apps",
            "--device",
            device,
            "--json-output",
            "-",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0:
        return {}
    data = json.loads(result.stdout)
    apps: dict[str, dict] = {}
    for app in data.get("result", {}).get("apps", []):
        bundle = app.get("bundleIdentifier")
        if bundle:
            apps[bundle] = {
                "name": app.get("name", bundle),
                "version": app.get("version", ""),
                "build": str(app.get("bundleVersion", "")),
            }
    return apps


def summarise(samples: list[dict], key: str) -> dict:
    values = [sample[key] for sample in samples if sample.get(key) is not None]
    if not values:
        return {"n": 0, "median": None, "min": None, "max": None}
    return {
        "n": len(values),
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
    }


def format_ms(value: float | int | None) -> str:
    if value is None:
        return "—"
    if isinstance(value, float) and not value.is_integer():
        return f"{value:.1f} ms"
    return f"{int(value)} ms"


def build_report(
    device_label: str,
    apps: dict[str, dict],
    samples: dict[str, list[dict]],
    runs: int,
    self_build_configuration: str = "Debug",
    production_bundle: str = PRODUCTION_BUNDLE,
    self_build_bundle: str = SELF_BUILD_BUNDLE,
) -> str:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        "# Device Home-load timing diff",
        "",
        f"Captured **{now}** from {device_label} with "
        f"`python3 tools/device-timing-diff.py --runs {runs}`.",
        "",
        "Both apps were launched with `PLZBOOT_STDOUT=1`, which mirrors the same "
        "`HomeVM` / `HomeAgg` telemetry the app already emits. Wall times start "
        "immediately before `devicectl`; app-side row times are the app's own "
        "millisecond measurements from `HomeVM.load START`.",
        "",
    ]
    for bundle, samples_for_app in samples.items():
        info = apps.get(bundle, {})
        label = info.get("name", bundle)
        version = " ".join(
            part for part in (info.get("version"), info.get("build")) if part
        )
        lines.extend(
            [
                f"## {label}",
                "",
                f"- Bundle: `{bundle}`",
                f"- Installed build: `{version or 'unknown'}`",
                f"- Samples: {len(samples_for_app)}",
                "",
                "| Metric | Median | Min | Max |",
                "| --- | ---: | ---: | ---: |",
            ]
        )
        metrics = [
            ("Launch → first telemetry", "first_boot_wall_ms"),
            ("Launch → Home load start", "home_start_wall_ms"),
            ("Launch → Home load done", "home_done_wall_ms"),
            ("App-side aggregate", "aggregate_ms"),
        ]
        for title, key in metrics:
            summary = summarise(samples_for_app, key)
            lines.append(
                f"| {title} | {format_ms(summary['median'])} | "
                f"{format_ms(summary['min'])} | {format_ms(summary['max'])} |"
            )
        for row in ROW_NAMES:
            key = f"row_{row}_ms"
            summary = summarise(samples_for_app, key)
            if summary["n"]:
                lines.append(
                    f"| `{row}` ready | {format_ms(summary['median'])} | "
                    f"{format_ms(summary['min'])} | {format_ms(summary['max'])} |"
                )
        lines.append("")

        states = [sample.get("state", "?") for sample in samples_for_app]
        silents = [str(sample.get("silent", "?")).lower() for sample in samples_for_app]
        accounts = sorted({sample.get("accounts") for sample in samples_for_app if sample.get("accounts")})
        lines.append(
            f"Observed states: `{', '.join(states)}`; silent refresh: "
            f"`{', '.join(silents)}`; accounts: `{', '.join(map(str, accounts))}`."
        )
        lines.append("")

    if production_bundle in samples and self_build_bundle in samples:
        lines.extend(
            [
                "## Diff (self-build − TestFlight)",
                "",
                "Positive values mean the self-build was slower on this run. The "
                f"self-build is a **{self_build_configuration}** build; the "
                "TestFlight app is Release, so compare like configurations when "
                "drawing an optimisation conclusion.",
                "",
                "| Metric | TestFlight | Self-build | Delta |",
                "| --- | ---: | ---: | ---: |",
            ]
        )
        for title, key in (
            ("Launch → first telemetry", "first_boot_wall_ms"),
            ("Launch → Home load start", "home_start_wall_ms"),
            ("Launch → Home load done", "home_done_wall_ms"),
            ("App-side aggregate", "aggregate_ms"),
        ):
            production = summarise(samples[production_bundle], key)["median"]
            self_build = summarise(samples[self_build_bundle], key)["median"]
            delta = (
                self_build - production
                if self_build is not None and production is not None
                else None
            )
            lines.append(
                f"| {title} | {format_ms(production)} | {format_ms(self_build)} | "
                f"{format_ms(delta)} |"
            )
        for row in ROW_NAMES:
            key = f"row_{row}_ms"
            production = summarise(samples[production_bundle], key)["median"]
            self_build = summarise(samples[self_build_bundle], key)["median"]
            if production is None and self_build is None:
                continue
            delta = (
                self_build - production
                if self_build is not None and production is not None
                else None
            )
            lines.append(
                f"| `{row}` ready | {format_ms(production)} | {format_ms(self_build)} | "
                f"{format_ms(delta)} |"
            )
        lines.append("")

    lines.extend(
        [
            "## Method notes",
            "",
            "- The app data containers are independent. Each run starts from the "
            "state the installed app had before launch; `--terminate-existing` "
            "removes the process but not the disk snapshot.",
            "- The launch wall time includes CoreDevice hand-off and the app's "
            "first telemetry line; the app-side aggregate/row times exclude that "
            "overhead and are the better comparison.",
            "- A missing `HomeAgg.fanout` marker is recorded as an incomplete run "
            "and left out of the median rather than treated as zero.",
            "- These are one-device, one-network samples, not a battery/thermal "
            "or scroll-smoothness result.",
            "",
        ]
    )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="iPhone UDID or CoreDevice identifier")
    parser.add_argument("--runs", type=int, default=3, help="launches per app (default 3)")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("docs/measurements/device-home-timing.md"),
        help="Markdown report path (default docs/measurements/device-home-timing.md)",
    )
    parser.add_argument("--timeout", type=float, default=25.0, help="seconds per launch")
    parser.add_argument(
        "--device-label",
        default="the connected iPhone",
        help="human label stored in the report instead of the UDID",
    )
    parser.add_argument(
        "--production-bundle", default=PRODUCTION_BUNDLE, help=argparse.SUPPRESS
    )
    parser.add_argument("--self-build-bundle", default=SELF_BUILD_BUNDLE, help=argparse.SUPPRESS)
    parser.add_argument(
        "--self-build-configuration",
        default="Debug",
        help="configuration label for the self-build report (default Debug)",
    )
    args = parser.parse_args(argv)

    if args.runs < 1:
        parser.error("--runs must be at least 1")

    apps = installed_apps(args.device)
    if not apps:
        print("device-timing-diff: no installed apps returned by devicectl", file=sys.stderr)
        return 1

    bundles = [args.production_bundle, args.self_build_bundle]
    missing = [bundle for bundle in bundles if bundle not in apps]
    if missing:
        print(
            "device-timing-diff: app(s) not installed: " + ", ".join(missing),
            file=sys.stderr,
        )
        return 1

    samples: dict[str, list[dict]] = {bundle: [] for bundle in bundles}
    raw: dict = {"capturedAt": datetime.now(timezone.utc).isoformat(), "runs": []}
    for index in range(args.runs):
        for bundle in bundles:
            print(f"[{index + 1}/{args.runs}] {apps[bundle]['name']} …", flush=True)
            lines, started, finished = launch_and_collect(args.device, bundle, args.timeout)
            boot_lines = [line for _, line in lines if "PLZBOOT " in line]
            parsed = parse_boot_lines(boot_lines)

            def wall_for(token: str) -> float | None:
                for elapsed_ms, line in lines:
                    if token in line:
                        return elapsed_ms
                return None

            first_boot = next(
                (elapsed_ms for elapsed_ms, line in lines if "PLZBOOT " in line), None
            )
            sample = {
                "bundle": bundle,
                "run": index + 1,
                **parsed,
                "first_boot_wall_ms": first_boot,
                "home_start_wall_ms": wall_for("HomeVM.load START"),
                "home_done_wall_ms": wall_for("HomeVM.load DONE"),
                "aggregate_ms": parsed["aggregate"],
                "complete": parsed["aggregate"] is not None,
            }
            for row in ROW_NAMES:
                sample[f"row_{row}_ms"] = parsed["rows"].get(row)
            sample["state"] = (parsed["start"] or {}).get("state")
            sample["silent"] = (parsed["start"] or {}).get("silent")
            sample["accounts"] = (parsed["start"] or {}).get("accounts")
            samples[bundle].append(sample)
            raw["runs"].append({"sample": sample, "lines": lines})
            print(
                "    "
                + f"first={format_ms(sample['first_boot_wall_ms'])}, "
                + f"aggregate={format_ms(sample['aggregate_ms'])}, "
                + f"done={format_ms(sample['home_done_wall_ms'])}",
                flush=True,
            )

    report = build_report(
        args.device_label, apps, samples, args.runs, args.self_build_configuration,
        args.production_bundle, args.self_build_bundle
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(report + "\n")
    raw_path = args.output.with_suffix(".json")
    raw_path.write_text(json.dumps(raw, indent=2, sort_keys=True) + "\n")
    print(f"\nWrote {args.output}")
    print(f"Wrote {raw_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
