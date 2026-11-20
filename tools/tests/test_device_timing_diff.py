import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "device_timing_diff", ROOT / "tools" / "device-timing-diff.py"
)
timing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(timing)


class DeviceTimingDiffTests(unittest.TestCase):
    def test_parses_start_aggregate_rows_and_requests(self) -> None:
        lines = [
            "PLZBOOT ensurePlexIdentity profile=default",
            "PLZBOOT HomeVM.load START vm=1 accounts=2 state=loaded silent=true",
            "PLZBOOT HomeAgg.request row=libraries provider=jellyfin ms=409",
            "PLZBOOT HomeAgg.rowReady row=libraries ms=419",
            "PLZBOOT HomeAgg.rowReady row=continueWatching ms=1461",
            "PLZBOOT HomeAgg.fanout accounts=2 ms=1461",
        ]
        parsed = timing.parse_boot_lines(lines)
        self.assertEqual(parsed["start"], {"accounts": 2, "state": "loaded", "silent": True})
        self.assertEqual(parsed["aggregate"], 1461)
        self.assertEqual(parsed["rows"], {"libraries": 419, "continueWatching": 1461})
        self.assertEqual(
            parsed["requests"],
            [{"row": "libraries", "provider": "jellyfin", "ms": 409}],
        )

    def test_missing_markers_are_none_not_zero(self) -> None:
        parsed = timing.parse_boot_lines(["PLZBOOT HomeVM.load START vm=1 accounts=1 state=loading silent=false"])
        self.assertEqual(parsed["aggregate"], None)
        self.assertEqual(parsed["rows"], {})
        self.assertFalse(parsed["start"]["silent"])

    def test_summary_ignores_incomplete_runs(self) -> None:
        samples = [
            {"first_boot_wall_ms": 800, "aggregate_ms": 1400},
            {"first_boot_wall_ms": 900, "aggregate_ms": None},
            {"first_boot_wall_ms": 1000, "aggregate_ms": 1600},
        ]
        aggregate = timing.summarise(samples, "aggregate_ms")
        self.assertEqual(aggregate["n"], 2)
        self.assertEqual(aggregate["median"], 1500)
        self.assertEqual(aggregate["min"], 1400)
        self.assertEqual(aggregate["max"], 1600)

    def test_both_apps_arm_the_opt_in_stall_probe(self) -> None:
        # `PLZSTALL=1` is the iOS/tvOS way to capture a real main-actor stall;
        # both entry points must arm it or a device timing run is blind.
        for relative in ("App/PlozziOS/PlozziOSApp.swift", "App/Plozz/PlozzApp.swift"):
            source = (ROOT / relative).read_text()
            self.assertIn("MainThreadStallProbe.startIfRequested()", source, relative)

    def test_report_contains_both_apps_and_the_delta(self) -> None:
        apps = {
            timing.PRODUCTION_BUNDLE: {"name": "Plozz", "version": "2026.11.12", "build": "72"},
            timing.SELF_BUILD_BUNDLE: {"name": "Plozz Self-build", "version": "2026.11.12", "build": "6290.9"},
        }
        production = [{"first_boot_wall_ms": 800, "home_start_wall_ms": 810, "home_done_wall_ms": 1500, "aggregate_ms": 1400, "row_continueWatching_ms": 1380, "state": "loaded", "silent": True, "accounts": 1}]
        self_build = [{"first_boot_wall_ms": 900, "home_start_wall_ms": 920, "home_done_wall_ms": 1700, "aggregate_ms": 1550, "row_continueWatching_ms": 1520, "state": "loaded", "silent": True, "accounts": 1}]
        report = timing.build_report(
            "device",
            apps,
            {timing.PRODUCTION_BUNDLE: production, timing.SELF_BUILD_BUNDLE: self_build},
            1,
        )
        self.assertIn("## Plozz", report)
        self.assertIn("## Plozz Self-build", report)
        self.assertIn("## Diff (self-build − TestFlight)", report)
        self.assertIn("150 ms", report)
        self.assertIn("`continueWatching` ready", report)


if __name__ == "__main__":
    unittest.main()
