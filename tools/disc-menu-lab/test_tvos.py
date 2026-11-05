import unittest
from pathlib import Path
import tempfile
import json
import plistlib
from unittest.mock import patch

import tvos
import tvos_smoke


class TVOSPortTests(unittest.TestCase):
    def test_patch_requires_exactly_one_match(self):
        self.assertEqual(tvos.replace_once("before target after", "target", "new"),
                         "before new after")
        for text in ("missing", "target target"):
            with self.assertRaises(ValueError):
                tvos.replace_once(text, "target", "new")

    def test_real_target_with_invocation_symbol_is_accepted(self):
        tvos.validate_jvm(" platform 3\n minos 18.0\n", " _malloc\n",
                          "0000 T _JNI_CreateJavaVM\n", "arm64\n")

    def test_desktop_simulator_and_mixed_architectures_are_rejected(self):
        for headers, architecture in (
            (" platform 1\n", "arm64"),
            (" platform 8\n", "arm64"),
            (" platform 3\n platform 1\n", "arm64 x86_64"),
            (" platform 3\n", "x86_64"),
            ("", "arm64"),
        ):
            with self.subTest(headers=headers, architecture=architecture):
                with self.assertRaises(ValueError):
                    tvos.validate_jvm(headers, "", "0000 T _JNI_CreateJavaVM", architecture)

    def test_unsupported_jit_and_process_imports_are_rejected(self):
        for symbol in ("pthread_jit_write_protect_np", "posix_spawn", "fork",
                       "task_set_exception_ports"):
            with self.subTest(symbol=symbol), self.assertRaises(ValueError):
                tvos.validate_jvm(" platform 3\n", f" _{symbol}\n",
                                  "0000 T _JNI_CreateJavaVM", "arm64")

    def test_missing_invocation_entry_is_not_a_jvm_pass(self):
        with self.assertRaises(ValueError):
            tvos.validate_jvm(" platform 3\n", "", "0000 T _other_symbol", "arm64")

    def test_simulator_artifacts_require_explicit_selection(self):
        tvos.validate_jvm(" platform 8\n", "", "0000 T _JNI_CreateJavaVM", "arm64",
                          simulator=True)
        with self.assertRaises(ValueError):
            tvos.validate_platform(" platform 3\n", "arm64", simulator=True)

    def test_mobile_artifacts_cannot_be_confused_with_tv_artifacts(self):
        tvos.validate_platform(" platform 2\n", "arm64", mobile=True)
        tvos.validate_platform(" platform 7\n", "arm64", mobile=True, simulator=True)
        for platform in ("1", "3", "8"):
            with self.assertRaises(ValueError):
                tvos.validate_platform(f" platform {platform}\n", "arm64", mobile=True)

    def test_staging_rejects_an_incomplete_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in (
                "jdk/modules/java.base", "support/modules_libs/java.base",
                "support/modules_conf/java.base", "support/modules_legal/java.base",
            ):
                (root / "build" / relative).mkdir(parents=True)
            with self.assertRaisesRegex(RuntimeError, "missing"):
                tvos.stage_runtime(root / "build", root / "runtime")

    def test_only_completed_simulator_execution_is_accepted(self):
        tvos_smoke.validate_result({
            "status": "pass", "platform": "tvOS Simulator", "physical_device": False,
        })
        for result in (
            {}, {"status": "pass"}, {"status": "staged"},
            {"status": "failed", "platform": "tvOS Simulator", "physical_device": False},
            {"status": "pass", "platform": "tvOS Simulator", "physical_device": True},
            {"status": "pass", "platform": "macOS", "physical_device": False},
        ):
            with self.subTest(result=result), self.assertRaises(RuntimeError):
                tvos_smoke.validate_result(result)

    def test_simulator_cleanup_after_boot_failure_is_owned_and_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            class FakeLab:
                run_dir = Path(directory)
                commands = []

                def run(self, name, arguments, *, timeout):
                    self.commands.append({"name": name, "argv": arguments,
                                          "log": name + ".log", "timeout": timeout})
                    if name == "list-smoke-runtimes":
                        text = json.dumps({"runtimes": [{
                            "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-27-0",
                            "version": "27.0", "isAvailable": True,
                        }]})
                    elif name == "create-owned-smoke-simulator":
                        text = "12345678-1234-1234-1234-123456789abc"
                    elif name == "wait-owned-smoke-simulator":
                        raise RuntimeError("Simulated boot failure")
                    else:
                        text = ""
                    (self.run_dir / (name + ".log")).write_text(text)

            lab = FakeLab()
            with self.assertRaisesRegex(RuntimeError, "Simulated boot failure"):
                tvos_smoke.execute(lab, Path(directory) / "probe.app", "app.plozz.lab.ZeroSmoke")
            for command, operation in zip(lab.commands[-2:], ("shutdown", "delete")):
                self.assertEqual(command["argv"], [
                    "xcrun", "simctl", operation, "12345678-1234-1234-1234-123456789abc",
                ])
                self.assertEqual(command["timeout"], 60)
            self.assertEqual(json.loads((lab.run_dir / "simulator-cleanup.json").read_text())[
                "status"], "complete")

    def test_device_execution_requires_device_evidence_and_matching_run(self):
        result = {"status": "pass", "platform": "tvOS", "physical_device": True,
                  "run_id": "current"}
        tvos_smoke.validate_result(result, simulator=False, run_id="current")
        with self.assertRaises(RuntimeError):
            tvos_smoke.validate_result(result, run_id="current")
        with self.assertRaisesRegex(RuntimeError, "different lab invocation"):
            tvos_smoke.validate_result(result, simulator=False, run_id="another")
        with self.assertRaises(RuntimeError):
            tvos_smoke.validate_result({
                **result, "platform": "tvOS Simulator", "physical_device": False,
            }, simulator=False, run_id="current")
        with self.assertRaises(RuntimeError):
            tvos_smoke.validate_result({**result, "physical_device": 1},
                                      simulator=False, run_id="current")

    def test_log_copy_failure_does_not_skip_owned_simulator_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            container = root / "container"
            cache = container / "Library/Caches"
            cache.mkdir(parents=True)
            (cache / "runtime-stdout.log").write_text("runtime log")
            (cache / "runtime-result.json").write_text(json.dumps({
                "status": "pass", "platform": "tvOS Simulator", "physical_device": False,
                "run_id": root.name,
            }))

            class FakeLab:
                run_dir = root

                def __init__(self):
                    self.commands = []

                def run(self, name, arguments, *, timeout):
                    self.commands.append({"name": name, "argv": arguments,
                                          "log": name + ".log"})
                    text = ""
                    if name == "list-smoke-runtimes":
                        text = json.dumps({"runtimes": [{
                            "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-27-0",
                            "version": "27.0", "isAvailable": True,
                        }]})
                    elif name == "create-owned-smoke-simulator":
                        text = "12345678-1234-1234-1234-123456789abc"
                    elif name == "locate-owned-smoke-container":
                        text = str(container)
                    (root / (name + ".log")).write_text(text)

            lab = FakeLab()
            with patch.object(tvos_smoke.shutil, "copy2", side_effect=OSError("copy failed")):
                with self.assertRaisesRegex(RuntimeError, "Could not retain runtime stdout"):
                    tvos_smoke.execute(lab, root / "probe.app", "app.plozz.lab.ZeroSmoke")
            self.assertEqual([entry["name"] for entry in lab.commands[-2:]], [
                "shutdown-owned-smoke-simulator", "delete-owned-smoke-simulator",
            ])

    def test_app_build_is_platform_specific_and_never_signs_or_installs(self):
        for simulator in (False, True):
            with self.subTest(simulator=simulator), tempfile.TemporaryDirectory() as directory:
                class FakeLab:
                    run_dir = Path(directory)
                    environment = {"JAVA_HOME": str(Path(directory) / "jdk")}

                    def __init__(self):
                        self.commands = []

                    def run(self, name, arguments):
                        self.commands.append({"name": name, "argv": arguments,
                                              "log": name + ".log"})
                        (self.run_dir / (name + ".log")).write_text("/isolated/sdk")

                lab = FakeLab()
                for name in ("runtime", "disc", "jars"):
                    (lab.run_dir / name).mkdir()
                app = tvos_smoke.build_app(lab, simulator=simulator,
                                          bdj={"include": "/isolated/include", "link": []})
                info = plistlib.loads((app / "Info.plist").read_bytes())
                self.assertEqual(info["CFBundleIdentifier"], "app.plozz.lab.ZeroSmoke")
                self.assertEqual(info["PlozzLabRunID"], lab.run_dir.name)
                self.assertEqual(info["CFBundleSupportedPlatforms"],
                                 ["AppleTVSimulator" if simulator else "AppleTVOS"])
                self.assertEqual([entry["name"] for entry in lab.commands], [
                    "smoke-sdk", "compile-embedded-navigation", "compile-runtime-smoke-app",
                ])
                target = "arm64-apple-tvos18.0" + ("-simulator" if simulator else "")
                for command in lab.commands[1:]:
                    arguments = command["argv"]
                    self.assertEqual(arguments[arguments.index("-target") + 1], target)


if __name__ == "__main__":
    unittest.main()
