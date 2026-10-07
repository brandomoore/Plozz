#!/usr/bin/env python3
"""Synthetic tests for exact-manifest Apple build-output cleanup."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools/lib"))
import apple_build_cleanup as cleanup
import apple_build_lease as lease


class AppleBuildCleanupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="apple-cleanup-tests-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.home.chmod(0o700)
        self.policy_home = self.home / ".config/smart-disk-maintenance"
        self.policy_home.mkdir(parents=True, mode=0o700)
        self.sentinel = self.policy_home / ".apple-build-interlock-test-root"
        self.sentinel.touch(mode=0o600)
        self.interlock = self.policy_home / lease.ROOT_NAME
        self.derived = self.home / "Library/Developer/Xcode/DerivedData"
        self.derived.mkdir(parents=True)
        self.worktree = self.home / "repo"
        self.worktree.mkdir(mode=0o700)
        subprocess.run(["git", "init", "--quiet", str(self.worktree)], check=True)
        self.build = self.worktree / ".build"
        self.build.mkdir()
        (self.build / "product.o").write_bytes(b"fixture")
        self.evidence = self.home / "owner-evidence.txt"
        self.evidence.write_text("Synthetic owner release evidence.\n")
        self.evidence.chmod(0o600)
        self.release = self.home / "owner-release.json"
        self.manifest = self.home / "manifest.json"
        self.journal = self.home / "journal.jsonl"
        self.now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        self.future = self.now + dt.timedelta(days=8)
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("APPLE_BUILD_")
        }
        self.env.update(
            HOME=str(self.home),
            APPLE_BUILD_INTERLOCK_TESTING="1",
            APPLE_BUILD_INTERLOCK_TEST_ROOT=str(self.interlock),
            APPLE_BUILD_CLEANUP_DERIVED_DATA_ROOT=str(self.derived),
        )
        self.patch = mock.patch.dict(os.environ, self.env, clear=True)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        lease.prepare_namespace()
        self.write_release()

    def write_json(self, path: Path, value: dict) -> None:
        path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
        path.chmod(0o600)

    def evidence_ref(self) -> dict[str, str]:
        return {
            "path": str(self.evidence),
            "sha256": cleanup.policy.digest(self.evidence.read_bytes()),
        }

    def write_release(
        self,
        *,
        target: Path | None = None,
        kind: str = "worktree-apple-build",
        evidence: list[dict[str, str]] | None = None,
    ) -> None:
        target = target or self.build
        self.write_json(
            self.release,
            {
                "schema": 1,
                "scope": cleanup.SCOPE,
                "owner": "fixture-owner",
                "session_id": "00000000-0000-0000-0000-000000000001",
                "released_at": cleanup.utc(self.now),
                "worktree": cleanup.identity_document(self.worktree),
                "evidence": evidence or [self.evidence_ref()],
                "targets": [{"identity": cleanup.identity_document(target), "kind": kind}],
            },
        )

    def make_manifest(self) -> dict:
        manifest = cleanup.inventory([self.release], current_time=self.future)
        cleanup.write_private_new(
            self.manifest,
            (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode(),
        )
        return manifest

    def authorization(self) -> dict[str, str]:
        return {
            "window_id": "00000000-0000-0000-0000-000000000002",
            "policy_sha256": "0" * 64,
            "expires_at": cleanup.utc(self.future + dt.timedelta(hours=1)),
        }

    def open_inventory(self, _ignored=frozenset()):
        return (("/unrelated/open-file",), frozenset({(999, 999)}))

    @contextlib.contextmanager
    def guard_allowed(self):
        with mock.patch.object(
            cleanup.policy, "check", return_value=self.authorization()
        ), mock.patch.object(cleanup.RuntimeGuard, "check"):
            yield

    def apply(self, **kwargs):
        return cleanup.apply_manifest(
            self.manifest, window_id=self.authorization()["window_id"],
            journal_path=self.journal, current_time=self.future,
            clock=lambda: self.future, open_inventory=kwargs.pop("open_inventory", self.open_inventory),
            **kwargs,
        )

    def test_inventory_requires_owner_release_and_whole_tree_retention(self) -> None:
        with self.assertRaisesRegex(lease.LeaseError, "retention period"):
            cleanup.inventory([self.release], current_time=self.now)
        manifest = cleanup.inventory([self.release], current_time=self.future)
        self.assertEqual(manifest["scope"], cleanup.SCOPE)
        self.assertEqual(len(manifest["targets"]), 1)
        target = manifest["targets"][0]
        self.assertEqual(target["retention"]["minimum_seconds"], 7 * 24 * 60 * 60)
        self.assertGreater(target["tree"]["entries"], 1)

    def test_protected_artifacts_git_and_evidence_refuse_inventory(self) -> None:
        protected = self.build / "result.xcresult"
        protected.mkdir()
        with self.assertRaisesRegex(lease.LeaseError, "protected release artifact"):
            cleanup.inventory([self.release], current_time=self.future)
        protected.rmdir()

        git = self.build / ".git"
        git.mkdir()
        with self.assertRaisesRegex(lease.LeaseError, "protected artifact"):
            cleanup.inventory([self.release], current_time=self.future)
        git.rmdir()

        nested_evidence = self.build / "owner.txt"
        nested_evidence.write_text("not allowed")
        nested_evidence.chmod(0o600)
        self.write_release(
            evidence=[
                {
                    "path": str(nested_evidence),
                    "sha256": cleanup.policy.digest(nested_evidence.read_bytes()),
                }
            ]
        )
        with self.assertRaisesRegex(lease.LeaseError, "evidence is inside"):
            cleanup.inventory([self.release], current_time=self.future)

    def test_private_dependency_checkout_git_is_protected(self) -> None:
        checkout_git = self.build / "SourcePackages/checkouts/pkg/.git"
        checkout_git.mkdir(parents=True)
        (checkout_git / "HEAD").write_text("ref: refs/heads/main\n")
        with self.assertRaisesRegex(lease.LeaseError, "protected artifact"):
            cleanup.inventory([self.release], current_time=self.future)

    def test_changed_tree_or_owner_identity_refuses_manifest(self) -> None:
        self.make_manifest()
        (self.build / "product.o").write_bytes(b"changed")
        with self.assertRaisesRegex(lease.LeaseError, "changed since inventory"):
            cleanup.validate_manifest(self.manifest, current_time=self.future)

        self.manifest.unlink()
        (self.build / "product.o").write_bytes(b"fixture")
        self.write_release()
        self.make_manifest()
        replacement = self.home / "replacement"
        self.worktree.rename(replacement)
        self.worktree.mkdir(mode=0o700)
        with self.assertRaises((lease.LeaseError, OSError)):
            cleanup.validate_manifest(self.manifest, current_time=self.future)

    def test_apply_requires_real_exclusive_companion_authorization(self) -> None:
        self.make_manifest()
        with self.assertRaisesRegex(lease.LeaseError, "exclusive lease"):
            cleanup.apply_manifest(
                self.manifest,
                window_id=self.authorization()["window_id"],
                journal_path=self.journal,
                current_time=self.future,
                clock=lambda: self.future,
                open_inventory=self.open_inventory,
            )
        self.assertTrue(self.build.exists())
        self.assertFalse(self.journal.exists())

    def test_open_inode_stops_before_removal_and_journals_failure(self) -> None:
        self.make_manifest()
        file = self.build / "product.o"
        st = file.stat()
        opened = ((str(file),), frozenset({(st.st_dev, st.st_ino)}))
        with mock.patch.object(
            cleanup.policy, "check", return_value=self.authorization()
        ), mock.patch.object(
            cleanup.policy,
            "inherited_exclusive",
            return_value=argparse.Namespace(),
        ), mock.patch.object(cleanup.RuntimeGuard, "check"):
            with self.assertRaisesRegex(lease.LeaseError, "open path or inode"):
                cleanup.apply_manifest(
                    self.manifest,
                    window_id=self.authorization()["window_id"],
                    journal_path=self.journal,
                    current_time=self.future,
                    clock=lambda: self.future,
                    open_inventory=lambda _ignored=frozenset(): opened,
                )
        self.assertTrue(file.exists())
        events = [json.loads(line)["event"] for line in self.journal.read_text().splitlines()]
        self.assertEqual(events, ["started", "stopped"])

    def test_interruption_leaves_durable_partial_journal_without_resume(self) -> None:
        (self.build / "second.o").write_bytes(b"second")
        self.write_release()
        self.make_manifest()
        real_unlink = os.unlink
        calls = 0

        def interrupted(path, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise KeyboardInterrupt()
            real_unlink(path, **kwargs)

        with mock.patch.object(
            cleanup.policy, "check", return_value=self.authorization()
        ), mock.patch.object(
            cleanup.policy,
            "inherited_exclusive",
            return_value=argparse.Namespace(),
        ), mock.patch.object(cleanup.RuntimeGuard, "check"), mock.patch.object(
            cleanup.os, "unlink", side_effect=interrupted
        ):
            with self.assertRaises(KeyboardInterrupt):
                cleanup.apply_manifest(
                    self.manifest,
                    window_id=self.authorization()["window_id"],
                    journal_path=self.journal,
                    current_time=self.future,
                    clock=lambda: self.future,
                    open_inventory=self.open_inventory,
                )
        events = [json.loads(line)["event"] for line in self.journal.read_text().splitlines()]
        self.assertIn("removed", events)
        self.assertEqual(events[-1], "stopped")
        self.assertTrue(self.build.exists())
        with self.assertRaisesRegex(lease.LeaseError, "changed since inventory"):
            with mock.patch.object(
                cleanup.policy, "check", return_value=self.authorization()
            ), mock.patch.object(
                cleanup.policy,
                "inherited_exclusive",
                return_value=argparse.Namespace(),
            ), mock.patch.object(cleanup.RuntimeGuard, "check"):
                cleanup.apply_manifest(
                    self.manifest,
                    window_id=self.authorization()["window_id"],
                    journal_path=self.journal,
                    current_time=self.future,
                    clock=lambda: self.future,
                    open_inventory=self.open_inventory,
                )

    def test_deadline_guard_refuses_before_lease_or_unlink_checks(self) -> None:
        pinned = mock.Mock()
        authorization = self.authorization()
        authorization["expires_at"] = cleanup.utc(self.future - dt.timedelta(seconds=1))
        with mock.patch.object(cleanup.policy, "check", return_value=authorization):
            guard = cleanup.RuntimeGuard({"targets": []}, pinned, authorization["window_id"], lambda: self.future)
            with self.assertRaisesRegex(lease.LeaseError, "expired"):
                guard.check()
        pinned.validate.assert_not_called()

    def test_successful_synthetic_apply_removes_only_manifest_target(self) -> None:
        outside = self.worktree / "source.swift"
        outside.write_text("preserved")
        self.write_release()
        self.make_manifest()
        with mock.patch.object(
            cleanup.policy, "check", return_value=self.authorization()
        ), mock.patch.object(
            cleanup.policy,
            "inherited_exclusive",
            return_value=argparse.Namespace(),
        ), mock.patch.object(cleanup.RuntimeGuard, "check"):
            result = cleanup.apply_manifest(
                self.manifest,
                window_id=self.authorization()["window_id"],
                journal_path=self.journal,
                current_time=self.future,
                clock=lambda: self.future,
                open_inventory=self.open_inventory,
            )
        self.assertFalse(self.build.exists())
        self.assertTrue(outside.exists())
        self.assertGreater(result["removed"], 1)
        events = [json.loads(line)["event"] for line in self.journal.read_text().splitlines()]
        self.assertEqual(events[-1], "completed")

    def test_unknown_sources_dependencies_and_bundles_stay_protected(self):
        for name in (
            "result.xcresult", "saved.dSYM", "archive.xcarchive", "app.ipa",
            "key.p8", "main.swift", "main.java", "main.d", "prefix.pch", "notes.txt", "unknown.bin",
            "SourcePackages", "checkouts", "repositories", "artifacts",
            "ModuleCache.noindex/evidence", "Logs", ".git", "VMs", ".Trash",
        ):
            with self.subTest(name=name):
                path = self.build / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.mkdir()
                (path / "content.o").write_bytes(b"preserved")
                if path.suffix and path.suffix.lower() not in cleanup.PROTECTED_SUFFIXES:
                    # An unrecognized regular file, not an arbitrary directory.
                    (path / "content.o").unlink()
                    path.rmdir()
                    path.write_bytes(b"preserved")
                with self.assertRaises(lease.LeaseError):
                    cleanup.inventory([self.release], current_time=self.future)
                if path.is_dir():
                    (path / "content.o").unlink()
                    path.rmdir()
                else:
                    path.unlink()

    def test_exact_generated_file_can_be_nominated_beside_protected_data(self):
        (self.build / "SourcePackages").mkdir()
        target = self.build / "product.o"
        self.write_release(target=target)
        self.make_manifest()
        with self.guard_allowed():
            self.apply()
        self.assertFalse(target.exists())
        self.assertTrue((self.build / "SourcePackages").exists())

    def test_tracked_compiler_output_refuses_inventory(self):
        subprocess.run(
            ["git", "-C", str(self.worktree), "add", ".build/product.o"], check=True
        )
        with self.assertRaisesRegex(lease.LeaseError, "tracked files"):
            cleanup.inventory([self.release], current_time=self.future)

    def test_retention_includes_birthtime_ctime_and_release_age(self):
        os.utime(self.build / "product.o", (1, 1))
        self.now -= dt.timedelta(days=8)
        self.write_release()
        with self.assertRaisesRegex(lease.LeaseError, "whole-tree retention"):
            cleanup.inventory([self.release], current_time=self.now + dt.timedelta(days=8))
        with self.assertRaisesRegex(lease.LeaseError, "integer >= 604800"):
            cleanup.inventory([self.release], minimum_seconds=1, current_time=self.future)

    def test_stale_owner_release_cannot_nominate_replacement_target(self):
        old = self.worktree / "old-build"
        self.build.rename(old)
        self.build.mkdir()
        (self.build / "product.o").write_bytes(b"new owner")
        with self.assertRaisesRegex(lease.LeaseError, "released root identity changed"):
            cleanup.inventory([self.release], current_time=self.future)

    def test_links_and_aliases_refuse_inventory(self):
        file = self.build / "product.o"
        outside = self.home / "protected.o"
        outside.write_bytes(b"preserved")
        file.unlink()
        file.symlink_to(outside)
        with self.assertRaisesRegex(lease.LeaseError, "symlink"):
            cleanup.inventory([self.release], current_time=self.future)
        file.unlink()
        os.link(outside, file)
        with self.assertRaisesRegex(lease.LeaseError, "hard-linked"):
            cleanup.inventory([self.release], current_time=self.future)
        file.unlink()
        alias = self.home / "alias"
        alias.symlink_to(self.worktree, target_is_directory=True)
        with self.assertRaisesRegex(lease.LeaseError, "physical"):
            cleanup.policy.physical_path(str(alias / ".build"))

    def test_nested_directory_removal_uses_descriptor_relative_paths(self):
        nested = self.build / "nested/objects"
        nested.mkdir(parents=True)
        (nested / "compiled.o").write_bytes(b"fixture")
        self.make_manifest()
        real_unlink = os.unlink
        calls = []
        def record(path, **kwargs):
            self.assertIsNotNone(kwargs.get("dir_fd"))
            self.assertFalse(Path(path).is_absolute())
            calls.append(path)
            return real_unlink(path, **kwargs)
        with self.guard_allowed(), mock.patch.object(cleanup.os, "unlink", side_effect=record):
            self.apply()
        self.assertEqual(set(calls), {"product.o", "compiled.o"})

    def test_new_open_inode_after_initial_scan_blocks_removal(self):
        self.make_manifest()
        st = (self.build / "product.o").stat()
        calls = 0
        def opened(_ignored=frozenset()):
            nonlocal calls
            calls += 1
            if calls >= 2:
                return (("/another/alias",), frozenset({(st.st_dev, st.st_ino)}))
            return self.open_inventory()
        with self.guard_allowed(), self.assertRaisesRegex(lease.LeaseError, "open path or inode"):
            self.apply(open_inventory=opened)
        self.assertTrue((self.build / "product.o").exists())

    def test_replaced_ancestor_during_open_scan_never_follows_symlink(self):
        self.make_manifest()
        outside = self.home / "outside"
        outside.mkdir()
        protected = outside / "product.o"
        protected.write_bytes(b"preserved")
        moved = self.worktree / "moved-build"
        calls = 0
        def opened(_ignored=frozenset()):
            nonlocal calls
            calls += 1
            if calls == 2:
                self.build.rename(moved)
                self.build.symlink_to(outside, target_is_directory=True)
            return self.open_inventory()
        with self.guard_allowed(), self.assertRaises((lease.LeaseError, OSError)):
            self.apply(open_inventory=opened)
        self.assertEqual(protected.read_bytes(), b"preserved")
        self.assertTrue((moved / "product.o").exists())

    def test_replaced_file_or_new_child_after_inventory_refuses(self):
        self.make_manifest()
        calls = 0
        def opened(_ignored=frozenset()):
            nonlocal calls
            calls += 1
            if calls == 2:
                (self.build / "product.o").write_bytes(b"new data")
            return self.open_inventory()
        with self.guard_allowed(), self.assertRaisesRegex(lease.LeaseError, "changed before removal"):
            self.apply(open_inventory=opened)
        self.assertEqual((self.build / "product.o").read_bytes(), b"new data")

    def test_deadline_after_journal_intent_prevents_next_unlink(self):
        self.make_manifest()
        original = cleanup.DurableJournal.append
        expired = False
        def append(journal, event):
            nonlocal expired
            original(journal, event)
            if event["event"] == "remove-intent":
                expired = True
        clock = lambda: self.future + (dt.timedelta(hours=2) if expired else dt.timedelta())
        with self.guard_allowed(), mock.patch.object(cleanup.DurableJournal, "append", append):
            with self.assertRaisesRegex(lease.LeaseError, "expired"):
                cleanup.apply_manifest(
                    self.manifest, window_id=self.authorization()["window_id"],
                    journal_path=self.journal, current_time=self.future,
                    clock=clock, open_inventory=self.open_inventory,
                )
        self.assertTrue((self.build / "product.o").exists())

    def test_journal_handles_short_writes_and_surfaces_fsync_failure(self):
        original_write = os.write
        with mock.patch.object(cleanup.os, "write", side_effect=lambda fd, data: original_write(fd, data[:7])):
            journal = cleanup.DurableJournal(self.journal, {"fixture": True})
            journal.append({"event": "complete-fixture"})
            journal.close()
        self.assertEqual(len(self.journal.read_text().splitlines()), 2)
        self.make_manifest()
        self.journal.unlink()
        with self.guard_allowed(), mock.patch.object(cleanup.os, "fsync", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                self.apply()
        self.assertTrue((self.build / "product.o").exists())

    def test_partial_removal_sync_failure_retains_durable_intent(self):
        self.make_manifest()
        original_fsync = os.fsync
        def fsync(fd):
            if not (self.build / "product.o").exists() and os.fstat(fd).st_ino == self.build.stat().st_ino:
                raise OSError("directory sync failed")
            original_fsync(fd)
        with self.guard_allowed(), mock.patch.object(cleanup.os, "fsync", side_effect=fsync):
            with self.assertRaisesRegex(OSError, "directory sync failed"):
                self.apply()
        events = [json.loads(line) for line in self.journal.read_text().splitlines()]
        self.assertTrue(any(event["event"] == "remove-intent" for event in events))
        self.assertEqual(events[-1]["event"], "stopped")
        self.assertEqual(events[-1]["removed"], 1)
        self.assertTrue(self.build.exists())

    def test_signal_interrupt_restores_handlers_and_keeps_target(self):
        self.make_manifest()
        old = signal.getsignal(signal.SIGTERM)
        def opened(_ignored=frozenset()):
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
        with self.guard_allowed(), self.assertRaisesRegex(lease.LeaseError, "interrupted by signal"):
            self.apply(open_inventory=opened)
        self.assertEqual(signal.getsignal(signal.SIGTERM), old)
        self.assertTrue(self.build.exists())
        self.assertIn('"event": "stopped"', self.journal.read_text())

    def test_approved_manifest_pin_catches_replacement(self):
        self.make_manifest()
        pinned = cleanup.PinnedManifest(self.manifest, self.manifest.read_bytes())
        try:
            replacement = self.home / "replacement.json"
            replacement.write_bytes(self.manifest.read_bytes())
            replacement.chmod(0o600)
            os.replace(replacement, self.manifest)
            with self.assertRaises(lease.LeaseError):
                pinned.validate()
        finally:
            pinned.close()

    def test_read_only_validation_reports_the_approved_canonical_digest(self):
        document = self.make_manifest()
        document["targets"][0]["released_at"] = document["targets"][0]["released_at"].replace("+00:00", "Z")
        self.write_json(self.manifest, document)
        checked, raw, _ = cleanup.validate_manifest(self.manifest, current_time=self.future)
        self.assertEqual(
            cleanup.policy.digest(cleanup.policy.canonical(checked)),
            cleanup.policy.digest(cleanup.policy.canonical(cleanup.policy.document(raw))),
        )

    def test_multiple_disjoint_targets_and_owner_record_survive_progress(self):
        # Both targets are in .build; neither contains the other.
        first = self.build / "product.o"
        second = self.build / "second.o"
        second.write_bytes(b"fixture")
        self.write_release(target=first)
        release = json.loads(self.release.read_text())
        release["targets"].append({"identity": cleanup.identity_document(second), "kind": "worktree-apple-build"})
        self.write_json(self.release, release)
        self.make_manifest()
        with self.guard_allowed():
            self.apply()
        self.assertFalse(first.exists())
        self.assertFalse(second.exists())
        self.assertTrue(self.release.exists())

    def test_deriveddata_requires_owner_workspace_and_rejects_shared_roots(self):
        project = self.worktree / "Fixture.xcodeproj"
        project.mkdir()
        app_root = self.derived / "Fixture-hash"
        app_root.mkdir()
        import plistlib
        (app_root / "info.plist").write_bytes(plistlib.dumps({"WorkspacePath": str(project)}))
        target = app_root / "compiled.o"
        target.write_bytes(b"fixture")
        self.write_release(target=target, kind="xcode-derived-data")
        self.make_manifest()
        with self.guard_allowed():
            self.apply()
        self.assertFalse(target.exists())
        self.assertTrue((app_root / "info.plist").exists())
        shared = self.derived / "ModuleCache.noindex"
        shared.mkdir()
        with self.assertRaisesRegex(lease.LeaseError, "shared DerivedData cache"):
            self.write_release(target=shared, kind="xcode-derived-data")
            cleanup.inventory([self.release], current_time=self.future)

    def test_overlapping_targets_refuse_before_any_deletion(self):
        document = self.make_manifest()
        duplicate = dict(document["targets"][0])
        duplicate["path"] = str(self.build / "product.o")
        with self.assertRaisesRegex(lease.LeaseError, "overlapping"):
            cleanup.validate_disjoint_targets(document["targets"] + [duplicate])

    def test_existing_journal_is_never_overwritten(self):
        self.make_manifest()
        self.journal.write_text("protected prior attempt\n")
        self.journal.chmod(0o600)
        with self.guard_allowed(), self.assertRaises(FileExistsError):
            self.apply()
        self.assertEqual(self.journal.read_text(), "protected prior attempt\n")
        self.assertTrue(self.build.exists())

    def test_build_activity_and_process_inspection_errors_refuse(self):
        for result in (
            subprocess.CompletedProcess([], 0, "active xcodebuild", ""),
            subprocess.CompletedProcess([], 1, "", ""),
            subprocess.CompletedProcess([], 0, "", "inspection failed"),
        ):
            with mock.patch.object(cleanup.subprocess, "run", return_value=result):
                with self.assertRaisesRegex(lease.LeaseError, "process inspection"):
                    cleanup.require_no_build_activity()

    def test_unwritable_journal_failure_is_not_silently_swallowed(self):
        self.make_manifest()
        original = cleanup.DurableJournal.append
        def append(journal, event):
            if event["event"] in {"remove-intent", "stopped"}:
                raise OSError("journal unavailable")
            original(journal, event)
        with self.guard_allowed(), mock.patch.object(cleanup.DurableJournal, "append", append):
            with self.assertRaisesRegex(OSError, "journal unavailable") as error:
                self.apply()
        self.assertIsNotNone(error.exception.__cause__)
        self.assertTrue((self.build / "product.o").exists())

    def test_output_cannot_create_policy_or_git_state(self):
        for path in (
            self.interlock / "manifest.json",
            self.policy_home / "SUSPENDED",
            self.worktree / ".git/new-output.json",
        ):
            with self.subTest(path=path), self.assertRaises(lease.LeaseError):
                cleanup.write_private_new(path, b"not permitted")
            self.assertFalse(path.exists())

    def test_lsof_is_nul_delimited_and_ignores_only_owned_directory_descriptors(self):
        output = (
            f"p{os.getpid()}\0\nf91\0tDIR\0D0x1\0i22\0n/owned/dir\0\n"
            f"f92\0tREG\0D0x1\0i23\0n/open\nname\0\n"
            "p123\0\nf91\0tREG\0D0x1\0i24\0n/other/open\0\n"
        )
        result = subprocess.CompletedProcess([], 0, output, "")
        with mock.patch.object(cleanup.subprocess, "run", return_value=result):
            paths, identities = cleanup.open_file_inventory(frozenset({91}))
        self.assertNotIn("/owned/dir", paths)
        self.assertIn("/open\nname", paths)
        self.assertEqual(identities, frozenset({(1, 23), (1, 24)}))
        for result in (
            subprocess.CompletedProcess([], 1, "", ""),
            subprocess.CompletedProcess([], 0, output, "warning: incomplete"),
            subprocess.CompletedProcess([], 0, "not machine-readable", ""),
            subprocess.CompletedProcess([], 0, output + "f9\0tREG\0n/incomplete\0", ""),
        ):
            with mock.patch.object(cleanup.subprocess, "run", return_value=result):
                with self.assertRaises(lease.LeaseError):
                    cleanup.open_file_inventory()

    def test_legacy_apply_refuses_before_any_production_side_effect(self):
        env = {key: value for key, value in self.env.items() if not key.startswith("APPLE_BUILD_")}
        for script in ("reclaim-disk.sh", "prune-deriveddata.sh"):
            result = subprocess.run(
                ["/bin/bash", str(ROOT / "tools" / script)], env=env,
                text=True, capture_output=True, timeout=10,
            )
            self.assertEqual(result.returncode, 75)
            self.assertIn("retired", result.stderr)
        self.assertFalse((self.home / "Library/Logs").exists())

    def file_targets(self, count):
        paths = [self.build / f"part-{i}.o" for i in range(count)]
        for path in paths:
            path.write_bytes(b"small fixture")
        self.write_release(target=paths[0])
        release = json.loads(self.release.read_text())
        release["targets"] = [
            {"identity": cleanup.identity_document(path), "kind": "worktree-apple-build"}
            for path in paths
        ]
        self.write_json(self.release, release)
        return paths

    def test_release_parsing_and_location_work_scale_linearly(self):
        for count in (3, 6):
            with self.subTest(count=count):
                self.file_targets(count)
                with mock.patch.object(cleanup, "parse_release_record", wraps=cleanup.parse_release_record) as parses:
                    manifest = cleanup.inventory([self.release], current_time=self.future)
                self.assertEqual(parses.call_count, 1)
                self.write_json(self.manifest, manifest)
                with mock.patch.object(cleanup, "parse_release_record", wraps=cleanup.parse_release_record) as parses, \
                     mock.patch.object(cleanup, "validate_target_location", wraps=cleanup.validate_target_location) as locations, \
                     mock.patch.object(cleanup.policy, "reference", wraps=cleanup.policy.reference) as references:
                    cleanup.validate_manifest(self.manifest, current_time=self.future)
                self.assertEqual(parses.call_count, 1)
                self.assertEqual(locations.call_count, 2 * count)
                # Shared evidence and the shared release are freshly read once
                # at the inspection boundary, not once per target.
                self.assertEqual(references.call_count, 2)

    def test_indexed_evidence_membership_deduplicates_shared_references(self):
        for count in (4, 12):
            self.file_targets(count)
            manifest = cleanup.inventory([self.release], current_time=self.future)
            original = cleanup.TargetIndex.contains
            calls = []
            def contains(index, path):
                calls.append(path)
                return original(index, path)
            with mock.patch.object(cleanup.TargetIndex, "contains", contains):
                cleanup.validate_disjoint_targets(manifest["targets"])
            self.assertEqual(len(calls), 2)
        index = cleanup.TargetIndex([Path("/cache/b"), Path("/cache/ab")])
        self.assertTrue(index.contains(Path("/cache/ab/child")))
        self.assertTrue(index.contains(Path("/cache/b")))
        self.assertFalse(index.contains(Path("/cache/abc")))
        self.assertFalse(index.contains(Path("/cache/a")))
        for roots in (
            [Path("/cache/ab/child"), Path("/cache/ab")],
            [Path("/cache/b"), Path("/cache/b")],
        ):
            with self.assertRaisesRegex(lease.LeaseError, "overlapping"):
                cleanup.TargetIndex(roots)

    def test_shared_release_change_during_inspection_is_not_memoized_away(self):
        self.file_targets(3)
        original = cleanup.scan_tree
        calls = 0
        def scan(*args, **kwargs):
            nonlocal calls
            calls += 1
            result = original(*args, **kwargs)
            if calls == 2:
                self.release.write_text(self.release.read_text() + "\n")
            return result
        with mock.patch.object(cleanup, "scan_tree", side_effect=scan):
            with self.assertRaisesRegex(lease.LeaseError, "changed evidence"):
                cleanup.inventory([self.release], current_time=self.future)
        self.assertFalse(self.manifest.exists())

    def test_reference_index_rechecks_bytes_and_rejects_conflicting_digests(self):
        index = cleanup.ReferenceIndex()
        ref = self.evidence_ref()
        index.add(ref, "fixture")
        index.add(ref, "fixture")
        with mock.patch.object(cleanup.policy, "reference", wraps=cleanup.policy.reference) as reads:
            index.validate()
            index.validate()
        self.assertEqual(reads.call_count, 2)
        with self.assertRaisesRegex(lease.LeaseError, "conflicting"):
            index.add({**ref, "sha256": "0" * 64}, "fixture")
        self.evidence.write_text("late replacement")
        with self.assertRaisesRegex(lease.LeaseError, "changed evidence"):
            index.validate()

    def test_target_and_declared_entry_limits_fail_before_tree_inspection(self):
        manifest = self.make_manifest()
        manifest["targets"] *= 3
        self.write_json(self.manifest, manifest)
        with mock.patch.object(cleanup, "MAX_TARGETS", 2), \
             mock.patch.object(cleanup, "scan_tree") as scan:
            with self.assertRaisesRegex(lease.LeaseError, "target limit"):
                cleanup.validate_manifest(self.manifest, current_time=self.future)
            scan.assert_not_called()
            with mock.patch.object(cleanup, "read_private_document") as read:
                with self.assertRaisesRegex(lease.LeaseError, "target limit"):
                    cleanup.inventory([self.release] * 3, current_time=self.future)
                read.assert_not_called()
        manifest["targets"] = manifest["targets"][:1]
        self.write_json(self.manifest, manifest)
        with mock.patch.object(cleanup, "MAX_TREE_ENTRIES", 1), \
             mock.patch.object(cleanup, "scan_tree") as scan:
            with self.assertRaisesRegex(lease.LeaseError, "aggregate entry limit"):
                cleanup.validate_manifest(self.manifest, current_time=self.future)
            scan.assert_not_called()

    def test_actual_aggregate_entries_and_encoded_document_are_bounded(self):
        self.file_targets(3)
        with mock.patch.object(cleanup, "MAX_TREE_ENTRIES", 2):
            with self.assertRaisesRegex(lease.LeaseError, "aggregate entry limit"):
                cleanup.inventory([self.release], current_time=self.future)
        with mock.patch.object(cleanup.policy, "MAX_DOCUMENT_BYTES", 128):
            with self.assertRaisesRegex(lease.LeaseError, "document limit"):
                cleanup.encode_manifest({"targets": [{"path": "x" * 180}]})
        self.assertFalse(self.manifest.exists())
        self.assertFalse(self.journal.exists())

    def test_directory_entry_limit_stops_enumeration_early(self):
        observed = []
        def children():
            for i in range(12):
                observed.append(i)
                yield argparse.Namespace(name=str(i))
        @contextlib.contextmanager
        def scan(_fd):
            yield children()
        with mock.patch.object(cleanup.os, "scandir", scan):
            with self.assertRaisesRegex(lease.LeaseError, "fixture bound"):
                cleanup.bounded_names(0, 2, "fixture bound")
        self.assertEqual(observed, [0, 1, 2])

    def test_directory_removal_uses_preindexed_children(self):
        for i in range(4):
            directory = self.build / f"nested-{i}"
            directory.mkdir()
            (directory / "part.o").write_bytes(b"fixture")
        target = self.make_manifest()["targets"][0]
        _, entries = cleanup.scan_tree(self.build, minimum_seconds=7 * 24 * 3600, current_time=self.future)
        journal = cleanup.DurableJournal(self.journal, {"fixture": True})
        guard = mock.Mock(clock=lambda: self.future)
        removal = cleanup.TargetRemoval(target, entries, guard, journal, self.open_inventory)
        class CountedDict(dict):
            iterations = 0
            def __iter__(self):
                self.iterations += 1
                return super().__iter__()
        removal.expected = CountedDict(removal.expected)
        try:
            removal.run()
        finally:
            journal.close()
        self.assertEqual(removal.expected.iterations, 0)
        self.assertFalse(self.build.exists())


class CleanupAuthorizationTests(unittest.TestCase):
    """Use the real companion validator, frozen wrapper and kernel locks."""

    def setUp(self):
        from tools.tests.test_apple_maintenance_policy import MaintenancePolicyTests
        self.fixture = MaintenancePolicyTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        f = self.fixture
        self.build = f.repo / ".build/objects"
        self.build.mkdir(parents=True)
        (self.build / "compiled.o").write_bytes(b"fixture")
        self.journal = f.home / "journal.jsonl"
        self.release = f.home / "release.json"
        self.release_evidence = f.home / "release-evidence.txt"
        self.release_evidence.write_text("Separate fixture output release evidence.\n")
        self.release_evidence.chmod(0o600)
        now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        f.write_json(self.release, {
            "schema": 1, "scope": cleanup.SCOPE, "owner": "fixture-owner",
            "session_id": "00000000-0000-0000-0000-000000000001",
            "released_at": cleanup.utc(now - dt.timedelta(days=9)),
            "worktree": cleanup.identity_document(f.repo),
            "evidence": [f.ref(self.release_evidence)],
            "targets": [{"kind": "worktree-apple-build", "identity": cleanup.identity_document(self.build)}],
        })
        original = cleanup.entry_record
        def aged(*args):
            value = original(*args)
            for key in ("mtime_ns", "ctime_ns", "birthtime_ns"):
                value[key] -= 8 * 86400 * 1_000_000_000
            return value
        self.aged = aged
        with mock.patch.object(cleanup, "entry_record", side_effect=aged):
            manifest = cleanup.inventory([self.release], current_time=now)
        f.write_json(f.manifest, manifest)
        files = (
            *cleanup.policy.PROTOCOL_FILES, "tools/apple-build-cleanup.py",
            "tools/lib/apple_build_cleanup.py", "tools/lib/apple_maintenance_policy.py",
            "tools/lib/apple-build-guard.sh",
        )
        for name in files:
            path = f.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, path)
        for item in f.package["cohorts"]:
            if item["name"] == "global-cleanup-entrypoints":
                item["roots"][0]["writers"] = [f.ref(f.repo / name) for name in files]
        f.package["window"]["manifest_sha256"] = cleanup.policy.digest(cleanup.policy.canonical(manifest))
        f.approve()
        f.install()
        rollout = f.namespace / lease.ROLLOUT_NAME
        rollout.write_text("\n".join(lease.REQUIRED_ROLLOUT) + "\n")
        rollout.chmod(0o600)

    def run_apply(self, fault=""):
        f = self.fixture
        code = """
import sys, json
from pathlib import Path
from unittest import mock
sys.path.insert(0, str(Path(sys.argv[1]) / 'tools/lib'))
import apple_build_cleanup as cleanup
import apple_build_lease as lease
original = cleanup.entry_record
def aged(*args):
    value = original(*args)
    for key in ('mtime_ns', 'ctime_ns', 'birthtime_ns'):
        value[key] -= 8 * 86400 * 1_000_000_000
    return value
calls = 0
def opened(_ignored=frozenset()):
    global calls
    calls += 1
    if calls == 2:
        if sys.argv[5] == 'evidence':
            Path(sys.argv[6]).write_text('changed fixture evidence')
        elif sys.argv[5] == 'record':
            (lease.paths()['leases'] / 'unresolved').write_text('fixture')
        elif sys.argv[5] == 'unlock':
            fd = cleanup.policy.inherited_exclusive().lock_fd
            lease.fcntl.flock(fd, lease.fcntl.LOCK_UN)
        elif sys.argv[5] in {'release', 'release-evidence', 'future-evidence', 'approval', 'attestation', 'companion', 'manifest', 'rollout'}:
            home = Path(sys.argv[1]).parent
            paths = {
                'release': home / 'release.json',
                'release-evidence': home / 'release-evidence.txt',
                'future-evidence': home / 'other-release-evidence.txt',
                'approval': home / 'approval.json',
                'attestation': home / 'plozz-current-writers.json',
                'companion': lease.paths()['root'] / cleanup.policy.POLICY_NAME,
                'manifest': Path(sys.argv[2]),
                'rollout': lease.paths()['rollout'],
            }
            path = paths[sys.argv[5]]
            path.write_bytes(path.read_bytes() + b'\\n')
        elif sys.argv[5] == 'writer':
            (Path(sys.argv[1]) / 'writer.sh').write_text('changed fixture writer')
        elif sys.argv[5] == 'registry':
            (Path(sys.argv[1]) / '.git/HEAD').write_text('ref: refs/heads/changed-fixture\\n')
        elif sys.argv[5] == 'suspended':
            (lease.paths()['root'].parent / 'SUSPENDED').touch(mode=0o600)
        elif sys.argv[5] == 'owner-root':
            Path(sys.argv[1]).rename(Path(sys.argv[1]).with_name('moved-fixture'))
    return (('/unrelated/file',), frozenset({(999,999)}))
with mock.patch.object(cleanup, 'entry_record', side_effect=aged), \
     mock.patch.object(cleanup, 'require_no_build_activity'), \
     mock.patch.object(cleanup, 'validate_target_location', wraps=cleanup.validate_target_location) as locations, \
     mock.patch.object(cleanup, 'validate_runtime_scope', wraps=cleanup.validate_runtime_scope) as scopes, \
     mock.patch.object(cleanup, 'parse_release_record', wraps=cleanup.parse_release_record) as releases, \
     mock.patch.object(cleanup.policy, 'check', wraps=cleanup.policy.check) as policies:
    cleanup.apply_manifest(Path(sys.argv[2]), window_id=sys.argv[3],
                           journal_path=Path(sys.argv[4]), open_inventory=opened)
    print(json.dumps({'locations': locations.call_count, 'scopes': scopes.call_count,
                      'releases': releases.call_count, 'policies': policies.call_count,
                      'open_scans': calls}))
"""
        result = subprocess.run([
            str(ROOT / "tools/with-apple-build-lease.sh"), "--exclusive", "test/cleanup",
            "--", sys.executable, "-c", code, str(f.repo), str(f.manifest),
            f.package["window"]["id"], str(self.journal), fault, str(f.evidence),
        ], env=f.env, text=True, capture_output=True, timeout=30)
        return result

    def test_real_exclusive_companion_allows_only_the_synthetic_target(self):
        result = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.build.exists())
        self.assertTrue(self.fixture.writer.exists())
        self.assertIn('"event": "completed"', self.journal.read_text())
        # Wait only for this fixture's exact release finalizer, never host owners.
        import time
        for _ in range(100):
            if not list((self.fixture.namespace / "leases").iterdir()):
                return
            time.sleep(0.02)
        self.fail("fixture lease finalizer did not complete")

    def test_incomplete_executing_entrypoint_fingerprints_refuse(self):
        f = self.fixture
        installed = cleanup.policy.digest((f.namespace / cleanup.policy.POLICY_NAME).read_bytes())
        for item in f.package["cohorts"]:
            if item["name"] == "global-cleanup-entrypoints":
                item["roots"][0]["writers"].pop()
        f.approve()
        f.install(installed)
        result = self.run_apply()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not fully fingerprinted", result.stderr)
        self.assertTrue(self.build.exists())
        self.assertFalse(self.journal.exists())

    def test_evidence_change_during_removal_refuses(self):
        result = self.run_apply("evidence")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed evidence", result.stderr)
        self.assertTrue((self.build / "compiled.o").exists())
        self.assertIn('"event": "stopped"', self.journal.read_text())

    def test_new_unresolved_record_during_removal_refuses(self):
        result = self.run_apply("record")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown file in lease registry", result.stderr)
        self.assertTrue((self.build / "compiled.o").exists())
        self.assertEqual((self.fixture.namespace / "leases/unresolved").read_text(), "fixture")

    def test_unlocked_kernel_capability_is_not_reacquired(self):
        result = self.run_apply("unlock")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exclusive kernel lock is not held", result.stderr)
        self.assertTrue((self.build / "compiled.o").exists())

    def replace_manifest(self, releases):
        f = self.fixture
        installed = cleanup.policy.digest((f.namespace / cleanup.policy.POLICY_NAME).read_bytes())
        with mock.patch.object(cleanup, "entry_record", side_effect=self.aged):
            manifest = cleanup.inventory(releases)
        f.write_json(f.manifest, manifest)
        f.package["window"]["manifest_sha256"] = cleanup.policy.digest(cleanup.policy.canonical(manifest))
        f.approve()
        f.install(installed)

    def assert_runtime_counts(self, count):
        f = self.fixture
        record = json.loads(self.release.read_text())
        files = [self.build / "compiled.o"]
        for i in range(count - 1):
            path = self.build / f"part-{i}.o"
            path.write_bytes(b"fixture")
            files.append(path)
        record["targets"] = [
            {"identity": cleanup.identity_document(path), "kind": "worktree-apple-build"}
            for path in files
        ]
        f.write_json(self.release, record)
        self.replace_manifest([self.release])
        result = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        counts = json.loads(result.stdout)
        self.assertEqual(counts, {
            "locations": 4 * count, "scopes": 1, "releases": 1,
            "policies": 2 + 2 * count, "open_scans": 3 * count,
        })
        self.assertTrue(all(not path.exists() for path in files))
        import time
        for _ in range(100):
            if not list((f.namespace / "leases").iterdir()):
                return
            time.sleep(0.02)
        self.fail("fixture finalizer did not finish")

    def test_two_target_runtime_counts_are_linear(self):
        self.assert_runtime_counts(2)

    def test_four_target_runtime_counts_are_linear(self):
        self.assert_runtime_counts(4)

    def assert_late_refusal(self, fault, message=None):
        result = self.run_apply(fault)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        if message:
            self.assertIn(message, result.stderr)
        self.assertTrue((self.build / "compiled.o").exists())
        self.assertIn('"event": "stopped"', self.journal.read_text())

    def test_release_bytes_remain_fresh_after_initial_parse(self):
        self.assert_late_refusal("release", "changed evidence")

    def test_release_evidence_remains_fresh_after_initial_parse(self):
        self.assert_late_refusal("release-evidence", "changed evidence")

    def test_approval_change_is_not_hidden_by_structural_scope_reuse(self):
        self.assert_late_refusal("approval", "changed evidence")

    def test_attestation_change_is_not_hidden_by_structural_scope_reuse(self):
        self.assert_late_refusal("attestation", "changed evidence")

    def test_companion_change_is_not_hidden_by_structural_scope_reuse(self):
        self.assert_late_refusal("companion", "authorization changed")

    def test_writer_change_is_not_hidden_by_structural_scope_reuse(self):
        self.assert_late_refusal("writer", "writer changed")

    def test_registry_change_is_not_hidden_by_structural_scope_reuse(self):
        self.assert_late_refusal("registry", "registered roots/HEADs changed")

    def test_manifest_change_is_not_hidden_by_structural_scope_reuse(self):
        self.assert_late_refusal("manifest", "manifest changed")

    def test_suspension_is_still_checked_for_every_removal(self):
        self.assert_late_refusal("suspended", "suspended")

    def test_rollout_change_is_still_checked_for_every_removal(self):
        self.assert_late_refusal("rollout")

    def test_owner_root_replacement_is_still_checked_globally(self):
        result = self.run_apply("owner-root")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.fixture.home / "moved-fixture/.build/objects/compiled.o").exists())
        self.assertIn('"event": "stopped"', self.journal.read_text())

    def test_future_target_evidence_change_stops_the_current_target_too(self):
        f = self.fixture
        other = f.repo / ".build/other.o"
        other.write_bytes(b"preserved future target")
        evidence = f.home / "other-release-evidence.txt"
        evidence.write_text("Separate future-target evidence.\n")
        evidence.chmod(0o600)
        release = json.loads(self.release.read_text())
        release["evidence"] = [f.ref(evidence)]
        release["targets"] = [{"identity": cleanup.identity_document(other), "kind": "worktree-apple-build"}]
        other_release = f.home / "other-release.json"
        f.write_json(other_release, release)
        self.replace_manifest([self.release, other_release])
        self.assert_late_refusal("future-evidence", "changed evidence")
        self.assertTrue(other.exists())

    def test_cli_does_not_write_bytecode_or_activate_anything(self):
        f = self.fixture
        env = dict(f.env)
        env.pop("PYTHONDONTWRITEBYTECODE", None)
        before = {str(path) for path in f.home.rglob("*")}
        result = subprocess.run(
            [sys.executable, "-B", str(f.repo / "tools/apple-build-cleanup.py"), "--help"],
            env=env, capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, {str(path) for path in f.home.rglob("*")})
        self.assertFalse(list(f.repo.rglob("__pycache__")))


if __name__ == "__main__":
    unittest.main()
