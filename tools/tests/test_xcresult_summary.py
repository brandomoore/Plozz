#!/usr/bin/env python3
"""XCTest crash/restart verdicts must come from xcresult, not survivor logs."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tools/xcresult-summary.py"
SPEC = importlib.util.spec_from_file_location("xcresult_summary", HELPER)
results = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(results)


def summary(**changes):
    value = {
        "result": "Passed",
        "totalTestCount": 14,
        "passedTests": 14,
        "failedTests": 0,
        "skippedTests": 0,
        "expectedFailures": 0,
        "testFailures": [],
    }
    value.update(changes)
    return value


class ResultSummaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="xcresult-summary-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / "summary.json"

    def write(self, value):
        self.path.write_text(json.dumps(value))
        return self.path

    def test_clean_run_passes(self):
        self.assertTrue(results.passed(results.read_summary(self.write(summary()))))

    def test_crash_is_not_erased_by_passing_survivors(self):
        value = summary(
            result="Failed", passedTests=13, failedTests=1,
            testFailures=[{"targetName": "FeatureProfilesTests",
                           "failureText": "Test crashed with signal abrt."}],
        )
        loaded = results.read_summary(self.write(value))
        self.assertFalse(results.passed(loaded))
        self.assertEqual(results.failed_targets(loaded), ["FeatureProfilesTests"])

    def test_repeated_crashes_retry_the_whole_target_only_once(self):
        value = summary(
            result="Failed", passedTests=10, failedTests=4,
            testFailures=[{"targetName": "FeatureProfilesTests"}] * 4,
        )
        self.assertEqual(results.failed_targets(value), ["FeatureProfilesTests"])

    def test_failure_count_cannot_be_overridden_by_result_label(self):
        self.assertFalse(results.passed(summary(passedTests=13, failedTests=1)))

    def test_unknown_and_empty_runs_do_not_pass(self):
        for value in (
            summary(result="unknown"),
            summary(result="Failed"),
            summary(totalTestCount=0, passedTests=0),
            summary(result="Skipped", passedTests=0, skippedTests=14),
            summary(passedTests=0, skippedTests=14),
        ):
            with self.subTest(value=value):
                self.assertFalse(results.passed(value))

    def test_expected_failures_do_not_become_retry_targets(self):
        value = summary(passedTests=13, expectedFailures=1,
                        testFailures=[{"targetName": "KnownIssueTests"}])
        self.assertTrue(results.passed(value))
        self.assertEqual(results.failed_targets(value), [])

    def test_malformed_results_fail_closed(self):
        for value in (
            [], {}, summary(failedTests=None), summary(failedTests=True),
            summary(failedTests=-1), summary(testFailures=None),
            summary(testFailures=[{}]),
            summary(testFailures=[{"targetName": None}]),
            summary(testFailures=[{"targetName": 42}]),
            summary(testFailures=[{"targetName": "../not-a-target"}]),
        ):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    results.read_summary(self.write(value))

    def test_missing_or_truncated_summary_fails_cli(self):
        for contents in (None, '{"result":'):
            if contents is not None:
                self.path.write_text(contents)
            result = subprocess.run(
                [sys.executable, str(HELPER), "verdict", str(self.path)],
                text=True, capture_output=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cannot verify test results", result.stderr)

    def test_cli_returns_all_failed_targets(self):
        value = summary(
            result="Failed", failedTests=2, passedTests=12,
            testFailures=[{"targetName": "FeatureProfilesTests"},
                          {"targetName": "CoreUITests"}],
        )
        result = subprocess.run(
            [sys.executable, str(HELPER), "failed-targets", str(self.write(value))],
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["CoreUITests", "FeatureProfilesTests"])

    def run_reaped_driver(self, value, *, finalizes=True, build_exit=0, manifests=1, filtered=True,
                          build_delay=0, start_delay=0, compile_limit=60, test_limit=60):
        self.write(value)
        binaries = self.root / "bin"
        binaries.mkdir()
        commands = {
            "xcodebuild": """#!/bin/bash
printf '%s\\n' "$*" >> "$FIXTURE_ROOT/calls.log"
if [[ "$1" == "build-for-testing" ]]; then
  sleep "$FIXTURE_BUILD_DELAY"
  if [[ "$FIXTURE_BUILD_EXIT" != "0" ]]; then exit "$FIXTURE_BUILD_EXIT"; fi
  mkdir -p "$FIXTURE_ROOT/derived/Build/Products"
  for ((i=0; i<FIXTURE_MANIFESTS; i++)); do
    touch "$FIXTURE_ROOT/derived/Build/Products/Fixture_appletvsimulator-$i.xctestrun"
  done
  exit 0
fi
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-resultBundlePath" ]]; then
    shift
    result="$1"
  fi
  shift
done
sleep "$FIXTURE_START_DELAY"
printf "Test Suite 'FeatureProfilesTests.xctest' passed\\n"
if [[ "$FIXTURE_FINALIZES" == "1" ]]; then
  sleep 2
  mkdir -p "$result"
  touch "$result/Info.plist"
fi
sleep 30
""",
            "xcrun": '#!/bin/bash\ncat "$FIXTURE_SUMMARY"\n',
        }
        for name, contents in commands.items():
            path = binaries / name
            path.write_text(contents)
            path.chmod(0o700)
        runner = (ROOT / "tools/run-tests.sh").read_text()
        helpers = runner.split("# --- Run helpers", 1)[1]
        helpers = helpers.split("\n# xcodebuild_test", 1)[0]
        helpers = helpers.split("\n", 1)[1]
        kill_tree = "kill_tree() {" + runner.split("kill_tree() {", 1)[1].split("\n\n", 1)[0]
        script = """
set -u
PARALLEL=NO
PACKAGE_RESOLUTION_ARGS=(-disableAutomaticPackageResolution)
LEAN_SETTINGS=(ONLY_ACTIVE_ARCH=YES)
PLOZZ_SIM_ID=fixture
PLOZZ_DERIVED_DATA="$FIXTURE_ROOT/derived"
PLOZZ_TEST_RESULTS_DIR="$FIXTURE_ROOT/results"
PLOZZ_HANG_SECS="$FIXTURE_TEST_LIMIT"
PLOZZ_COMPILE_HANG_SECS="$FIXTURE_COMPILE_LIMIT"
PLOZZ_VERDICT_GRACE=0
PLOZZ_RESULT_TIMEOUT="$FIXTURE_RESULT_TIMEOUT"
POLL_SECS=1
EXPECTED_BUNDLES=1
""" + kill_tree + "\n" + helpers + (
            '\n_xcb_once "$FIXTURE_ROOT/main.log" -scheme Fixture'
            + (' -only-testing:FeatureProfilesTests' if filtered else '') + '\n'
        )
        process = subprocess.Popen(
            ["/bin/bash", "-c", script], cwd=ROOT, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, env={
                **os.environ, "PATH": f"{binaries}:{os.environ['PATH']}",
                "FIXTURE_ROOT": str(self.root), "FIXTURE_SUMMARY": str(self.path),
                "FIXTURE_FINALIZES": "1" if finalizes else "0",
                "FIXTURE_BUILD_EXIT": str(build_exit),
                "FIXTURE_BUILD_DELAY": str(build_delay), "FIXTURE_START_DELAY": str(start_delay),
                "FIXTURE_COMPILE_LIMIT": str(compile_limit), "FIXTURE_TEST_LIMIT": str(test_limit),
                "FIXTURE_MANIFESTS": str(manifests),
                "FIXTURE_RESULT_TIMEOUT": "15" if finalizes else "4",
            },
        )
        try:
            stdout, stderr = process.communicate(timeout=30)
            return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
        finally:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)

    def test_reaping_survivor_logs_does_not_hide_a_crash(self):
        result = self.run_reaped_driver(summary(
            result="Failed", passedTests=13, failedTests=1,
            testFailures=[{"targetName": "FeatureProfilesTests"}],
        ))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("xcresult: Failed", result.stdout)

    def test_reaping_successful_teardown_keeps_verified_success(self):
        result = self.run_reaped_driver(summary())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("xcresult: Passed", result.stdout)
        self.assertIn("xcresult is readable", result.stderr)
        calls = (self.root / "calls.log").read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[0].startswith("build-for-testing -scheme Fixture"))
        self.assertTrue(calls[1].startswith("test-without-building -xctestrun "))
        self.assertNotIn("-scheme", calls[1])
        self.assertNotIn("-derivedDataPath", calls[1])
        self.assertIn("-only-testing:FeatureProfilesTests", calls[1])

    def test_build_failure_never_runs_stale_tests(self):
        result = self.run_reaped_driver(summary(), build_exit=65)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len((self.root / "calls.log").read_text().splitlines()), 1)

    def test_quiet_compile_can_outlast_test_silence_budget(self):
        result = self.run_reaped_driver(summary(), build_delay=5, test_limit=3, compile_limit=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("xcresult: Passed", result.stdout)

    def test_silent_compile_remains_bounded(self):
        result = self.run_reaped_driver(summary(), build_delay=15, compile_limit=2)
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        self.assertIn("no compile output", result.stderr)
        self.assertEqual(len((self.root / "calls.log").read_text().splitlines()), 1)

    def test_silent_tests_do_not_inherit_the_compile_budget(self):
        result = self.run_reaped_driver(summary(), start_delay=15, test_limit=2)
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        self.assertIn("no test output", result.stderr)

    def test_full_matrix_runs_without_test_filters_under_nounset(self):
        result = self.run_reaped_driver(summary(), filtered=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / "calls.log").read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[1].startswith("test-without-building -xctestrun "))
        self.assertNotIn("-only-testing", calls[1])
        self.assertNotIn("-skip-testing", calls[1])

    def test_missing_manifest_fails_closed(self):
        result = self.run_reaped_driver(summary(), manifests=0)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("found 0", (self.root / "main.log").read_text())
        self.assertEqual(len((self.root / "calls.log").read_text().splitlines()), 1)

    def test_ambiguous_manifests_fail_closed(self):
        result = self.run_reaped_driver(summary(), manifests=2)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("found 2", (self.root / "main.log").read_text())
        self.assertEqual(len((self.root / "calls.log").read_text().splitlines()), 1)

    def test_result_finalization_timeout_does_not_pass(self):
        result = self.run_reaped_driver(summary(), finalizes=False)
        self.assertEqual(result.returncode, 124, result.stdout + result.stderr)
        self.assertIn("xcresult did not finalize", result.stderr)
        self.assertNotIn("xcresult: Passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
