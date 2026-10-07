"""Review regressions: no implicit resets and bounded private release storage."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
from unittest import mock

from tools.tests import test_plozz_build_lifecycle as fixtures
from tools.tests.test_fastlane_pipeline import FASTFILE_HARNESS
from tools.tests.test_l10n_freshness import SYNC

ROOT = fixtures.ROOT
lifecycle = fixtures.lifecycle


class BuildLifecycleRegressions(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.LifecycleTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.f = self.fixture

    def fastlane_plan(self, count=1):
        repo = self.f.repo
        (repo / "fastlane").mkdir(exist_ok=True)
        for name in ("Fastfile", "testflight_pipeline.rb"):
            shutil.copyfile(ROOT / "fastlane" / name, repo / "fastlane" / name)
        (repo / "tools/lib").mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / "tools/lib/apple_build_lease.rb", repo / "tools/lib/apple_build_lease.rb")
        source = FASTFILE_HARNESS.split("module AppleBuildLease")[0] + r"""
def harness.system(*args, **descriptors)
  (@registrations ||= []) << args
  true
end
options = []
Integer(ENV.fetch("COUNT")).times do
  harness.instance_variable_set(:@package_writer_id, nil)
  options << %w[Plozz PlozziOS].map { |scheme| harness.swift_package_build_options(scheme: scheme) }
end
puts JSON.generate(options: options, registrations: harness.instance_variable_get(:@registrations))
"""
        prefix = self.f.home / "external-prefix"
        prefix.mkdir(exist_ok=True)
        result = subprocess.run(
            ["ruby", "-e", source], cwd=repo, capture_output=True, text=True, check=True,
            env={**self.f.env, "COUNT": str(count),
                 "PLOZZ_FASTLANE_CLONED_SOURCE_PACKAGES": str(prefix),
                 "APPLE_BUILD_LEASE_PROOF_FD": "10", "APPLE_BUILD_LEASE_LOCK_FD": "11"},
            timeout=30,
        )
        return json.loads(result.stdout)

    def test_timeout_preserves_registered_root_and_next_registration(self):
        derived = self.f.worktree / ".build/tests"
        before = self.f.register(derived)["resources"][0]["id"]
        artifact = derived / "retained.o"
        artifact.write_bytes(b"owned fixture")
        source = (ROOT / "tools/run-tests.sh").read_text()
        function = "xcodebuild_test() {" + source.split("xcodebuild_test() {", 1)[1].split(
            "\n# --- Decide", 1
        )[0]
        script = """
_xcb_once() { echo called >> "$CALLS"; return 124; }
has_verdict() { return 1; }
reported_bundles_count() { echo 0; }
""" + function + '\nxcodebuild_test "$LOG"\n'
        calls = self.f.home / "calls"
        result = subprocess.run(
            ["bash", "-c", script], cwd=self.f.worktree, text=True, capture_output=True,
            env={**self.f.env, "PLOZZ_DERIVED_DATA": str(derived), "CALLS": str(calls),
                 "LOG": str(self.f.home / "run.log")}, timeout=10,
        )
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertTrue(artifact.exists(), "a timeout must not reset registered DerivedData")
        self.assertEqual(calls.read_text().splitlines(), ["called"])
        self.assertEqual(self.f.register(derived)["resources"][0]["id"], before)

    def test_clean_flags_refuse_before_any_build_or_cache_write(self):
        result = subprocess.run(
            ["bash", str(ROOT / "tools/deploy-tv.sh"), "--clean"], cwd=self.f.repo,
            capture_output=True, text=True, env=self.f.env, timeout=15,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("no longer supported", result.stderr)
        result = subprocess.run(
            [sys.executable, "-B", str(ROOT / "tools/l10n-sync.py"), "--clean"],
            cwd=self.f.repo, capture_output=True, text=True, env=self.f.env, timeout=15,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("no longer supported", result.stderr)
        with mock.patch.object(sys, "argv", ["l10n-sync.py", "--clean"]), \
             mock.patch.object(SYNC, "CATALOG", self.f.repo / "missing-catalog"), \
             mock.patch.object(SYNC, "exec_under_build_lease") as acquire:
            with self.assertRaises(SystemExit) as raised:
                SYNC.main()
            self.assertEqual(raised.exception.code, 2)
            acquire.assert_not_called()

    def test_external_invocation_with_missing_parent_is_registered(self):
        prefix = self.f.home / "external-prefix"
        prefix.mkdir()
        leaf = prefix / "private-invocation" / "Plozz"
        state = self.f.register(leaf, kind="package-workspace")
        self.assertTrue(leaf.is_dir())
        self.assertEqual(state["resources"][0]["identity"]["path"], str(leaf))
        self.assertEqual(self.f.register(leaf, kind="package-workspace")["resources"][0]["id"],
                         state["resources"][0]["id"])

    def test_unexplained_root_replacement_is_still_refused(self):
        derived = self.f.worktree / ".build/tests"
        original = self.f.register(derived)["resources"][0]["id"]
        derived.rename(derived.with_name("retained-original"))
        derived.mkdir()
        result = self.f.leased("register", "--repo", self.f.worktree,
                               "--root", "derived-data", derived)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owned build root replaced or repurposed", result.stderr)
        self.assertEqual(lifecycle.read_state(lifecycle.state_path())["resources"][0]["id"], original)

    def test_external_prefix_symlink_and_replacement_are_refused(self):
        prefix = self.f.home / "prefix"
        prefix.mkdir()
        alias = self.f.home / "alias"
        alias.symlink_to(prefix, target_is_directory=True)
        result = self.f.leased("register", "--repo", self.f.repo,
                               "--root", "package-workspace", alias / "invocation/Plozz")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((prefix / "invocation").exists())
        driver = """
import contextlib, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import plozz_build_lifecycle as lifecycle
prefix = Path(sys.argv[3])
original = lifecycle.registry
@contextlib.contextmanager
def replaced_while_waiting():
    prefix.rename(prefix.with_name("retained-prefix"))
    prefix.mkdir()
    with original() as state:
        yield state
lifecycle.registry = replaced_while_waiting
try:
    lifecycle.register(Path(sys.argv[2]), [("package-workspace", prefix / "invocation/Plozz")])
except lifecycle.lease.LeaseError as error:
    assert "anchor changed while waiting" in str(error), str(error)
else:
    raise AssertionError("replaced prefix was accepted")
"""
        result = subprocess.run(
            [str(ROOT / "tools/with-apple-build-lease.sh"), "test/prefix-replacement", "--",
             sys.executable, "-B", "-c", driver, str(ROOT / "tools/lib"), str(self.f.repo), str(prefix)],
            env=self.f.env, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((prefix / "invocation").exists())
        self.assertFalse((self.f.home / "retained-prefix/invocation").exists())

    def test_actual_fastlane_commands_prepare_private_leaves_and_retain_evidence(self):
        plans = [self.fastlane_plan(), self.fastlane_plan()]
        paths = set()
        for plan in plans:
            for command in plan["registrations"]:
                result = self.f.leased(*command[3:])
                self.assertEqual(result.returncode, 0, result.stderr)
            for options in plan["options"][0]:
                for key in ("cloned_source_packages_path", "derived_data_path"):
                    path = Path(options[key])
                    self.assertNotIn(path, paths)
                    self.assertTrue(path.is_dir())
                    paths.add(path)
            state = lifecycle.read_state(lifecycle.state_path())
            self.assertEqual(len(state["resources"]), 3)
            evidence = next(r for r in state["resources"] if r["kind"] == "release-evidence")
            self.assertTrue(evidence["release_hold"])
            for name in ("release.xcarchive", "symbols.dSYM"):
                (Path(evidence["identity"]["path"]) / name).mkdir(exist_ok=True)
        self.assertTrue((Path(evidence["identity"]["path"]) / "symbols.dSYM").is_dir())
        # A private writer must not create through an alias or outside its nominated container.
        container = next(r for r in state["resources"] if r["kind"] == "package-workspace")
        root = Path(container["identity"]["path"])
        (root / "alias").symlink_to(self.f.home, target_is_directory=True)
        for child in (root / "alias/escaped", self.f.home / "escaped"):
            result = self.f.leased("register", "--repo", self.f.repo,
                                   "--root", "package-workspace", root,
                                   "--private-child", root, child)
            self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.f.home / "escaped").exists())

    def test_257_fastlane_invocations_register_bounded_containers(self):
        plan = self.fastlane_plan(257)
        paths = []
        roots = set()
        for command in plan["registrations"]:
            for i, argument in enumerate(command):
                if argument == "--root":
                    roots.add(tuple(command[i + 1:i + 3]))
        for invocation in plan["options"]:
            for options in invocation:
                paths.extend((options["cloned_source_packages_path"], options["derived_data_path"]))
        self.assertEqual(len(paths), len(set(paths)), "concurrent writers must keep private leaves")
        self.assertEqual(len(roots), 3, "invocation IDs must not grow the registry")
        self.assertEqual({kind for kind, _ in roots},
                         {"package-workspace", "derived-data", "release-evidence"})
        # Repeated metadata publication, not hundreds of package/build trees.
        payload = self.f.home / "registration-plan.json"
        payload.write_text(json.dumps(sorted(roots)))
        driver = """
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import plozz_build_lifecycle as lifecycle
roots = [(kind, Path(path)) for kind, path in json.loads(Path(sys.argv[3]).read_text())]
for _ in range(257):
    lifecycle.register(Path(sys.argv[2]), roots)
state = lifecycle.read_state(lifecycle.state_path())
assert len(state["resources"]) == 3
assert any(r["release_hold"] and r["kind"] == "release-evidence" for r in state["resources"])
print(lifecycle.state_path().stat().st_size)
"""
        result = subprocess.run(
            [str(ROOT / "tools/with-apple-build-lease.sh"), "test/repeated-release", "--",
             sys.executable, "-B", "-c", driver, str(ROOT / "tools/lib"), str(self.f.repo), str(payload)],
            env=self.f.env, capture_output=True, text=True, timeout=240,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(int(result.stdout), 8192)
        self.assertEqual(len(self.f.register(self.f.worktree / ".build/new")["resources"]), 4)


if __name__ == "__main__":
    unittest.main()
