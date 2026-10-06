import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "main-landing.py"
SPEC = importlib.util.spec_from_file_location("main_landing", PATH)
MAIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MAIN)


class MainLandingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repo"
        subprocess.run(["git", "init", "-q", self.root], check=True)
        subprocess.run(["git", "-C", self.root, "-c", "user.name=Fixture",
                        "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgSign=false",
                        "commit", "--allow-empty", "-qm", "fixture"], check=True)
        self.worktree = Path(self.temporary.name) / "linked"
        subprocess.run(["git", "-C", self.root, "worktree", "add", "-qb", "feature", self.worktree], check=True)

    def child(self, *, pass_fds=(), keep_environment=False):
        env = dict(os.environ)
        if not keep_environment:
            env.pop("PLOZZ_MAIN_LANDING_FD", None)
        code = (
            "import importlib.util,pathlib;"
            f"s=importlib.util.spec_from_file_location('m',{str(PATH)!r});"
            "m=importlib.util.module_from_spec(s);s.loader.exec_module(m);"
            f"\nwith m.landing(pathlib.Path({str(self.worktree)!r}),timeout=0): print('acquired')"
        )
        return subprocess.run([sys.executable, "-c", code], env=env, pass_fds=pass_fds,
                              capture_output=True, text=True, timeout=10)

    def test_linked_worktrees_share_lock_and_release_after_failure(self):
        with self.assertRaisesRegex(RuntimeError, "owned failure"):
            with MAIN.landing(self.root):
                blocked = self.child()
                self.assertNotEqual(blocked.returncode, 0)
                self.assertIn("deadline", blocked.stderr)
                raise RuntimeError("owned failure")
        self.assertEqual(self.child().returncode, 0)

    def test_nested_hook_reenters_without_releasing_parent_lock(self):
        with MAIN.landing(self.root) as fd:
            nested = self.child(pass_fds=(fd,), keep_environment=True)
            self.assertEqual(nested.returncode, 0, nested.stderr)
            self.assertNotEqual(self.child().returncode, 0)
        self.assertEqual(self.child().returncode, 0)

    def test_real_git_push_preserves_parent_lock_into_hook(self):
        remote = Path(self.temporary.name) / "remote.git"
        subprocess.run(["git", "init", "--bare", "-q", remote], check=True)
        hooks = self.root / "hooks"
        hooks.mkdir()
        hook = hooks / "pre-push"
        hook.write_text(
            f"#!{sys.executable}\n"
            "import importlib.util,pathlib\n"
            f"s=importlib.util.spec_from_file_location('landing',{str(PATH)!r})\n"
            "m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
            f"with m.landing(pathlib.Path({str(self.root)!r}),timeout=0): print('hook reentered')\n"
        )
        hook.chmod(0o755)
        with MAIN.landing(self.root) as fd:
            result = subprocess.run(
                ["git", "-c", f"core.hooksPath={hooks}", "push", str(remote), "HEAD:main"],
                cwd=self.root, pass_fds=(fd,), capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("hook reentered", result.stdout)
            self.assertNotEqual(self.child().returncode, 0)

    def test_forged_or_closed_inherited_descriptor_fails(self):
        with patch.dict(os.environ, {"PLOZZ_MAIN_LANDING_FD": "99999"}):
            with self.assertRaises(OSError):
                with MAIN.landing(self.root):
                    self.fail("invalid ownership accepted")

    def test_feature_push_never_waits_for_main_or_runs_gates(self):
        with patch.object(MAIN, "landing") as lock, patch.object(MAIN.subprocess, "run") as run:
            MAIN.pre_push(self.root, "refs/heads/feature a refs/heads/feature b\n")
        lock.assert_not_called()
        run.assert_not_called()

    def test_main_push_keeps_all_localization_gates_and_inherited_lock(self):
        with patch.object(MAIN.subprocess, "check_output", return_value=".git\n"), \
                patch.object(MAIN.subprocess, "run") as run:
            MAIN.pre_push(self.root, "refs/heads/feature a refs/heads/main b\n")
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(len(commands), 3)
        self.assertEqual(commands[0], ["tools/l10n-guard.sh"])
        self.assertIn("--validate-only", commands[1])
        self.assertNotIn("--reuse-if-unchanged", commands[1])
        self.assertIn("--check-snapshot", commands[2])
        self.assertTrue(all(call.kwargs["pass_fds"] for call in run.call_args_list))
