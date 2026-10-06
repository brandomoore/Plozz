#!/usr/bin/env python3
"""An extraction receipt is usable only for its exact complete inputs/output."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS / "lib"))
import l10n_freshness as freshness

SPEC = importlib.util.spec_from_file_location("freshness_sync", TOOLS / "l10n-sync.py")
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class ExtractionFreshnessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.write(".gitignore", ".build/\nPlozz.xcodeproj/\nConfig/Secrets.local.xcconfig\n")
        self.write("Sources/Example.swift", 'Text("Hello")\n')
        self.write("Package.swift", "// fixture package\n")
        self.write("Package.resolved", '{"pins":[]}\n')
        self.write("project.yml", "name: Fixture\n")
        self.write("App/Resources/Localizable.xcstrings", '{"strings":{}}\n')
        self.write("Config/Secrets.local.xcconfig", "PRIVATE_KEY = never-show-this\n")
        self.write("Plozz.xcodeproj/project.pbxproj",
                   "\tCURRENT_PROJECT_VERSION = 7;\n\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;\n")
        self.write(".build/extraction/Build/Intermediates.noindex/Objects-normal/arm64/Example.stringsdata",
                   '{"tables":{"":[{"key":"Hello"}]}}\n')
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        self.derived = self.root / ".build/extraction"
        self.workspace = self.root / ".build/packages"
        self.catalog = self.root / "App/Resources/Localizable.xcstrings"
        self.toolchain = patch.object(freshness, "toolchain_fingerprint", return_value="toolchain-A")
        self.toolchain.start()
        self.addCleanup(self.toolchain.stop)
        ownership = patch.object(freshness, "phase_paths", return_value=(set(), set()))
        ownership.start()
        self.addCleanup(ownership.stop)
        self.receipt = freshness.ExtractionReceipt(self.root, self.derived, self.workspace, "arm64")

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def record(self):
        self.receipt.record(self.receipt.inputs())

    def matches(self):
        return self.receipt.matches(self.receipt.inputs())

    def test_same_tree_reuses_real_complete_output(self):
        self.assertFalse(self.matches())
        self.record()
        self.assertTrue(self.matches())
        stored = self.receipt.path.read_text()
        self.assertNotIn("never-show-this", stored)
        self.assertNotIn("PRIVATE_KEY", stored)

    def test_changed_added_deleted_and_untracked_inputs_invalidate(self):
        mutations = [
            lambda: self.write("Sources/Example.swift", 'Text("Different")'),
            lambda: self.write("Sources/New.swift", 'Text("New")'),
            lambda: (self.root / "Sources/Example.swift").unlink(),
            lambda: self.write("Package.resolved", '{"pins":[{"identity":"changed"}]}'),
            lambda: self.write("project.yml", "name: Changed"),
            lambda: self.write("Config/Secrets.local.xcconfig", "PRIVATE_KEY = different"),
            lambda: self.write("tools/new-generator.sh", "exit 1"),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.record()
                mutate()
                self.assertFalse(self.matches())

    def test_catalog_and_snapshot_updates_reuse_extraction_not_validation(self):
        self.record()
        self.write("App/Resources/Localizable.xcstrings", '{"strings":{"new":{}}}')
        self.write("tools/l10n-source-snapshot.json", '{"updated":"source"}')
        self.assertTrue(self.matches())
        # The caller still synchronizes and validates the current catalog.
        result, build, validate, sync = self.execute(self.args(), validation=1)
        self.assertEqual(result, 1)
        build.assert_not_called()
        validate.assert_called_once()
        sync.assert_called_once()

    def test_same_size_and_mtime_source_edit_still_invalidates(self):
        self.record()
        source = self.root / "Sources/Example.swift"
        old = source.stat()
        source.write_text('Text("World")\n')
        os.utime(source, ns=(old.st_atime_ns, old.st_mtime_ns))
        self.assertFalse(self.matches())

    def test_build_stamp_is_ignored_but_other_generated_settings_are_not(self):
        self.record()
        project = self.root / "Plozz.xcodeproj/project.pbxproj"
        project.write_text(project.read_text().replace("VERSION = 7", "VERSION = 8.12"))
        self.assertTrue(self.matches())
        project.write_text(project.read_text().replace("= DEBUG", "= RELEASE"))
        self.assertFalse(self.matches())

    def test_script_mode_changes_invalidate_even_when_contents_do_not(self):
        script = self.write("tools/generate-project.sh", "#!/bin/sh\nexit 0\n")
        script.chmod(0o755)
        self.record()
        script.chmod(0o644)
        self.assertFalse(self.matches())

    def test_toolchain_arch_and_build_environment_invalidate(self):
        self.record()
        self.receipt.toolchain = "toolchain-B"
        self.assertFalse(self.matches())
        self.receipt.toolchain = "toolchain-A"
        with patch.dict(os.environ, {"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "NEW"}):
            self.assertFalse(self.matches())
        self.receipt.arch = "x86_64"
        self.assertFalse(self.matches())

    def test_same_external_xcconfig_path_with_new_bytes_invalidates(self):
        config = self.write(".build/environment.xcconfig", "FLAG = BEFORE")
        with patch.dict(os.environ, {"XCODE_XCCONFIG_FILE": str(config)}):
            self.record()
            config.write_text("FLAG = AFTER")
            self.assertFalse(self.matches())

    def test_toolchain_change_during_extraction_cannot_record_success(self):
        before = self.receipt.inputs()
        with patch.object(freshness, "toolchain_fingerprint", return_value="replacement-toolchain"):
            with self.assertRaises(freshness.FreshnessError):
                self.receipt.record(before)
        self.assertFalse(self.receipt.path.exists())

    def test_missing_changed_and_added_outputs_invalidate(self):
        output = self.derived / "Build/Intermediates.noindex/Objects-normal/arm64/Example.stringsdata"
        self.record()
        output.write_text('{"tables":{}}')
        self.assertFalse(self.matches())
        self.record()
        self.write(".build/extraction/Build/Intermediates.noindex/Objects-normal/arm64/Another.stringsdata", "{}")
        self.assertFalse(self.matches())
        self.record()
        output.unlink()
        self.assertFalse(self.matches())

    def test_malformed_partial_or_missing_receipt_is_not_evidence(self):
        self.record()
        good = json.loads(self.receipt.path.read_text())
        for record in ("broken", "null", '{"platforms":["tvos"]}', json.dumps({**good, "schemaVersion": 2})):
            self.receipt.path.write_text(record)
            self.assertFalse(self.matches())
        self.receipt.invalidate()
        self.assertFalse(self.matches())

    def test_source_race_cannot_record_a_success(self):
        before = self.receipt.inputs()
        self.write("Sources/Example.swift", 'Text("Changed during extraction")')
        with self.assertRaises(freshness.FreshnessError):
            self.receipt.record(before)
        self.assertFalse(self.receipt.path.exists())

    def test_workspace_changes_invalidate(self):
        self.record()
        self.write(".build/packages/workspace-state.json", '{"changed":true}')
        self.assertFalse(self.matches())

    def test_workspace_artifact_order_and_json_format_do_not_invalidate(self):
        state = {
            "version": 6,
            "object": {
                "artifacts": [
                    {"packageRef": {"identity": "one"}, "path": "/one", "source": {"checksum": "one"}},
                    {"packageRef": {"identity": "two"}, "path": "/two", "source": {"checksum": "two"}},
                ],
                "dependencies": [{"identity": "one", "revision": "pin-one"}],
            },
        }
        self.write(".build/packages/workspace-state.json", json.dumps(state, indent=2))
        self.record()
        state["object"]["artifacts"].reverse()
        self.write(".build/packages/workspace-state.json", json.dumps(state, sort_keys=True))
        self.assertTrue(self.matches())

    def test_real_workspace_input_changes_still_invalidate(self):
        baseline = {
            "version": 6,
            "object": {
                "artifacts": [
                    {"packageRef": {"identity": "one"}, "path": "/one", "source": {"checksum": "one"}},
                    {"packageRef": {"identity": "two"}, "path": "/two", "source": {"checksum": "two"}},
                ],
                "dependencies": [{"identity": "one", "revision": "pin-one"}],
                "orderedValues": ["first", "second"],
            },
        }
        mutations = [
            lambda obj: obj["artifacts"][0]["source"].update(checksum="changed"),
            lambda obj: obj["artifacts"][0].update(path="/changed"),
            lambda obj: obj["artifacts"][0]["packageRef"].update(identity="changed"),
            lambda obj: obj["artifacts"].pop(),
            lambda obj: obj["artifacts"].append(obj["artifacts"][0]),
            lambda obj: obj["dependencies"][0].update(revision="pin-two"),
            lambda obj: obj["orderedValues"].reverse(),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.write(".build/packages/workspace-state.json", json.dumps(baseline))
                self.record()
                changed = json.loads(json.dumps(baseline))
                mutate(changed["object"])
                self.write(".build/packages/workspace-state.json", json.dumps(changed))
                self.assertFalse(self.matches())

    def test_malformed_workspace_state_is_not_reusable_evidence(self):
        for invalid in ("{broken", "null", "[]"):
            with self.subTest(invalid=invalid):
                self.write(".build/packages/workspace-state.json", "{}")
                self.record()
                self.write(".build/packages/workspace-state.json", invalid)
                self.assertFalse(self.matches())
                with self.assertRaises(freshness.FreshnessError):
                    self.receipt.record(self.receipt.inputs())

    def test_dirty_or_replaced_checkout_invalidates_even_with_same_package_lock(self):
        checkout = self.workspace / "checkouts/Dependency"
        checkout.mkdir(parents=True)
        original = freshness.command
        state = {"dirty": False, "head": "pin-one"}
        def command(root, *args):
            if root == checkout:
                if args[1] == "status":
                    return b" M Source.swift\n" if state["dirty"] else b""
                return state["head"].encode()
            return original(root, *args)
        with patch.object(freshness, "command", side_effect=command):
            self.record()
            state["dirty"] = True
            self.assertFalse(self.matches())
            state["dirty"] = False
            self.assertTrue(self.matches())
            state["head"] = "pin-two"
            self.assertFalse(self.matches())

    def test_parent_push_hook_environment_does_not_redirect_dependency_git(self):
        checkout = self.workspace / "checkouts/Dependency"
        checkout.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(checkout)], check=True)
        (checkout / "Source.swift").write_text("// dependency fixture\n")
        subprocess.run(["git", "-C", str(checkout), "add", "."], check=True)
        subprocess.run([
            "git", "-C", str(checkout), "-c", "user.name=Fixture",
            "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgSign=false",
            "commit", "-qm", "Fixture",
        ], check=True)
        expected = freshness.package_workspace_fingerprint(self.root, self.workspace)
        with patch.dict(os.environ, {
            "GIT_DIR": str(self.root / ".git"),
            "GIT_WORK_TREE": str(self.root),
            "GIT_INDEX_FILE": str(self.root / ".git/index"),
        }):
            self.assertEqual(
                freshness.package_workspace_fingerprint(self.root, self.workspace), expected
            )
            self.record()
            self.assertTrue(self.matches())

    def test_other_architecture_and_product_copies_are_not_current_extraction(self):
        self.record()
        self.write(".build/extraction/Build/Intermediates.noindex/Objects-normal/x86_64/Stale.stringsdata", "{}")
        self.write(".build/extraction/Build/Products/Fixture.app/arm64/Copy.stringsdata", "{}")
        self.assertTrue(self.matches())
        files = freshness.extraction_files(self.derived, "arm64")
        self.assertEqual(len(files), 1)

    def test_external_config_symlink_bytes_are_fingerprinted_not_exposed(self):
        target = self.write(".build/local-key.xcconfig", "PRIVATE_KEY = one")
        config = self.root / "Config/Secrets.local.xcconfig"
        config.unlink()
        config.symlink_to(target)
        self.record()
        target.write_text("PRIVATE_KEY = two")
        self.assertFalse(self.matches())

    def args(self, **overrides):
        values = dict(platform=None, no_build=False, clean=False, quiet=True,
                      reuse_if_unchanged=True, check=True)
        return argparse.Namespace(**{**values, **overrides})

    def execute(self, args, *, build=None, sync=None, validation=0):
        patches = [
            patch.object(SYNC, "REPO", self.root),
            patch.object(SYNC, "CATALOG", self.catalog),
            patch.object(SYNC, "DERIVED", self.derived),
            patch.object(SYNC, "CLONED_SOURCE_PACKAGES", self.workspace),
            patch.object(SYNC, "ARCH", "arm64"),
            patch.object(SYNC, "build_for_extraction",
                         side_effect=build or (lambda _platforms, _quiet, receipt: receipt.inputs())),
            patch.object(SYNC, "collect_stringsdata", return_value=[
                self.derived / "Build/Intermediates.noindex/Objects-normal/arm64/Example.stringsdata"
            ]),
            patch.object(SYNC, "check_conflicts", return_value=0),
            patch.object(SYNC, "validate_catalog", return_value=validation),
            patch.object(SYNC, "sync", side_effect=sync),
        ]
        active = [p.start() for p in patches]
        try:
            result = SYNC.extract_and_sync(args)
            return result, active[5], active[8], active[9]
        finally:
            for p in reversed(patches):
                p.stop()

    def test_warm_check_skips_only_build_and_still_syncs_and_validates(self):
        self.record()
        result, build, validate, sync = self.execute(self.args())
        self.assertEqual(result, 0)
        build.assert_not_called()
        validate.assert_called_once()
        sync.assert_called_once()
        self.assertTrue(sync.call_args.kwargs["allow_stale"])

    def test_cache_miss_runs_the_real_build_before_recording(self):
        result, build, _, _ = self.execute(self.args())
        self.assertEqual(result, 0)
        build.assert_called_once()
        self.assertTrue(self.matches())

    def test_failing_build_invalidates_old_receipt_before_attempt(self):
        self.record()
        def fail(*_):
            self.assertFalse(self.receipt.path.exists())
            raise SystemExit(1)
        with self.assertRaises(SystemExit):
            self.execute(self.args(reuse_if_unchanged=False), build=fail)
        self.assertFalse(self.matches())

    def test_partial_and_unsafe_no_build_cannot_seed_a_complete_receipt(self):
        for args in (self.args(platform="tvos", reuse_if_unchanged=False),
                     self.args(no_build=True, reuse_if_unchanged=False)):
            with self.subTest(args=args):
                self.record()
                result, _, _, sync = self.execute(args)
                self.assertEqual(result, 0)
                self.assertFalse(self.receipt.path.exists())
                self.assertFalse(sync.call_args.kwargs["allow_stale"])

    def test_out_of_date_check_restores_catalog_and_does_not_cache_success(self):
        before = self.catalog.read_text()
        result, _, _, _ = self.execute(self.args(), sync=lambda *_a, **_k: self.catalog.write_text('{"changed":true}'))
        self.assertEqual(result, 1)
        self.assertEqual(self.catalog.read_text(), before)
        self.assertFalse(self.receipt.path.exists())

    def prepare_hook(self):
        self.write("tools/main-landing.py", (TOOLS / "main-landing.py").read_text())
        self.write("tools/l10n-guard.sh", '#!/bin/sh\necho guard >> "$HOOK_LOG"\n')
        (self.root / "tools/l10n-guard.sh").chmod(0o755)
        for name in ("l10n-sync.py", "l10n-export-source.py"):
            self.write("tools/" + name, """
import json,os,sys
from pathlib import Path
with open(os.environ["HOOK_LOG"],"a") as stream:
    stream.write(json.dumps([Path(__file__).name,*sys.argv[1:]])+"\\n")
raise SystemExit(7 if os.environ.get("FAIL_STEP")==Path(__file__).name else 0)
""")
        return self.write(".githooks/pre-push", (TOOLS.parent / ".githooks/pre-push").read_text())

    def test_main_hook_validates_catalog_without_rebuilding_at_publication(self):
        hook = self.prepare_hook()
        log = self.root / "hook.log"
        result = subprocess.run(["bash", str(hook)], cwd=self.root,
                                input="feature a refs/heads/main b\n", text=True,
                                capture_output=True, env={**os.environ, "HOOK_LOG": str(log)})
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = log.read_text().splitlines()
        self.assertEqual(lines[0], "guard")
        calls = [json.loads(line) for line in lines[1:]]
        sync = [call for call in calls if call[0] == "l10n-sync.py"]
        self.assertEqual(len(sync), 1)
        self.assertEqual(sync[0], ["l10n-sync.py", "--validate-only"])
        self.assertIn("--check-snapshot", calls[-1])

    def test_hook_stops_on_failed_check_and_leaves_feature_push_fast(self):
        hook = self.prepare_hook()
        log = self.root / "hook.log"
        env = {**os.environ, "HOOK_LOG": str(log), "FAIL_STEP": "l10n-sync.py"}
        result = subprocess.run(["bash", str(hook)], cwd=self.root,
                                input="feature a refs/heads/main b\n", text=True,
                                capture_output=True, env=env)
        self.assertEqual(result.returncode, 7)
        self.assertNotIn("l10n-export-source.py", log.read_text())
        log.unlink()
        result = subprocess.run(["bash", str(hook)], cwd=self.root,
                                input="feature a refs/heads/feature b\n", text=True,
                                capture_output=True, env=env)
        self.assertEqual(result.returncode, 0)
        self.assertFalse(log.exists())


if __name__ == "__main__":
    unittest.main()
