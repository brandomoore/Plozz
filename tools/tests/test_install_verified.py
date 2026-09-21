#!/usr/bin/env python3
"""Device-free tests for the shared installer, including transient failures."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("install_verified", ROOT / "tools/install-verified.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class FakeCommands:
    def __init__(self, evidence, snapshots, installs, signature=0, package_error=False):
        self.evidence = evidence
        self.snapshots = iter(snapshots)
        self.installs = iter(installs)
        self.signature = signature
        self.package_error = package_error
        self.calls = []
        self.launch_status = 0

    def run(self, name, command, timeout):
        self.calls.append((name, command, timeout))
        if name == "signature":
            return self.signature
        if name == "launch":
            return self.launch_status
        if name.startswith("install-"):
            result = next(self.installs)
            if self.package_error:
                (self.evidence / f"{name}.json").write_text(json.dumps({
                    "error": {"underlyingErrors": [{"domain": "MIInstallerErrorDomain", "code": 13}]}
                }))
            return result
        snapshot = next(self.snapshots)
        if snapshot is installer.UNKNOWN:
            return 124
        apps = [] if snapshot is None else [{
            "bundleIdentifier": "com.example.fixture",
            "version": snapshot[0], "bundleVersion": snapshot[1],
        }]
        (self.evidence / f"{name}.json").write_text(json.dumps({"result": {"apps": apps}}))
        return 0


class InstallerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="plozz-install-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.app = self.root / "Fixture.app"
        self.app.mkdir()
        with (self.app / "Info.plist").open("wb") as stream:
            plistlib.dump({
                "CFBundleIdentifier": "com.example.fixture",
                "CFBundleShortVersionString": "1.0", "CFBundleVersion": "42",
            }, stream)
        self.target = ("1.0", "42")
        self.old = ("1.0", "41")
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()
        self.output = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.output)
        self.redirect.__enter__()
        self.addCleanup(self.redirect.__exit__, None, None, None)

    def make(self, snapshots, installs, **kwargs):
        commands = FakeCommands(self.evidence, snapshots, installs, **kwargs)
        sleep = mock.Mock()
        lane = installer.Installer("fixture-device", self.app, self.evidence, commands, sleep=sleep)
        return lane, commands, sleep

    def receipt(self):
        return json.loads((self.evidence / "receipt.json").read_text())

    def test_defaults_allow_three_full_180_second_attempts_without_outer_cutoff(self):
        lane, commands, sleep = self.make([self.old, self.old, self.old, self.target], [124, 1, 0])
        self.assertTrue(lane.install(force=True))
        attempts = [call for call in commands.calls if call[0].startswith("install-")]
        self.assertEqual(len(attempts), 3)
        self.assertTrue(all(timeout == 185 for _, _, timeout in attempts))
        self.assertTrue(all(command[command.index("--timeout") + 1] == "180" for _, command, _ in attempts))
        self.assertEqual(sleep.call_args_list, [mock.call(3), mock.call(6)])
        self.assertEqual(self.receipt()["attempts"], 3)

    def test_cached_unavailability_does_not_gate_install(self):
        lane, commands, _ = self.make([installer.UNKNOWN, self.target], [0])
        self.assertTrue(lane.install(force=True))
        self.assertEqual(self.receipt()["outcome"], "installed")
        self.assertFalse(any("details" in command for _, command, _ in commands.calls))

    def test_error_after_completed_install_is_verified_without_reinstall(self):
        lane, commands, sleep = self.make([self.old, self.target], [1])
        self.assertTrue(lane.install(force=True))
        self.assertEqual(self.receipt()["outcome"], "verified-after-error")
        sleep.assert_not_called()
        self.assertEqual(sum(name.startswith("install-") for name, _, _ in commands.calls), 1)

    def test_force_cannot_accept_an_unchanged_build_after_failure(self):
        lane, commands, _ = self.make([self.target] * 4, [1, 1, 1])
        self.assertFalse(lane.install(force=True))
        self.assertEqual(self.receipt()["outcome"], "unconfirmed")
        self.assertFalse(any(name == "launch" for name, _, _ in commands.calls))

    def test_unknown_baseline_is_not_proof_of_force_replacement(self):
        lane, _, _ = self.make([installer.UNKNOWN, self.target, self.target], [1, 0])
        self.assertTrue(lane.install(force=True))
        self.assertEqual(self.receipt()["attempts"], 2)

    def test_successful_install_does_not_depend_on_followup_connection(self):
        lane, _, _ = self.make([installer.UNKNOWN, installer.UNKNOWN], [0])
        self.assertTrue(lane.install(force=True))
        self.assertEqual(self.receipt()["outcome"], "installed")

    def test_expired_followup_and_launch_do_not_erase_install_success(self):
        lane, commands, _ = self.make([self.old], [0])
        run = commands.run

        def deadline_after_install(name, command, timeout):
            if name.startswith("verify-") or name == "launch":
                raise TimeoutError("explicit deadline")
            return run(name, command, timeout)

        with mock.patch.object(commands, "run", side_effect=deadline_after_install):
            self.assertTrue(lane.install(force=True))
        self.assertEqual(self.receipt()["outcome"], "installed")

    def test_clean_exit_with_wrong_version_is_not_success(self):
        lane, _, _ = self.make([self.old] * 4, [0, 0, 0])
        self.assertFalse(lane.install(force=True))

    def test_non_force_skips_existing_build(self):
        lane, commands, _ = self.make([self.target], [])
        self.assertTrue(lane.install(launch=False))
        self.assertEqual([name for name, _, _ in commands.calls], ["signature", "baseline"])

    def test_package_rejection_is_not_retried_as_a_connection_problem(self):
        lane, commands, sleep = self.make([self.old, self.old], [1], package_error=True)
        self.assertFalse(lane.install(force=True))
        self.assertEqual(self.receipt()["outcome"], "package-rejected")
        sleep.assert_not_called()

    def test_invalid_signature_never_touches_device(self):
        lane, commands, _ = self.make([], [], signature=1)
        self.assertFalse(lane.install(force=True))
        self.assertEqual([name for name, _, _ in commands.calls], ["signature"])

    def test_launch_failure_does_not_turn_installation_into_failure(self):
        lane, commands, _ = self.make([self.old, self.target], [0])
        commands.launch_status = 1
        self.assertTrue(lane.install(force=True))
        self.assertNotIn("Launch request succeeded", self.output.getvalue())

    def test_malformed_verification_fails_closed(self):
        lane, commands, _ = self.make([], [])
        with mock.patch.object(commands, "run", return_value=0):
            (self.evidence / "broken.json").write_text('{"result":{"apps":"not an array"}}')
            self.assertIs(lane.installed("broken"), installer.UNKNOWN)

    def test_cancellation_stops_only_the_owned_command_group(self):
        process = mock.Mock(pid=987654)
        process.wait.side_effect = [installer.Interrupted(signal.SIGTERM), 0, 0]
        commands = installer.Commands(self.evidence, (8, 9))
        with mock.patch.object(installer.subprocess, "Popen", return_value=process) as spawn, \
             mock.patch.object(installer.os, "killpg") as kill:
            with self.assertRaises(installer.Interrupted):
                commands.run("cancel", ["fixture"], 180)
        self.assertEqual(spawn.call_args.kwargs["pass_fds"], (8, 9))
        self.assertTrue(spawn.call_args.kwargs["start_new_session"])
        self.assertEqual(kill.call_args_list, [
            mock.call(987654, signal.SIGTERM), mock.call(987654, signal.SIGKILL),
        ])

    def test_timeout_terminates_then_reaps_owned_process(self):
        process = mock.Mock(pid=987654)
        process.wait.side_effect = [
            subprocess.TimeoutExpired("fixture", 1),
            subprocess.TimeoutExpired("fixture", 5), 0,
        ]
        commands = installer.Commands(self.evidence, ())
        with mock.patch.object(installer.subprocess, "Popen", return_value=process), \
             mock.patch.object(installer.os, "killpg") as kill:
            self.assertEqual(commands.run("timeout", ["fixture"], 1), 124)
        self.assertEqual(kill.call_args_list, [
            mock.call(987654, signal.SIGTERM), mock.call(987654, signal.SIGKILL),
        ])

    def test_explicit_overall_deadline_expires_without_spawning(self):
        commands = installer.Commands(self.evidence, (), deadline=0)
        with mock.patch.object(installer.subprocess, "Popen") as spawn:
            with self.assertRaises(TimeoutError):
                commands.run("expired", ["fixture"], 1)
        spawn.assert_not_called()

    def test_settings_are_bounded_and_fail_before_device_work(self):
        for name, value, maximum in [
            ("PLOZZ_INSTALL_TIMEOUT", "0", 600), ("PLOZZ_INSTALL_TIMEOUT", "601", 600),
            ("PLOZZ_INSTALL_ATTEMPTS", "6", 5), ("PLOZZ_INSTALL_ATTEMPTS", "not-a-number", 5),
        ]:
            with mock.patch.dict(os.environ, {name: value}):
                with self.assertRaises(ValueError):
                    installer.positive_setting(name, 1, maximum)

    def test_wrappers_share_recovery_without_fixed_150_second_deadline(self):
        for name in ("deploy-ios.sh", "deploy-tv.sh"):
            source = (ROOT / "tools" / name).read_text()
            self.assertIn('install-verified.sh"', source)
            self.assertNotIn("PLOZZ_DEPLOY_INSTALL_DEADLINE:-150", source)
        source = (ROOT / "tools/install-verified.py").read_text()
        self.assertNotIn("pgrep", source)
        self.assertNotIn("reset_coredevice", source)


if __name__ == "__main__":
    unittest.main()
