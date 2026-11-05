import unittest
from pathlib import Path
import tempfile
import json

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


if __name__ == "__main__":
    unittest.main()
