"""Exercise real deployment argument parsing with isolated build-tool stubs."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DeploymentOptimizationTests(unittest.TestCase):
    def run_wrapper(self, name, arguments):
        with tempfile.TemporaryDirectory(prefix="plozz-deploy-flags-") as directory:
            root = Path(directory)
            tools = root / "tools"
            (tools / "lib").mkdir(parents=True)
            binaries = root / "bin"
            binaries.mkdir()
            app = root / "Plozz.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "test.fixture",
                "CFBundleVersion": "1",
                "TMDBBearerToken": "fixture",
                "TVDBAPIKey": "fixture",
            }))
            project = root / "Plozz.xcodeproj"
            project.mkdir()
            (project / "project.pbxproj").write_text("fixture")
            shutil.copyfile(ROOT / "tools" / name, tools / name)
            (tools / "lib/apple-build-lease.sh").write_text("""
acquire_apple_build_shared_lease() { :; }
install_apple_build_lease_traps() { :; }
release_apple_build_lease() { :; }
abandon_apple_build_lease() { :; }
apple_build_lease_signal_exit() { exit "$1"; }
""")
            (tools / "lib/swift-package-storage.sh").write_text(
                'configure_plozz_package_resolution() { PACKAGE_RESOLUTION_ARGS=(-skipPackageUpdates); }\n'
            )
            (tools / "run-bounded.py").write_text(
                'import subprocess,sys\nsys.exit(subprocess.call(sys.argv[sys.argv.index("--")+1:]))\n'
            )
            for helper in ["generate-project.sh", "l10n-prune-stale-products.sh"]:
                path = tools / helper
                path.write_text("#!/bin/bash\nexit 0\n")
                path.chmod(0o755)
            xcodebuild = binaries / "xcodebuild"
            xcodebuild.write_text("""#!/usr/bin/python3
import json,os,sys
with open(os.environ["COMMAND_LOG"],"a") as handle:
    handle.write(json.dumps(sys.argv[1:])+"\\n")
if "-showBuildSettings" in sys.argv:
    print(" CODESIGNING_FOLDER_PATH = "+os.environ["FIXTURE_APP"])
else:
    print("Build Succeeded")
""")
            xcodebuild.chmod(0o755)
            for binary, code in [("codesign", 0), ("xcrun", 91), ("security", 92)]:
                path = binaries / binary
                path.write_text(f"#!/bin/bash\nexit {code}\n")
                path.chmod(0o755)
            log = root / "commands.jsonl"
            environment = {
                **os.environ,
                "PATH": f"{binaries}:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": str(root),
                "COMMAND_LOG": str(log),
                "FIXTURE_APP": str(app),
                "ASC_KEY_PATH": str(root / "nonexistent-key.p8"),
                "PLOZZ_SIM_ID": "fixture-simulator",
                "PLOZZ_TV_ID": "fixture-tv",
                "PLOZZ_IPHONE_CORE_ID": "fixture-phone",
                "PLOZZ_IPAD_CORE_ID": "fixture-tablet",
            }
            result = subprocess.run(
                ["/bin/bash", str(tools / name), *arguments],
                cwd=root, env=environment, text=True, capture_output=True, timeout=15
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return [json.loads(line) for line in log.read_text().splitlines()]

    def test_device_build_settings_and_compiles_are_optimized_by_default(self):
        for wrapper in ["deploy-tv.sh", "deploy-ios.sh"]:
            with self.subTest(wrapper=wrapper):
                commands = self.run_wrapper(wrapper, ["--build-only"])
                self.assertTrue(any("build" in args for args in commands))
                self.assertTrue(any("-showBuildSettings" in args for args in commands))
                for args in commands:
                    self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-O", args)
                    self.assertNotIn("SWIFT_OPTIMIZATION_LEVEL=-Onone", args)
                    self.assertEqual(args[args.index("-configuration") + 1], "Debug")

    def test_debugger_opt_out_reaches_settings_and_compiler(self):
        for wrapper in ["deploy-tv.sh", "deploy-ios.sh"]:
            with self.subTest(wrapper=wrapper):
                for args in self.run_wrapper(wrapper, ["--build-only", "--unoptimized"]):
                    self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-Onone", args)
                    self.assertNotIn("SWIFT_OPTIMIZATION_LEVEL=-O", args)

    def test_simulator_compile_keeps_unoptimized_debugging(self):
        for args in self.run_wrapper("deploy-tv.sh", ["--sim-build"]):
            self.assertIn("SWIFT_OPTIMIZATION_LEVEL=-Onone", args)
            self.assertIn("platform=tvOS Simulator,id=fixture-simulator", args)


if __name__ == "__main__":
    unittest.main()
