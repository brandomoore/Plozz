"""Isolated lifecycle fixtures. No production metadata, build or cleanup calls."""

import contextlib
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import pwd
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/lib"))
import plozz_build_lifecycle as lifecycle
import apple_build_cleanup as cleanup
import apple_build_lease as lease


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="plozz-lifecycle-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.home.chmod(0o700)
        control = self.home / ".config/smart-disk-maintenance"
        control.mkdir(parents=True, mode=0o700)
        (control / ".apple-build-interlock-test-root").touch(mode=0o600)
        self.env = {
            k: v for k, v in os.environ.items()
            if not k.startswith(("APPLE_BUILD_", "PLOZZ_", "GIT_CONFIG_"))
        }
        self.env.update(HOME=str(self.home), APPLE_BUILD_INTERLOCK_TESTING="1",
                        APPLE_BUILD_INTERLOCK_TEST_ROOT=str(control / lease.ROOT_NAME),
                        GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'",
                        PYTHONDONTWRITEBYTECODE="1")
        patch = mock.patch.dict(os.environ, self.env, clear=True)
        patch.start()
        self.addCleanup(patch.stop)
        lease.prepare_namespace()
        self.repo = self.home / "repo"
        self.repo.mkdir(mode=0o700)
        self.git(self.repo, "init", "-q")
        self.git(self.repo, "config", "user.name", "Fixture")
        self.git(self.repo, "config", "user.email", "fixture@example.invalid")
        (self.repo / ".gitignore").write_text(".build/\nbuild/\nPlozz.xcodeproj/\n")
        (self.repo / "source.swift").write_text("// Protected fixture source\n")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-qm", "Fixture")
        self.worktree = self.home / "worktree"
        self.git(self.repo, "worktree", "add", "-qb", "fixture", str(self.worktree))
        self.external = self.home / "external-derived"
        self.manifest = self.home / "manifest.json"
        self.now = cleanup.now_utc()

    def git(self, repo, *args):
        return subprocess.run(["git", "-C", str(repo), *args], check=True,
                              capture_output=True, text=True, env=self.env).stdout

    def leased(self, *args):
        return subprocess.run(
            [str(ROOT / "tools/with-apple-build-lease.sh"), "test/lifecycle", "--",
             sys.executable, "-B", str(ROOT / "tools/plozz-build-lifecycle.py"), *map(str, args)],
            env=self.env, capture_output=True, text=True, timeout=30,
        )

    def register(self, path=None, repo=None, kind="derived-data"):
        result = self.leased("register", "--repo", repo or self.worktree,
                             "--root", kind, path or self.external)
        self.assertEqual(result.returncode, 0, result.stderr)
        return lifecycle.read_state(lifecycle.state_path())

    def retire(self):
        self.git(self.repo, "worktree", "remove", "--force", str(self.worktree))
        with mock.patch.object(lifecycle, "inherited_shared", return_value=()):
            with lifecycle.registry() as state:
                lifecycle.reconcile(state, self.now + dt.timedelta(seconds=10))
        return self.now + dt.timedelta(days=8)

    def target(self):
        self.register()
        unit = self.external / "Objects"
        unit.mkdir()
        (unit / "fixture.o").write_bytes(b"compiled fixture")
        return unit

    def test_created_registered_archived_contained_outputs_leave_no_external_orphan(self):
        derived = self.worktree / ".build/device"
        self.register(derived)
        (derived / "object.o").write_bytes(b"object")
        packages = self.worktree / ".build/packages"
        self.register(packages, kind="package-workspace")
        (packages / "dependency.swift").write_text("fixture package source")
        self.retire()
        state = lifecycle.read_state(lifecycle.state_path())
        self.assertFalse(derived.exists())
        self.assertFalse(packages.exists())
        self.assertEqual(state["resources"], [])
        self.assertEqual(state["retired_contained"], 2)
        self.assertTrue((self.repo / "source.swift").exists())

    def test_external_retirement_proposes_and_deletes_exact_fixture_unit(self):
        unit = self.target()
        later = self.retire()
        manifest = lifecycle.proposal(unit, later)
        cleanup.write_private_new(self.manifest, cleanup.encode_manifest(manifest))
        checked, _, entries = cleanup.validate_manifest(self.manifest, current_time=later)
        self.assertEqual(checked, manifest)
        self.assertGreater(len(entries[str(unit)]), 1)
        authorization = {
            "window_id": "00000000-0000-0000-0000-000000000002",
            "policy_sha256": "0" * 64,
            "expires_at": cleanup.utc(later + dt.timedelta(hours=1)),
        }
        # Destructive engine's full real-authority suite is separate. This test
        # keeps lifecycle owner checks live while substituting fixture authority.
        def guard_check(guard, target=None):
            guard.pinned.validate()
            guard.references.validate()
            if target:
                guard.validate_owner(target)
        with mock.patch.object(cleanup.policy, "check", return_value=authorization), \
             mock.patch.object(cleanup.RuntimeGuard, "check", guard_check):
            cleanup.apply_manifest(
                self.manifest, window_id=authorization["window_id"],
                journal_path=self.home / "journal.jsonl", current_time=later,
                clock=lambda: later, open_inventory=lambda *_: ((), frozenset()),
            )
        self.assertFalse(unit.exists())
        self.assertTrue(self.external.exists())
        self.assertTrue(lifecycle.state_path().exists())

    def test_registration_requires_real_inherited_lease(self):
        with self.assertRaisesRegex(lease.LeaseError, "authenticated shared"):
            lifecycle.register(self.worktree, [("derived-data", self.external)])
        self.assertFalse(self.external.exists())

    def test_live_primary_shared_and_release_roots_stay_protected(self):
        state = self.register()
        self.assertIn("living", lifecycle.resource_status(state["resources"][0]))
        self.register(repo=self.repo)
        later = self.retire()
        with self.assertRaisesRegex(lease.LeaseError, "live/shared"):
            lifecycle.proposal(self.external, later)
        state = self.register(self.home / "release", repo=self.repo, kind="release-evidence")
        self.assertIn("durable release", lifecycle.resource_status(state["resources"][-1]))

    def test_missing_checkout_prunable_registration_is_not_retirement(self):
        state = self.register()
        self.worktree.rename(self.home / "temporarily-away")
        self.assertIn("still registered", lifecycle.resource_status(state["resources"][0]))
        with self.assertRaises(lease.LeaseError):
            lifecycle.proposal(self.external, self.now + dt.timedelta(days=30))

    def test_git_move_and_new_checkout_at_original_path_protect(self):
        state = self.register()
        moved = self.home / "moved"
        self.git(self.repo, "worktree", "move", str(self.worktree), str(moved))
        self.assertIn("may have moved", lifecycle.resource_status(state["resources"][0]))
        self.git(self.repo, "worktree", "add", "-qb", "restored", str(self.worktree))
        self.assertIn("restored or replaced", lifecycle.resource_status(state["resources"][0]))

    def test_replaced_parent_common_dir_and_symlink_fail_closed(self):
        state = self.register()
        resource = state["resources"][0]
        for key in ("parent", "common"):
            with self.subTest(key=key):
                original = resource["owners"][0][key]["inode"]
                resource["owners"][0][key]["inode"] += 1
                with self.assertRaises(lease.LeaseError):
                    lifecycle.resource_status(resource)
                resource["owners"][0][key]["inode"] = original
        destination = self.home / "real-derived"
        self.external.rename(destination)
        self.external.symlink_to(destination, target_is_directory=True)
        with self.assertRaises(lease.LeaseError):
            lifecycle.proposal(self.external, self.now + dt.timedelta(days=30))

    def test_retention_whole_tree_and_new_leaf_are_not_root_mtime_tests(self):
        unit = self.target()
        later = self.retire()
        with self.assertRaisesRegex(lease.LeaseError, "seven-day"):
            lifecycle.proposal(unit, self.now + dt.timedelta(days=6))
        lifecycle.proposal(unit, later)
        os.utime(unit / "fixture.o", (later.timestamp(), later.timestamp()))
        with self.assertRaisesRegex(lease.LeaseError, "whole-tree retention"):
            lifecycle.proposal(unit, later)

    def test_protected_bundles_source_modified_packages_links_and_unknown_files(self):
        unit = self.target()
        later = self.retire()
        for name in (
            "release.xcarchive", "symbols.dSYM", "symbols.dSYM.zip", "run.xcresult",
            "source.swift", "object.h", ".git", "key.p8", "app.app", "unknown.dat",
            "SourcePackages", "checkouts",
        ):
            with self.subTest(name=name):
                path = unit / name
                path.write_bytes(b"protected")
                with self.assertRaises(lease.LeaseError):
                    lifecycle.proposal(unit, later)
                path.unlink()
        other = self.home / "other.o"
        other.write_bytes(b"do not delete")
        (unit / "link.o").symlink_to(other)
        with self.assertRaises(lease.LeaseError):
            lifecycle.proposal(unit, later)
        (unit / "link.o").unlink()
        os.link(other, unit / "hard.o")
        with self.assertRaisesRegex(lease.LeaseError, "hard-linked"):
            lifecycle.proposal(unit, later)
        self.assertTrue(other.exists())

    def test_preview_epoch_changed_tree_and_restoration_are_revalidated(self):
        unit = self.target()
        later = self.retire()
        cleanup.write_private_new(self.manifest, cleanup.encode_manifest(lifecycle.proposal(unit, later)))
        self.git(self.repo, "worktree", "add", "-qb", "new-session", str(self.worktree))
        with self.assertRaises(lease.LeaseError):
            cleanup.validate_manifest(self.manifest, current_time=later)
        self.assertTrue((unit / "fixture.o").exists())

    def test_corrupt_missing_and_bounded_registry_surface_errors(self):
        self.register()
        path = lifecycle.state_path()
        original = path.read_bytes()
        path.write_bytes(b'{"schema":1,"schema":1}')
        with self.assertRaises(lease.LeaseError):
            lifecycle.read_state(path)
        path.unlink()
        result = self.leased("reconcile")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing after initialization", result.stderr)
        path.write_bytes(original)
        path.chmod(0o600)
        with mock.patch.object(lifecycle, "MAX_RESOURCES", 0):
            with self.assertRaisesRegex(lease.LeaseError, "limit"):
                lifecycle.read_state(path)

    def test_repeated_registration_is_bounded_and_source_is_never_owned(self):
        for _ in range(3):
            self.register()
        state = lifecycle.read_state(lifecycle.state_path())
        self.assertEqual(len(state["resources"]), 1)
        self.assertEqual(len(state["resources"][0]["owners"]), 1)
        for path in (self.worktree, self.worktree / ".git", self.worktree / "source.swift"):
            result = self.leased("register", "--repo", self.worktree, "--root", "derived-data", path)
            self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.worktree / "source.swift").exists())
        self.assertLess(lifecycle.state_path().stat().st_size, 8192)

    def test_owner_disappearing_while_waiting_does_not_recreate_checkout(self):
        self.register()
        original = lifecycle.registry
        @contextlib.contextmanager
        def delayed():
            with original() as state:
                self.git(self.repo, "worktree", "remove", "--force", str(self.worktree))
                yield state
        with mock.patch.object(lifecycle, "inherited_shared", return_value=()), \
             mock.patch.object(lifecycle, "registry", delayed):
            with self.assertRaises((lease.LeaseError, OSError)):
                lifecycle.register(self.worktree, [("derived-data", self.worktree / ".build/new")])
        self.assertFalse(self.worktree.exists())

    def test_legacy_attribution_is_read_only_and_never_adopts_missing_owner(self):
        derived = self.home / "Library/Developer/Xcode/DerivedData"
        root = derived / "Plozz-fixture"
        root.mkdir(parents=True)
        project = self.worktree / "Plozz.xcodeproj"
        project.mkdir()
        (root / "info.plist").write_bytes(plistlib.dumps({"WorkspacePath": str(project)}))
        before = (root / "info.plist").read_bytes()
        self.assertIn("existing legacy", lifecycle.legacy_inventory()[0]["status"])
        result = self.leased("workspace", "--repo", self.worktree)
        self.assertEqual(result.returncode, 0, result.stderr)
        state = lifecycle.read_state(lifecycle.state_path())
        self.assertEqual(len(state["resources"]), 2)
        self.retire()
        self.assertIn("owner absent", lifecycle.legacy_inventory()[0]["status"])
        self.assertEqual((root / "info.plist").read_bytes(), before)

    def test_recreated_contained_build_root_gets_new_epoch_without_losing_shared_refs(self):
        derived = self.worktree / ".build/device"
        first = self.register(derived)["resources"][0]["id"]
        derived.rmdir()
        self.git(self.worktree, "commit", "--allow-empty", "-qm", "Next fixture source")
        second = self.register(derived)["resources"][0]["id"]
        self.assertNotEqual(first, second)
        self.assertEqual(len(lifecycle.read_state(lifecycle.state_path())["resources"]), 1)

    def test_native_workspace_settings_are_updated_without_erasing_other_keys(self):
        settings = self.worktree / "Plozz.xcodeproj/project.xcworkspace/xcuserdata" / (
            pwd.getpwuid(os.geteuid()).pw_name + ".xcuserdatad"
        ) / "WorkspaceSettings.xcsettings"
        settings.parent.mkdir(parents=True)
        settings.write_bytes(plistlib.dumps({"BuildSystemType": "Latest"}))
        result = self.leased("workspace", "--repo", self.worktree)
        self.assertEqual(result.returncode, 0, result.stderr)
        value = plistlib.loads(settings.read_bytes())
        self.assertEqual(value["DerivedDataLocationStyle"], "WorkspaceRelativePath")
        self.assertEqual(value["DerivedDataCustomLocation"], ".build/xcode-gui")
        self.assertEqual(value["BuildSystemType"], "Latest")

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcodegen"), "native Xcode fixture")
    def test_xcode_resolves_native_gui_location_without_building(self):
        (self.worktree / "project.yml").write_text(
            "name: Plozz\ntargets:\n  Plozz:\n    type: library.static\n"
            "    platform: macOS\n    sources: [source.swift]\n"
        )
        subprocess.run(["xcodegen", "generate"], cwd=self.worktree, env=self.env,
                       check=True, capture_output=True, timeout=30)
        result = self.leased("workspace", "--repo", self.worktree)
        self.assertEqual(result.returncode, 0, result.stderr)
        command = ["xcodebuild", "-project", str(self.worktree / "Plozz.xcodeproj"),
                   "-scheme", "Plozz", "-showBuildSettings", "-json"]
        result = subprocess.run(
            [str(ROOT / "tools/with-apple-build-lease.sh"), "test/xcode-settings", "--", *command],
            env=self.env, text=True, capture_output=True, timeout=90,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        settings = json.loads(result.stdout)[0]["buildSettings"]
        self.assertTrue(str(Path(settings["BUILD_DIR"]).resolve()).startswith(str(self.worktree / ".build/xcode-gui") + "/"),
                        settings["BUILD_DIR"])


class RetiredAuthorizationTests(unittest.TestCase):
    def setUp(self):
        from tools.tests.test_apple_build_cleanup import CleanupAuthorizationTests
        self.adapter = CleanupAuthorizationTests()
        self.adapter.setUp()
        self.addCleanup(self.adapter.doCleanups)
        f = self.adapter.fixture
        self.f = f
        def git(*args):
            return subprocess.run(["git", "-C", str(f.repo), *args], check=True,
                                  env=f.env, capture_output=True)
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        git("add", "writer.sh")
        git("commit", "-qm", "Fixture")
        worktree = f.home / "retiring"
        git("worktree", "add", "-qb", "retiring", str(worktree))
        derived = f.home / "external-derived"
        registered = subprocess.run([
            str(ROOT / "tools/with-apple-build-lease.sh"), "test/retired-register", "--",
            sys.executable, "-B", str(ROOT / "tools/plozz-build-lifecycle.py"),
            "register", "--repo", str(worktree), "--root", "derived-data", str(derived),
        ], env=f.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(registered.returncode, 0, registered.stderr)
        self.unit = derived / "objects"
        self.unit.mkdir()
        (self.unit / "fixture.o").write_bytes(b"fixture object")
        git("worktree", "remove", "--force", str(worktree))
        # Only synthetic fixture time is accelerated; production has no age override.
        with mock.patch.object(lifecycle, "inherited_shared", return_value=()):
            with lifecycle.registry() as state:
                resource = state["resources"][0]
                past = cleanup.now_utc() - dt.timedelta(days=9)
                resource["created_at"] = resource["observed_at"] = cleanup.utc(past)
                lifecycle.reconcile(state, past)
        with mock.patch.object(cleanup, "entry_record", side_effect=self.adapter.aged):
            manifest = lifecycle.proposal(self.unit)
        f.write_json(f.manifest, manifest)
        added = ("tools/lib/plozz_build_lifecycle.py", "tools/plozz-build-lifecycle.py")
        for name in added:
            shutil.copyfile(ROOT / name, f.repo / name)
        for cohort in f.package["cohorts"]:
            if cohort["name"] == "global-cleanup-entrypoints":
                cohort["roots"][0]["writers"].extend(f.ref(f.repo / name) for name in added)
        f.package["registries"][0]["sha256"] = cleanup.policy.worktree_snapshot(f.repo)[0]
        f.package["window"]["manifest_sha256"] = cleanup.policy.digest(cleanup.policy.canonical(manifest))
        current = cleanup.policy.digest((f.namespace / cleanup.policy.POLICY_NAME).read_bytes())
        f.approve()
        f.install(current)

    def test_real_companion_and_exclusive_lease_delete_retired_fixture_only(self):
        result = self.adapter.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.unit.exists())
        self.assertTrue((self.f.repo / "writer.sh").exists())
        self.assertTrue(lifecycle.state_path().exists())

    def test_suspension_and_crash_hold_still_prevent_retired_cleanup(self):
        (self.f.policy_home / "SUSPENDED").touch(mode=0o600)
        result = self.adapter.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.unit / "fixture.o").exists())
        (self.f.policy_home / "SUSPENDED").unlink()
        (self.f.namespace / "leases/unresolved-crash").write_text("fixture hold")
        result = self.adapter.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.unit / "fixture.o").exists())


if __name__ == "__main__":
    unittest.main()
