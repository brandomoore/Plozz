import argparse
import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("performance", ROOT / "tools/performance.py")
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


def report(name="sync-unchanged", value=10):
    return {
        "schema": 1, "scenario": name, "warmups": 1,
        "samples": [{
            "iteration": index, "wallMilliseconds": value, "cpuMilliseconds": value,
            "residentBytes": 100_000, "residentDeltaBytes": -100,
            "counters": {key: 0 for key in performance.expected_reports([name])[name]["counters"]},
        } for index in range(5)],
    }


def run(value=10):
    return {
        "schema": 1, "status": "passed", "evidenceKind": "simulator",
        "scenarios": ["sync-unchanged"], "reports": {"sync-unchanged": report(value=value)},
        "environment": {**dict.fromkeys(("runtime", "runtimeBuild", "deviceType", "platform", "architecture",
                                        "runnerHash", "xcode", "sdk", "macOS", "hardware"), "fixture"),
                        "flags": performance.FLAGS},
        "fixtures": {"fixture.swift": "one"}, "source": {"head": "a" * 40, "files": {"source.swift": "one"}},
    }


def summary(count=1):
    return dict(result="Passed", passedTests=count, totalTestCount=count, failedTests=0,
                skippedTests=0, expectedFailures=0, testFailures=[])


def stack_sample(pid=42, main="Main Thread"):
    return f"""Process: FocusHost [{pid}]
Call graph:
    20 Thread_1: {main} DispatchQueue_main
    + 20 main (in FocusHost)
    + ! 10 mach_msg (in libsystem_kernel.dylib)
    20 Thread_2   DispatchQueue_340: com.plozz.textless-backdrop-index (serial)
    + 7 TextlessBackdropIndex.persist (in FocusHost)
    + ! 7 rename (in libsystem_kernel.dylib)
    9 Thread_<multiple>   DispatchQueue_341: com.plozz.textless-backdrop-index (serial)
    + 8 merged writer (in FocusHost)
Total number in stack (recursive counted multiple, when >=5):
    100 ignored summary (in FocusHost)
Binary Images:
    fixture
"""


class EvidenceTests(unittest.TestCase):
    def test_stack_sample_separates_main_and_background_and_excludes_footer(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.txt"
            for name in ("Main Thread", "com.apple.main-thread"):
                path.write_text(stack_sample(main=name))
                result = performance.stack_sample_summary(path, 42)
                self.assertEqual(len(result["mainThreadFrames"]), 2)
                self.assertEqual(result["appFrames"], [{"stackSamples": 20, "frame": "main (in FocusHost)"}])
                self.assertEqual([row["stackSamples"] for row in result["backgroundAppFrames"]], [8, 7])
                self.assertIn("include waiting", result["note"])
                self.assertTrue(result["binaryImagesAvailable"])

    def test_finalized_sample_can_explicitly_lack_the_binary_image_map(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.txt"
            path.write_text(stack_sample().split("Binary Images:")[0] + "Binary images description not available\n")
            result = performance.stack_sample_summary(path, 42)
            self.assertFalse(result["binaryImagesAvailable"])
            self.assertEqual(len(result["appFrames"]), 1)

    def test_stack_sample_rejects_wrong_process_truncation_and_missing_main_thread(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.txt"
            for text in (stack_sample(pid=99), stack_sample().split("Binary Images:")[0],
                         stack_sample(main="background-worker")):
                path.write_text(text)
                with self.assertRaises(performance.Failure):
                    performance.stack_sample_summary(path, 42)

    def test_selection_is_explicit_and_narrow_by_default(self):
        self.assertEqual(set(performance.select(None, None)), {
            "sync-unchanged", "library-unchanged", "catalog-import", "watchlist-artwork-rehydration",
            "live-tv-schedule-capture", "live-tv-schedule-sync", "poster-preview-admission",
        })
        self.assertEqual(performance.select(None, ["guide-large-batches"]), ["guide-large-batches"])
        self.assertEqual(performance.select(None, ["poster-preview-admission"]),
                         ["poster-preview-admission"])
        self.assertEqual(performance.select(None, ["watchlist-artwork-rehydration"]),
                         ["watchlist-artwork-rehydration"])
        self.assertEqual(performance.select("matrix", None), ["runtime-matrix"])
        self.assertEqual(performance.select("diagnostics", None),
                         ["diagnostics-disabled", "diagnostics-enabled", "diagnostics-snapshot"])
        self.assertEqual(len(performance.expected_reports(["runtime-matrix"])), 16)
        for suite, names in [("core", ["sync-unchanged"]), (None, ["unknown"]),
                             (None, ["sync-unchanged", "sync-unchanged"])]:
            with self.assertRaises(performance.Failure):
                performance.select(suite, names)

    def test_measurement_contract_rejects_missing_nonfinite_and_duplicate_samples(self):
        original = report()
        spec = performance.SCENARIOS["sync-unchanged"]
        performance.validate_report(original, spec)
        mutations = [
            lambda r: r["samples"].pop(),
            lambda r: r["samples"][1].update(iteration=0),
            lambda r: r["samples"][0].update(cpuMilliseconds=float("nan")),
            lambda r: r["samples"][0].update(cpuMilliseconds=float("inf")),
            lambda r: r["samples"][0].update(cpuMilliseconds=-1),
            lambda r: r["samples"][0].update(cpuMilliseconds=True),
            lambda r: r["samples"][0]["counters"].pop("checks"),
            lambda r: r["samples"][0]["counters"].update(checks=-1),
            lambda r: r.update(warmups=True),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                candidate = copy.deepcopy(original)
                mutate(candidate)
                with self.assertRaises(performance.Failure):
                    performance.validate_report(candidate, spec)

    def test_platform_specific_selection_rejects_explicit_unsupported_workloads(self):
        artwork = {"home-artwork-layout", "home-artwork-layout-duplicate", "home-artwork-layout-cold"}
        self.assertTrue(artwork <= set(performance.select("ui", None, "tvOS")))
        self.assertFalse(artwork & set(performance.select("ui", None, "iOS")))
        self.assertFalse(artwork & set(performance.select("all", None, "iOS")))
        for name in artwork:
            self.assertEqual(performance.select(None, [name], "tvOS"), [name])
            with self.assertRaisesRegex(performance.Failure, "not supported on iOS"):
                performance.select(None, [name], "iOS")

    def test_only_complete_no_skip_summary_passes(self):
        performance.verify_summary(summary(), 1)
        for change in [
            {"result": "Failed"}, {"passedTests": 0}, {"skippedTests": 1},
            {"expectedFailures": 1}, {"failedTests": 1}, {"totalTestCount": 2},
            {"passedTests": True}, {"testFailures": [{"targetName": "Crash"}]},
        ]:
            with self.subTest(change=change), self.assertRaises(performance.Failure):
                performance.verify_summary(dict(summary(), **change), 1)

    def test_attachment_reader_checks_expected_set_and_paths(self):
        with tempfile.TemporaryDirectory() as path:
            folder = Path(path)
            performance.write_json(folder / "report.json", report())
            attachment = {"suggestedHumanReadableName": "plozz-performance-sync-unchanged.json",
                          "exportedFileName": "report.json"}
            def manifest(entries):
                performance.write_json(folder / "manifest.json", [{"attachments": entries}])
            manifest([attachment])
            expected = performance.expected_reports(["sync-unchanged"])
            self.assertEqual(set(performance.read_attachments(folder, expected)), {"sync-unchanged"})
            for entries in [[], [attachment, attachment],
                            [dict(attachment, exportedFileName="../report.json")]]:
                manifest(entries)
                with self.assertRaises(performance.Failure):
                    performance.read_attachments(folder, expected)

    def test_simulator_validation_never_accepts_hardware_or_wrong_platform(self):
        data = {"devices": {"com.apple.CoreSimulator.SimRuntime.tvOS-26-2": [
            {"udid": "owned", "isAvailable": True, "state": "Shutdown", "deviceTypeIdentifier": "AppleTV"},
        ]}}
        runtimes = {"runtimes": [{"identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-26-2", "buildversion": "23K51"}]}
        info, state = performance.simulator_info(data, runtimes, "owned", "tvOS")
        self.assertEqual(state, "Shutdown")
        self.assertEqual(info["runtimeBuild"], "23K51")
        for device, platform in [("physical", "tvOS"), ("owned", "iOS")]:
            with self.assertRaises(performance.Failure):
                performance.simulator_info(data, runtimes, device, platform)

    def test_scheme_has_opt_in_without_debugger_or_coverage(self):
        tree = performance.package_scheme({"FeatureSyncCloudTests"})
        test = tree.getroot().find("TestAction")
        self.assertEqual(test.get("buildConfiguration"), "Debug")
        self.assertEqual(test.get("selectedDebuggerIdentifier"), "")
        self.assertEqual(test.get("codeCoverageEnabled"), "NO")
        variable = test.find("EnvironmentVariables/EnvironmentVariable")
        self.assertEqual(variable.get("key"), "PLOZZ_PERFORMANCE")
        self.assertEqual(variable.get("value"), "1")
        self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-O", performance.FLAGS)

    def test_compare_retains_noise_and_does_not_call_within_budget_improvement(self):
        self.assertEqual(performance.compare(run(), run(11), 15)["verdict"], "within-budget")
        self.assertEqual(performance.compare(run(), run(14), 15)["verdict"], "regression")
        self.assertEqual(performance.compare(run(), run(5), 15)["verdict"], "within-budget")
        noisy = run()
        for sample, value in zip(noisy["reports"]["sync-unchanged"]["samples"], [1, 5, 10, 15, 20]):
            sample["cpuMilliseconds"] = value
        self.assertEqual(performance.compare(run(), noisy, 15)["verdict"], "inconclusive")

    def test_comparison_rejects_mismatched_fixture_platform_flags_or_selection(self):
        for key in ("fixtures", "environment", "scenarios"):
            candidate = run()
            candidate[key] = {"different": True}
            with self.assertRaises(performance.Failure):
                performance.compare(run(), candidate, 15)
        for tolerance in (-1, 101, float("nan")):
            with self.assertRaises(performance.Failure):
                performance.compare(run(), run(), tolerance)

    def test_failed_or_partial_run_cannot_become_a_baseline(self):
        with tempfile.TemporaryDirectory() as path:
            file = Path(path) / "result.json"
            performance.write_json(file, run())
            self.assertEqual(performance.read_run(file)["status"], "passed")
            for mutate in [
                lambda r: r.update(status="failed"),
                lambda r: r.update(evidenceKind="device"),
                lambda r: r["reports"].clear(),
                lambda r: r["environment"].clear(),
                lambda r: r["environment"].pop("sdk"),
                lambda r: r["source"].clear(),
                lambda r: r.update(scenarios=[]),
                lambda r: r["reports"]["sync-unchanged"].update(scenario="other"),
            ]:
                candidate = run()
                mutate(candidate)
                performance.write_json(file, candidate)
                with self.assertRaises(performance.Failure):
                    performance.read_run(file)

    def test_comparison_does_not_mutate_evidence(self):
        before, after = run(), run(15)
        original = copy.deepcopy((before, after))
        performance.compare(before, after, 15)
        self.assertEqual((before, after), original)

    def test_report_is_compact_and_preserves_units_and_counter_ranges(self):
        result = performance.summarize(run())
        self.assertNotIn("source", result)
        self.assertNotIn("fixtures", result)
        self.assertEqual(result["scenarios"]["sync-unchanged"]["metrics"]["cpuMilliseconds"]["median"], 10)
        self.assertEqual(result["scenarios"]["sync-unchanged"]["counters"]["checks"], {"min": 0, "max": 0})


class RunnerFailureTests(unittest.TestCase):
    def test_profile_refuses_preexisting_booted_simulator_without_stopping_it(self):
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(platform="tvOS", sim_id="owned", timeout=120, names=[], operation="profile")
            lane = performance.Lane(Path(directory), args, ())
            with patch.object(lane, "command", return_value=(0, "{}")) as command, \
                    patch.object(performance, "simulator_info", return_value=({}, "Booted")):
                with self.assertRaisesRegex(performance.Failure, "shutdown owned simulator"):
                    lane.execute()
            labels = [call.args[0] for call in command.call_args_list]
            self.assertNotIn("simulator-start", labels)
            self.assertNotIn("simulator-shutdown", labels)
            self.assertEqual(json.loads((lane.output / "result.json").read_text())["status"], "failed")

    def test_profile_lifecycle_preserves_evidence_and_never_drives_without_recorder(self):
        for failure in (None, "horizontal-navigation", "detail-return", "missing-journal", "build", "identity", "readiness", "test", "early-exit",
                        "finalize", "summary", "process", "sample"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                schemes = root / "Plozz.xcodeproj/xcshareddata/xcschemes"
                schemes.mkdir(parents=True)
                performance.package_scheme({"Fixture"}).write(schemes / "PlozzHomeFixtureTests.xcscheme")
                app = root / ".build/performance-derived-data/tvOS/ui/Build/Products/Debug-appletvsimulator/PlozzFocusHost.app"
                app.mkdir(parents=True)
                bundle = "com.thatcube.Plozz.FocusHost"
                (app / "Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": bundle, "CFBundleExecutable": "Wrong" if failure == "identity" else "FocusHost",
                }))
                args = argparse.Namespace(platform="tvOS", sim_id="owned", timeout=120, names=[],
                                          operation="profile", template="Process Sample",
                                          workload="detail-return" if failure in ("detail-return", "missing-journal")
                                          else "horizontal-navigation" if failure == "horizontal-navigation"
                                          else "home-navigation")
                if failure == "detail-return":
                    journal = root / "data/Library/Caches/Plozz/playback-trace.log"
                    journal.parent.mkdir(parents=True)
                    journal.write_text("fixture focus journal\n")
                lane = performance.Lane(root, args, ())
                labels = []
                class Recorder:
                    returncode = None
                    pid = 99999
                    def poll(self):
                        if failure == "readiness" or (failure == "early-exit" and "navigation-test" in labels):
                            self.returncode = 1
                        return self.returncode
                    def send_signal(self, _signal):
                        (lane.output / "navigation/thread-stacks.txt").write_text(
                            stack_sample(pid=99 if failure == "sample" else 42))
                    def wait(self, timeout):
                        self.returncode = 1 if failure == "finalize" else 0
                        return self.returncode
                recorder = Recorder()
                def spawn(_argv, **kwargs):
                    kwargs["stdout"].write(b"Sampling process 42\n")
                    kwargs["stdout"].flush()
                    return recorder
                def command(label, argv, *_args, **_kwargs):
                    labels.append(label)
                    if label == "navigation-build" and failure == "build":
                        raise performance.Failure("build failure")
                    if label == "navigation-test":
                        self.assertIsNone(recorder.returncode)
                        expected = (
                            "LargeNativeNavigationRemoteTests/testProfileRapidHorizontalNavigation"
                            if args.workload == "horizontal-navigation"
                            else "DetailReturnFocusRemoteTests/testProfilePopulatedShowcaseDetailReturns"
                            if args.workload == "detail-return"
                            else "ProductionHomeNavigationTests/testNavigateProductionHomeWithNativeCards"
                        )
                        self.assertIn("-only-testing:PlozzHomeRemoteTests/" + expected, argv)
                        if failure == "test":
                            raise performance.Failure("driver failure")
                    values = {
                        "fixture-launch": bundle + ": 42\n", "fixture-container": str(app),
                        "fixture-process": str(app / "FocusHost"),
                        "fixture-data-container": str(root / "data"),
                        "fixture-final-process": "different" if failure == "process" else str(app / "FocusHost"),
                        "navigation-summary": json.dumps(summary(0 if failure == "summary" else 1)),
                    }
                    return 0, values.get(label, "")
                with patch.object(lane, "command", side_effect=command), \
                        patch.object(performance.subprocess, "Popen", side_effect=spawn), \
                        patch.object(performance, "stop_owned") as stop:
                    if failure and failure not in ("detail-return", "horizontal-navigation"):
                        with self.assertRaises(performance.Failure):
                            lane.profile_navigation([])
                    else:
                        result = lane.profile_navigation([])
                        self.assertEqual(result["pid"], 42)
                        self.assertTrue(result["stacks"]["mainThreadFrames"])
                        if args.workload == "horizontal-navigation":
                            self.assertIn("--large-native-navigation-fixture", result["arguments"])
                            self.assertIn("--real-library-pages", result["arguments"])
                        else:
                            self.assertIn("--home-artwork-cache-namespace=" + lane.output.name, result["arguments"])
                        self.assertEqual(result["workload"], args.workload)
                        if args.workload == "detail-return":
                            self.assertIn("--populated-home-return", result["arguments"])
                            self.assertIn("--return-focus-trace", result["arguments"])
                            self.assertEqual((lane.output / "navigation/handoff-journal.log").read_text(),
                                             "fixture focus journal\n")
                    self.assertEqual(stop.call_count, int(failure == "test"))
                self.assertEqual("fixture-terminate" in labels, failure not in ("build", "identity"))
                self.assertEqual("navigation-test" in labels, failure not in ("build", "identity", "readiness"))
                self.assertEqual(len(list((lane.output / "navigation").glob("*.xcscheme"))), 1)
                self.assertEqual(len(list(schemes.glob("*.xcscheme"))), 1)

    def test_source_identity_includes_vendor_and_untracked_code_but_not_docs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("Sources/New.swift", "Vendor/decoder.c", "docs/guide.md"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture")
            args = argparse.Namespace(platform="tvOS", sim_id="owned", timeout=120, names=["sync-unchanged"])
            lane = performance.Lane(root, args, ())
            files = "Sources/New.swift\0Vendor/decoder.c\0Sources/Deleted.swift\0docs/guide.md\0"
            with patch.object(lane, "command", return_value=(0, files)):
                hashes = lane.fingerprint("source")
                (root / "Vendor/decoder.c").write_text("changed")
                changed = lane.fingerprint("changed")
            self.assertEqual(set(hashes), {"Sources/New.swift", "Vendor/decoder.c", "Sources/Deleted.swift"})
            self.assertEqual(hashes["Sources/Deleted.swift"], "deleted")
            self.assertNotEqual(hashes["Vendor/decoder.c"], changed["Vendor/decoder.c"])

    def test_timeout_stops_only_the_owned_command_and_retains_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(platform="tvOS", sim_id="owned", timeout=120, names=["sync-unchanged"])
            lane = performance.Lane(Path(directory), args, ())
            with patch.object(performance.subprocess, "Popen") as spawn, \
                    patch.object(performance, "stop_owned") as stop:
                spawn.return_value.wait.side_effect = subprocess.TimeoutExpired("owned", 1)
                with self.assertRaises(subprocess.TimeoutExpired):
                    lane.command("test", ["owned"], timeout=1)
                stop.assert_called_once_with(spawn.return_value)
                self.assertTrue((lane.output / "01-test.log").exists())
                self.assertTrue(spawn.call_args.kwargs["start_new_session"])

    def test_expired_lane_never_starts_another_process(self):
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(platform="tvOS", sim_id="owned", timeout=120, names=["sync-unchanged"])
            lane = performance.Lane(Path(directory), args, ())
            lane.deadline = 0
            with patch.object(performance.subprocess, "Popen") as spawn:
                with self.assertRaisesRegex(performance.Failure, "deadline"):
                    lane.command("test", ["owned"])
                spawn.assert_not_called()

    def test_source_change_fails_and_only_newly_booted_simulator_is_shutdown(self):
        for state in ("Shutdown", "Booted"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                args = argparse.Namespace(platform="tvOS", sim_id="owned", timeout=120, names=["sync-unchanged"])
                lane = performance.Lane(Path(directory), args, ())
                labels = []
                def command(label, *_args, **_kwargs):
                    labels.append(label)
                    text = {
                        "simulators": "{}", "runtimes": "{}",
                        "package-options": "-clonedSourcePackagesDirPath\0private\0",
                        "source-head": "a" * 40,
                    }.get(label, "fixture")
                    return 0, text
                sources = {"tools/performance.py": "one", "Tests/fixture.swift": "one"}
                with patch.object(lane, "command", side_effect=command), \
                        patch.object(lane, "fingerprint", side_effect=[sources, dict(sources, changed="two")]), \
                        patch.object(lane, "run_group", return_value={"sync-unchanged": report()}), \
                        patch.object(performance, "simulator_info", return_value=({}, state)):
                    with self.assertRaisesRegex(performance.Failure, "Source changed"):
                        lane.execute()
                result = json.loads((lane.output / "result.json").read_text())
                self.assertEqual(result["status"], "failed")
                self.assertEqual("simulator-shutdown" in labels, state == "Shutdown")

    def test_build_failure_restores_project_and_retains_scheme(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / "Plozz.xcodeproj"
            project.mkdir()
            (project / "original").write_text("keep")
            args = argparse.Namespace(platform="tvOS", sim_id="owned", timeout=120, names=["sync-unchanged"])
            lane = performance.Lane(root, args, ())
            with patch.object(lane, "command", side_effect=performance.Failure("build failed")):
                with self.assertRaisesRegex(performance.Failure, "build failed"):
                    lane.run_group(args.names, ["-clonedSourcePackagesDirPath", "private"], False)
            self.assertEqual((project / "original").read_text(), "keep")
            self.assertEqual(len(list((lane.output / "core").glob("*.xcscheme"))), 1)

    def test_restoration_conflict_preserves_both_projects(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / "Plozz.xcodeproj"
            project.mkdir()
            (project / "original").write_text("keep")
            args = argparse.Namespace(platform="tvOS", sim_id="owned", timeout=120, names=["sync-unchanged"])
            lane = performance.Lane(root, args, ())
            def conflicting_writer(*_args, **_kwargs):
                project.mkdir()
                (project / "concurrent").write_text("keep too")
                raise performance.Failure("writer")
            with patch.object(lane, "command", side_effect=conflicting_writer):
                with self.assertRaisesRegex(performance.Failure, "restoration conflict"):
                    lane.run_group(args.names, [], False)
            self.assertEqual((project / "concurrent").read_text(), "keep too")
            self.assertEqual((lane.output / "Plozz.xcodeproj/original").read_text(), "keep")

    def test_nonzero_test_driver_exit_cannot_be_overridden_by_passing_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = argparse.Namespace(platform="tvOS", sim_id="owned", timeout=120, names=["sync-unchanged"])
            lane = performance.Lane(root, args, ())
            def command(label, *_args, **_kwargs):
                return (65, "") if label.endswith("-test") else (0, json.dumps(summary()))
            with patch.object(lane, "command", side_effect=command):
                with self.assertRaisesRegex(performance.Failure, "passing summary"):
                    lane.run_group(args.names, [], False)


if __name__ == "__main__":
    unittest.main()
