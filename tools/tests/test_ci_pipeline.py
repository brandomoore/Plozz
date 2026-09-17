#!/usr/bin/env python3
"""CI topology, trust boundaries, cache compatibility, and failure regressions.

These checks use only the standard library. actionlint separately validates the
complete GitHub Actions YAML/expression grammar.
"""

from __future__ import annotations

import importlib.util
from contextlib import redirect_stdout
from io import StringIO
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ci_cache", ROOT / "tools/ci-cache.py")
CACHE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CACHE)
WORKFLOW = (ROOT / ".github/workflows/ci.yml").read_text()
PREPARE = (ROOT / ".github/actions/ci-prepare/action.yml").read_text()
SAVE = (ROOT / ".github/actions/ci-save/action.yml").read_text()
TRUST = (
    "success() && github.ref == 'refs/heads/main' && "
    "(github.event_name == 'push' || github.event_name == 'workflow_dispatch')"
)


def named_blocks(source: str, indent: int) -> dict[str, str]:
    matches = list(re.finditer(rf"(?m)^{' ' * indent}([\w-]+):\s*\n", source))
    return {
        match[1]: source[match.end(): matches[index + 1].start() if index + 1 < len(matches) else len(source)]
        for index, match in enumerate(matches)
    }


JOBS = named_blocks(WORKFLOW.split("\njobs:\n", 1)[1], 2)


def run_block(source: str) -> str:
    match = re.search(r"(?m)^([ ]+)run: \|\n((?:\1  .*\n|\n)+)", source)
    if not match:
        raise AssertionError("Expected a literal run block")
    return textwrap.dedent(match[2])


class WorkflowTests(unittest.TestCase):
    def test_existing_triggers_permissions_and_concurrency_are_preserved(self):
        self.assertIn(
            "on:\n  push:\n    branches: [ main ]\n  pull_request:\n  workflow_dispatch:",
            WORKFLOW,
        )
        self.assertIn("permissions:\n  contents: read", WORKFLOW)
        self.assertIn(
            "concurrency:\n  group: ci-${{ github.ref }}\n  cancel-in-progress: true", WORKFLOW
        )
        self.assertNotIn("pull_request_target", WORKFLOW)
        self.assertNotIn("secrets.", WORKFLOW + PREPARE + SAVE)
        self.assertEqual(WORKFLOW.count("uses: actions/checkout@v5"), 4)
        self.assertEqual(WORKFLOW.count("persist-credentials: false"), 4)

    def test_expensive_lanes_are_independent_after_preflight(self):
        self.assertEqual(set(JOBS), {"guards", *CACHE.LANES, "build-and-test"})
        self.assertNotIn("needs:", JOBS["guards"])
        for lane in CACHE.LANES:
            with self.subTest(lane=lane):
                block = JOBS[lane]
                self.assertIn("    needs: guards\n", block)
                self.assertEqual(block.count("needs:"), 1)
                self.assertIn("    runs-on: macos-15\n", block)
                self.assertIn("    timeout-minutes: 60\n", block)
                self.assertIn(f"          lane: {lane}\n", block)
                self.assertIn("uses: ./.github/actions/ci-prepare", block)
        self.assertNotIn("strategy:", WORKFLOW)
        self.assertNotIn("continue-on-error", WORKFLOW + PREPARE + SAVE)

    def test_all_original_preflight_checks_still_run_without_cache_gates(self):
        checks = (
            "python3 tools/arch-guard.py",
            "python3 tools/test-hygiene.py",
            "tools/l10n-guard.sh",
            "python3 -m unittest discover -s tools/tests -p 'test_l10n_*.py'",
            "python3 -m unittest discover -s tools/tests -p 'test_release_notes*.py'",
            "python3 -m unittest discover -s tools/tests -p 'test_package_storage.py'",
            "python3 -m unittest discover -s tools/tests -p 'test_fastlane_pipeline.py'",
            "python3 -m unittest discover -s tools/tests -p 'test_ci_simulator.py'",
            "python3 -m unittest discover -s tools/tests -p 'test_ci_pipeline.py'",
            "python3 -m unittest discover -s tools/tests -p 'test_xcresult_summary.py'",
            "python3 tools/l10n-sync.py --validate-only",
            "python3 tools/l10n-export-source.py .build/ci-scratch/plozz-l10n-delta.json",
            "--missing-for nl",
            "--check-snapshot",
        )
        before_artifact = JOBS["guards"].split("- name: Retain preflight diagnostics")[0]
        for check in checks:
            self.assertIn(check, before_artifact)
        self.assertNotIn("if:", before_artifact)
        self.assertIn('GIT_CONFIG_PARAMETERS: "\'safe.bareRepository=all\'"', WORKFLOW)

    def test_full_matrix_and_hosted_tests_remain_unconditional_and_bounded(self):
        self.assertIn(
            'run: python3 tools/run-bounded.py 2400 "CI full test matrix" -- tools/run-tests.sh\n',
            JOBS["package-tests"],
        )
        self.assertIn("run: tools/run-focus-tests.sh\n", JOBS["hosted-focus"])
        for lane in ("package-tests", "hosted-focus"):
            before_save = JOBS[lane].split("- name: Save successful trusted caches")[0]
            self.assertNotIn("if:", before_save)
        for unsafe in (
            "-only-testing", "-skip-testing", "test-fast.sh",
            "PLOZZ_SKIP_", "PLOZZ_HANG_SECS:", "PLOZZ_FOCUS_TEST_TIMEOUT:",
            "PLOZZ_RESULT_TIMEOUT:", "PLOZZ_PARALLEL: YES",
        ):
            self.assertNotIn(unsafe, WORKFLOW + PREPARE)

    def test_cache_hits_do_not_skip_generation_or_sdk_selection(self):
        self.assertIn("sudo xcode-select -s /Applications/Xcode_26.2.app", PREPARE)
        self.assertIn('tools/select-ci-tvos-simulator.py --sdk-version "$sdk_version"', PREPARE)
        self.assertIn('PLOZZ_SIM_ID=%s\\n', PREPARE)
        self.assertLess(PREPARE.index("tools/generate-project.sh"), PREPARE.index("ci-cache.py keys"))
        self.assertLess(PREPARE.index("ci-cache.py keys"), PREPARE.index("actions/cache/restore"))
        self.assertNotIn("cache-hit ==", PREPARE)
        self.assertNotIn("xcodegen generate", PREPARE)

    def test_cache_saves_are_successful_main_only_and_have_one_package_writer(self):
        self.assertEqual(WORKFLOW.count("if: ${{ " + TRUST + " }}"), 3)
        self.assertEqual(SAVE.count("if: ${{ " + TRUST), 3)
        self.assertEqual(WORKFLOW.count("seed-packages: 'true'"), 1)
        self.assertIn("seed-packages: 'true'", JOBS["app-build"])
        self.assertIn("inputs.seed-packages == 'true'", SAVE)
        self.assertIn("inputs.build-hit != 'true'", SAVE)
        self.assertIn("inputs.package-hit != 'true'", SAVE)
        self.assertEqual(SAVE.count("uses: actions/cache/save@v4"), 2)
        self.assertNotIn("actions/cache/save", PREPARE)
        self.assertNotIn("uses: actions/cache@", WORKFLOW + PREPARE + SAVE)

    def test_shared_cache_is_compressed_only_and_fallback_is_lane_compatible(self):
        package_paths = (
            ".build/ci/swiftpm-cache/repositories\n"
            "          .build/ci/swiftpm-cache/artifacts"
        )
        self.assertIn(package_paths, PREPARE)
        self.assertIn(package_paths, SAVE)
        self.assertEqual(PREPARE.count("restore-keys:"), 1)
        self.assertIn("restore-keys: ${{ steps.keys.outputs.build-prefix }}", PREPARE)
        for unsafe in ("~/", "$HOME", "$RUNNER_TEMP", "/tmp/", "rm -rf", "keychains", "Provisioning"):
            self.assertNotIn(unsafe, WORKFLOW + PREPARE + SAVE)

    def test_timestamp_restore_and_capture_are_bound_to_the_matching_lane_snapshot(self):
        self.assertLess(
            PREPARE.index("- name: Restore lane-private compilation"),
            PREPARE.index('python3 tools/ci-cache.py restore "$CI_LANE"'),
        )
        self.assertLess(
            SAVE.index('python3 tools/ci-cache.py record "$CI_LANE"'),
            SAVE.index("- name: Save lane-private compilation"),
        )
        self.assertIn("CI_LANE: ${{ inputs.lane }}", SAVE)
        for lane in CACHE.LANES:
            saving = JOBS[lane].split("uses: ./.github/actions/ci-save")[1]
            self.assertIn(f"lane: {lane}", saving)
            self.assertIn(CACHE.timestamp_manifest(lane), CACHE.build_paths(lane))

    def test_all_lanes_retain_unique_diagnostics_even_on_failure(self):
        names = []
        for lane in ("guards", *CACHE.LANES):
            artifact = JOBS[lane].split("uses: actions/upload-artifact@v4")[1]
            name = re.search(r"(?m)^          name: (.+)$", artifact)[1]
            names.append(name)
            self.assertTrue(name.startswith(f"{lane}-diagnostics-"))
            self.assertIn("${{ github.run_id }}-${{ github.run_attempt }}", name)
            self.assertIn("retention-days: 7", artifact)
            self.assertIn("if: ${{ always() }}", JOBS[lane])
            self.assertNotIn("DerivedData", artifact)
            self.assertNotIn("SourcePackages", artifact)
        self.assertEqual(len(names), len(set(names)))
        self.assertIn(".build/test-results", JOBS["package-tests"])
        self.assertIn(".build/focus-test-results", JOBS["hosted-focus"])

    def test_app_build_uses_explicit_private_storage_and_original_compile_flags(self):
        build = JOBS["app-build"]
        for fragment in (
            'configure_plozz_package_resolution "$PLOZZ_CLONED_SOURCE_PACKAGES"',
            '"${PACKAGE_RESOLUTION_ARGS[@]}"',
            '-derivedDataPath "$PLOZZ_DERIVED_DATA"',
            "-scheme Plozz",
            "'generic/platform=tvOS Simulator'",
            "ARCHS=arm64",
            "ONLY_ACTIVE_ARCH=YES",
            "CODE_SIGNING_ALLOWED=NO",
        ):
            self.assertIn(fragment, build)

    def test_app_log_pipe_preserves_original_failure_status(self):
        # Exercise the actual workflow's post-pipe status handling with harmless
        # stand-ins, including simultaneous build and log-writer failures.
        status_code = run_block(JOBS["app-build"])
        status_code = status_code[status_code.index('statuses=("${PIPESTATUS[@]}")'):]
        for build_status, log_status, expected in ((0, 0, 0), (65, 0, 65), (65, 9, 65), (0, 9, 9)):
            with self.subTest(build=build_status, log=log_status):
                result = subprocess.run(
                    ["bash", "-c", f"(exit {build_status}) | (exit {log_status})\n{status_code}"],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, expected)

    def test_host_and_test_bundle_keep_one_umbrella_product(self):
        source = (ROOT / "project.yml").read_text().split("\ntargets:\n", 1)[1]
        targets = named_blocks(source.split("\nschemes:\n")[0], 2)
        for target in ("PlozzFocusHost", "PlozzFocusTests"):
            self.assertEqual(re.findall(r"\bproduct: (\w+)", targets[target]), ["AppShell"])
        self.assertIn("target: PlozzFocusHost", targets["PlozzFocusTests"])
        self.assertNotIn("CoreUI.framework", PREPARE + SAVE)


class AggregateTests(unittest.TestCase):
    def verdict(self, needs):
        script = run_block(JOBS["build-and-test"])
        return subprocess.run(
            ["bash", "-e", "-c", script],
            env=dict(os.environ, NEEDS_JSON=json.dumps(needs)),
            capture_output=True,
            text=True,
        )

    def successes(self):
        return {name: {"result": "success"} for name in ("guards", *CACHE.LANES)}

    def test_exact_compatibility_check_always_waits_for_every_lane(self):
        block = JOBS["build-and-test"]
        self.assertIn("    name: Build and test tvOS app\n", block)
        self.assertIn("    needs: [guards, app-build, package-tests, hosted-focus]\n", block)
        self.assertIn("    if: ${{ always() }}\n", block)
        self.assertIn("NEEDS_JSON: ${{ toJSON(needs) }}", block)
        self.assertEqual(self.verdict(self.successes()).returncode, 0)

    def test_failure_cancellation_and_skip_never_pass(self):
        for lane in ("guards", *CACHE.LANES):
            for status in ("failure", "cancelled", "skipped", "", None):
                with self.subTest(lane=lane, status=status):
                    needs = self.successes()
                    needs[lane]["result"] = status
                    self.assertNotEqual(self.verdict(needs).returncode, 0)

    def test_missing_unexpected_or_resultless_dependencies_fail_closed(self):
        for lane in ("guards", *CACHE.LANES):
            needs = self.successes()
            del needs[lane]
            self.assertNotEqual(self.verdict(needs).returncode, 0)
            needs = self.successes()
            needs[lane] = {}
            self.assertNotEqual(self.verdict(needs).returncode, 0)
        needs = self.successes()
        needs["unexpected"] = {"result": "success"}
        self.assertNotEqual(self.verdict(needs).returncode, 0)
        self.assertNotEqual(self.verdict({}).returncode, 0)


class CacheKeyTests(unittest.TestCase):
    def setUp(self):
        # Keep fixtures inside the checkout, even on machines with a shared /tmp.
        scratch = ROOT / ".build/ci-pipeline-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        self.fixture = tempfile.TemporaryDirectory(dir=scratch, prefix="cache workspace ")
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)
        for name in CACHE.CONFIG_INPUTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"fixture {name}\n")
        (self.root / "Package.resolved").write_text('{"version": 3, "pins": [{"identity": "dep"}]}')
        project = self.root / "Plozz.xcodeproj"
        project.mkdir()
        (project / "project.pbxproj").write_text(
            "CURRENT_PROJECT_VERSION = 123;\nMARKETING_VERSION = 2026.9.16;\nPRODUCT_NAME = Plozz;\n"
        )
        (project / "Plozz.xcscheme").write_text("<Scheme/>")
        self.toolchain = {
            "workspace": "/checkout/Plozz",
            "xcode": "Xcode 26.2\nBuild version 17C52",
            "sdk": "26.2",
            "sdk-build": "23K54",
            "sdk-path": "/Applications/Xcode_26.2.app/SDKs/AppleTVSimulator26.2.sdk",
            "host-arch": "arm64",
            "os-build": "24G207",
            "developer": "/Applications/Xcode_26.2.app/Contents/Developer",
            "xcodegen": "Version: 2.44.1",
        }
        self.revision = "a" * 40

    def keys(self, **overrides):
        packages, configuration = CACHE.input_fingerprints(self.root)
        return CACHE.cache_keys(
            overrides.get("lane", "app-build"),
            overrides.get("toolchain", self.toolchain),
            packages, configuration, overrides.get("revision", self.revision),
        )

    def test_compiled_roots_are_disjoint_and_do_not_cache_diagnostics_or_credentials(self):
        seen = set()
        for lane in CACHE.LANES:
            paths = CACHE.build_paths(lane)
            self.assertEqual(len(paths), len(CACHE.BUILD_PARTS))
            self.assertFalse(seen.intersection(paths))
            seen.update(paths)
            for path in paths:
                self.assertTrue(path.startswith(f".build/ci/{lane}/"))
                for forbidden in ("Logs", "xcresult", "Keychain", "Provisioning", ".git", "swiftpm-cache"):
                    self.assertNotIn(forbidden, path)
            self.assertIn(f".build/ci/{lane}/SourcePackages", paths)
        with self.assertRaises(ValueError):
            CACHE.build_paths("../outside")

    def test_environment_is_workspace_local_and_hosted_uses_the_same_private_root(self):
        for lane in CACHE.LANES:
            env = CACHE.environment(self.root, lane)
            for value in env.values():
                self.assertTrue(Path(value).is_relative_to(self.root))
            self.assertEqual(env["PLOZZ_DERIVED_DATA"], env["PLOZZ_FOCUS_DERIVED_DATA"])
            self.assertEqual(env["PLOZZ_CLONED_SOURCE_PACKAGES"], env["PLOZZ_FOCUS_PACKAGES"])
            self.assertNotEqual(env["PLOZZ_CLONED_SOURCE_PACKAGES"], env["PLOZZ_PACKAGE_CACHE_PATH"])

    def test_configure_cli_creates_only_workspace_storage(self):
        result = subprocess.run(
            ["python3", str(ROOT / "tools/ci-cache.py"), "configure", "hosted-focus"],
            cwd=self.root,
            env=dict(os.environ, GITHUB_ACTIONS="true", GITHUB_WORKSPACE=str(self.root)),
            text=True,
            capture_output=True,
            check=True,
        )
        emitted = dict(line.split("=", 1) for line in result.stdout.splitlines())
        self.assertEqual(emitted, CACHE.environment(self.root.resolve(), "hosted-focus"))
        for value in emitted.values():
            self.assertTrue(Path(value).is_dir())

    def test_configure_rejects_storage_symlinks_escaping_the_workspace(self):
        sibling = self.root.parent / f"{self.root.name}-outside"
        sibling.mkdir()
        self.addCleanup(sibling.rmdir)
        (self.root / ".build").symlink_to(sibling, target_is_directory=True)
        result = subprocess.run(
            ["python3", str(ROOT / "tools/ci-cache.py"), "configure", "app-build"],
            cwd=self.root,
            env=dict(os.environ, GITHUB_ACTIONS="true", GITHUB_WORKSPACE=str(self.root)),
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(sibling.iterdir()), [])
        self.assertIn("escapes the workspace", result.stderr)

    def test_key_cli_reads_toolchain_metadata_without_building_and_emits_cache_paths(self):
        values = {
            ("xcodebuild", "-version"): self.toolchain["xcode"],
            ("xcode-select", "-p"): self.toolchain["developer"],
            ("xcrun", "--sdk", "appletvsimulator", "--show-sdk-version"): self.toolchain["sdk"],
            ("xcrun", "--sdk", "appletvsimulator", "--show-sdk-build-version"): self.toolchain["sdk-build"],
            ("xcrun", "--sdk", "appletvsimulator", "--show-sdk-path"): self.toolchain["sdk-path"],
            ("uname", "-m"): self.toolchain["host-arch"],
            ("sw_vers", "-buildVersion"): self.toolchain["os-build"],
            ("xcodegen", "--version"): self.toolchain["xcodegen"],
            ("git", "rev-parse", "HEAD"): self.revision,
        }
        output = StringIO()
        with (
            patch.object(CACHE, "command", side_effect=lambda *args: values[args]) as command,
            patch.object(Path, "cwd", return_value=self.root),
            patch("sys.argv", ["ci-cache.py", "keys", "hosted-focus"]),
            patch.dict(os.environ, GITHUB_ACTIONS="true", GITHUB_WORKSPACE=str(self.root)),
            redirect_stdout(output),
        ):
            CACHE.main()
        self.assertEqual(command.call_count, len(values))
        keys, paths = output.getvalue().split("build-paths<<PLOZZ_CI_PATHS\n")
        emitted = dict(line.split("=", 1) for line in keys.splitlines())
        toolchain = dict(self.toolchain, workspace=str(self.root.resolve()))
        self.assertEqual(emitted, self.keys(lane="hosted-focus", toolchain=toolchain))
        self.assertEqual(paths.splitlines(), CACHE.build_paths("hosted-focus") + ["PLOZZ_CI_PATHS"])
        self.assertTrue(all(len(value) < 512 for value in emitted.values()))

    def test_toolchain_sdk_arch_os_workspace_and_generator_changes_invalidate_every_cache(self):
        before = self.keys()
        for field in self.toolchain:
            with self.subTest(field=field):
                changed = dict(self.toolchain)
                changed[field] += "-changed"
                after = self.keys(toolchain=changed)
                self.assertNotEqual(before["package-key"], after["package-key"])
                self.assertNotEqual(before["build-prefix"], after["build-prefix"])

    def test_only_same_lane_configuration_can_be_a_compiled_fallback(self):
        before = self.keys()
        for lane in ("package-tests", "hosted-focus"):
            after = self.keys(lane=lane)
            self.assertNotEqual(before["build-prefix"], after["build-prefix"])
            self.assertEqual(before["package-key"], after["package-key"])
        after = self.keys(revision="b" * 40)
        self.assertEqual(before["build-prefix"], after["build-prefix"])
        self.assertEqual(before["package-key"], after["package-key"])
        self.assertNotEqual(before["build-key"], after["build-key"])
        self.assertTrue(before["build-key"].startswith(before["build-prefix"]))
        with self.assertRaises(ValueError):
            self.keys(revision="main")

    def test_manifest_and_lock_changes_invalidate_both_cache_types(self):
        before = self.keys()
        for name in ("Package.swift", "Package.resolved"):
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_text()
                path.write_text(original + "\n")
                after = self.keys()
                self.assertNotEqual(before["package-key"], after["package-key"])
                self.assertNotEqual(before["build-prefix"], after["build-prefix"])
                path.write_text(original)

    def test_generated_project_schemes_and_runner_settings_invalidate_compilation(self):
        before = self.keys()
        names = (
            "project.yml", "tools/generate-project.sh", ".github/workflows/ci.yml",
            "tools/run-tests.sh", "tools/run-focus-tests.sh", "tools/lib/swift-package-storage.sh",
            "Plozz.xcodeproj/project.pbxproj", "Plozz.xcodeproj/Plozz.xcscheme",
        )
        for name in names:
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_text()
                path.write_text(original + "\nchanged\n")
                after = self.keys()
                self.assertEqual(before["package-key"], after["package-key"])
                self.assertNotEqual(before["build-prefix"], after["build-prefix"])
                path.write_text(original)

    def test_only_volatile_version_values_are_normalized_not_build_settings(self):
        before = self.keys()
        path = self.root / "Plozz.xcodeproj/project.pbxproj"
        path.write_text(
            "CURRENT_PROJECT_VERSION = 124;\nMARKETING_VERSION = 2026.9.17;\nPRODUCT_NAME = Plozz;\n"
        )
        self.assertEqual(before, self.keys())
        path.write_text(path.read_text().replace("PRODUCT_NAME = Plozz", "PRODUCT_NAME = Other"))
        self.assertNotEqual(before["build-prefix"], self.keys()["build-prefix"])

    def test_bad_missing_or_empty_lock_fails_instead_of_using_a_broad_fallback(self):
        lock = self.root / "Package.resolved"
        for data in ("invalid", '{"pins": []}'):
            lock.write_text(data)
            with self.assertRaises(ValueError):
                self.keys()
        lock.unlink()
        with self.assertRaises(FileNotFoundError):
            self.keys()

    def test_local_secret_configuration_is_never_accepted_for_cache_publication(self):
        config = self.root / "Config"
        config.mkdir()
        (config / "Secrets.local.xcconfig").write_text("fixture only")
        with self.assertRaisesRegex(ValueError, "local secrets"):
            self.keys()

    def outside_directory(self):
        fixture = tempfile.TemporaryDirectory(
            dir=ROOT / ".build/ci-pipeline-tests", prefix="outside key fixture "
        )
        self.addCleanup(fixture.cleanup)
        return Path(fixture.name)

    def test_all_key_text_reads_use_no_follow_descriptors(self):
        with patch.object(Path, "read_text", side_effect=AssertionError("Unsafe path-based read")):
            self.keys()

    def test_explicit_key_inputs_cannot_be_symlinked_outside_the_workspace(self):
        outside = self.outside_directory()
        for name in (*CACHE.CONFIG_INPUTS, "Plozz.xcodeproj/project.pbxproj"):
            with self.subTest(name=name):
                path = self.root / name
                target = outside / name.replace("/", "-")
                path.rename(target)
                path.symlink_to(target)
                try:
                    with self.assertRaises(OSError):
                        self.keys()
                finally:
                    path.unlink()
                    target.rename(path)

    def test_config_file_symlink_is_rejected_without_reading_its_target(self):
        config = self.root / "Config"
        config.mkdir()
        target = self.outside_directory() / "Settings.xcconfig"
        target.write_text("outside fixture")
        (config / "Settings.xcconfig").symlink_to(target)
        with self.assertRaisesRegex(ValueError, "Symlinked cache-key input"):
            self.keys()

    def test_config_directory_symlinks_are_not_traversed(self):
        outside = self.outside_directory()
        (outside / "Settings.xcconfig").write_text("outside fixture")
        config = self.root / "Config"
        config.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError):
            self.keys()
        config.unlink()
        config.mkdir()
        (config / "Nested").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "Symlinked cache-key input"):
            self.keys()

    def test_generated_project_root_symlink_is_not_traversed(self):
        project = self.root / "Plozz.xcodeproj"
        outside = self.outside_directory() / "Plozz.xcodeproj"
        project.rename(outside)
        project.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(OSError):
            self.keys()

    def test_generated_scheme_and_workspace_symlinks_are_not_read(self):
        project = self.root / "Plozz.xcodeproj"
        outside = self.outside_directory()
        for name in ("Plozz.xcscheme", "contents.xcworkspacedata"):
            with self.subTest(name=name):
                path = project / name
                if path.exists():
                    path.unlink()
                target = outside / name
                target.write_text("outside fixture")
                path.symlink_to(target)
                with self.assertRaisesRegex(ValueError, "Symlinked cache-key input"):
                    self.keys()
                path.unlink()
        (project / "xcshareddata").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "Symlinked cache-key input"):
            self.keys()

    def test_hard_linked_metadata_is_not_read(self):
        config = self.root / "Config"
        config.mkdir()
        outside = self.outside_directory() / "Settings.xcconfig"
        outside.write_text("outside fixture")
        os.link(outside, config / "Settings.xcconfig")
        with self.assertRaisesRegex(ValueError, "single-link regular"):
            self.keys()


class SourceTimestampTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / ".build/ci-pipeline-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        fixture = tempfile.TemporaryDirectory(dir=scratch, prefix="source timestamps ")
        outside = tempfile.TemporaryDirectory(dir=scratch, prefix="outside fixture ")
        self.addCleanup(fixture.cleanup)
        self.addCleanup(outside.cleanup)
        self.root = Path(fixture.name)
        self.outside = Path(outside.name)
        self.old_time = 1_700_000_000_123_456_789
        self.new_time = self.old_time + 600_000_000_000
        self.tracked = {"Sources/Feature.swift", "Tests/FeatureTests.swift", "Package.swift"}
        for name in self.tracked:
            self.make_file(self.root / name)
        for lane in CACHE.LANES:
            (self.root / CACHE.lane_root(lane)).mkdir(parents=True)
        mock = patch.object(CACHE, "tracked_inputs", side_effect=lambda root: self.tracked.copy())
        mock.start()
        self.addCleanup(mock.stop)
        self.source = self.root / "Sources/Feature.swift"
        self.manifest = self.root / CACHE.timestamp_manifest("app-build")

    def make_file(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("let value = 1\n")
        path.chmod(0o644)
        os.utime(path, ns=(self.old_time, self.old_time))
        return path

    def record(self, lane="app-build"):
        return CACHE.record_source_timestamps(self.root, lane)

    def restore(self, lane="app-build"):
        return CACHE.restore_source_timestamps(self.root, lane)

    def freshen(self):
        for name in self.tracked:
            path = self.root / name
            os.utime(path, ns=(self.new_time, self.new_time))

    def test_unchanged_tracked_contents_restore_exact_nanosecond_timestamps(self):
        self.assertEqual(self.record(), 3)
        self.freshen()
        before = {name: (self.root / name).read_bytes() for name in self.tracked}
        self.assertEqual(self.restore(), 3)
        for name in self.tracked:
            path = self.root / name
            self.assertEqual(path.stat().st_mtime_ns, self.old_time)
            self.assertEqual(path.read_bytes(), before[name])

    def test_same_size_changed_source_keeps_its_fresh_timestamp(self):
        self.record()
        self.source.write_text("let value = 2\n")
        self.freshen()
        self.assertEqual(self.restore(), 2)
        self.assertEqual(self.source.stat().st_mtime_ns, self.new_time)
        self.assertEqual(self.source.read_text(), "let value = 2\n")

    def test_changed_mode_is_not_mistaken_for_an_unchanged_input(self):
        self.record()
        self.source.chmod(0o755)
        self.freshen()
        self.assertEqual(self.restore(), 2)
        self.assertEqual(self.source.stat().st_mtime_ns, self.new_time)
        self.assertEqual(self.source.stat().st_mode & 0o777, 0o755)

    def test_deleted_and_new_files_do_not_reuse_an_old_timestamp(self):
        self.record()
        self.source.unlink()
        new = self.make_file(self.root / "Sources/New.swift")
        self.tracked.add("Sources/New.swift")
        os.utime(new, ns=(self.new_time, self.new_time))
        self.assertEqual(self.restore(), 2)
        self.assertFalse(self.source.exists())
        self.assertEqual(new.stat().st_mtime_ns, self.new_time)

    def test_untracked_and_out_of_scope_files_are_never_candidates(self):
        untracked = self.make_file(self.root / "Sources/Untracked.swift")
        documentation = self.make_file(self.root / "docs/example.md")
        self.tracked.add("docs/example.md")
        self.assertEqual(self.record(), 3)
        snapshot = json.loads(self.manifest.read_text())
        saved = snapshot["files"]["Sources/Feature.swift"]
        snapshot["files"]["Sources/Untracked.swift"] = saved
        snapshot["files"]["docs/example.md"] = saved
        self.manifest.write_text(json.dumps(snapshot))
        for path in (untracked, documentation):
            os.utime(path, ns=(self.new_time, self.new_time))
        self.assertEqual(self.restore(), 3)
        for path in (untracked, documentation):
            self.assertEqual(path.stat().st_mtime_ns, self.new_time)

    def test_symlinked_file_cannot_restore_or_record_outside_content(self):
        self.record()
        outside = self.make_file(self.outside / "Feature.swift")
        os.utime(outside, ns=(self.new_time, self.new_time))
        self.source.unlink()
        self.source.symlink_to(outside)
        self.assertEqual(self.restore(), 2)
        self.assertEqual(outside.stat().st_mtime_ns, self.new_time)
        self.assertEqual(self.record(), 2)
        self.assertNotIn("Sources/Feature.swift", json.loads(self.manifest.read_text())["files"])

    def test_symlinked_parent_cannot_escape_through_a_regular_leaf_file(self):
        self.record()
        outside = self.make_file(self.outside / "Feature.swift")
        os.utime(outside, ns=(self.new_time, self.new_time))
        self.source.unlink()
        self.source.parent.rmdir()
        self.source.parent.symlink_to(self.outside, target_is_directory=True)
        self.assertEqual(self.restore(), 2)
        self.assertEqual(outside.stat().st_mtime_ns, self.new_time)
        self.assertEqual(self.record(), 2)

    def test_hard_links_are_not_timestamp_candidates(self):
        self.record()
        outside = self.make_file(self.outside / "Feature.swift")
        os.utime(outside, ns=(self.new_time, self.new_time))
        self.source.unlink()
        os.link(outside, self.source)
        self.assertEqual(self.restore(), 2)
        self.assertEqual(outside.stat().st_mtime_ns, self.new_time)
        self.assertEqual(self.record(), 2)

    def test_manifest_symlink_is_neither_followed_nor_truncated(self):
        self.record()
        original = self.manifest.read_text()
        outside = self.outside / "snapshot.json"
        outside.write_text(original)
        self.manifest.unlink()
        self.manifest.symlink_to(outside)
        self.assertEqual(self.restore(), 0)
        with self.assertRaises(OSError):
            self.record()
        self.assertEqual(outside.read_text(), original)

    def test_manifest_hard_link_is_not_truncated(self):
        self.record()
        original = self.manifest.read_text()
        outside = self.outside / "snapshot.json"
        os.link(self.manifest, outside)
        self.assertEqual(self.restore(), 0)
        with self.assertRaises(ValueError):
            self.record()
        self.assertEqual(outside.read_text(), original)

    def test_absolute_and_traversal_paths_are_rejected_even_if_listed_as_tracked(self):
        self.record()
        outside = self.make_file(self.outside / "Feature.swift")
        os.utime(outside, ns=(self.new_time, self.new_time))
        snapshot = json.loads(self.manifest.read_text())
        bad_names = (
            str(outside),
            "../" + self.outside.name + "/Feature.swift",
            "Sources/../../" + self.outside.name + "/Feature.swift",
            "Sources//Feature.swift",
            "Sources/./Feature.swift",
        )
        for name in bad_names:
            self.tracked.add(name)
            snapshot["files"][name] = snapshot["files"]["Sources/Feature.swift"]
        self.manifest.write_text(json.dumps(snapshot))
        self.assertEqual(self.restore(), 3)
        self.assertEqual(outside.stat().st_mtime_ns, self.new_time)

    def test_missing_corrupt_and_unsupported_snapshots_leave_sources_fresh(self):
        self.freshen()
        self.assertEqual(self.restore(), 0)
        for snapshot in ("{", "null", '{"version":2,"files":{}}', '{"version":1,"files":[]}'):
            self.manifest.write_text(snapshot)
            self.assertEqual(self.restore(), 0)
            for name in self.tracked:
                self.assertEqual((self.root / name).stat().st_mtime_ns, self.new_time)

    def test_invalid_future_and_boolean_timestamps_are_not_applied(self):
        self.record()
        original = json.loads(self.manifest.read_text())
        for value in (-1, True, "123", time.time_ns() + 1_000_000_000_000):
            self.freshen()
            original["files"]["Sources/Feature.swift"]["mtime_ns"] = value
            self.manifest.write_text(json.dumps(original))
            self.assertEqual(self.restore(), 2)
            self.assertEqual(self.source.stat().st_mtime_ns, self.new_time)

    def test_content_changes_while_hashing_are_not_restored(self):
        self.record()
        self.freshen()
        original_read = os.read
        changed = False

        def change_while_reading(descriptor, size):
            nonlocal changed
            contents = original_read(descriptor, size)
            if not changed and contents:
                changed = True
                self.source.write_text("let value = 2\n")
                os.utime(self.source, ns=(self.new_time, self.new_time))
            return contents

        # Limit the run to the source under inspection, not the other fixtures.
        self.tracked = {"Sources/Feature.swift"}
        with patch.object(CACHE.os, "read", side_effect=change_while_reading):
            self.assertEqual(self.restore(), 0)
        self.assertEqual(self.source.stat().st_mtime_ns, self.new_time)

    def test_lane_snapshots_are_not_used_by_siblings(self):
        self.record("app-build")
        self.freshen()
        self.assertEqual(self.restore("hosted-focus"), 0)
        self.assertEqual(self.restore("package-tests"), 0)
        self.assertEqual(self.source.stat().st_mtime_ns, self.new_time)
        self.assertEqual(self.restore("app-build"), 3)


if __name__ == "__main__":
    unittest.main()
