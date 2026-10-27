import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("connection_evidence", ROOT / "tools/tracker-connection-evidence.py")
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


def manifest(platform="tvOS"):
    target = evidence.TARGETS[platform]
    products = "__TESTROOT__/Debug-" + {"tvOS": "appletvsimulator", "iOS": "iphonesimulator"}[platform]
    return {"TestConfigurations": [{"TestTargets": [{
        "BlueprintName": target,
        "IsUITestBundle": True,
        "TestHostPath": f"{products}/{target}-Runner.app",
        "DependentProductPaths": [
            f"{products}/{target}-Runner.app",
            f"{products}/{target}-Runner.app/PlugIns/{target}.xctest",
        ],
        "SystemAttachmentLifetime": "keepNever",
        "PreferredScreenCaptureFormat": "screenshots",
        "UITargetAppCommandLineArguments": [],
        "UITargetAppEnvironmentVariables": {
            "APP_DISTRIBUTOR_ID_OVERRIDE": "com.apple.AppStore",
            "DYLD_FRAMEWORK_PATH": products + ":" + products + "/PackageFrameworks",
            "DYLD_LIBRARY_PATH": products,
            "XCODE_SCHEME_NAME": target,
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS": products,
            "__XPC_DYLD_FRAMEWORK_PATH": products,
            "__XPC_DYLD_LIBRARY_PATH": products,
        },
    }]}]}


def results():
    return (
        {"result": "Passed", "totalTestCount": 1, "passedTests": 1, "failedTests": 0,
         "skippedTests": 0, "expectedFailures": 0, "testFailures": []},
        {"testNodes": [{"nodeType": "Test Plan", "children": [{
            "nodeType": "UI test bundle", "name": evidence.TARGETS["tvOS"], "children": [{
                "nodeType": "Test Case", "nodeIdentifier": evidence.METHOD, "result": "Passed",
            }],
        }]}]},
    )


class TrackerConnectionEvidenceTests(unittest.TestCase):
    def test_both_platforms_require_a_single_unbound_runner_and_no_automatic_capture(self):
        for platform in evidence.TARGETS:
            value = manifest(platform)
            self.assertEqual(evidence.validate_manifest(value, platform)["BlueprintName"], evidence.TARGETS[platform])
            target = value["TestConfigurations"][0]["TestTargets"][0]
            self.assertEqual(evidence.validate_manifest({target["BlueprintName"]: target}, platform), target)

    def test_app_or_fixture_bindings_launch_injection_and_capture_are_rejected(self):
        for field, value in (
            ("UITargetAppPath", "__TESTROOT__/Plozz.app"),
            ("UITargetAppBundleIdentifier", "com.thatcube.Plozz"),
            ("UITargetAppBundleIdentifier", "com.thatcube.Plozz.FocusHost"),
            ("DependentProductPaths", ["__TESTROOT__/Plozz.app"]),
            ("DependentProductPaths", ["__TESTROOT__/PlozzFocusHost.app"]),
            ("DependentProductPaths", ["__TESTROOT__/Debug-appletvsimulator/PlozzTrackerConnectionTests-Runner.app/../Plozz.app"]),
            ("TestHostPath", "__TESTROOT__/Plozz.app/Plozz"),
            ("UITargetAppCommandLineArguments", ["--fixture"]),
            ("UITargetAppEnvironmentVariables", {"PLOZZ_TEST": "1"}),
            ("UITargetAppEnvironmentVariables", {"DYLD_LIBRARY_PATH": "/tmp/unexpected"}),
            ("UITargetAppEnvironmentVariables", {"XCODE_SCHEME_NAME": "Plozz"}),
            ("SystemAttachmentLifetime", "keepAlways"),
            ("PreferredScreenCaptureFormat", "video"),
            ("IsUITestBundle", False),
        ):
            with self.subTest(field=field, value=value):
                data = manifest()
                data["TestConfigurations"][0]["TestTargets"][0][field] = value
                with self.assertRaises(ValueError):
                    evidence.validate_manifest(data, "tvOS")

    def test_wrong_extra_and_missing_targets_or_configurations_fail(self):
        for mode in ("wrong", "extra", "missing", "configuration"):
            data = manifest()
            targets = data["TestConfigurations"][0]["TestTargets"]
            if mode == "wrong":
                targets[0]["BlueprintName"] = "PlozzHomeRemoteTests"
            elif mode == "extra":
                targets.append(copy.deepcopy(targets[0]))
            elif mode == "missing":
                targets.clear()
            else:
                data["TestConfigurations"].append(copy.deepcopy(data["TestConfigurations"][0]))
            with self.assertRaises(ValueError):
                evidence.validate_manifest(data, "tvOS")

    def test_exact_installed_production_binary_is_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "Plozz"
            binary.write_bytes(b"test-only-executable")
            info = {"CFBundleIdentifier": evidence.APP_ID, "CFBundleExecutable": "Plozz",
                    "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"}
            (root / "Info.plist").write_bytes(plistlib.dumps(info))
            expected = hashlib.sha256(binary.read_bytes()).hexdigest()
            self.assertEqual(evidence.installed_app(str(root), expected), {
                "bundleID": evidence.APP_ID, "version": "1.0", "build": "1", "executableSHA256": expected
            })
            result = subprocess.run(
                ["python3", str(ROOT / "tools/tracker-connection-evidence.py"), "app", expected],
                input=str(root) + "\n", text=True, capture_output=True, timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["executableSHA256"], expected)
            with self.assertRaises(ValueError):
                evidence.installed_app(str(root), "0" * 64)
            with self.assertRaises(ValueError):
                evidence.installed_app("", expected)
            info["CFBundleIdentifier"] += ".FocusHost"
            (root / "Info.plist").write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError):
                evidence.installed_app(str(root), expected)
            result = subprocess.run(
                ["python3", str(ROOT / "tools/tracker-connection-evidence.py"), "app", expected],
                input=str(root) + "\n", text=True, capture_output=True, timeout=5,
            )
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("executableSHA256", result.stdout)

    def test_missing_or_traversing_executable_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("../other/Plozz", "", None, "/Plozz"):
                info = {"CFBundleIdentifier": evidence.APP_ID}
                if name is not None:
                    info["CFBundleExecutable"] = name
                (root / "Info.plist").write_bytes(plistlib.dumps(info))
                with self.assertRaises(ValueError):
                    evidence.installed_app(str(root), "0" * 64)

    def test_exact_pass_is_accepted_without_inventing_account_acceptance(self):
        summary, tree = results()
        evidence.validate_summary(summary, tree, evidence.TARGETS["tvOS"])

    def test_each_scenario_requires_its_own_exact_native_verdict(self):
        for actual, method in evidence.METHODS.items():
            summary, tree = results()
            tree["testNodes"][0]["children"][0]["children"][0]["nodeIdentifier"] = method
            evidence.validate_summary(summary, tree, evidence.TARGETS["tvOS"], actual)
            for requested in evidence.METHODS:
                if requested != actual:
                    with self.subTest(actual=actual, requested=requested), self.assertRaises(ValueError):
                        evidence.validate_summary(summary, tree, evidence.TARGETS["tvOS"], requested)
        with self.assertRaises(ValueError):
            evidence.validate_summary(summary, tree, evidence.TARGETS["tvOS"], "unknown")

    def test_skips_expected_failures_zero_cases_and_boolean_counts_never_pass(self):
        for field, value in (
            ("result", "Failed"), ("totalTestCount", 0), ("totalTestCount", 2), ("totalTestCount", True),
            ("passedTests", 0), ("passedTests", True), ("failedTests", 1), ("failedTests", False),
            ("skippedTests", 1), ("expectedFailures", 1), ("testFailures", [{"targetName": "Other"}]),
        ):
            summary, tree = results()
            summary[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                evidence.validate_summary(summary, tree, evidence.TARGETS["tvOS"])

    def test_missing_different_or_duplicated_test_results_fail_even_with_green_summary(self):
        for mode in ("missing", "method", "bundle", "bundle-type", "duplicate", "skipped"):
            summary, tree = results()
            bundle = tree["testNodes"][0]["children"][0]
            case = bundle["children"][0]
            if mode == "missing":
                bundle["children"].clear()
            elif mode == "method":
                case["nodeIdentifier"] = "Fixture/testConnection()"
            elif mode == "bundle":
                bundle["name"] = "PlozzFocusTests"
            elif mode == "bundle-type":
                bundle["nodeType"] = "Test Bundle"
            elif mode == "duplicate":
                bundle["children"].append(copy.deepcopy(case))
            else:
                case["result"] = "Skipped"
            with self.assertRaises(ValueError):
                evidence.validate_summary(summary, tree, evidence.TARGETS["tvOS"])

    def test_runner_rejects_invalid_invocation_before_build_or_device_work(self):
        for args in ([], ["--run", "macOS", "device", "hash"], ["--build-only", "tvOS", "extra"],
                     ["--run", "iOS"], ["--run", "iOS", "device", "hash", "setup"],
                     ["--run", "iOS", "device", "hash", "browser"],
                     ["--run", "iOS", "device", "hash", "persistence"],
                     ["--run", "iOS", "device", "hash", "disconnect"],
                     ["--run", "iOS", "device", "hash", "manual"],
                     ["--run", "tvOS", "device", "hash", "unknown"]):
            result = subprocess.run(["bash", str(ROOT / "tools/run-tracker-connection-tests.sh"), *args],
                                    cwd=ROOT, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"Usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
